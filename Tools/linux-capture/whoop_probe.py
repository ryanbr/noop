#!/usr/bin/env python3
"""whoop_probe.py — READ-ONLY strap status probe: current RTC + historical data range.

Sends only non-destructive GET commands (GET_CLOCK=11, GET_DATA_RANGE=34, GET_BATTERY_LEVEL=26) and
reports what the strap answers. It does NOT set the clock, trigger an offload, or write any state — use
it to decide whether there's history worth pulling before touching the RTC.

WHOOP 4.0 framing (CRC8). Phone Bluetooth must be OFF and the strap bonded + advertising (see README).

Usage:
  python3 whoop_probe.py --address AA:BB:CC:DD:EE:FF
"""
import argparse
import asyncio
import time

from bleak import BleakClient, BleakScanner

import whoop_frame as wf

WHOOP4 = {
    "service": "61080001-8d6d-82b8-614a-1c8cb0f8dcc6",
    "cmd_write": "61080002-8d6d-82b8-614a-1c8cb0f8dcc6",
    "notify": [
        "61080003-8d6d-82b8-614a-1c8cb0f8dcc6",
        "61080004-8d6d-82b8-614a-1c8cb0f8dcc6",
        "61080005-8d6d-82b8-614a-1c8cb0f8dcc6",
    ],
}

CMD_GET_CLOCK = 11
CMD_GET_DATA_RANGE = 34
CMD_GET_BATTERY_LEVEL = 26

# Plausible window for a *real* unix timestamp (≈2023-11 … 2030), used to tell a correctly-set strap
# clock from a stale/reset one.
UNIX_LO, UNIX_HI = 1_700_000_000, 1_900_000_000


def u32le(b: bytes, off: int) -> int:
    return int.from_bytes(b[off:off + 4], "little")


def words_u32le(body: bytes):
    return [u32le(body, i) for i in range(0, len(body) - 3)]


async def resolve(address: str):
    print(f"scanning to resolve {address} …")
    dev = await BleakScanner.find_device_by_address(address, timeout=20.0)
    if dev is None:
        print(f"{address} not found — wear/tap the strap (phone BT OFF) and retry.")
    return dev


async def run(args):
    dev = await resolve(args.address)
    if dev is None:
        return 2

    # COMMAND_RESPONSE frames the strap sends back, keyed by the command they acknowledge.
    responses: dict[int, bytes] = {}

    def on_notify(_c, data: bytes):
        cmd = wf.command_response_cmd(bytes(data), "whoop4")
        if cmd is not None:
            responses[cmd] = bytes(data)

    async with BleakClient(dev) as client:
        print(f"connected: {client.is_connected}")
        for u in WHOOP4["notify"]:
            try:
                await client.start_notify(u, on_notify)
            except Exception as e:
                print(f"  (subscribe {u} failed: {e})")

        # Open the session (a GET_BATTERY_LEVEL confirmed write — harmless).
        await client.write_gatt_char(WHOOP4["cmd_write"],
                                     wf.build_command_frame(CMD_GET_BATTERY_LEVEL), response=True)
        await asyncio.sleep(0.6)

        # Fire the read-only GETs.
        seq = 2
        for cmd in (CMD_GET_CLOCK, CMD_GET_DATA_RANGE, CMD_GET_BATTERY_LEVEL):
            await client.write_gatt_char(WHOOP4["cmd_write"],
                                         wf.build_command_frame(cmd, seq=seq), response=False)
            seq += 1
            await asyncio.sleep(1.2)
        await asyncio.sleep(1.0)

    wall = int(time.time())
    print(f"\nwall clock now: {wall}  ({time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(wall))})")

    # --- GET_CLOCK ---------------------------------------------------------------------------------
    device_clock = None
    if CMD_GET_CLOCK in responses:
        body = responses[CMD_GET_CLOCK][7:-4]            # after [type,seq,cmd], before crc32
        device_clock = u32le(body, 0) if len(body) >= 4 else None
    if device_clock is not None:
        drift = wall - device_clock
        dc_str = time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(device_clock))
        ok = UNIX_LO <= device_clock <= UNIX_HI
        print(f"strap RTC:      {device_clock}  ({dc_str})  "
              f"{'OK — clock is current' if ok else 'STALE — clock is wrong'}")
        print(f"drift:          {drift:+d} s  ({drift / 86400:+.1f} days)")
    else:
        print("strap RTC:      no GET_CLOCK response (strap may not support cmd 11 on this fw)")

    # --- GET_DATA_RANGE ----------------------------------------------------------------------------
    if CMD_GET_DATA_RANGE in responses:
        raw = responses[CMD_GET_DATA_RANGE]
        # The range markers are NOT 4-byte aligned in the body, so scan EVERY byte offset for words
        # that fall in the real-unix window — same approach as BLEManager.dataRangeNewestUnix. Stored
        # records keep the (correct) timestamp they were written with, even after the live RTC resets.
        hits = sorted({int.from_bytes(raw[i:i + 4], "little")
                       for i in range(len(raw) - 3)
                       if UNIX_LO <= int.from_bytes(raw[i:i + 4], "little") <= UNIX_HI})
        print(f"\nGET_DATA_RANGE: {raw.hex()}")
        if hits:
            oldest, newest = hits[0], hits[-1]
            print(f"  real-unix record markers: " +
                  ", ".join(time.strftime('%Y-%m-%d', time.localtime(w)) for w in hits))
            print(f"  → STORED HISTORY on strap: "
                  f"{time.strftime('%Y-%m-%d', time.localtime(oldest))} … "
                  f"{time.strftime('%Y-%m-%d', time.localtime(newest))}  "
                  f"({(newest - oldest) / 86400:.1f} days). Offload it BEFORE any SET_CLOCK.")
        else:
            print("  → no real-unix record markers — store likely empty (already offloaded).")
    else:
        print("\nGET_DATA_RANGE: no response (strap may not support cmd 34 on this fw)")

    # --- battery (context) -------------------------------------------------------------------------
    if CMD_GET_BATTERY_LEVEL in responses:
        print(f"\nGET_BATTERY_LEVEL: {responses[CMD_GET_BATTERY_LEVEL].hex()}")
    return 0


def main():
    p = argparse.ArgumentParser(description="Read-only WHOOP 4 status probe (clock + data range).")
    p.add_argument("--address", required=True, help="strap BLE MAC")
    args = p.parse_args()
    import sys
    try:
        sys.exit(asyncio.run(run(args)))
    except KeyboardInterrupt:
        print("\ninterrupted.")


if __name__ == "__main__":
    main()
