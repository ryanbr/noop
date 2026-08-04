#!/usr/bin/env python3
"""whoop_setclock.py — set a WHOOP strap's RTC to the current wall-clock time, and verify it latched.

A strap left offline (no app) for a long time loses its clock — realtime/historical frames then carry
bogus timestamps. The phone app fixes this with SET_CLOCK on every connect; this does the same from
Linux. WRITE operation, but safe and reversible (the phone re-sets the clock on its next sync).

Verification: after writing SET_CLOCK, the tool briefly subscribes and scans incoming frames (events
carry the strap RTC in a u32 timestamp) for a value within a minute of wall time. If found, the clock
latched; if every timestamp is still far off, it warns (e.g. a wrong-length SET_CLOCK that didn't take).

Phone Bluetooth must be OFF and the strap bonded + advertising.

It reads the strap clock first and only writes when it has drifted past `--if-drift` seconds (mirrors
the app's ClockPolicy — avoid gratuitous resets), then re-reads to verify the new clock latched.

Usage:
  python3 whoop_setclock.py --model whoop4 --address AA:BB:CC:DD:EE:FF            # set to now
  python3 whoop_setclock.py --model whoop4 --address CF:.. --if-drift 30          # set only if >30s off
  python3 whoop_setclock.py --model whoop4 --address CF:.. --check                # read-only, report drift
"""
import argparse
import asyncio
import time

from bleak import BleakClient, BleakScanner

import whoop_frame as wf

FAMILIES = {
    "whoop4": {
        "cmd_write": "61080002-8d6d-82b8-614a-1c8cb0f8dcc6",
        "notify": ["61080003-8d6d-82b8-614a-1c8cb0f8dcc6",
                   "61080004-8d6d-82b8-614a-1c8cb0f8dcc6",
                   "61080005-8d6d-82b8-614a-1c8cb0f8dcc6"],
        # GET_HELLO_HARVARD opens the session AND kicks the strap into emitting EVENT frames, whose RTC
        # is our latch read-back (GET_BATTERY opens the session but stays quiet, so we'd see nothing).
        "session": wf.build_command_frame(wf.CMD_GET_HELLO_HARVARD),
        "build_set_clock": wf.build_whoop4_set_clock,
    },
    "whoop5": {
        "cmd_write": "fd4b0002-cce1-4033-93ce-002d5875f58a",
        "notify": ["fd4b0003-cce1-4033-93ce-002d5875f58a",
                   "fd4b0004-cce1-4033-93ce-002d5875f58a",
                   "fd4b0005-cce1-4033-93ce-002d5875f58a",
                   "fd4b0007-cce1-4033-93ce-002d5875f58a"],
        "session": wf.WHOOP5_CLIENT_HELLO,
        "build_set_clock": wf.build_whoop5_set_clock,
    },
}

UNIX_LO, UNIX_HI = 1_700_000_000, 1_900_000_000

event_rtc = wf.frame_rtc   # strap RTC read-back lives in whoop_frame.py (pure, unit-tested)


def _enable_stream_frames(model: str):
    """Frames that switch the realtime stream ON (cmds 63 + 3) so the strap reliably emits timestamped
    EVENT/REALTIME frames — our clock read-back. A passive link is too quiet to read from. Reversible."""
    mk = ((lambda c, s: wf.build_command_frame(c, seq=s, payload=b"\x01")) if model == "whoop4"
          else (lambda c, s: wf.build_puffin_command(c, seq=s, payload=b"\x01")))
    return [mk(63, 3), mk(3, 4)]


async def read_strap_clock(client, cfg, model, window=12.0):
    """Enable the stream and return the strap's current RTC (unix secs) from the first EVENT/REALTIME
    frame, or None if none arrived within `window` seconds."""
    rtcs = []

    def on_notify(_c, data):
        r = event_rtc(bytes(data), model)
        if r is not None:
            rtcs.append(r)

    for u in cfg["notify"]:
        try:
            await client.start_notify(u, on_notify)
        except Exception:
            pass
    await client.write_gatt_char(cfg["cmd_write"], cfg["session"], response=True)
    await asyncio.sleep(0.5)
    for fr in _enable_stream_frames(model):
        try:
            await client.write_gatt_char(cfg["cmd_write"], fr, response=False)
        except Exception:
            pass
    waited = 0.0
    while waited < window and not rtcs:
        await asyncio.sleep(0.5)
        waited += 0.5
    return rtcs[-1] if rtcs else None


async def run(args) -> int:
    cfg = FAMILIES[args.model]

    if args.dry_run:
        now = int(time.time())
        frame = cfg["build_set_clock"](now, seq=2)
        body_len = len(frame) - 11 if args.model == "whoop4" else len(frame) - 16
        print(f"SET_CLOCK frame for now={now}: {frame.hex()}  ({body_len}-byte body)  — --dry-run, not sending.")
        return 0

    print(f"scanning to resolve {args.address} …")
    dev = await BleakScanner.find_device_by_address(args.address, timeout=20.0)
    if dev is None:
        print(f"{args.address} not found — wear/tap the strap (phone BT OFF) and retry.")
        return 2

    async with BleakClient(dev) as client:
        print(f"connected: {client.is_connected}")

        # 1. READ the strap clock first (so we only write when needed — mirrors the app's ClockPolicy).
        before = await read_strap_clock(client, cfg, args.model)
        wall = int(time.time())
        if before is None:
            print("⚠ could not read the strap clock (no timestamped frames). Re-run, or verify with a "
                  "short realtime capture.")
            return 3
        drift = wall - before
        print(f"strap clock: {before}  ({time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(before))})  "
              f"drift {drift:+d} s ({drift / 86400:+.1f} days)")

        if args.check:
            print("--check: read-only, not setting.")
            return 0
        if abs(drift) <= args.if_drift:
            print(f"✓ within ±{args.if_drift}s threshold — leaving the clock as-is.")
            return 0

        # 2. SET the clock (confirmed write), then re-read to VERIFY it latched.
        now = int(time.time())
        frame = cfg["build_set_clock"](now, seq=5)
        await client.write_gatt_char(cfg["cmd_write"], frame, response=True)
        print(f"SET_CLOCK written → target {now} "
              f"({time.strftime('%H:%M:%S', time.localtime(now))}); verifying …")
        after = await read_strap_clock(client, cfg, args.model)

    if after is None:
        print("⚠ clock written (confirmed) but could not read back to verify within the window. "
              "Re-run with --check to confirm.")
        return 3
    new_drift = int(time.time()) - after
    if abs(new_drift) <= max(5, args.if_drift):
        print(f"✓ CLOCK SET — strap now reports {after} "
              f"({time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(after))}), drift {new_drift:+d} s.")
        return 0
    print(f"⚠ clock still off after write (now {after}, drift {new_drift:+d}s). On older WHOOP 4 fw only "
          f"the 9-byte SET_CLOCK latches — confirm --model is correct and retry.")
    return 3


def main():
    p = argparse.ArgumentParser(description="Read a WHOOP strap's RTC and set it to now if it has drifted.")
    p.add_argument("--model", choices=["whoop4", "whoop5"], default="whoop4")
    p.add_argument("--address", required=True, help="strap BLE MAC")
    p.add_argument("--if-drift", type=int, default=0, metavar="SECONDS",
                   help="only set the clock when |drift| exceeds this many seconds (default 0 = always set)")
    p.add_argument("--check", action="store_true", help="read and report the clock only; never write")
    p.add_argument("--dry-run", action="store_true", help="build and print the frame without connecting")
    args = p.parse_args()
    import sys
    try:
        sys.exit(asyncio.run(run(args)))
    except KeyboardInterrupt:
        print("\ninterrupted.")


if __name__ == "__main__":
    main()
