#!/usr/bin/env python3
"""Multi-device validation of the WHOOP 5/MG v18 SpO₂ candidate at frame byte @82.

Context (see docs/WHOOP5_DEEP_DATA.md and issue #103):
  • There is no GET_SPO2 BLE command.
  • On 5.0/MG, SpO₂ is believed to be a strap-computed scalar banked during sleep.
  • NOOP decodes in-band values (70–100) at absolute frame offset 82 as spo2_candidate_82
    (instrumentation only — never spo2Pct until multi-device evidence is solid).

This tool answers the promote-or-not question as *known plaintext*:

    capture.json OR a whoop_sync.py .db OR a NOOP app store  +  whoop_export
                                       ──►  mean(@82 | asleep, 70–100, in-window)
                                       vs CSV blood_oxygen_pct
                                       ──►  r, MAE, bias, offset-specificity, window coverage

Owners can validate one strap, or batch several devices, and post **only aggregate
stats** on #103 (never raw SpO₂ values). Stdlib only.

THREE INPUT KINDS, and the third is why #103 has been stuck (#845):

  • `capture.json` — hci_extract / whoop_capture output.
  • a `whoop_sync.py` `.db` — the CAPTURE TOOLING's frame store.
  • a **NOOP app store** — the shipped app's own SQLite (GRDB), read from `v18AuxSample`, the table
    PR #848 added. Until this existed, only someone running linux-capture could contribute evidence,
    so the app could not answer its own open question even though it banks the byte. An ordinary user
    who syncs with NOOP can now run the promote gate on their own data.

    The one thing an app store cannot do is the OFFSET SPECIFICITY SCAN: the app banks decoded slots,
    not frame bytes, so there is no neighbour byte to rank @82 against. That is reported as
    `specificity_scan: "unavailable_app_db"` and the corresponding checklist item is n/a — NOT False,
    which would read as "@82 lost the scan" about a byte that was never ranked. A capture is still
    required to settle specificity; the correlation, MAE, bias, duty-cycle detection and window
    coverage all work from either.

Three things the harness has to get right before a number from it means anything:

  • **@82 is duty-cycled.** It is nonzero only inside a short, phase-locked window that repeats on a
    fixed period; outside it the byte is identically 0x00. A capture that is not aligned to that
    phase reads all zeros and looks exactly like a strap with the feature off. The harness therefore
    DETECTS the period/phase/window length per capture (never assumes them), aggregates per window
    rather than per second, and reports how much of each night's window schedule it actually sampled.
  • **"value is in 70–100" is not a specific screen.** Timestamp bytes and thermal channels pass it.
    An offset must also show real variation before its correlation is worth ranking.
  • **A strap that never emits @82 is not a failed correlation.** It is classified `feature_absent`
    and counts as neither a PASS nor a FAIL in the multi-device promote gate.

Usage:

    # Single device (privacy-safe summary):
    python3 validate_spo2_candidate.py capture.json my_whoop_data/ --device strap-a

    # Show per-night table locally (still stays on your machine):
    python3 validate_spo2_candidate.py capture.json export.zip --show-nights

    # Multi-device batch:
    python3 validate_spo2_candidate.py --batch devices.json

    # From a NOOP app database (no linux-capture needed):
    python3 validate_spo2_candidate.py noop.sqlite my_whoop_data/ --device strap-a

devices.json example:
    [
      {"device": "strap-a", "capture": "a.json", "export": "export_a/"},
      {"device": "strap-b", "capture": "b.json", "export": "export_b.zip"}
    ]
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import math
import os
import sqlite3
import statistics
import sys
import zipfile
from datetime import datetime, timezone
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

import whoop_activity as wa
import whoop_frame as wf

# Absolute frame offsets (Interpreter.decodeWhoop5Historical / whoop_activity.decode_v18).
OFF_HIST_VERSION = 9
OFF_UNIX = 15
OFF_SLEEP_BYTE = 81
OFF_SPO2_CANDIDATE = 82

# In-band SpO₂ % range (tri-mode filter — matches Swift spo2_candidate_82).
INBAND = range(70, 101)

# Band sleep_state high-nibble: 2 = asleep.
SLEEP_ASLEEP = 2

# Scan window for offset-specificity (docs checklist: only @82 should win).
SPECIFICITY_SCAN = range(74, 93)

# --- Duty cycle ------------------------------------------------------------------------------------
# @82 is NOT sampled every second. Measured on a corpus of 18,650 v18 records — 18,602 of them from
# @digitalerdude's public PacketLogger capture of an official-app overnight sync, plus 48 from a NOOP
# sync — the byte is nonzero in only 450 records (2.41 %), and every one of those falls inside a short
# window that repeats on a fixed period: 15 windows, each exactly 30 records long, each starting at
# the same `unix % 1200`, zero phase variance. Outside the window @82 is identically 0x00.
#
# Why this matters here more than anywhere else: a capture (or a sampling scheme) not aligned to that
# phase reads all zeros and is indistinguishable from a strap with the feature switched off — a
# plausible contributor to the contradictory cross-device evidence on #103, where one device
# correlated +0.99 and another moved opposite. So this harness measures coverage instead of assuming
# it, and a night whose windows were barely sampled is flagged rather than quietly averaged.
#
# What is treated as robust: that a periodic window EXISTS and has a stable length. What is NOT
# assumed: the period, and above all the phase offset — neither is guaranteed to hold across straps
# or firmware, so detect_duty_cycle() measures both per capture and reports what it found. The 1200 s
# figure below is used only as a minimum-evidence bar, never as a detector input.
NOMINAL_DUTY_PERIOD_S = 1200
CONTINUOUS_NONZERO_FRACTION = 0.5   # ≥ this share nonzero ⇒ not duty-cycled; every second is a sample
MIN_DUTY_WINDOWS = 3                # fewer observed windows than this ⇒ no period worth claiming
DEFAULT_MIN_WINDOW_COVERAGE = 0.5   # below this share of a night's windows, its mean means little

# "Feature absent" evidence bar. To call @82 absent rather than merely un-sampled, the capture must
# be long enough that a duty-cycled feature would have fired several times while the wearer slept.
ABSENT_MIN_RECORDS = 100
ABSENT_MIN_ASLEEP_SPAN_S = 3 * NOMINAL_DUTY_PERIOD_S

# ...and it must have been sampled FINELY enough to see one of those firings. Duration is not enough,
# because missing the window is a phase problem, not a length one: a cadence that shares a large
# factor with the period only ever occupies `period // gcd` residues, so it either always lands inside
# the window or never does. At 300 s against the reference 1200 s that is 4 residues — six nights of
# eight hours' scored sleep clear both bars above and still read a flat 0x00 off a perfectly healthy
# strap. This is the aliasing documented at the top of this file, turned on our own absence claim.
#
# A cadence at or below the window length cannot skip a window, whatever the phase, so that is the
# bar. Same caveat as NOMINAL_DUTY_PERIOD_S: 30 s is the reference strap's window, not a law — it is
# used only as a minimum-evidence figure, never as a detector input. A coarser capture that reads all
# zeros stays a plain FAIL, which is the conservative direction: `feature_absent` REMOVES a device
# from the multi-device gate, so over-claiming absence makes promotion easier, not harder.
NOMINAL_DUTY_WINDOW_S = 30

# --- Variance floor --------------------------------------------------------------------------------
# "The value lands in 70–100" is not a specific screen. On a real subscription-free 5.0 strap SIX
# offsets pass an in-band-only screen on a majority of records — @17, @33, @59, @69, @71, @107 — and
# every one is either an already-decoded non-SpO₂ field (@33 cardiac_flags, @59 step_cadence, @69/@71
# the two aux thermal channels) or near-constant: @17 is byte 2 of the u32 unix timestamp at @15 and
# reads 99–100 for a day and a half of wall clock, and @107 has 4 distinct values. A nightly SpO₂
# cannot have 2 distinct values, so an offset must clear a variation floor before its correlation is
# worth ranking — otherwise a 2-valued byte can win a 5-night |r| race by coincidence alone.
MIN_DISTINCT_INBAND = 5
MIN_INBAND_STDEV = 0.5

# English + localized cycle headers → canonical keys (mirrors StrandImport HeaderNorm subset).
HEADER_ALIASES = {
    # English (official export; lowercase after norm)
    "cycle start time": "cycle_start_time",
    "cycle end time": "cycle_end_time",
    "sleep onset": "sleep_onset",
    "wake onset": "wake_onset",
    "blood oxygen %": "blood_oxygen_pct",
    "skin temp (celsius)": "skin_temp_celsius",
    "resting heart rate (bpm)": "resting_heart_rate_bpm",
    "heart rate variability (ms)": "heart_rate_variability_ms",
    "respiratory rate (rpm)": "respiratory_rate_rpm",
    # German
    "startzeit des zyklus": "cycle_start_time",
    "blutsauerstoff %": "blood_oxygen_pct",
    "hauttemperatur (celsius)": "skin_temp_celsius",
    # Spanish
    "hora de inicio del ciclo": "cycle_start_time",
    "oxígeno en sangre %": "blood_oxygen_pct",
    "temp. cutánea (grados centígrados)": "skin_temp_celsius",
}

CYCLES_FILES = {
    "physiological_cycles.csv",
    "physiologische_zyklen.csv",
    "ciclos_fisiologicos.csv",
}


# --- CSV ground truth ------------------------------------------------------------------------------

def _norm_header(h: str) -> str:
    key = h.strip().lower().lstrip("\ufeff")
    return HEADER_ALIASES.get(key, key)


def _parse_float(raw: str) -> Optional[float]:
    raw = (raw or "").strip()
    if not raw:
        return None
    try:
        return float(raw.replace(",", "."))
    except ValueError:
        return None


def _parse_export_ts(raw: str) -> Optional[int]:
    """Parse WHOOP export timestamps to unix seconds (naive wall clock → UTC for windowing).

    Export stamps are wall-clock; for night bucketing we only need a consistent second scale
    that lines up with the strap's unix field. Absolute TZ offset cancels out when both sides
    use the same convention for a given local night.
    """
    raw = (raw or "").strip()
    if not raw:
        return None
    cleaned = raw.replace("T", " ").rstrip("Z")
    for n, fmt in ((19, "%Y-%m-%d %H:%M:%S"), (16, "%Y-%m-%d %H:%M")):
        try:
            dt = datetime.strptime(cleaned[:n], fmt)
            return int(dt.replace(tzinfo=timezone.utc).timestamp())
        except ValueError:
            continue
    return None


def load_cycles(export_path: str) -> List[dict]:
    """Load physiological cycle rows with canonical keys from a WHOOP export zip/folder."""
    files: Dict[str, str] = {}
    if zipfile.is_zipfile(export_path):
        with zipfile.ZipFile(export_path) as z:
            for name in z.namelist():
                base = name.rsplit("/", 1)[-1].lower()
                if base.endswith(".csv"):
                    files[base] = z.read(name).decode("utf-8-sig", errors="replace")
    else:
        for root, _dirs, names in os.walk(export_path):
            for n in names:
                if n.lower().endswith(".csv"):
                    with open(os.path.join(root, n), encoding="utf-8-sig", errors="replace") as f:
                        files[n.lower()] = f.read()

    text = None
    for base, body in files.items():
        if base in CYCLES_FILES:
            text = body
            break
    if text is None:
        # Header sniff: any CSV that carries blood oxygen + cycle start.
        for body in files.values():
            head = body.splitlines()[0].lower() if body else ""
            if "blood oxygen" in head or "blutsauerstoff" in head or "oxígeno en sangre" in head:
                text = body
                break
    if not text:
        return []

    reader = csv.reader(io.StringIO(text))
    rows = list(reader)
    if not rows:
        return []
    headers = [_norm_header(h) for h in rows[0]]
    out = []
    for raw in rows[1:]:
        if not any(cell.strip() for cell in raw):
            continue
        row = {headers[i]: raw[i] for i in range(min(len(headers), len(raw)))}
        spo2 = _parse_float(row.get("blood_oxygen_pct", ""))
        if spo2 is None:
            continue  # incomplete night / nap without SpO₂ — not a validation target
        sleep0 = _parse_export_ts(row.get("sleep_onset", ""))
        sleep1 = _parse_export_ts(row.get("wake_onset", ""))
        cyc0 = _parse_export_ts(row.get("cycle_start_time", ""))
        cyc1 = _parse_export_ts(row.get("cycle_end_time", ""))
        # Prefer sleep window; fall back to cycle span.
        t0 = sleep0 if sleep0 is not None else cyc0
        t1 = sleep1 if sleep1 is not None else cyc1
        if t0 is None:
            continue
        if t1 is None:
            t1 = t0 + 12 * 3600  # open-ended night: generous upper bound
        if t1 <= t0:
            t1 = t0 + 12 * 3600
        out.append({
            "cycle_start_time": row.get("cycle_start_time", ""),
            "spo2_export": spo2,
            "t0": t0,
            "t1": t1,
        })
    return out


# --- Capture decode --------------------------------------------------------------------------------

def looks_like_sqlite(path: str) -> bool:
    """True if `path` is a SQLite file. Sniffs the 16-byte header rather than trusting the extension,
    since capture DBs get renamed freely (`whoop.db`, `strap-a.db`, no suffix at all)."""
    try:
        with open(path, "rb") as f:
            return f.read(16) == b"SQLite format 3\x00"
    except OSError:
        return False


# --- NOOP app database ------------------------------------------------------------------------------
#
# #845/#103: the app banks @82 (PR #848 added `v18AuxSample`), but until this path existed the harness
# could only read the CAPTURE TOOLING's store — so a NOOP user could not run the promote gate on their
# own synced data, and only someone running linux-capture could contribute evidence. That is the gap
# #845 called "the app itself cannot currently contribute the data needed to resolve its own question".
#
# READ-ONLY, and opened as such: `mode=ro` plus `immutable=1` so no WAL recovery write is attempted
# against a file pulled off a phone (the same reasoning `Tools/SleepBench` documents).

# `V18AuxSlot` order and widths, mirrored from Streams.swift. Order IS the wire contract — the packed
# body carries present slots in ascending slot order — so this list must not be reordered.
V18_AUX_SLOTS: Sequence[Tuple[str, int]] = (
    ("record_index", 4), ("rr_count", 1), ("cardiac_flags", 1), ("hr_quality_flags", 1),
    ("heart_rate_alt", 1), ("rr_packed", 2), ("cardiac_status", 1), ("step_cadence", 1),
    ("status_word", 2), ("status_word_1", 2), ("status_word_2", 2), ("aux_byte_82", 1),
    ("optical_baseline_a", 1), ("optical_baseline_b", 1), ("optical_amp_a", 1),
    ("optical_amp_b", 1), ("unknown_f32_113", 4),
)
V18_AUX_FORMAT_VERSION = 2
V18_AUX_HEADER_BYTES = 5


def unpack_v18_aux(blob: bytes) -> Dict[str, int]:
    """Decode a `v18AuxSample.fields` blob. Python port of Swift `V18AuxCodec.unpack`.

    Wire format (little-endian, no padding): version byte, u32 presence bitmap, then each PRESENT slot's
    value in ascending slot order at its declared width.

    Absence is first-class — a clear bit means "the strap did not report this field", never 0 — so the
    returned dict simply omits it. A malformed, truncated or unknown-version blob yields `{}` rather than
    raising, matching the Swift/Kotlin readers: a census over durable rows must not die on one bad row.
    """
    if len(blob) < V18_AUX_HEADER_BYTES or blob[0] != V18_AUX_FORMAT_VERSION:
        return {}
    bitmap = int.from_bytes(blob[1:5], "little")
    out: Dict[str, int] = {}
    i = V18_AUX_HEADER_BYTES
    for slot, (name, width) in enumerate(V18_AUX_SLOTS):
        if not bitmap & (1 << slot):
            continue
        if i + width > len(blob):
            break        # truncated tail: keep what decoded, drop the rest
        out[name] = int.from_bytes(blob[i:i + width], "little")
        i += width
    return out


def looks_like_app_db(path: str) -> bool:
    """True if `path` is a NOOP app store (GRDB/iOS/macOS) rather than a `whoop_sync.py` capture DB.

    Discriminated on the `v18AuxSample` table, which only the app has; the capture store has `frames`
    and the app has no `frames` table at all.
    """
    if not looks_like_sqlite(path):
        return False
    try:
        con = sqlite3.connect(f"file:{path}?mode=ro&immutable=1", uri=True)
    except sqlite3.Error:
        return False
    try:
        row = con.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='v18AuxSample'"
        ).fetchone()
        return row is not None
    except sqlite3.Error:
        return False
    finally:
        con.close()


def load_app_db_records(path: str, *, device_id: Optional[str] = None) -> List[dict]:
    """Records from a NOOP app store, shaped like `iter_v18_records` output.

    Joins `v18AuxSample` (the banked per-second slots, #848) to `sleepStateSample.state` on
    (deviceId, ts) — the band's own sleep state, which the asleep-only gate needs.

    ONE STRUCTURAL LIMITATION, and it is not a bug: the raw frame is gone. The strap trims its history
    once NOOP acks the offload and the app banks decoded slots, not frame bytes, so the OFFSET
    SPECIFICITY SCAN (which reads neighbour bytes @70-@100 out of `_frame`) cannot run on this path.
    The correlation, MAE, bias, duty-cycle detection and window coverage all can. Records therefore
    carry no `_frame` key, which the scan already treats as "skip", and `main` says so rather than
    printing an empty scan that reads like a negative result.
    """
    con = sqlite3.connect(f"file:{path}?mode=ro&immutable=1", uri=True)
    try:
        devices = [r[0] for r in con.execute("SELECT DISTINCT deviceId FROM v18AuxSample").fetchall()]
        if not devices:
            raise SystemExit(f"{path}: no v18AuxSample rows — nothing banked from a 5/MG v18 offload yet")
        if device_id is None:
            if len(devices) > 1:
                raise SystemExit(
                    f"{path}: {len(devices)} devices in v18AuxSample ({', '.join(sorted(devices))}); "
                    f"pass --app-device to pick one — pooling straps would average away the very "
                    f"per-device difference the promote gate is testing"
                )
            device_id = devices[0]
        elif device_id not in devices:
            raise SystemExit(f"{path}: no v18AuxSample rows for deviceId={device_id!r} "
                             f"(have: {', '.join(sorted(devices))})")
        rows = con.execute(
            "SELECT a.ts, a.fields, s.state FROM v18AuxSample a "
            "LEFT JOIN sleepStateSample s ON s.deviceId = a.deviceId AND s.ts = a.ts "
            "WHERE a.deviceId = ? ORDER BY a.ts",
            (device_id,),
        ).fetchall()
    except sqlite3.Error as e:
        raise SystemExit(f"{path}: not a readable NOOP app store ({e})")
    finally:
        con.close()

    out: List[dict] = []
    for ts, blob, state in rows:
        fields = unpack_v18_aux(bytes(blob) if blob is not None else b"")
        raw82 = fields.get("aux_byte_82")
        rec = dict(fields)
        rec["unix"] = ts
        rec["sleep_state"] = state
        rec["aux_byte_82"] = raw82 if raw82 is not None else 0
        rec["spo2_candidate_82"] = raw82 if raw82 in INBAND else None
        out.append(rec)
    if not out:
        raise SystemExit(f"{path}: no v18AuxSample rows for deviceId={device_id!r}")
    return out


def load_frame_records(path: str, *, device_id: int = 2) -> List[dict]:
    """Frame records as `{"hex": ...}` dicts, from EITHER a capture.json or a `whoop_sync.py` store.

    The JSON path is what hci_extract / whoop_capture produce. The SQLite path reads the `frames`
    table that `whoop_sync.py` writes (`captures/whoop.db`) and `whoop_activity.py` reads.

    NOTE: this is the CAPTURE TOOLING's database, not the app's. Neither shipped app has a `frames`
    table — Android uses Room, iOS/macOS uses GRDB — so this cannot be pointed at a phone's store or
    a `.noopbak`. It exists because `whoop_sync.py` writes `.db` while this tool read only `.json`,
    forcing a `whoop_sync.py export --only-type 47` round-trip between two tools in the same
    directory.
    """
    if looks_like_sqlite(path):
        con = sqlite3.connect(path)
        try:
            # Filter to v18 IN SQL, not after loading. hist_version sits at frame offset 9, i.e. hex
            # chars 19-20 (substr is 1-indexed), and 0x12 == 18. Newer 5/MG firmware serves a
            # v20 (2140 B) + v21 (1244 B) pair every second alongside the 124-byte v18, so a mixed
            # corpus is mostly bytes this tool discards: measured 115 MB to reach 20k usable records
            # unfiltered, against 56 MB for 50k when the store is pure v18. Only v18 carries @82.
            rows = con.execute(
                "SELECT hex FROM frames WHERE device_id=? AND inner_type=47 "
                "AND substr(hex, 19, 2) = '12'",
                (device_id,),
            ).fetchall()
            if not rows:
                # Distinguish "no v18" from "no frames at all" — they need different fixes.
                any47 = con.execute(
                    "SELECT COUNT(*) FROM frames WHERE device_id=? AND inner_type=47", (device_id,)
                ).fetchone()[0]
                if any47:
                    raise SystemExit(
                        f"{path}: {any47} type-47 frames for device_id={device_id}, but none are "
                        f"v18 — @82 only exists in the v18 layout"
                    )
        except sqlite3.Error as e:
            raise SystemExit(f"{path}: not a whoop_sync.py frame store ({e})")
        finally:
            con.close()
        if not rows:
            raise SystemExit(
                f"{path}: no type-47 frames for device_id={device_id} "
                f"(try --device-id; whoop_activity.py defaults to 2)"
            )
        return [{"hex": r[0]} for r in rows]

    with open(path) as f:
        capture = json.load(f)
    if not isinstance(capture, list):
        raise SystemExit(f"{path}: expected a JSON list of frame records, or a whoop_sync.py .db")
    return capture


def iter_v18_records(capture_records: Sequence[dict]) -> Iterable[dict]:
    """Yield decoded v18 fields from capture.json entries (absolute frame offsets)."""
    for rec in capture_records:
        hx = rec.get("hex") if isinstance(rec, dict) else None
        if not hx:
            continue
        try:
            frame = bytes.fromhex(hx)
        except ValueError:
            continue
        if len(frame) <= 116:
            continue
        # Prefer CRC-valid WHOOP 5 frames; still accept synthetic absolute buffers used in tests
        # (make_v18 style: length 124, hist_version @9, no real CRC).
        if frame[0] == 0xAA and len(frame) > 8:
            if not (wf.verify_whoop5_frame(frame) or frame[OFF_HIST_VERSION] == 18):
                continue
        d = wa.decode_v18(frame)
        if d is None:
            continue
        d = dict(d)
        raw82 = frame[OFF_SPO2_CANDIDATE] if len(frame) > OFF_SPO2_CANDIDATE else d.get("aux_byte_82", 0)
        d["aux_byte_82"] = raw82
        d["spo2_candidate_82"] = raw82 if raw82 in INBAND else None
        # Neighbor bytes for specificity scan (absolute offsets).
        d["_frame"] = frame
        yield d


def byte_at_offset(rec: dict, offset: int) -> Optional[int]:
    """The raw byte at absolute frame `offset` for one record, or None when it is unavailable.

    Frame-derived records carry `_frame` and any offset can be read from it. Records loaded from a NOOP
    app store do NOT — the app banks decoded slots, not frame bytes — so only @82 is answerable there,
    from the banked `aux_byte_82`. Every other offset returns None, which is what correctly confines the
    OFFSET SPECIFICITY SCAN to captures while leaving the @82 correlation itself fully available.

    Returning None (not 0) matters: 0 is a legitimate @82 reading outside the duty window, and treating
    "cannot know" as "read zero" would manufacture out-of-band samples that silently depress coverage.
    """
    frame = rec.get("_frame")
    if frame is not None:
        return frame[offset] if len(frame) > offset else None
    if offset == OFF_SPO2_CANDIDATE:
        v = rec.get("aux_byte_82")
        return v if isinstance(v, int) else None
    return None


# --- Duty-cycle detection --------------------------------------------------------------------------

def _median_record_interval(records: Sequence[dict]) -> float:
    """Median seconds between consecutive records. Sets the run-gap tolerance so detection works on a
    1 Hz capture and on a sparser one without a hard-coded cadence."""
    stamps = sorted({r["unix"] for r in records})
    deltas = [b - a for a, b in zip(stamps, stamps[1:]) if b > a]
    return float(statistics.median(deltas)) if deltas else 1.0


def _circ_dist(a: int, b: int, period: int) -> int:
    d = abs(a - b) % period
    return min(d, period - d)


def detect_duty_cycle(records: Sequence[dict], *, gap_tolerance_s: Optional[float] = None) -> dict:
    """Measure @82's on/off schedule from the capture itself. Nothing about it is hard-coded.

    Returns a dict whose `mode` is one of:
      absent       — @82 is 0x00 on every record (the feature never fired, or is not present)
      continuous   — @82 is nonzero on most records (no duty cycle to correct for)
      duty_cycled  — nonzero only in a repeating, phase-locked window; period/phase/length measured
      irregular    — nonzero sometimes, but with no period the harness is willing to claim

    Only `duty_cycled` changes how nights are aggregated; the other modes fall through to the
    per-sample behaviour, so a capture this cannot characterise is never silently reweighted.
    """
    n = len(records)
    nonzero = [r for r in records if r.get("aux_byte_82")]
    interval = _median_record_interval(records)
    tol = gap_tolerance_s if gap_tolerance_s is not None else max(2.0 * interval, 2.0)

    info = {
        "mode": "absent",
        "n_records": n,
        "n_nonzero": len(nonzero),
        "nonzero_fraction": (len(nonzero) / n) if n else 0.0,
        "distinct_values": len({r["aux_byte_82"] for r in nonzero}),
        "record_interval_s": interval,
        "period_s": None,
        "phase_s": None,
        "window_len_s": None,
        "windows_observed": 0,
        "window_len_stable": None,
        "phase_jitter_s": None,
    }
    if not nonzero:
        return info
    if info["nonzero_fraction"] >= CONTINUOUS_NONZERO_FRACTION:
        info["mode"] = "continuous"
        return info

    # Group the nonzero seconds into runs; a run is one firing of the window.
    stamps = sorted({r["unix"] for r in nonzero})
    runs: List[List[int]] = [[stamps[0]]]
    for prev, cur in zip(stamps, stamps[1:]):
        if cur - prev <= tol:
            runs[-1].append(cur)
        else:
            runs.append([cur])
    spans = [run[-1] - run[0] + 1 for run in runs]
    starts = [run[0] for run in runs]
    info["windows_observed"] = len(runs)
    info["window_len_s"] = int(statistics.median(spans))
    info["window_len_stable"] = len(set(spans)) == 1

    if len(starts) < MIN_DUTY_WINDOWS:
        info["mode"] = "irregular"
        return info
    period = int(statistics.median(b - a for a, b in zip(starts, starts[1:])))
    if period <= info["window_len_s"]:
        info["mode"] = "irregular"
        return info

    # Circular medoid: the candidate phase closest to all the others, wrap-safe.
    phases = [s % period for s in starts]
    phase = min(phases, key=lambda p: sum(_circ_dist(p, q, period) for q in phases))
    jitter = max(_circ_dist(p, phase, period) for p in phases)
    info.update(period_s=period, phase_s=phase, phase_jitter_s=jitter)
    info["mode"] = "duty_cycled" if jitter <= max(tol, 1) else "irregular"
    return info


def is_duty_cycled(duty: Optional[dict]) -> bool:
    return bool(duty) and duty.get("mode") == "duty_cycled"


def window_index(u: int, duty: dict) -> int:
    return (u - duty["phase_s"]) // duty["period_s"]


def in_duty_window(u: int, duty: dict) -> bool:
    return (u - duty["phase_s"]) % duty["period_s"] < duty["window_len_s"]


def duty_windows_in(t0: int, t1: int, duty: Optional[dict]) -> List[Tuple[int, int]]:
    """The duty windows whose start falls in [t0, t1), from the DETECTED schedule."""
    if not is_duty_cycled(duty):
        return []
    period, phase, wlen = duty["period_s"], duty["phase_s"], duty["window_len_s"]
    if t1 <= t0 or (t1 - t0) // period > 100_000:
        return []
    out = []
    s = t0 + ((phase - t0) % period)
    while s < t1:
        out.append((s, s + wlen))
        s += period
    return out


def night_window_coverage(
    records: Sequence[dict], t0: int, t1: int, duty: Optional[dict]
) -> Tuple[Optional[int], Optional[int]]:
    """(windows sampled, windows expected) for one night, or (None, None) if not duty-cycled.

    Deliberately ignores sleep_state: this measures the CAPTURE, answering "did it sample the window
    at all" — the failure mode a phase-unaligned capture hits — and keeps that separable from "the
    wearer was awake", which is what the asleep filter on the aggregate already handles.
    """
    windows = duty_windows_in(t0, t1, duty)
    if not windows:
        return (None, None)
    expected = {window_index(s, duty) for s, _ in windows}
    sampled = {
        window_index(r["unix"], duty)
        for r in records
        if t0 <= r["unix"] < t1 and in_duty_window(r["unix"], duty)
    }
    return (len(sampled & expected), len(expected))


def night_mean_at_offset(
    records: Sequence[dict],
    t0: int,
    t1: int,
    offset: int,
    *,
    require_asleep: bool = True,
    duty: Optional[dict] = None,
) -> Optional[Tuple[float, int]]:
    """Nightly aggregate of in-band u8 samples at `offset` inside [t0, t1). Returns (mean, n) or None.

    On a duty-cycled capture only in-window samples count, and the aggregate is the mean of the
    per-window means — one number per firing of the window, not one per second. A 30-second burst is
    one measurement the strap took, not 30 independent ones; averaging per second silently weights
    the night towards whichever windows the capture happened to sample most densely.
    """
    duty_cycled = is_duty_cycled(duty)
    per_window: Dict[int, List[int]] = {}
    vals: List[int] = []
    for r in records:
        u = r["unix"]
        if u < t0 or u >= t1:
            continue
        if require_asleep and r.get("sleep_state") != SLEEP_ASLEEP:
            continue
        v = byte_at_offset(r, offset)
        if v is None or v not in INBAND:
            continue
        if duty_cycled:
            if not in_duty_window(u, duty):
                continue
            per_window.setdefault(window_index(u, duty), []).append(v)
        vals.append(v)
    if not vals:
        return None
    if duty_cycled:
        return (statistics.fmean(statistics.fmean(w) for w in per_window.values()), len(vals))
    return (statistics.fmean(vals), len(vals))


def offset_variability(
    records: Sequence[dict],
    offset: int,
    *,
    require_asleep: bool = True,
    duty: Optional[dict] = None,
) -> Tuple[int, float]:
    """(distinct values, stdev) of the in-band samples at `offset`, pooled over the whole capture.

    The specificity scan's floor: a byte with 2–4 distinct values across every record is a flag or an
    enum that happens to land in 70–100, not a nightly measurement, however well it correlates.
    """
    duty_cycled = is_duty_cycled(duty)
    vals = []
    for r in records:
        if require_asleep and r.get("sleep_state") != SLEEP_ASLEEP:
            continue
        if duty_cycled and not in_duty_window(r["unix"], duty):
            continue
        v = byte_at_offset(r, offset)
        if v is not None and v in INBAND:
            vals.append(v)
    if not vals:
        return (0, 0.0)
    return (len(set(vals)), statistics.pstdev(vals) if len(vals) > 1 else 0.0)


def pearson_r(xs: Sequence[float], ys: Sequence[float]) -> Optional[float]:
    n = len(xs)
    if n < 2:
        return None
    mx = statistics.fmean(xs)
    my = statistics.fmean(ys)
    num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    denx = math.sqrt(sum((x - mx) ** 2 for x in xs))
    deny = math.sqrt(sum((y - my) ** 2 for y in ys))
    if denx == 0 or deny == 0:
        return None
    return num / (denx * deny)


def mae(xs: Sequence[float], ys: Sequence[float]) -> Optional[float]:
    if not xs:
        return None
    return statistics.fmean(abs(x - y) for x, y in zip(xs, ys))


# --- Per-device validation -------------------------------------------------------------------------

def validate_device(
    capture_path: str,
    export_path: str,
    *,
    device: str = "device",
    require_asleep: bool = True,
    device_id: int = 2,
    app_device: Optional[str] = None,
    min_window_coverage: float = DEFAULT_MIN_WINDOW_COVERAGE,
    min_distinct: int = MIN_DISTINCT_INBAND,
) -> dict:
    # A NOOP app store and a whoop_sync.py capture store are both SQLite; they are told apart by the
    # `v18AuxSample` table rather than by extension or by a flag, so a user does not have to know which
    # kind of file they were handed.
    from_app_db = looks_like_app_db(capture_path)
    if from_app_db:
        records = load_app_db_records(capture_path, device_id=app_device)
    else:
        records = list(iter_v18_records(load_frame_records(capture_path, device_id=device_id)))

    cycles = load_cycles(export_path)

    # Measure the on/off schedule before averaging anything against it.
    duty = detect_duty_cycle(records)

    nights = []
    for c in cycles:
        covered, expected = night_window_coverage(records, c["t0"], c["t1"], duty)
        coverage = (covered / expected) if expected else None
        night = {
            "cycle_start_time": c["cycle_start_time"],
            "export": c["spo2_export"],
            "candidate_mean": None,
            "n_samples": 0,
            "matched": False,
            "windows_sampled": covered,
            "windows_expected": expected,
            "coverage": coverage,
            "low_coverage": coverage is not None and coverage < min_window_coverage,
        }
        hit = night_mean_at_offset(
            records, c["t0"], c["t1"], OFF_SPO2_CANDIDATE, require_asleep=require_asleep, duty=duty
        )
        if hit is not None:
            mean_v, n = hit
            night.update(
                candidate_mean=mean_v,
                n_samples=n,
                matched=True,
                abs_err=abs(mean_v - c["spo2_export"]),
            )
        nights.append(night)

    paired_export = [n["export"] for n in nights if n["matched"]]
    paired_cand = [n["candidate_mean"] for n in nights if n["matched"]]
    r = pearson_r(paired_export, paired_cand) if len(paired_cand) >= 2 else None
    err = mae(paired_export, paired_cand)
    bias = (
        statistics.fmean(c - e for c, e in zip(paired_cand, paired_export))
        if paired_cand else None
    )

    # Offset specificity: among SPECIFICITY_SCAN, which offset maximises |r| on paired nights?
    # An offset must clear the variation floor first — see MIN_DISTINCT_INBAND. Without it a byte
    # holding 2 distinct in-band values can top the ranking on 5 nights by coincidence.
    spec_scores = []
    rejected = []
    for off in SPECIFICITY_SCAN:
        distinct, sd = offset_variability(records, off, require_asleep=require_asleep, duty=duty)
        if distinct < min_distinct or sd < MIN_INBAND_STDEV:
            if distinct:
                rejected.append({"offset": off, "distinct": distinct, "stdev": sd})
            continue
        xs, ys = [], []
        for c in cycles:
            hit = night_mean_at_offset(
                records, c["t0"], c["t1"], off, require_asleep=require_asleep, duty=duty
            )
            if hit is None:
                continue
            xs.append(c["spo2_export"])
            ys.append(hit[0])
        rr = pearson_r(xs, ys) if len(xs) >= 2 else None
        if rr is not None:
            spec_scores.append({"offset": off, "r": rr, "nights": len(xs)})
    spec_scores.sort(key=lambda s: abs(s["r"]), reverse=True)
    best_off = spec_scores[0]["offset"] if spec_scores else None
    r_at_82 = next((s["r"] for s in spec_scores if s["offset"] == OFF_SPO2_CANDIDATE), r)
    distinct_82, stdev_82 = offset_variability(
        records, OFF_SPO2_CANDIDATE, require_asleep=require_asleep, duty=duty
    )

    covs = [n["coverage"] for n in nights if n["coverage"] is not None]
    median_coverage = statistics.median(covs) if covs else None
    low_cov_nights = sum(1 for n in nights if n["low_coverage"])

    # Checklist gates (docs/WHOOP5_DEEP_DATA.md) — conservative defaults for instrumentation.
    n_paired = len(paired_cand)
    checklist = {
        "min_nights": n_paired >= 5,
        "real_spread": (
            (max(paired_export) - min(paired_export) >= 1.0) if n_paired >= 2 else False
        ),
        "corr_ge_0_7": (r is not None and r >= 0.7),
        "mae_le_1_0": (err is not None and err <= 1.0),
        # From an app store the scan CANNOT run — the app banks decoded slots, so no neighbour byte
        # exists to compare @82 against. Reporting False there would fail the gate for a reason that is
        # about the input format, not the data, and "@82 did not win" is exactly the wrong thing to
        # record about a strap whose byte was never ranked. n/a is the honest value; `specificity_scan`
        # below says which of the two happened so a reader cannot mistake one for the other.
        "offset_82_wins": True if from_app_db else best_off == OFF_SPO2_CANDIDATE,
        # A byte with a handful of distinct values cannot be a nightly SpO₂ however well it correlates.
        "value_variance": distinct_82 >= min_distinct and stdev_82 >= MIN_INBAND_STDEV,
        # n/a (True) unless a duty cycle was detected and coverage could actually be measured.
        "window_coverage": median_coverage is None or median_coverage >= min_window_coverage,
    }
    checklist["pass"] = all(checklist.values())

    # A strap that never emits @82 has not failed a correlation — it has no data to correlate. Say so
    # explicitly, but only once the capture actually WATCHED the strap long enough, and finely enough,
    # that a duty-cycled feature would have fired where the capture could see it.
    #
    # Both halves of that are easy to get wrong in the same direction:
    #   • Long enough is OBSERVED time, not wall-clock span. max-minus-min counts the gaps, so a
    #     capture that ran densely for two minutes and then logged one record eight hours later scores
    #     an 8 h "span" off 121 s of observation. Sleep samples times cadence is what was watched.
    #   • Finely enough is NOMINAL_DUTY_WINDOW_S. Missing the window is a phase problem: a cadence
    #     sharing a large factor with the period only ever occupies period//gcd residues, so it either
    #     always lands in the window or never does, and no amount of duration fixes that.
    #
    # Both failures produce the same wrong answer — a working strap reported as lacking the feature —
    # and that error is asymmetric, because feature_absent REMOVES a device from the multi-device gate
    # rather than failing it. Over-claiming absence loosens the promote bar.
    #
    # Both are therefore measured over the ASLEEP records only, on DISTINCT timestamps. Two ways that
    # bites if you take the whole-capture figures instead:
    #   • The global median cadence is set by whichever state has more records. A capture that is 1 Hz
    #     awake and 300 s asleep reports a 1 s cadence and sails through the window gate, while the
    #     part that matters aliases.
    #   • Counting records rather than distinct seconds over-counts a capture that re-delivers the
    #     same historical rows — a resume/reconnect in whoop_sync.py does exactly that — so 200 s of
    #     sleep repeated twenty times scores as 4000 s of observation.
    asleep_records = [r for r in records if r.get("sleep_state") == SLEEP_ASLEEP]
    asleep_stamps = sorted({r["unix"] for r in asleep_records})
    asleep_span = (asleep_stamps[-1] - asleep_stamps[0]) if len(asleep_stamps) >= 2 else 0
    asleep_interval = _median_record_interval(asleep_records) if len(asleep_stamps) >= 2 else None
    observed_asleep_s = len(asleep_stamps) * asleep_interval if asleep_interval else 0
    cadence_could_see_window = (
        asleep_interval is not None and asleep_interval <= NOMINAL_DUTY_WINDOW_S
    )
    feature_absent = (
        duty["mode"] == "absent"
        and len(records) >= ABSENT_MIN_RECORDS
        and observed_asleep_s >= ABSENT_MIN_ASLEEP_SPAN_S
        and cadence_could_see_window
    )
    classification = (
        "feature_absent" if feature_absent else ("pass" if checklist["pass"] else "fail")
    )

    return {
        "device": device,
        # Which store the records came from, and whether the specificity scan was possible on it.
        # Both are reported rather than inferred from the numbers: "no specificity result" means
        # something completely different in the two cases, and a batch pooling both must be able to
        # tell them apart without re-opening the files.
        "source": "noop_app_db" if from_app_db else "capture",
        "specificity_scan": "unavailable_app_db" if from_app_db else "ran",
        "v18_records": len(records),
        "export_nights_with_spo2": len(cycles),
        "paired_nights": n_paired,
        "r": r,
        "r_at_82_specificity": r_at_82,
        "mae": err,
        "bias": bias,
        "best_specificity_offset": best_off,
        "specificity_top3": spec_scores[:3],
        "specificity_rejected_low_variance": rejected,
        "inband_distinct_82": distinct_82,
        "inband_stdev_82": stdev_82,
        "duty": duty,
        "median_window_coverage": median_coverage,
        "low_coverage_nights": low_cov_nights,
        "asleep_span_s": asleep_span,
        # Reported beside the span on purpose: the two diverging is the signature of a capture with
        # gaps, and it is the observed figure the absence claim is gated on. `asleep_interval_s` is
        # the cadence of the ASLEEP records specifically — the whole-capture median in `duty` can be
        # set by a dense awake stretch and hide an aliasing sleep cadence.
        "observed_asleep_s": observed_asleep_s,
        "asleep_interval_s": asleep_interval,
        "classification": classification,
        "checklist": checklist,
        "nights": nights,
        "inband_samples_total": sum(n["n_samples"] for n in nights),
    }


def format_summary(result: dict, *, show_nights: bool = False) -> str:
    """Privacy-safe summary: aggregates only (no raw SpO₂ unless --show-nights)."""
    lines = []
    cl = result["checklist"]
    lines.append(
        f"device={result['device']}  v18_records={result['v18_records']}  "
        f"export_nights={result['export_nights_with_spo2']}  paired={result['paired_nights']}  "
        f"inband_samples={result['inband_samples_total']}"
    )
    r = result["r"]
    mae_v = result["mae"]
    bias = result["bias"]
    lines.append(
        f"  @82 nightly mean vs export:  r="
        f"{'n/a' if r is None else f'{r:+.3f}'}  "
        f"MAE={'n/a' if mae_v is None else f'{mae_v:.3f}'}  "
        f"bias={'n/a' if bias is None else f'{bias:+.3f}'}"
    )
    lines.append(format_duty_line(result))
    cov = result.get("median_window_coverage")
    if cov is not None:
        lines.append(
            f"  window coverage: median={cov:.0%} over {result['export_nights_with_spo2']} nights  "
            f"low_coverage_nights={result['low_coverage_nights']}"
        )
    lines.append(
        f"  specificity: best_offset={result['best_specificity_offset']}  "
        f"@82 distinct_inband={result.get('inband_distinct_82', 0)} "
        f"stdev={result.get('inband_stdev_82', 0.0):.2f}  "
        f"top3="
        + ", ".join(
            f"@{s['offset']} r={s['r']:+.3f} (n={s['nights']})"
            for s in result.get("specificity_top3", [])
        )
    )
    rejected = result.get("specificity_rejected_low_variance", [])
    if rejected:
        lines.append(
            "  rejected by variance floor (in-band but near-constant): "
            + ", ".join(f"@{s['offset']}({s['distinct']}v)" for s in rejected)
        )
    flags = " ".join(
        f"{k}={'PASS' if v else 'FAIL'}"
        for k, v in cl.items()
        if k != "pass"
    )
    lines.append(f"  checklist: {flags}")
    lines.append(f"  OVERALL: {OVERALL_TEXT[result.get('classification', 'fail')]}")
    for w in coverage_warnings(result):
        lines.append(f"  !! {w}")
    if show_nights:
        lines.append("  per-night (local only — do not post raw values):")
        for n in result["nights"]:
            cov_s = (
                f"  windows={n['windows_sampled']}/{n['windows_expected']}"
                if n["windows_expected"] else ""
            )
            warn = "  !! LOW COVERAGE" if n["low_coverage"] else ""
            if not n["matched"]:
                lines.append(
                    f"    {n['cycle_start_time']}: export={n['export']:.2f}  candidate=—  "
                    f"(no in-band samples){cov_s}{warn}"
                )
            else:
                lines.append(
                    f"    {n['cycle_start_time']}: export={n['export']:.2f}  "
                    f"candidate={n['candidate_mean']:.2f}  n={n['n_samples']}  "
                    f"|err|={n['abs_err']:.2f}{cov_s}{warn}"
                )
    return "\n".join(lines)


OVERALL_TEXT = {
    "pass": "PASS (candidate strengthens)",
    "fail": "FAIL (keep instrumentation-only)",
    "feature_absent": (
        "FEATURE ABSENT (@82 flat 0x00 across the capture — neither a PASS nor a FAIL; "
        "excluded from the multi-device gate)"
    ),
}


def format_duty_line(result: dict) -> str:
    """One line describing the DETECTED @82 schedule. Timing only — no health values."""
    d = result.get("duty") or {}
    mode = d.get("mode", "unknown")
    head = (
        f"  @82 duty cycle: mode={mode}  nonzero={d.get('n_nonzero', 0)}/{d.get('n_records', 0)} "
        f"({d.get('nonzero_fraction', 0.0):.2%})  distinct_values={d.get('distinct_values', 0)}"
    )
    if mode == "absent":
        # Say WHY an all-zero capture was not allowed to claim absence, rather than letting it read as
        # a plain FAIL for no stated reason. Same principle as reporting rejected offsets.
        #
        # Reads the ASLEEP cadence, not `duty.record_interval_s` — the whole-capture median is what
        # the gate deliberately does not trust, so quoting it here would print a reassuring number
        # while the claim was refused on a different one.
        interval = result.get("asleep_interval_s")
        observed = result.get("observed_asleep_s") or 0
        if interval is not None and interval > NOMINAL_DUTY_WINDOW_S:
            head += (
                f"\n    NOT claiming feature_absent: {interval:g}s asleep cadence is coarser than a "
                f"nominal {NOMINAL_DUTY_WINDOW_S}s window, so an aliased capture could read 0x00 off a "
                f"working strap. Recapture at ≤{NOMINAL_DUTY_WINDOW_S}s to make an absence claim."
            )
        elif observed < ABSENT_MIN_ASLEEP_SPAN_S:
            head += (
                f"\n    NOT claiming feature_absent: only {observed:.0f}s of sleep actually observed "
                f"(need {ABSENT_MIN_ASLEEP_SPAN_S}s). Wall-clock span counts gaps; this counts samples."
            )
        return head
    if mode != "duty_cycled":
        return head
    return (
        head
        + f"\n    detected: period={d['period_s']}s  window={d['window_len_s']}s  "
        f"phase=unix%{d['period_s']}∈[{d['phase_s']},{d['phase_s'] + d['window_len_s'] - 1}]  "
        f"windows_seen={d['windows_observed']}  jitter={d['phase_jitter_s']}s  "
        f"equal_length_windows={d['window_len_stable']}"
    )


def coverage_warnings(result: dict) -> List[str]:
    """Loud, quotable reasons a device's numbers should not be read at face value."""
    out = []
    d = result.get("duty") or {}
    cov = result.get("median_window_coverage")
    if cov is not None and cov < DEFAULT_MIN_WINDOW_COVERAGE:
        out.append(
            f"{result['device']}: only {cov:.0%} of the detected @82 windows were sampled — the "
            f"nightly means are not comparable across devices; re-capture aligned to "
            f"unix%{d.get('period_s')}={d.get('phase_s')}"
        )
    if result.get("low_coverage_nights"):
        out.append(
            f"{result['device']}: {result['low_coverage_nights']} night(s) below the coverage floor "
            f"— their means rest on a fraction of the night's windows"
        )
    if result.get("classification") == "feature_absent":
        out.append(
            f"{result['device']}: @82 is 0x00 on all {d.get('n_records', 0)} v18 records across "
            f"{result.get('asleep_span_s', 0) // 60} min of scored sleep — reported as feature "
            f"absent, not as a failed correlation"
        )
    if d.get("mode") == "irregular":
        out.append(
            f"{result['device']}: @82 fires, but with no period this tool will claim — treating "
            f"every sample as independent, which may over-weight dense bursts"
        )
    return out


def format_postable(results: Sequence[dict]) -> str:
    """One-liner block safe to paste on GitHub #103 (no health values).

    The duty columns are device timing, not health data: period/window/phase are what another owner
    needs to align a capture, and coverage is what says whether a row is worth reading at all.
    """
    lines = [
        "spo2_candidate_82 multi-device validation (validate_spo2_candidate.py)",
        "device,classification,paired_nights,r,mae,bias,best_offset,"
        "duty_mode,duty_period_s,duty_window_s,duty_phase_s,window_coverage,checklist_pass",
    ]
    for res in results:
        r = res["r"]
        mae_v = res["mae"]
        bias = res["bias"]
        d = res.get("duty") or {}
        cov = res.get("median_window_coverage")
        lines.append(
            f"{res['device']},{res.get('classification', 'fail')},{res['paired_nights']},"
            f"{'' if r is None else f'{r:.3f}'},"
            f"{'' if mae_v is None else f'{mae_v:.3f}'},"
            f"{'' if bias is None else f'{bias:.3f}'},"
            f"{res['best_specificity_offset']},"
            f"{d.get('mode', '')},"
            f"{d.get('period_s') or ''},"
            f"{d.get('window_len_s') or ''},"
            f"{'' if d.get('phase_s') is None else d['phase_s']},"
            f"{'' if cov is None else f'{cov:.2f}'},"
            f"{res['checklist']['pass']}"
        )
    # Multi-device aggregate: promote only if every device with ≥5 paired nights passes. A strap that
    # never emits @82 is counted on neither side — it is not evidence for the candidate, and it is
    # not evidence against it either.
    absent = [res for res in results if res.get("classification") == "feature_absent"]
    eligible = [
        res for res in results
        if res["paired_nights"] >= 5 and res.get("classification") != "feature_absent"
    ]
    if eligible:
        all_pass = all(res["checklist"]["pass"] for res in eligible)
        lines.append(
            f"multi_device_eligible={len(eligible)} all_pass={all_pass} "
            f"feature_absent={len(absent)} "
            f"(promote spo2Pct only if all_pass and ≥2 devices)"
        )
    else:
        lines.append(
            f"multi_device_eligible=0 feature_absent={len(absent)} "
            f"(need ≥5 paired nights per device)"
        )
    for res in results:
        for w in coverage_warnings(res):
            lines.append(f"warning: {w}")
    return "\n".join(lines)


# --- CLI -------------------------------------------------------------------------------------------

def main(argv: Optional[Sequence[str]] = None) -> int:
    p = argparse.ArgumentParser(
        description="Validate WHOOP 5/MG v18 spo2_candidate_82 against a CSV export (#103)."
    )
    p.add_argument("capture", nargs="?", help="capture.json (from hci_extract / whoop_capture)")
    p.add_argument("export", nargs="?", help="WHOOP CSV export .zip or folder")
    p.add_argument("--device", default="device", help="label for this strap (default: device)")
    p.add_argument("--device-id", type=int, default=2,
                   help="device_id row filter when the capture is a whoop_sync.py .db "
                        "(default: 2, matching whoop_activity.py)")
    p.add_argument("--app-device", metavar="DEVICE_ID",
                   help="deviceId row filter when the capture is a NOOP APP store (the text strap "
                        "id in v18AuxSample, not the integer --device-id). Optional when the store "
                        "holds exactly one strap; required when it holds several, since pooling "
                        "them would average away the per-device difference the gate is testing")
    p.add_argument(
        "--batch",
        metavar="devices.json",
        help="JSON list of {device,capture,export} for multi-device validation",
    )
    p.add_argument(
        "--show-nights",
        action="store_true",
        help="print per-night export vs candidate (local only — contains health values)",
    )
    p.add_argument(
        "--allow-any-sleep-state",
        action="store_true",
        help="do not require sleep_state=asleep when averaging @82 (debug)",
    )
    p.add_argument(
        "--postable",
        action="store_true",
        help="print a CSV-ish block safe to paste on GitHub (no raw SpO₂ values)",
    )
    p.add_argument(
        "--min-window-coverage",
        type=float,
        default=DEFAULT_MIN_WINDOW_COVERAGE,
        help="share of a night's detected @82 duty windows the capture must sample before its "
             f"nightly mean is treated as meaningful (default: {DEFAULT_MIN_WINDOW_COVERAGE})",
    )
    p.add_argument(
        "--min-distinct-values",
        type=int,
        default=MIN_DISTINCT_INBAND,
        help="distinct in-band values an offset must show to enter the specificity ranking "
             f"(default: {MIN_DISTINCT_INBAND}; a 2-valued byte is a flag, not a measurement)",
    )
    args = p.parse_args(argv)

    require_asleep = not args.allow_any_sleep_state
    results: List[dict] = []

    if args.batch:
        with open(args.batch) as f:
            batch = json.load(f)
        if not isinstance(batch, list) or not batch:
            print("batch file must be a non-empty JSON list", file=sys.stderr)
            return 1
        for entry in batch:
            results.append(
                validate_device(
                    entry["capture"],
                    entry["export"],
                    device=entry.get("device", "device"),
                    device_id=int(entry.get("device_id", args.device_id)),
                    app_device=entry.get("app_device", args.app_device),
                    require_asleep=require_asleep,
                    min_window_coverage=args.min_window_coverage,
                    min_distinct=args.min_distinct_values,
                )
            )
    else:
        if not args.capture or not args.export:
            p.error("capture and export are required unless --batch is set")
        results.append(
            validate_device(
                args.capture,
                args.export,
                device=args.device,
                device_id=args.device_id,
                app_device=args.app_device,
                require_asleep=require_asleep,
                min_window_coverage=args.min_window_coverage,
                min_distinct=args.min_distinct_values,
            )
        )

    for res in results:
        print(format_summary(res, show_nights=args.show_nights))
        print()
    if args.postable or len(results) > 1:
        print("--- postable summary (safe for #103) ---")
        print(format_postable(results))
    # Same warnings on stderr so they survive a redirect of the report into a file.
    for res in results:
        for w in coverage_warnings(res):
            print(f"warning: {w}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
