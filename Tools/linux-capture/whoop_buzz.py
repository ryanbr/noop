#!/usr/bin/env python3
"""whoop_buzz.py — make a misplaced WHOOP strap vibrate (and home in on it by signal strength).

Sends the strap's haptic ("notify") pattern on repeat over BLE so you can hear/feel a lost strap and
walk toward it. The command is the exact maverick haptic the official app and the Strand app use for
alarms/notifications:

  * WHOOP 5 / MG: opcode 0x13 (RUN_HAPTIC_PATTERN_MAVERICK), the "notify" preset (effects 47,152).
  * WHOOP 4.0:    RUN_HAPTICS_PATTERN (79), patternId=2, 3 loops.

Both are safe and reversible — they only run the vibration motor; nothing is written to the data
store, clock, alarm, or firmware. Frame building lives in whoop_frame.py (stdlib-only, unit-tested);
this module is just the BLE driver around it.

Preconditions (same as the capture tools):
  * The strap must already be BONDED to this machine. Bond once with pair_probe.py if not (see README).
  * The PHONE's Bluetooth must be OFF — the strap accepts one central at a time and the phone re-grabs
    it, so this tool cannot connect while a paired phone is nearby.
  * The strap must be awake and in BLE range (~10 m line of sight; less through walls/floors). A
    dead-battery strap cannot buzz.

Usage:
  python3 whoop_buzz.py                                  # scan for any WHOOP 5, buzz 12×, every 3 s
  python3 whoop_buzz.py --address AA:BB:CC:DD:EE:FF      # connect straight to a known strap
  python3 whoop_buzz.py --model whoop4 --address AA:..   # WHOOP 4.0 strap
  python3 whoop_buzz.py --count 0                        # buzz until Ctrl-C
  python3 whoop_buzz.py --locate --address D1:5C:..      # don't buzz; print live signal strength

Exit status: 0 = the strap acknowledged at least one buzz (or --no-ack-check / --locate); 2 = strap
not found / not reachable; 3 = connected but no buzz was acknowledged (likely wrong opcode or out of
range mid-run). Useful for scripting/retries.
"""
from __future__ import annotations

import argparse
import asyncio
import logging
import sys

from bleak import BleakClient, BleakScanner
from bleak.exc import BleakError

import whoop_frame as wf

log = logging.getLogger("whoop_buzz")

# Per-family GATT endpoints (from docs/BLE_REVERSE_ENGINEERING.md) and the frame written to open the
# session / confirm the bond before the strap will act on commands.
FAMILIES = {
    "whoop5": {
        "service": "fd4b0001-cce1-4033-93ce-002d5875f58a",
        "cmd_write": "fd4b0002-cce1-4033-93ce-002d5875f58a",
        "notify": [
            "fd4b0003-cce1-4033-93ce-002d5875f58a",
            "fd4b0004-cce1-4033-93ce-002d5875f58a",
            "fd4b0005-cce1-4033-93ce-002d5875f58a",
            "fd4b0007-cce1-4033-93ce-002d5875f58a",
        ],
        "session_frame": wf.WHOOP5_CLIENT_HELLO,
        "buzz_cmd": wf.MAVERICK_HAPTIC_CMD,
    },
    "whoop4": {
        "service": "61080001-8d6d-82b8-614a-1c8cb0f8dcc6",
        "cmd_write": "61080002-8d6d-82b8-614a-1c8cb0f8dcc6",
        "notify": [
            "61080003-8d6d-82b8-614a-1c8cb0f8dcc6",
            "61080004-8d6d-82b8-614a-1c8cb0f8dcc6",
            "61080005-8d6d-82b8-614a-1c8cb0f8dcc6",
        ],
        "session_frame": wf.build_command_frame(wf.CMD_GET_BATTERY_LEVEL),
        "buzz_cmd": wf.WHOOP4_RUN_HAPTICS_PATTERN,
    },
}

# Exit codes (documented in the module docstring).
EXIT_OK = 0
EXIT_NOT_FOUND = 2
EXIT_NO_ACK = 3

SCAN_TIMEOUT = 20.0       # seconds to look for the strap before giving up
ACK_WAIT = 1.2            # seconds to wait for a COMMAND_RESPONSE after each buzz


async def resolve_device(cfg: dict, address: str | None, name_filter: str):
    """Find the strap by address (preferred) or by advertised service/name. Scanning first is more
    reliable than a bare-address connect: BlueZ often has no cache for a strap that just woke."""
    if address:
        log.info("scanning to resolve %s …", address)
        dev = await BleakScanner.find_device_by_address(address, timeout=SCAN_TIMEOUT)
        if dev is None:
            log.error("%s not found. Wake the strap (tap/wear it so it advertises), make sure the "
                      "phone's Bluetooth is OFF, then retry.", address)
        return dev

    log.info("scanning for a %s strap (service %s) …", "WHOOP 5/MG" if cfg is FAMILIES["whoop5"]
             else "WHOOP 4.0", cfg["service"])
    svc = cfg["service"].lower()
    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: (svc in [s.lower() for s in (ad.service_uuids or [])])
        or (name_filter.lower() in (d.name or "").lower()),
        timeout=SCAN_TIMEOUT,
    )
    if dev is None:
        log.error("no WHOOP strap found. Make sure it is awake, in range, and the phone's BT is OFF.")
    else:
        log.info("found %s @ %s", dev.name or "?", dev.address)
    return dev


async def connect(target, attempts: int, timeout: float) -> BleakClient | None:
    """Connect with bounded retries and linear backoff. Returns a connected client, or None."""
    for i in range(1, attempts + 1):
        client = BleakClient(target, timeout=timeout)
        try:
            await client.connect()
            log.info("connected (attempt %d/%d)", i, attempts)
            return client
        except (BleakError, asyncio.TimeoutError, OSError) as e:
            log.warning("connect attempt %d/%d failed: %s", i, attempts, e)
            try:
                await client.disconnect()
            except Exception:
                pass
            if i < attempts:
                await asyncio.sleep(min(2.0 * i, 6.0))
    log.error("could not connect after %d attempts.", attempts)
    return None


async def run_buzz(args) -> int:
    cfg = FAMILIES[args.model]
    target = await resolve_device(cfg, args.address, args.name_filter)
    if target is None:
        return EXIT_NOT_FOUND

    client = await connect(target, args.retries, args.connect_timeout)
    if client is None:
        return EXIT_NOT_FOUND

    acked: set[int] = set()          # buzz cmd numbers the strap acknowledged this run

    def on_notify(_char, data: bytes):
        cmd = wf.command_response_cmd(bytes(data), args.model)
        if cmd is not None:
            acked.add(cmd)
            log.debug("← COMMAND_RESPONSE for cmd 0x%02X(%d)", cmd, cmd)

    try:
        # Subscribe so we can confirm the strap accepted each buzz (COMMAND_RESPONSE) and to keep the
        # link lively. Best-effort: a failed subscribe doesn't stop us trying to buzz.
        if not args.no_ack_check:
            for u in cfg["notify"]:
                try:
                    await client.start_notify(u, on_notify)
                except Exception as e:
                    log.debug("could not subscribe %s: %s", u, e)

        # Open the session / confirm the bond. On the 5.0 strap this CONFIRMED write establishes the
        # encrypted link the fd4b service needs — without it, command writes hang.
        try:
            await client.write_gatt_char(cfg["cmd_write"], cfg["session_frame"], response=True)
            log.info("session opened")
        except BleakError as e:
            log.error("session/bond write failed — is the strap bonded to this machine? Run "
                      "pair_probe.py once. (%s)", e)
            return EXIT_NOT_FOUND
        await asyncio.sleep(0.8)

        seq, sent = 2, 0
        print("buzzing — walk toward the vibration. Ctrl-C to stop.", flush=True)
        while args.count == 0 or sent < args.count:
            frame = wf.buzz_frame(args.model, seq=seq)
            try:
                await client.write_gatt_char(cfg["cmd_write"], frame, response=False)
            except BleakError as e:
                log.warning("buzz write failed (link dropped?): %s", e)
                if not client.is_connected:
                    log.error("disconnected mid-run — strap moved out of range or phone grabbed it.")
                    break
                await asyncio.sleep(args.interval)
                continue
            sent += 1
            seq = (seq + 1) & 0xFF
            if not args.no_ack_check:
                await asyncio.sleep(ACK_WAIT)   # let the COMMAND_RESPONSE arrive
                state = "acknowledged" if cfg["buzz_cmd"] in acked else "no ack yet"
                log.info("buzz %d%s — %s", sent, "" if args.count == 0 else f"/{args.count}", state)
            else:
                log.info("buzz %d%s sent", sent, "" if args.count == 0 else f"/{args.count}")
            remaining = args.interval - (ACK_WAIT if not args.no_ack_check else 0)
            if remaining > 0:
                await asyncio.sleep(remaining)

        if args.no_ack_check:
            print(f"done — sent {sent} buzz command(s) (ack check disabled).", flush=True)
            return EXIT_OK
        if cfg["buzz_cmd"] in acked:
            print(f"done — sent {sent} buzz(es); strap acknowledged. It should have vibrated.",
                  flush=True)
            return EXIT_OK
        print(f"done — sent {sent} buzz(es) but saw NO acknowledgement. The strap may be out of "
              f"range, asleep, or held by the phone (turn phone BT off).", flush=True)
        return EXIT_NO_ACK
    finally:
        try:
            await client.disconnect()
        except Exception:
            pass


async def run_locate(args) -> int:
    """Don't buzz — continuously print the strap's BLE signal strength so you can play hot/cold to
    home in on a strap that's not in the same room. Stronger (less negative) RSSI = closer."""
    if not args.address:
        log.error("--locate needs --address so it tracks YOUR strap, not every WHOOP nearby.")
        return EXIT_NOT_FOUND
    want = args.address.upper()
    last = {"rssi": None}

    def cb(d, ad):
        if d.address.upper() == want:
            last["rssi"] = ad.rssi

    scanner = BleakScanner(detection_callback=cb)
    await scanner.start()
    print(f"locating {want} — move around; the bar grows as you get closer. Ctrl-C to stop.",
          flush=True)
    seen = False
    try:
        while True:
            await asyncio.sleep(1.0)
            rssi = last["rssi"]
            last["rssi"] = None   # require a fresh advert each tick
            if rssi is None:
                print("  … no signal this second (out of range / asleep)", flush=True)
                continue
            seen = True
            # Map a typical -100..-40 dBm range to a 0..30 char bar.
            filled = max(0, min(30, int((rssi + 100) / 60 * 30)))
            bar = "█" * filled + "·" * (30 - filled)
            print(f"  {rssi:4d} dBm [{bar}]", flush=True)
    except (KeyboardInterrupt, asyncio.CancelledError):
        pass
    finally:
        try:
            await scanner.stop()
        except Exception:
            pass
    return EXIT_OK if seen else EXIT_NOT_FOUND


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Make a misplaced WHOOP strap vibrate so you can find it.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--model", choices=["whoop5", "whoop4"], default="whoop5",
                   help="strap family (default: whoop5)")
    p.add_argument("--address", help="BLE MAC address of the strap (recommended; required for --locate)")
    p.add_argument("--name-filter", default="whoop",
                   help="substring matched against the advertised name when scanning (default: whoop)")
    p.add_argument("--count", type=int, default=12,
                   help="number of buzzes to send; 0 = forever until Ctrl-C (default: 12)")
    p.add_argument("--interval", type=float, default=3.0,
                   help="seconds between buzzes (default: 3.0)")
    p.add_argument("--connect-timeout", type=float, default=20.0,
                   help="per-attempt BLE connect timeout in seconds (default: 20)")
    p.add_argument("--retries", type=int, default=3,
                   help="connect attempts before giving up (default: 3)")
    p.add_argument("--locate", action="store_true",
                   help="don't buzz — print live RSSI to home in on the strap by signal strength")
    p.add_argument("--no-ack-check", action="store_true",
                   help="fire-and-forget: don't subscribe/confirm each buzz (slightly faster)")
    p.add_argument("--verbose", "-v", action="store_true", help="debug logging")
    return p


def main() -> int:
    args = build_parser().parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(message)s")
    if args.count < 0:
        log.error("--count must be >= 0")
        return EXIT_NOT_FOUND
    if args.interval <= 0:
        log.error("--interval must be > 0")
        return EXIT_NOT_FOUND
    try:
        coro = run_locate(args) if args.locate else run_buzz(args)
        return asyncio.run(coro)
    except KeyboardInterrupt:
        print("\ninterrupted.", flush=True)
        return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
