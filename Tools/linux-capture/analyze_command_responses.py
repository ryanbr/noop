#!/usr/bin/env python3
"""analyze_command_responses.py — validate the WHOOP 5 COMMAND_RESPONSE (+4) decode against a capture.

Local dev helper (not part of the committed tooling). Run it on a capture taken with
`whoop_capture.py --model whoop5 --commands`: it isolates the type-36 frames, reads the response
command at frame[10] and the payload at frame[11:] (the 4.0 offsets + 4), and applies the same field
math as the 4.0 `command_response` post-hook so we can confirm the +4 hypothesis at a glance.

    python3 analyze_command_responses.py capture_cmds.json
"""
import json
import sys

import whoop_frame as wf

# Response command numbers (CommandNumber enum) → human name.
CMD = {7: "REPORT_VERSION_INFO", 11: "GET_CLOCK", 26: "GET_BATTERY_LEVEL", 34: "GET_DATA_RANGE",
       98: "GET_EXTENDED_BATTERY_INFO", 151: "GET_BATTERY_PACK_INFO"}


def u16(b, o): return int.from_bytes(b[o:o + 2], "little") if o + 2 <= len(b) else None
def u32(b, o): return int.from_bytes(b[o:o + 4], "little") if o + 4 <= len(b) else None


def decode(resp_cmd, pay):
    """Mirror the 4.0 command_response hook on `pay` (= frame[11:] for whoop5)."""
    name = CMD.get(resp_cmd, f"cmd{resp_cmd}")
    if name == "GET_BATTERY_LEVEL" and len(pay) >= 4:
        return f"battery_pct={u16(pay, 2) / 10}"
    if name == "GET_CLOCK" and len(pay) >= 6:
        return f"clock={u32(pay, 2)}"
    if name == "GET_EXTENDED_BATTERY_INFO" and len(pay) >= 9:
        return f"battery_mV={u16(pay, 7)}"
    if name == "REPORT_VERSION_INFO" and len(pay) >= 19:
        fw = ".".join(str(u32(pay, o)) for o in (3, 7, 11, 15))
        return f"fw_harvard={fw}"
    if name == "GET_DATA_RANGE":
        vals = sorted({u32(pay, o) for o in range(3, len(pay) - 3)
                       if 1_600_000_000 <= (u32(pay, o) or 0) <= 1_800_000_000})
        return f"history_range={vals[0]}..{vals[-1]}" if vals else "history_range=(none found)"
    return "(unmapped — inspect raw)"


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    data = json.load(open(sys.argv[1]))
    seen = {}
    for r in data:
        h = bytes.fromhex(r["hex"])
        if len(h) <= 11 or h[8] != 36:        # type 36 = COMMAND_RESPONSE, inner record at offset 8
            continue
        if not wf.verify_whoop5_frame(h):
            continue
        resp_cmd = h[10]                       # resp_cmd = 4.0 frame[6] + 4
        seen.setdefault(resp_cmd, h)           # one (CRC-valid) sample per response type
    if not seen:
        print("no CRC-valid type-36 COMMAND_RESPONSE frames in this capture.")
        return
    print(f"{len(seen)} distinct COMMAND_RESPONSE types:\n")
    for resp_cmd, h in sorted(seen.items()):
        pay = h[11:len(h) - 4]                 # payload = frame[11 : end-CRC32]
        print(f"  cmd {resp_cmd:>3} {CMD.get(resp_cmd, '?'):<26} → {decode(resp_cmd, pay)}")
        print(f"      pay[{len(pay)}]: {pay.hex()}")
        print(f"      frame:   {h.hex()}\n")


if __name__ == "__main__":
    main()
