#!/usr/bin/env python3
"""whoop_capture.py — headless WHOOP BLE frame capture for protocol RE, on Linux (BlueZ via bleak).

Scans for a WHOOP strap you own, connects, triggers just-works bonding, subscribes to the strap's
custom notify channels (and the standard Heart Rate profile for a ground-truth cross-check), and
records every complete frame to a JSON file. That file is the bridge to the rest of the workflow:

    whoop_capture.py  →  capture.json  →  whoop-decode (Swift)  /  WhoopProtocol parity tests

The capture format matches the macOS app's frame-export hook exactly: a JSON array of
    {"hex": <frame hex>, "char": <source uuid>, "ts_ms": <unix millis>, "hr": <live bpm or null>}
so frames captured here and on a Mac are interchangeable.

This tool is READ-ONLY with respect to your strap apart from the single bonding handshake every
client must perform; it records data the strap already broadcasts. Use only on a strap you own.

Usage:
    python3 whoop_capture.py --model whoop5 --out capture.json
    python3 whoop_capture.py --model whoop4 --address AA:BB:CC:DD:EE:FF --duration 120

Requires: bleak  (pip install -r requirements.txt)
"""

import argparse
import asyncio
import json
import signal
import time

from bleak import BleakClient, BleakScanner

import whoop_frame as wf

# --- GATT UUIDs (from docs/BLE_REVERSE_ENGINEERING.md) ---------------------------------------------

WHOOP4 = {
    "service": "61080001-8d6d-82b8-614a-1c8cb0f8dcc6",
    "cmd_write": "61080002-8d6d-82b8-614a-1c8cb0f8dcc6",
    "notify": [
        "61080003-8d6d-82b8-614a-1c8cb0f8dcc6",
        "61080004-8d6d-82b8-614a-1c8cb0f8dcc6",
        "61080005-8d6d-82b8-614a-1c8cb0f8dcc6",
    ],
}
WHOOP5 = {
    "service": "fd4b0001-cce1-4033-93ce-002d5875f58a",
    "cmd_write": "fd4b0002-cce1-4033-93ce-002d5875f58a",
    "notify": [
        "fd4b0003-cce1-4033-93ce-002d5875f58a",
        "fd4b0004-cce1-4033-93ce-002d5875f58a",
        "fd4b0005-cce1-4033-93ce-002d5875f58a",
        "fd4b0007-cce1-4033-93ce-002d5875f58a",
    ],
}
HR_MEASUREMENT = "00002a37-0000-1000-8000-00805f9b34fb"   # standard HR (works unbonded)

# --- Capture state --------------------------------------------------------------------------------


class Capture:
    def __init__(self, family: str, out_path: str):
        self.family = family
        self.out_path = out_path
        # Family-aware offload plumbing: the inner record (where the packet-type byte lives) starts at
        # offset 8 on WHOOP 5 (puffin) but offset 4 on WHOOP 4 (Harvard), and the metadata/ack framing
        # differs accordingly. Pick the right offsets + helpers once so the hot path stays generic.
        if family == "whoop5":
            self.inner_off = wf.WHOOP5_INNER_OFF
            self.meta_type_off = wf.WHOOP5_META_TYPE_OFF
            self._end_data_fn = wf.history_end_data
            self._build_ack_fn = wf.build_history_ack
            self._build_cmd_fn = wf.build_puffin_command
        else:
            self.inner_off = wf.WHOOP4_INNER_OFF
            self.meta_type_off = wf.WHOOP4_META_TYPE_OFF
            self._end_data_fn = wf.history_end_data_whoop4
            self._build_ack_fn = wf.build_history_ack_whoop4
            self._build_cmd_fn = wf.build_command_frame
        self.records = []
        self.latest_hr = None
        self.reassemblers = {}     # char uuid -> Reassembler
        self._dirty = 0
        # Historical chunk-ack plumbing (set up by run() only in --history-ack mode). The notify
        # callback must stay non-blocking, so it only ENQUEUES end_data; a separate task does the
        # confirmed GATT write. Re-ack the same cursor at most every `ack_retry_s` so a burst of
        # identical HISTORY_ENDs doesn't spam acks, but a still-stuck cursor is retried.
        self.ack_queue = None
        self._last_end = None
        self._last_ack_ms = 0
        self.ack_retry_s = 2.0
        self.type47_count = 0
        self.history_complete = 0    # HISTORY_COMPLETE (METADATA meta_type 3) markers seen
        self.last_frame_ms = 0       # wall-clock of the most recent frame (for idle detection)

    def on_hr(self, _sender, data: bytearray):
        hr = wf.parse_standard_hr(bytes(data))
        if hr is not None:
            self.latest_hr = hr

    def on_frame_notify(self, sender, data: bytearray):
        char = str(getattr(sender, "uuid", sender)).lower()
        ra = self.reassemblers.get(char)
        if ra is None:
            ra = wf.Reassembler(self.family)
            self.reassemblers[char] = ra
        for frame in ra.feed(bytes(data)):
            self.last_frame_ms = int(time.time() * 1000)
            self.records.append({
                "hex": frame.hex(),
                "char": char,
                "ts_ms": self.last_frame_ms,
                "hr": self.latest_hr,
            })
            if len(frame) > self.inner_off:
                t = frame[self.inner_off]
                if t == wf.PACKET_HISTORICAL_DATA:
                    self.type47_count += 1          # the prize — log it loudly in run()
                elif t == wf.PACKET_METADATA:
                    if len(frame) > self.meta_type_off \
                            and frame[self.meta_type_off] == wf.META_HISTORY_COMPLETE:
                        self.history_complete += 1   # store fully drained at least once
                    if self.ack_queue is not None:
                        self._maybe_queue_ack(frame)
        # Deliberately NO disk flush here. A historical offload arrives as a fast burst (~21 KB in
        # ~2.6 s); a blocking JSON rewrite on this notification callback drops BlueZ notifications and
        # loses frames (observed: ~79% of a burst lost, including all type-47 biometric records). We
        # buffer in memory and flush once at the end / on Ctrl-C — the hot path stays non-blocking.

    def _maybe_queue_ack(self, frame: bytes):
        """Enqueue a HISTORY_END's end_data for acking (non-blocking — the write happens in the
        ack-sender task). Dedups a burst of identical cursors but retries a stuck one."""
        end_data = self._end_data_fn(frame)
        if end_data is None:
            return
        now_ms = int(time.time() * 1000)
        if end_data == self._last_end and (now_ms - self._last_ack_ms) < self.ack_retry_s * 1000:
            return
        self._last_end = end_data
        self._last_ack_ms = now_ms
        try:
            self.ack_queue.put_nowait(end_data)
        except Exception:
            pass

    def flush(self):
        if not self.records:
            return
        tmp = self.out_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.records, f, indent=1)
        import os
        os.replace(tmp, self.out_path)
        self._dirty = 0


# --- Connect + capture ----------------------------------------------------------------------------


async def find_address(cfg, name_filter):
    print(f"scanning for WHOOP service {cfg['service']} …")
    device = await BleakScanner.find_device_by_filter(
        lambda d, ad: (cfg["service"].lower() in [s.lower() for s in (ad.service_uuids or [])])
        or (name_filter and name_filter.lower() in (d.name or "").lower()),
        timeout=20.0,
    )
    return device


async def run(args):
    cfg = WHOOP5 if args.model == "whoop5" else WHOOP4
    cap = Capture(args.model, args.out)

    target = args.address
    if not args.address:
        device = await find_address(cfg, args.name_filter)
        if device is None:
            print("no WHOOP strap found. Make sure it is awake, near, and not bonded to a phone.")
            return
        target = device
        print(f"found {device.name or '?'} @ {device.address}")
    else:
        # Even with an explicit --address, resolve the device via a scan first: BlueZ connects far more
        # reliably to a freshly-discovered device object than to a bare address, especially for a strap
        # that just woke (a bare-address connect raises "Device ... not found" if BlueZ has no cache).
        print(f"scanning to resolve {args.address} …")
        device = await BleakScanner.find_device_by_address(args.address, timeout=20.0)
        if device is None:
            print(f"{args.address} not found. Wake the strap (wear or tap it so it advertises) and "
                  f"make sure the phone's Bluetooth is OFF, then retry.")
            return
        target = device

    stop = asyncio.Event()

    async with BleakClient(target) as client:
        print(f"connected: {client.is_connected}")

        # Just-works bond: the protocol bonds via a single CONFIRMED WRITE (the session frame below),
        # not an explicit pairing call — that's how the app does it. An explicit BlueZ pair() actually
        # FAILS on the WHOOP 5 (AuthenticationFailed) and tears down the link, so it is opt-in only.
        if args.pair:
            try:
                await client.pair()
                print("paired")
            except Exception as e:
                print(f"pair() failed (continuing; bond comes from the confirmed write): {e}")

        # Arm the chunk-ack queue BEFORE subscribing, so a HISTORY_END arriving in the very first
        # post-bond burst is enqueued rather than dropped.
        if args.history_ack:
            cap.ack_queue = asyncio.Queue()

        # Standard HR (unbonded) → ground-truth bpm for correlation.
        try:
            await client.start_notify(HR_MEASUREMENT, cap.on_hr)
            print("subscribed: standard HR (2a37)")
        except Exception as e:
            print(f"standard HR not available: {e}")

        # Subscribe the custom notify channels first, so the post-bond flood is captured.
        for u in cfg["notify"]:
            try:
                await client.start_notify(u, cap.on_frame_notify)
                print(f"subscribed: {u}")
            except Exception as e:
                print(f"could not subscribe {u}: {e}")

        # Open the session / trigger bonding.
        if args.model == "whoop5":
            bond = wf.WHOOP5_CLIENT_HELLO
        else:
            bond = wf.build_command_frame(wf.CMD_GET_BATTERY_LEVEL)
        try:
            await client.write_gatt_char(cfg["cmd_write"], bond, response=True)
            print(f"wrote session/bond frame to {cfg['cmd_write']}: {bond.hex()}")
        except Exception as e:
            print(f"bond/session write failed: {e}")

        # EXPERIMENTAL post-hello probes (WHOOP 5 only): try to coax the strap into streaming by
        # sending candidate puffin commands. The command numbers are UNVERIFIED guesses (4.0 numbers
        # on the 5.0 transport) — all non-destructive reads/toggles. Off unless --probe.
        if (args.probe or args.history_only or args.commands) and args.model == "whoop5":
            await asyncio.sleep(1.0)
            if args.commands:
                # Elicit COMMAND_RESPONSE (type 36) frames to map the WHOOP 5 response payloads at +4.
                # Each is a non-destructive read; the response echoes the command number, which selects
                # the payload layout. GET_CLOCK takes an EMPTY payload (a wrong length is ignored).
                probes = [
                    (wf.PUFFIN_CMD_GET_BATTERY_LEVEL, b"\x00", "GET_BATTERY_LEVEL"),
                    (wf.PUFFIN_CMD_GET_CLOCK, b"", "GET_CLOCK"),
                    (wf.PUFFIN_CMD_REPORT_VERSION_INFO, b"\x00", "REPORT_VERSION_INFO"),
                    (wf.PUFFIN_CMD_GET_EXTENDED_BATTERY_INFO, b"\x00", "GET_EXTENDED_BATTERY_INFO"),
                    (wf.PUFFIN_CMD_GET_BATTERY_PACK_INFO, b"\x00", "GET_BATTERY_PACK_INFO"),
                    (wf.PUFFIN_CMD_GET_DATA_RANGE, b"\x00", "GET_DATA_RANGE"),
                ]
            elif args.history_only:
                # Turn the realtime streams OFF first so they don't starve the historical offload
                # (mirrors the 4.0 handshake, which disables the type-43 flood before requesting
                # history), then ask for the data range + the historical store.
                probes = [
                    (wf.PUFFIN_CMD_TOGGLE_REALTIME_HR, b"\x00", "TOGGLE_REALTIME_HR(off)"),
                    (wf.PUFFIN_CMD_SEND_R10_R11_REALTIME, b"\x00", "SEND_R10_R11_REALTIME(off)"),
                    (wf.PUFFIN_CMD_GET_DATA_RANGE, b"\x00", "GET_DATA_RANGE"),
                    (wf.PUFFIN_CMD_SEND_HISTORICAL_DATA, b"\x00", "SEND_HISTORICAL_DATA"),
                ]
            else:
                probes = [
                    (wf.PUFFIN_CMD_TOGGLE_REALTIME_HR, b"\x01", "TOGGLE_REALTIME_HR"),
                    (wf.PUFFIN_CMD_SEND_R10_R11_REALTIME, b"\x01", "SEND_R10_R11_REALTIME"),
                    (wf.PUFFIN_CMD_GET_CLOCK, b"", "GET_CLOCK"),
                    (wf.PUFFIN_CMD_SEND_HISTORICAL_DATA, b"\x00", "SEND_HISTORICAL_DATA"),
                ]
            seq = 2
            for cmd, pl, name in probes:
                frame = wf.build_puffin_command(cmd, seq=seq, payload=pl)
                try:
                    await client.write_gatt_char(cfg["cmd_write"], frame, response=False)
                    print(f"probe → {name} (cmd {cmd}): {frame.hex()}")
                except Exception as e:
                    print(f"probe {name} failed: {e}")
                seq += 1
                await asyncio.sleep(1.5)

        # WHOOP 4 command probe: the same read-only GETs, 4.0 (CRC8) framing. The strap's COMMAND_RESPONSE
        # (type 36) replies decode via the existing 4.0 command_response post-hook — useful to validate
        # the 4.0 decoder against real hardware and to spot any firmware-version divergence.
        if args.commands and args.model == "whoop4":
            await asyncio.sleep(1.0)
            probes4 = [
                (wf.CMD_GET_BATTERY_LEVEL, b"\x00", "GET_BATTERY_LEVEL"),
                (wf.CMD_GET_CLOCK, b"", "GET_CLOCK"),
                (wf.CMD_REPORT_VERSION_INFO, b"\x00", "REPORT_VERSION_INFO"),
                (wf.CMD_GET_EXTENDED_BATTERY_INFO, b"\x00", "GET_EXTENDED_BATTERY_INFO"),
                (wf.CMD_GET_DATA_RANGE, b"\x00", "GET_DATA_RANGE"),
                (wf.CMD_GET_HELLO_HARVARD, b"\x00", "GET_HELLO_HARVARD"),
            ]
            seq = 2
            for cmd, pl, name in probes4:
                frame = wf.build_command_frame(cmd, seq=seq, payload=pl)
                try:
                    await client.write_gatt_char(cfg["cmd_write"], frame, response=False)
                    print(f"probe(4.0) → {name} (cmd {cmd}): {frame.hex()}")
                except Exception as e:
                    print(f"probe {name} failed: {e}")
                seq += 1
                await asyncio.sleep(1.5)

        # WHOOP 4 historical offload: turn the realtime streams OFF (so the type-43 flood doesn't
        # starve the offload — the 4.0 handshake does this), then request the historical store. With
        # --history-ack each HISTORY_END is echoed back to walk the trim cursor (see ack_sender). The
        # command NUMBERS are shared with 5.0; only the framing differs (CRC8). Used to read the 4.0
        # historical record version on this firmware (is it still v24, or has it drifted?).
        if (args.history_only or args.history_ack) and args.model == "whoop4":
            await asyncio.sleep(1.0)
            probes4h = [
                (wf.PUFFIN_CMD_TOGGLE_REALTIME_HR, b"\x00", "TOGGLE_REALTIME_HR(off)"),
                (wf.PUFFIN_CMD_SEND_R10_R11_REALTIME, b"\x00", "SEND_R10_R11_REALTIME(off)"),
                (wf.CMD_GET_DATA_RANGE, b"\x00", "GET_DATA_RANGE"),
                (wf.PUFFIN_CMD_SEND_HISTORICAL_DATA, b"\x00", "SEND_HISTORICAL_DATA"),
            ]
            seq = 2
            for cmd, pl, name in probes4h:
                frame = wf.build_command_frame(cmd, seq=seq, payload=pl)
                try:
                    await client.write_gatt_char(cfg["cmd_write"], frame, response=False)
                    print(f"probe(4.0) → {name} (cmd {cmd}): {frame.hex()}")
                except Exception as e:
                    print(f"probe {name} failed: {e}")
                seq += 1
                await asyncio.sleep(1.5)

        # Capture until Ctrl-C or the optional duration elapses.
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                loop.add_signal_handler(sig, stop.set)
            except NotImplementedError:
                pass
        print("capturing… (Ctrl-C to stop)")

        async def rerequest_history():
            # The offload is deterministic while we never ack (the trim cursor doesn't advance), so
            # re-requesting re-sends the same records. Repeating + dedup fills in frames that random
            # BLE drops lost on earlier attempts. Realtime stays off (history-only mode).
            seq2 = 100
            while not stop.is_set():
                await asyncio.sleep(args.history_repeat)
                if stop.is_set():
                    break
                frame = cap._build_cmd_fn(wf.PUFFIN_CMD_SEND_HISTORICAL_DATA, seq=seq2 & 0xFF,
                                          payload=b"\x00")
                try:
                    await client.write_gatt_char(cfg["cmd_write"], frame, response=False)
                    print(f"  re-request SEND_HISTORICAL_DATA (#{seq2-99})")
                except Exception as e:
                    print(f"  re-request failed: {e}")
                seq2 += 1

        async def ack_sender():
            # Drain the ack queue and write each HISTORICAL_DATA_RESULT(23) as a CONFIRMED write —
            # the link-layer half of the offload handshake. This is what advances the strap's trim
            # cursor to the next chunk; watch the live trim in the HISTORY_END log move once acks land.
            seq3 = 50
            while not stop.is_set():
                try:
                    end_data = await asyncio.wait_for(cap.ack_queue.get(), timeout=0.5)
                except asyncio.TimeoutError:
                    continue
                ack = cap._build_ack_fn(end_data, seq=seq3 & 0xFF)
                trim = int.from_bytes(end_data[0:4], "little")
                try:
                    await client.write_gatt_char(cfg["cmd_write"], ack, response=True)
                    print(f"  → ACK HISTORICAL_DATA_RESULT trim={trim} ({end_data.hex()})  "
                          f"[type47 so far: {cap.type47_count}]")
                except Exception as e:
                    print(f"  ack write failed: {e}")
                seq3 += 1

        async def stop_when_idle():
            # End the run shortly after the offload goes quiet, instead of guessing --duration. The
            # ack-driven offload streams continuously, then stops once the store is drained; when no
            # frame has arrived for `stop_on_idle` seconds we're done.
            while not stop.is_set():
                await asyncio.sleep(1.0)
                if cap.last_frame_ms and (int(time.time() * 1000) - cap.last_frame_ms) \
                        > args.stop_on_idle * 1000:
                    print(f"  idle for {args.stop_on_idle}s — offload appears complete, stopping")
                    stop.set()
                    return

        async def periodic_flush():
            # Persist to disk OFF the notify hot path: between bursts (no frame for >1s) flush any new
            # records, so a crash or pulled dongle mid-capture doesn't lose the whole session. The
            # atomic tmp + os.replace in flush() means a partial write never corrupts the output file,
            # and skipping mid-burst keeps the blocking JSON rewrite off BlueZ's notification callback.
            last_count = 0
            while not stop.is_set():
                await asyncio.sleep(2.0)
                if len(cap.records) > last_count and cap.last_frame_ms \
                        and (int(time.time() * 1000) - cap.last_frame_ms) > 1000:
                    cap.flush()
                    last_count = len(cap.records)

        tasks = [asyncio.create_task(periodic_flush())]
        if args.history_only and args.history_repeat:
            tasks.append(asyncio.create_task(rerequest_history()))
        if cap.ack_queue is not None:
            tasks.append(asyncio.create_task(ack_sender()))
        if args.stop_on_idle:
            tasks.append(asyncio.create_task(stop_when_idle()))
        try:
            if args.duration:
                await asyncio.wait_for(stop.wait(), timeout=args.duration)
            else:
                await stop.wait()
        except asyncio.TimeoutError:
            pass
        stop.set()
        for t in tasks:
            t.cancel()

        cap.flush()
        print(f"\ncaptured {len(cap.records)} frames → {args.out}")
        chans = {}
        for r in cap.records:
            chans[r["char"]] = chans.get(r["char"], 0) + 1
        for c, n in sorted(chans.items(), key=lambda kv: -kv[1]):
            print(f"  {n:6d}  {c}")
        # Per-type tally so the result is obvious without a separate decode pass. The inner record
        # (where the packet-type byte lives) starts at offset 8 on WHOOP 5 but offset 4 on WHOOP 4.
        inner_off = cap.inner_off
        types = {}
        for r in cap.records:
            h = bytes.fromhex(r["hex"])
            t = h[inner_off] if len(h) > inner_off else None
            types[t] = types.get(t, 0) + 1
        print("  by inner type:", dict(sorted(types.items(), key=lambda kv: -kv[1])))
        if cap.type47_count or args.history_only or args.history_ack:
            verdict = "GOT THEM" if cap.type47_count else "none"
            print(f"  type-47 HISTORICAL_DATA frames: {cap.type47_count}  → {verdict}")
            # The historical record VERSION byte (the answer to "did the layout drift?"): it sits at
            # the inner record's seq slot — frame[5] on 4.0, frame[9] on 5.0 (inner_off + 1). 4.0 is
            # documented as v24; anything else on this firmware is a genuine drift finding.
            ver_off = inner_off + 1
            versions = {}
            for r in cap.records:
                h = bytes.fromhex(r["hex"])
                if len(h) > ver_off and h[inner_off] == wf.PACKET_HISTORICAL_DATA:
                    versions[h[ver_off]] = versions.get(h[ver_off], 0) + 1
            if versions:
                print(f"  type-47 record version(s) [frame[{ver_off}]]: "
                      f"{dict(sorted(versions.items(), key=lambda kv: -kv[1]))}")
            if cap.ack_queue is not None:
                drained = "yes" if cap.history_complete else "no (no HISTORY_COMPLETE seen)"
                print(f"  offload drained to completion: {drained} "
                      f"({cap.history_complete} HISTORY_COMPLETE markers)")


def main():
    p = argparse.ArgumentParser(description="Capture WHOOP BLE frames for protocol RE (Linux/BlueZ).")
    p.add_argument("--model", choices=["whoop4", "whoop5"], default="whoop5",
                   help="strap generation (default: whoop5)")
    p.add_argument("--address", help="BLE MAC address (skip scanning)")
    p.add_argument("--name-filter", help="substring match on advertised name when scanning")
    p.add_argument("--out", default="capture.json", help="output JSON file (default: capture.json)")
    p.add_argument("--duration", type=float, help="stop automatically after N seconds")
    p.add_argument("--probe", action="store_true",
                   help="WHOOP 5 only: after CLIENT_HELLO, send candidate puffin commands (realtime "
                        "toggles + history request) to try to start the biometric stream. Experimental.")
    p.add_argument("--commands", action="store_true",
                   help="after bond/hello, send the read-only GET commands (battery, clock, version, "
                        "ext-battery, data-range, hello) to capture their COMMAND_RESPONSE (type 36) "
                        "frames. WHOOP 5 uses puffin framing (+ battery-pack); WHOOP 4 uses 4.0 framing.")
    p.add_argument("--history-only", dest="history_only", action="store_true",
                   help="turn the realtime streams OFF, then request the historical offload (type-47 "
                        "records). Use instead of --probe to avoid the realtime flood starving the "
                        "offload. Works for both whoop4 (CRC8) and whoop5 (puffin).")
    p.add_argument("--history-repeat", dest="history_repeat", type=float, default=5.0,
                   help="In --history-only mode, re-request the offload every N seconds (default 5). "
                        "The offload is deterministic, so repeating + dedup recovers drop-lost frames.")
    p.add_argument("--history-ack", dest="history_ack", action="store_true",
                   help="ack each HISTORY_END with HISTORICAL_DATA_RESULT(23) to advance the strap's "
                        "trim cursor (the offload handshake). Without this the cursor stays stuck and "
                        "the type-47 DSP records past it are never served. Both generations.")
    p.add_argument("--stop-on-idle", dest="stop_on_idle", type=float, default=0,
                   help="stop the capture once no frame has arrived for N seconds (the offload has "
                        "drained). 0 = off (use --duration / Ctrl-C instead).")
    p.add_argument("--pair", action="store_true",
                   help="also call BlueZ pair() (default off; the confirmed write bonds. The WHOOP 5 "
                        "rejects explicit pair() — leave this off for 5/MG)")
    args = p.parse_args()
    try:
        asyncio.run(run(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
