#!/usr/bin/env python3
"""Decode WHOOP 5/MG v18 type-47 records into steps + on-band sleep state.

Field map established by observing a strap's own synced captures against ground truth
(live heart rate at the same second, movement, and a scored night) — every offset below was
read off real v18 frames and checked for a behaviour that can only hold if the offset is right:

  frame[9] == 18   v18 record guard
  record_index = u32 LE @11   per-record counter: +1 every record across the whole offload and
                              independent of unix (advances across gaps); span == record count on
                              two different straps.
  unix   = u32 LE @15         ticks +1 s per record.
  hr     = frame[22]          equals the live HR at the same unix second.
  hr_quality_flags = frame[36]  a FLAG byte, not the low half of a fixed-point HR: bit 4 is never set
                              (0/18,650 real v18 records — a genuine 8.8 fraction sets it ~50% of the
                              time) and 95.02% of values land in 0x80-0x8F over only 40 distinct values.
                              Bit 7 reads as a validity bit (rr_count == 0 in 70.32% of records when it
                              is clear vs 19.82% when set).
  heart_rate_alt = frame[37]  a DUPLICATE of hr@22 — equal in 99.575% of records, differing by -6..+2.
                              (The retired `hr_fixed_8_8 = u16 LE @36, bpm = value/256` read these two
                              bytes as one field; its "corr 0.989" was circular — the u16 is hr@22 plus
                              the flag byte over 256, a flat +0.504 +/- 0.189 residual.)
  motion_count = u16 LE @[57:59]   cumulative counter: climbs while moving, flat when still, low byte
                              wraps at 256. Steps = sum of wrap-aware diffs (summing the value
                              over-counts massively — that's the WHOOP 5/MG step over-report).
  step_cadence = frame[59]    a per-step cadence-like byte: never 0, and orders by effort
                              (lower when moving faster); raw (no unit asserted).
  motion_wear_quality = frame[63]   a 3-valued byte {0,1,2} (0xFF invalid); kept raw (semantics not
                              pinned from observation — matches the upstream field name).
  rr_packed = u16 LE @38      raw (a u16 near the R-R fields; meaning not pinned).
  cardiac_flags = frame[33]   raw byte near the HR fields; weak/flat correlation.
  cardiac_status = frame[40]  raw status-like byte near the HR fields.
  status_word = u16 LE @75    raw: NOT a deep-sleep marker (its low nibble is 0 across ~258k records
                              and it occurs as often awake as asleep — the "80=deep" reading is wrong).
  temp_aux_1_raw = i16 LE @69   secondary temperature channel; °C = value/10; tracks skin_temp
                              (corr ~0.92), same diurnal curve.
  temp_aux_2_raw = i16 LE @71   secondary temperature channel; °C = value/10; tracks skin_temp
                              (corr ~0.97).
  status_word_1 = u16 LE @77   raw; near-static sibling of status_word@75 (low nibble = 1).
  status_word_2 = u16 LE @79   raw; sibling of @75 (low nibble = 2).
  onwrist = frame[81] & 3     on-wrist/validity flag (b0-1).
  wake_quality = (frame[81] >> 2) & 3   quality code (b2-3); observed nonzero only in wake.
  sleep_state = (frame[81] >> 4) & 3   high nibble tracks a scored night (wake/still/asleep/up); the
                              low nibble is sub-flags. Deep/REM/light are computed off-band, not here.
  aux_byte_82 = frame[82]     raw; observed nonzero only while sleep_state = asleep.
  spo2_candidate_82           aux_byte_82 when in 70..100 (inclusive); else absent. Instrumentation
                              only (#103) — multi-device validation via validate_spo2_candidate.py
                              before any promote to spo2Pct.
  unknown_f32_113 = f32 LE @113   a float32 (observed range ~ -5.3..0, 0 = unset); purpose unknown,
                              carried raw for completeness.

Steps = sum of wrap-aware diffs of motion_count (NOT the byte summed per record).
Sleep is reported RAW (segments + per-state minutes); no derived deep/REM/light summary.
Pure stdlib; mirrors what a Swift port would do.
"""
import struct
from collections import Counter, defaultdict

SLEEP_NAMES = {0: "wake", 1: "still", 2: "asleep", 3: "up"}
WEAR_NAMES = {0: "good", 1: "fair", 2: "poor", 0xFF: "invalid"}


def u16le(buf, off):
    return buf[off] | (buf[off + 1] << 8)


def decode_v18(frame):
    """Return decoded fields for a v18 type-47 frame, or None if not v18 / too short."""
    if len(frame) <= 116 or frame[9] != 18:
        return None
    return {
        "record_index": struct.unpack_from("<I", frame, 11)[0],  # @11 per-record counter
        "unix": struct.unpack_from("<I", frame, 15)[0],
        "hr": frame[22],
        "onwrist": frame[81] & 3,            # @81 b0-1 on-wrist/validity flag
        "wake_quality": (frame[81] >> 2) & 3,  # @81 b2-3 quality code (nonzero only in wake)
        "sleep_state": (frame[81] >> 4) & 3,
        "aux_byte_82": frame[82],            # @82 raw (nonzero only while asleep)
        # In-band only (70–100): mirrors Swift spo2_candidate_82 / Kotlin twin — instrumentation.
        "spo2_candidate_82": frame[82] if 70 <= frame[82] <= 100 else None,
        "motion_count": u16le(frame, 57),
        "step_cadence": frame[59],           # @59 cadence-like byte (raw)
        "motion_wear_quality": frame[63],    # @63 3-valued byte (raw; semantics not pinned)
        "hr_quality_flags": frame[36],       # @36 flag byte: bit7 = valid, bit4 never set (NOT a fixed-point HR)
        "heart_rate_alt": frame[37],         # @37 duplicate of hr@22 (99.6% exact)
        "rr_packed": u16le(frame, 38),       # raw u16 near the R-R fields
        "cardiac_flags": frame[33],          # raw byte near the HR fields
        "cardiac_status": frame[40],         # raw status-like byte near the HR fields
        "temp_aux_1_raw": struct.unpack_from("<h", frame, 69)[0],  # @69 i16; °C = value/10 (tracks skin_temp)
        "temp_aux_2_raw": struct.unpack_from("<h", frame, 71)[0],  # @71 i16; °C = value/10 (tracks skin_temp)
        "status_word": u16le(frame, 75),     # @75 raw status word (NOT a deep-sleep marker)
        "status_word_1": u16le(frame, 77),   # @77 raw sibling of @75 (low nibble = 1)
        "status_word_2": u16le(frame, 79),   # @79 raw sibling of @75 (low nibble = 2)
        "unknown_f32_113": struct.unpack_from("<f", frame, 113)[0],  # @113 float32, purpose unknown
    }


def step_deltas(recs, max_gap_s=5, sanity_max=512):
    """Wrap-aware motion_count increments between consecutive records within max_gap_s.
    Returns [(unix, delta)]. Drops deltas >= sanity_max (spurious jumps across gaps)."""
    out = []
    for p, c in zip(recs, recs[1:]):
        gap = c["unix"] - p["unix"]
        if 0 < gap <= max_gap_s:
            d = (c["motion_count"] - p["motion_count"]) & 0xFFFF
            if d < sanity_max:
                out.append((c["unix"], d))
    return out


def steps_total(recs, **kw):
    return sum(d for _, d in step_deltas(recs, **kw))


def steps_by_hour(recs, **kw):
    """unix-hour bucket -> step count."""
    h = defaultdict(int)
    for unix, d in step_deltas(recs, **kw):
        h[unix // 3600 * 3600] += d
    return dict(h)


def wear_quality_minutes(recs):
    """motion_wear_quality name -> whole minutes (records are 1 Hz)."""
    c = Counter(WEAR_NAMES.get(r["motion_wear_quality"], f"class_{r['motion_wear_quality']}")
                for r in recs)
    return {k: v // 60 for k, v in c.items()}


def sleep_segments(recs):
    """Collapse the sleep_state series into contiguous (state_name, start_unix, end_unix) segments.
    Consecutive records of the same state extend the segment (end = last record's unix)."""
    segs = []
    for r in recs:
        st = SLEEP_NAMES[r["sleep_state"]]
        if segs and segs[-1][0] == st:
            segs[-1] = (st, segs[-1][1], r["unix"])
        else:
            segs.append((st, r["unix"], r["unix"]))
    return segs


def sleep_state_minutes(recs):
    """sleep-state name -> whole minutes (records are 1 Hz). Raw; no derived summary."""
    c = Counter(SLEEP_NAMES[r["sleep_state"]] for r in recs)
    return {k: v // 60 for k, v in c.items()}


import sqlite3
import argparse
import json
import datetime as _dt

DEFAULT_DB = "captures/whoop4.db"


def records(db_path=DEFAULT_DB, device_id=2, start=None, end=None):
    """Decoded v18 records (time-ordered) from the frames table."""
    con = sqlite3.connect(db_path)
    q = "SELECT hex FROM frames WHERE device_id=? AND inner_type=47"
    args = [device_id]
    if start is not None:
        q += " AND unix>=?"; args.append(start)
    if end is not None:
        q += " AND unix<?"; args.append(end)
    q += " ORDER BY unix"
    out = []
    for (hx,) in con.execute(q, args):
        d = decode_v18(bytes.fromhex(hx))
        if d is not None:
            out.append(d)
    con.close()
    return out


def _day_bounds(day):
    """'YYYY-MM-DD' (UTC) -> (start_unix, end_unix)."""
    d = _dt.datetime.fromisoformat(day).replace(tzinfo=_dt.timezone.utc)
    s = int(d.timestamp())
    return s, s + 86400


def _window(a):
    if a.day:
        return _day_bounds(a.day)
    s = int(_dt.datetime.fromisoformat(a.start).replace(tzinfo=_dt.timezone.utc).timestamp()) if a.start else None
    e = int(_dt.datetime.fromisoformat(a.end).replace(tzinfo=_dt.timezone.utc).timestamp()) if a.end else None
    return s, e


def _hhmm(unix):
    return _dt.datetime.fromtimestamp(unix, _dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def main(argv=None):
    p = argparse.ArgumentParser(description="WHOOP v18 steps + on-band sleep state from captures DB")
    p.add_argument("cmd", choices=["steps", "sleep"])
    p.add_argument("--db", default=DEFAULT_DB)
    p.add_argument("--device", type=int, default=2)
    p.add_argument("--day", help="YYYY-MM-DD (UTC)")
    p.add_argument("--start", help="ISO start (UTC)")
    p.add_argument("--end", help="ISO end (UTC)")
    p.add_argument("--json", action="store_true")
    a = p.parse_args(argv)
    start, end = _window(a)
    recs = records(a.db, a.device, start, end)

    if a.cmd == "steps":
        result = {
            "frames": len(recs),
            "steps_total": steps_total(recs),
            "steps_by_hour": {_hhmm(h): n for h, n in sorted(steps_by_hour(recs).items())},
            "wear_quality_minutes": wear_quality_minutes(recs),
        }
        if a.json:
            print(json.dumps(result, indent=2)); return
        print(f"frames: {result['frames']}   steps: {result['steps_total']}")
        print("wear quality (min):", result["wear_quality_minutes"])
        for h, n in result["steps_by_hour"].items():
            print(f"  {h}  {n}")
    else:  # sleep
        result = {
            "frames": len(recs),
            "segments": sleep_segments(recs),
            "state_minutes": sleep_state_minutes(recs),
        }
        if a.json:
            print(json.dumps(result, indent=2)); return
        print(f"frames: {result['frames']}   WHOOP-band sleep state (raw; not deep/REM/light)")
        print("minutes:", result["state_minutes"])
        for st, s0, s1 in result["segments"]:
            print(f"  {_hhmm(s0)} -> {_hhmm(s1)}  {st}")


if __name__ == "__main__":
    main()
