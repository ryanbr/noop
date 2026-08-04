"""Locate WHOOP record fields by correlating capture frames against a CSV-export ground truth.

An HCI capture (issue #103) gives raw, un-decoded records — type-`0x2F` biometrics and the 5/MG
history types NOOP still skips (see docs/WHOOP5_DEEP_DATA.md). This tool solves the "what byte is
what" problem as *known-plaintext*: the owner's own WHOOP CSV export lists the official per-night
values (HRV, resting HR, skin temp, SpO₂, respiratory rate, sleep-stage minutes), so we search the
records for the byte offset + encoding that reproduces each known value across every night.

    capture.json  +  whoop_export.zip  ──►  correlate_ground_truth.py  ──►  candidate field offsets

Only aggregate offsets are reported — never the health values themselves — so the output is safe to
post on #103 while the CSV (personal health data) and the capture (device identifiers) stay local.

The CSV side reuses the canonical column keys and the German/Spanish/etc. header aliases from the
Swift importer (Packages/StrandImport/.../CSVParsing.swift), kept in sync here as `HEADER_ALIASES`.

Stdlib-only. Usage:

    python3 correlate_ground_truth.py capture.json my_whoop_data.zip
    python3 correlate_ground_truth.py capture.json export_folder/ --family whoop5 --tolerance 0.02
"""

import argparse
import bisect
import csv
import io
import json
import struct
import sys
import zipfile

import whoop_frame as wf

# --- Ground-truth CSV loading ----------------------------------------------------------------------

# Canonical WHOOP export filenames (English). Localized bundles rename the files; we match by these
# after aliasing, and fall back to header-sniffing, exactly like the Swift importer.
CYCLES_FILES = {"physiological_cycles.csv", "physiologische_zyklen.csv", "ciclos_fisiologicos.csv"}
SLEEP_FILES = {"sleeps.csv", "schlaf.csv", "sueno.csv", "sueños.csv"}

# Localized column header → canonical key. Mirrors HeaderNorm.foreignAliases in CSVParsing.swift
# (German + Spanish subset that covers the physiologic/sleep numeric fields we correlate on). English
# headers pass through unchanged, so an English export needs no alias.
HEADER_ALIASES = {
    # English (official app.whoop.com export — headers are title case; we lowercase first)
    "cycle start time": "cycle_start_time",
    "cycle end time": "cycle_end_time",
    "recovery score %": "recovery_score_pct",
    "resting heart rate (bpm)": "resting_heart_rate_bpm",
    "heart rate variability (ms)": "heart_rate_variability_ms",
    "skin temp (celsius)": "skin_temp_celsius",
    "blood oxygen %": "blood_oxygen_pct",
    "respiratory rate (rpm)": "respiratory_rate_rpm",
    "asleep duration (min)": "asleep_duration_min",
    "deep (sws) duration (min)": "deep_sws_duration_min",
    "rem duration (min)": "rem_duration_min",
    "sleep onset": "sleep_onset",
    "wake onset": "wake_onset",
    # German
    "erholungswert %": "recovery_score_pct",
    "ruheherzfrequenz (schläge pro minute)": "resting_heart_rate_bpm",
    "herzfrequenzvariabilität (ms)": "heart_rate_variability_ms",
    "hauttemperatur (celsius)": "skin_temp_celsius",
    "blutsauerstoff %": "blood_oxygen_pct",
    "atemfrequenz (atemzüge/min.)": "respiratory_rate_rpm",
    "schlafdauer (min.)": "asleep_duration_min",
    "dauer des tiefschlafs (min.)": "deep_sws_duration_min",
    "dauer des rem-schlafs (min.)": "rem_duration_min",
    "startzeit des zyklus": "cycle_start_time",
    # Spanish
    "puntuación de recuperación %": "recovery_score_pct",
    "frecuencia cardíaca en reposo (lpm)": "resting_heart_rate_bpm",
    "variabilidad de la frecuencia cardíaca (ms)": "heart_rate_variability_ms",
    "temp. cutánea (grados centígrados)": "skin_temp_celsius",
    "oxígeno en sangre %": "blood_oxygen_pct",
    "frecuencia respiratoria (rpm)": "respiratory_rate_rpm",
    "hora de inicio del ciclo": "cycle_start_time",
}

# Numeric fields we correlate on, with the scale factor the raw record is *likely* to carry the value
# at (the tool tries each). A field whose real encoding differs simply won't match — no harm.
#   name: (canonical CSV column, [candidate scale multipliers])
GROUND_TRUTH_FIELDS = {
    "hrv_ms": ("heart_rate_variability_ms", [1, 1000]),          # ms, or seconds×1000
    "resting_hr_bpm": ("resting_heart_rate_bpm", [1]),
    "respiratory_rate": ("respiratory_rate_rpm", [1, 10, 100]),  # 14.6 → 146 or 1460
    "skin_temp_c": ("skin_temp_celsius", [1, 10, 100]),          # 34.93 → 349 or 3493
    "spo2_pct": ("blood_oxygen_pct", [1, 10, 100]),
}


def _norm_header(h: str) -> str:
    key = h.strip().lower().lstrip("﻿")
    return HEADER_ALIASES.get(key, key)


def load_csv_rows(text: str):
    """Parse one WHOOP CSV into a list of {canonical_key: value} dicts."""
    reader = csv.reader(io.StringIO(text))
    rows = list(reader)
    if not rows:
        return []
    headers = [_norm_header(h) for h in rows[0]]
    out = []
    for raw in rows[1:]:
        if not any(cell.strip() for cell in raw):
            continue
        out.append({headers[i]: raw[i] for i in range(min(len(headers), len(raw)))})
    return out


def load_ground_truth(path: str):
    """Load the cycles + sleep rows from a WHOOP export .zip or folder.

    Returns a list of per-cycle dicts keyed by cycle_start_time, each carrying whatever numeric
    ground-truth fields were present. Cycles and sleeps are merged on cycle_start_time.
    """
    files = {}   # lowercased basename -> text
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as z:
            for name in z.namelist():
                base = name.rsplit("/", 1)[-1].lower()
                if base.endswith(".csv"):
                    files[base] = z.read(name).decode("utf-8-sig", errors="replace")
    else:
        import os
        for root, _dirs, names in os.walk(path):
            for n in names:
                if n.lower().endswith(".csv"):
                    with open(os.path.join(root, n), encoding="utf-8-sig", errors="replace") as f:
                        files[n.lower()] = f.read()

    def pick(candidates):
        for base, text in files.items():
            if base in candidates:
                return text
        return None

    merged = {}    # cycle_start_time -> row dict
    for text in (pick(CYCLES_FILES), pick(SLEEP_FILES)):
        if text is None:
            continue
        for row in load_csv_rows(text):
            key = row.get("cycle_start_time", "")
            merged.setdefault(key, {}).update(row)
    return [r for r in merged.values() if r]


def truth_values(rows):
    """Extract {field_name: [floats]} for every GROUND_TRUTH_FIELDS column present in the export."""
    out = {}
    for field, (col, _scales) in GROUND_TRUTH_FIELDS.items():
        vals = []
        for r in rows:
            raw = r.get(col, "").strip()
            if not raw:
                continue
            try:
                vals.append(float(raw.replace(",", ".")))
            except ValueError:
                pass
        if vals:
            out[field] = vals
    return out


# --- Candidate value extraction from frames --------------------------------------------------------

def frame_inner(frame: bytes, family: str):
    """Return the inner record (type byte onward, CRC32 trailer stripped) of a CRC-valid frame, else
    None. Correlation runs on the decoded payload region, not the framing/CRC bytes."""
    verify = wf.verify_whoop5_frame if family == "whoop5" else wf.verify_whoop4_frame
    if not verify(frame):
        return None
    inner_off = wf.WHOOP5_INNER_OFF if family == "whoop5" else wf.WHOOP4_INNER_OFF
    return frame[inner_off:-4]


def candidates_at(record: bytes, offset: int):
    """All numeric interpretations of `record` at `offset`: u8/i8, u16/i16 LE+BE, float32 LE+BE.

    Returns {encoding_name: value}. Out-of-range offsets are simply omitted.
    """
    out = {}
    n = len(record)
    if offset < n:
        out["u8"] = record[offset]
        out["i8"] = struct.unpack_from("b", record, offset)[0]
    if offset + 2 <= n:
        out["u16le"] = struct.unpack_from("<H", record, offset)[0]
        out["u16be"] = struct.unpack_from(">H", record, offset)[0]
        out["i16le"] = struct.unpack_from("<h", record, offset)[0]
        out["i16be"] = struct.unpack_from(">h", record, offset)[0]
    if offset + 4 <= n:
        out["f32le"] = struct.unpack_from("<f", record, offset)[0]
        out["f32be"] = struct.unpack_from(">f", record, offset)[0]
    return out


def _close(a: float, b: float, tol: float) -> bool:
    if a != a or b != b:            # NaN (junk float32 interpretation)
        return False
    if abs(b) > 1e9:                # absurd magnitude — not a real biometric
        return False
    denom = max(abs(b), 1.0)
    return abs(a - b) / denom <= tol


def _has_neighbor(sorted_vals, target, tol):
    """True if `sorted_vals` contains a value within relative `tol` of `target`."""
    if not sorted_vals:
        return False
    span = tol * max(abs(target), 1.0)
    i = bisect.bisect_left(sorted_vals, target - span)
    return i < len(sorted_vals) and sorted_vals[i] <= target + span


def correlate(records_by_type, truth, family, tolerance, min_hits):
    """For each record type and each ground-truth field, find (offset, encoding, scale) whose decoded
    values reproduce the field's distribution.

    Records aren't 1:1 with nights, so we don't pair them up. Instead we compare the *distribution* of
    decoded values against the known values two ways:

      * recall    — fraction of ground-truth nights that have a decoded value within tolerance. A real
                    field reproduces every night's value, so recall ≈ 1. A near-constant byte only
                    covers the few nights near that constant → low recall (this is the guard against a
                    fixed byte masquerading as a low-variance field like skin temp).
      * precision — fraction of decoded values that land on some known value. Random bytes scatter
                    outside the biometric's range → low precision.

    Both are needed: recall alone is fooled by a byte that ranges over the whole scale; precision alone
    by a constant that happens to sit in-range. `score = recall × precision`. Distinct decoded values
    must exceed a floor so a degenerate constant can't score on a single-valued field. Best first.
    """
    hits = []
    encodings = ("u8", "i8", "u16le", "u16be", "i16le", "i16be", "f32le", "f32be")
    for rtype, records in sorted(records_by_type.items()):
        if not records:
            continue
        maxlen = max(len(r) for r in records)
        for field, values in truth.items():
            truth_sorted = sorted(values)
            _col, scales = GROUND_TRUTH_FIELDS[field]
            for offset in range(maxlen):
                for enc in encodings:
                    for scale in scales:
                        decoded = []
                        for rec in records:
                            cands = candidates_at(rec, offset)
                            if enc in cands:
                                v = cands[enc]
                                if v == v and abs(v) < 1e9:      # skip NaN / absurd float32 junk
                                    decoded.append(v / scale if scale != 1 else v)
                        if len(decoded) < min_hits:
                            continue
                        dec_sorted = sorted(decoded)
                        recall = sum(_has_neighbor(dec_sorted, t, tolerance)
                                     for t in truth_sorted) / len(truth_sorted)
                        precision = sum(_has_neighbor(truth_sorted, d, tolerance)
                                        for d in decoded) / len(decoded)
                        distinct = len(set(decoded))
                        if recall >= 0.6 and precision >= 0.6 and distinct >= 3:
                            hits.append({
                                "type": rtype, "field": field, "offset": offset,
                                "encoding": enc, "scale": scale,
                                "records_matched": round(precision * len(decoded)),
                                "records_total": len(decoded),
                                "nights_covered": round(recall * len(truth_sorted)),
                                "nights_total": len(truth_sorted),
                                "score": recall * precision,
                            })
    hits.sort(key=lambda h: h["score"], reverse=True)
    return hits


def group_records_by_type(records, family):
    """Group CRC-valid frames' inner records by their packet-type byte."""
    by_type = {}
    for r in records:
        frame = bytes.fromhex(r["hex"])
        inner = frame_inner(frame, family)
        if inner is None or not inner:
            continue
        by_type.setdefault(inner[0], []).append(inner)
    return by_type


def main():
    p = argparse.ArgumentParser(
        description="Correlate capture frames against a WHOOP CSV export to locate record fields.")
    p.add_argument("capture", help="capture.json from whoop_capture.py or hci_extract.py")
    p.add_argument("export", help="WHOOP CSV export .zip or folder (your ground truth)")
    p.add_argument("--family", choices=["whoop4", "whoop5"], default="whoop5",
                   help="strap generation for framing/CRC rules (default: whoop5)")
    p.add_argument("--tolerance", type=float, default=0.03,
                   help="relative match tolerance, e.g. 0.03 = ±3%% (default: 0.03)")
    p.add_argument("--min-hits", type=int, default=5,
                   help="minimum matching records for a candidate offset (default: 5)")
    p.add_argument("--type", type=lambda s: int(s, 0), default=None,
                   help="restrict to one record type byte, e.g. 0x2f")
    args = p.parse_args()

    with open(args.capture) as f:
        records = json.load(f)
    rows = load_ground_truth(args.export)
    if not rows:
        print("no cycles/sleep rows found in the export — check the path/format", file=sys.stderr)
        sys.exit(1)
    truth = truth_values(rows)
    if not truth:
        print("no usable ground-truth numeric fields in the export", file=sys.stderr)
        sys.exit(1)

    by_type = group_records_by_type(records, args.family)
    if args.type is not None:
        by_type = {args.type: by_type.get(args.type, [])}

    print(f"ground truth: {len(rows)} cycles; fields "
          + ", ".join(f"{k}(n={len(v)})" for k, v in truth.items()))
    print("record types in capture: "
          + ", ".join(f"0x{t:02x}×{len(r)}" for t, r in sorted(by_type.items())) + "\n")

    hits = correlate(by_type, truth, args.family, args.tolerance, args.min_hits)
    if not hits:
        print("no field offsets matched. Try a larger --tolerance, or confirm the capture actually "
              "contains deep records (type 0x2f / history types), not just live HR.")
        return

    # One best hit per (type, field) — the strongest offset for each biometric.
    seen = set()
    print(f"{'type':>6}  {'field':<16} {'offset':>6} {'enc':>6} {'scale':>6}  "
          f"{'records':>12}  {'nights':>10}  score")
    for h in hits:
        k = (h["type"], h["field"])
        if k in seen:
            continue
        seen.add(k)
        print(f"  0x{h['type']:02x}  {h['field']:<16} {h['offset']:>6} {h['encoding']:>6} "
              f"{h['scale']:>6}  {h['records_matched']:>5}/{h['records_total']:<6}  "
              f"{h['nights_covered']:>4}/{h['nights_total']:<5}  {h['score']:.2f}")
    print("\nOffsets are into the inner record (type byte = offset 0). Safe to share on #103; "
          "your CSV values and the capture stay local.")


if __name__ == "__main__":
    main()
