"""Tests for validate_spo2_candidate — multi-device @82 SpO₂ candidate validation.

Run: python3 -m unittest test_validate_spo2_candidate -v
Stdlib only; synthetic planted captures — no personal health data.
"""

from __future__ import annotations

import json
import os
import sqlite3
import struct
import tempfile
import unittest
from datetime import datetime, timezone

import validate_spo2_candidate as vs
from test_whoop_activity import make_v18


def _utc(y, m, d, hh=0, mm=0, ss=0) -> int:
    return int(datetime(y, m, d, hh, mm, ss, tzinfo=timezone.utc).timestamp())


def _unix_of(rec: dict) -> int:
    """The u32 unix at frame offset 15, straight off a planted capture record."""
    return int.from_bytes(bytes.fromhex(rec["hex"])[15:19], "little")


def _plant_night(
    t0: int,
    t1: int,
    spo2: int,
    *,
    asleep: bool = True,
    neighbor_offset: int | None = None,
    neighbor_value: int = 0,
    step_s: int = 60,
) -> list[dict]:
    """Plant v18 records for one night with @82 = spo2 while asleep (default 1/min)."""
    out = []
    sleep_state = 2 if asleep else 0
    for u in range(t0, t1, step_s):
        f = bytearray(
            make_v18(
                unix=u,
                sleep_state=sleep_state,
                aux_byte_82=spo2 if asleep else 0,
                length=124,
            )
        )
        if neighbor_offset is not None and asleep:
            f[neighbor_offset] = neighbor_value & 0xFF
        out.append({"hex": bytes(f).hex(), "dir": "rx"})
    return out


def _plant_duty_night(
    t0: int,
    t1: int,
    spo2: int,
    *,
    period: int,
    phase: int,
    window: int,
    step_s: int = 1,
    asleep: bool = True,
    neighbor_offset: int | None = None,
    neighbor_value: int = 0,
) -> list[dict]:
    """Plant v18 records where @82 is nonzero ONLY inside a duty window, as the real strap does.

    `phase` is the residue `unix % period` at which the window opens. Tests deliberately use periods
    and phases that are *not* the ones measured on the reference corpus — the tool must recover them
    from the capture, never assume them.
    """
    out = []
    sleep_state = 2 if asleep else 0
    for u in range(t0, t1, step_s):
        in_window = (u - phase) % period < window
        f = bytearray(
            make_v18(
                unix=u,
                sleep_state=sleep_state,
                aux_byte_82=spo2 if (in_window and asleep) else 0,
                length=124,
            )
        )
        if neighbor_offset is not None and asleep:
            f[neighbor_offset] = neighbor_value & 0xFF
        out.append({"hex": bytes(f).hex(), "dir": "rx"})
    return out


def _write_export(folder: str, nights: list[tuple[str, float, int, int]]) -> str:
    """nights: (cycle_start_str, spo2_export, sleep_unix, wake_unix)"""
    path = os.path.join(folder, "physiological_cycles.csv")
    lines = [
        "Cycle start time,Cycle end time,Blood oxygen %,Sleep onset,Wake onset\n"
    ]
    for start, spo2, t0, t1 in nights:
        s0 = datetime.fromtimestamp(t0, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
        s1 = datetime.fromtimestamp(t1, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
        lines.append(f"{start},,{spo2:.2f},{s0},{s1}\n")
    with open(path, "w") as f:
        f.writelines(lines)
    return folder


class HeaderAndTsTests(unittest.TestCase):
    def test_english_blood_oxygen_header(self):
        self.assertEqual(vs._norm_header("Blood oxygen %"), "blood_oxygen_pct")
        self.assertEqual(vs._norm_header("Cycle start time"), "cycle_start_time")

    def test_parse_export_ts(self):
        self.assertEqual(
            vs._parse_export_ts("2026-07-15 23:25:58"),
            _utc(2026, 7, 15, 23, 25, 58),
        )


class PlantedValidationTests(unittest.TestCase):
    def test_recovers_perfect_correlation_across_nights(self):
        # 6 nights with real spread; @82 equals round(export) while asleep.
        base = _utc(2026, 6, 1, 0, 0, 0)
        nights_meta = []
        frames = []
        exports = []
        for i, spo2 in enumerate([95, 96, 97, 98, 94, 99]):
            t0 = base + i * 86400 + 23 * 3600
            t1 = t0 + 7 * 3600
            frames.extend(_plant_night(t0, t1, spo2))
            start = datetime.fromtimestamp(t0, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
            exports.append((start, float(spo2), t0, t1))
            nights_meta.append(spo2)

        with tempfile.TemporaryDirectory() as td:
            cap = os.path.join(td, "capture.json")
            with open(cap, "w") as f:
                json.dump(frames, f)
            exp = _write_export(td, exports)
            res = vs.validate_device(cap, exp, device="planted-a")

        self.assertEqual(res["paired_nights"], 6)
        self.assertIsNotNone(res["r"])
        self.assertGreaterEqual(res["r"], 0.99)
        self.assertLessEqual(res["mae"], 0.01)
        self.assertEqual(res["best_specificity_offset"], 82)
        self.assertTrue(res["checklist"]["pass"])

    def test_incomplete_nights_without_export_spo2_are_skipped(self):
        t0 = _utc(2026, 6, 10, 23, 0, 0)
        t1 = t0 + 6 * 3600
        frames = _plant_night(t0, t1, 97)
        with tempfile.TemporaryDirectory() as td:
            cap = os.path.join(td, "capture.json")
            with open(cap, "w") as f:
                json.dump(frames, f)
            # Export row with empty SpO₂ — must not pair.
            path = os.path.join(td, "physiological_cycles.csv")
            with open(path, "w") as f:
                f.write(
                    "Cycle start time,Blood oxygen %,Sleep onset,Wake onset\n"
                    "2026-06-10 23:00:00,,"
                    f"{datetime.fromtimestamp(t0, tz=timezone.utc).strftime('%Y-%m-%d %H:%M:%S')},"
                    f"{datetime.fromtimestamp(t1, tz=timezone.utc).strftime('%Y-%m-%d %H:%M:%S')}\n"
                )
            res = vs.validate_device(cap, td, device="empty")
        self.assertEqual(res["export_nights_with_spo2"], 0)
        self.assertEqual(res["paired_nights"], 0)
        self.assertFalse(res["checklist"]["pass"])

    def test_awake_samples_do_not_contribute(self):
        t0 = _utc(2026, 6, 11, 23, 0, 0)
        t1 = t0 + 6 * 3600
        # All wake, @82=97 — should not pair when require_asleep (default).
        frames = _plant_night(t0, t1, 97, asleep=False)
        # Force aux byte even while wake for the test plant.
        for rec in frames:
            f = bytearray(bytes.fromhex(rec["hex"]))
            f[82] = 97
            rec["hex"] = bytes(f).hex()
        with tempfile.TemporaryDirectory() as td:
            cap = os.path.join(td, "capture.json")
            with open(cap, "w") as f:
                json.dump(frames, f)
            start = datetime.fromtimestamp(t0, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
            exp = _write_export(td, [(start, 97.0, t0, t1)])
            res = vs.validate_device(cap, exp, device="wake-only")
        self.assertEqual(res["paired_nights"], 0)

    def test_offset_specificity_prefers_true_offset(self):
        # Plant signal at @82; put a constant 98 at @80 that should not track spread.
        base = _utc(2026, 7, 1, 0, 0, 0)
        frames = []
        exports = []
        for i, spo2 in enumerate([92, 94, 96, 98, 95, 97]):
            t0 = base + i * 86400 + 22 * 3600
            t1 = t0 + 8 * 3600
            frames.extend(
                _plant_night(t0, t1, spo2, neighbor_offset=80, neighbor_value=98)
            )
            start = datetime.fromtimestamp(t0, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
            exports.append((start, float(spo2), t0, t1))
        with tempfile.TemporaryDirectory() as td:
            cap = os.path.join(td, "capture.json")
            with open(cap, "w") as f:
                json.dump(frames, f)
            exp = _write_export(td, exports)
            res = vs.validate_device(cap, exp, device="spec")
        self.assertEqual(res["best_specificity_offset"], 82)

    def test_postable_summary_has_no_raw_values(self):
        # Perfect single-device result → postable block must not contain SpO₂ numbers from nights.
        base = _utc(2026, 8, 1, 0, 0, 0)
        frames, exports = [], []
        for i, spo2 in enumerate([95, 96, 97, 98, 94, 99]):
            t0 = base + i * 86400 + 23 * 3600
            t1 = t0 + 7 * 3600
            frames.extend(_plant_night(t0, t1, spo2))
            start = datetime.fromtimestamp(t0, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
            exports.append((start, float(spo2), t0, t1))
        with tempfile.TemporaryDirectory() as td:
            cap = os.path.join(td, "capture.json")
            with open(cap, "w") as f:
                json.dump(frames, f)
            exp = _write_export(td, exports)
            res = vs.validate_device(cap, exp, device="post")
        blob = vs.format_postable([res])
        self.assertIn("spo2_candidate_82 multi-device validation", blob)
        self.assertIn("checklist_pass", blob)
        # Nightly export values must not appear as raw 95.00-style lines.
        self.assertNotIn("95.00", blob)
        self.assertNotIn("cycle_start", blob.lower())


class MultiDeviceBatchTests(unittest.TestCase):
    def test_batch_all_pass(self):
        def make_device(td, label, spo2s):
            base = _utc(2026, 5, 1, 0, 0, 0)
            frames, exports = [], []
            for i, spo2 in enumerate(spo2s):
                t0 = base + i * 86400 + 23 * 3600
                t1 = t0 + 7 * 3600
                frames.extend(_plant_night(t0, t1, spo2))
                start = datetime.fromtimestamp(t0, tz=timezone.utc).strftime(
                    "%Y-%m-%d %H:%M:%S"
                )
                exports.append((start, float(spo2), t0, t1))
            cap = os.path.join(td, f"{label}.json")
            with open(cap, "w") as f:
                json.dump(frames, f)
            exp_dir = os.path.join(td, label)
            os.makedirs(exp_dir)
            _write_export(exp_dir, exports)
            return {"device": label, "capture": cap, "export": exp_dir}

        with tempfile.TemporaryDirectory() as td:
            a = make_device(td, "strap-a", [95, 96, 97, 98, 94, 99])
            b = make_device(td, "strap-b", [93, 94, 95, 96, 97, 98])
            batch = os.path.join(td, "devices.json")
            with open(batch, "w") as f:
                json.dump([a, b], f)
            rc = vs.main(["--batch", batch, "--postable"])
            self.assertEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()


class LoadFrameRecordsTest(unittest.TestCase):
    """#103: `whoop_sync.py` writes its captures to a SQLite `frames` table, but this validator read
    only capture.json — so a Linux capture had to be round-tripped through
    `whoop_sync.py export --only-type 47` to be analysed by a tool sitting in the same directory.

    This is the CAPTURE TOOLING's database, not the app's: neither shipped app has a `frames` table
    (Android is Room, iOS/macOS is GRDB), so this path cannot reach a phone store or a .noopbak."""

    def _store(self, rows, *, device_id=2, inner_type=47):
        path = tempfile.mktemp(suffix=".db")
        con = sqlite3.connect(path)
        con.execute("CREATE TABLE frames (device_id INT, inner_type INT, hex TEXT)")
        for h in rows:
            con.execute("INSERT INTO frames VALUES (?,?,?)", (device_id, inner_type, h))
        con.commit()
        con.close()
        self.addCleanup(lambda: os.path.exists(path) and os.unlink(path))
        return path

    def test_reads_frames_from_a_noop_sqlite_store(self):
        frames = [make_v18(unix=1780000000 + i * 60, sleep_state=2, aux_byte_82=96).hex()
                  for i in range(5)]
        recs = vs.load_frame_records(self._store(frames), device_id=2)
        self.assertEqual(len(recs), 5)
        decoded = list(vs.iter_v18_records(recs))
        self.assertEqual([d["spo2_candidate_82"] for d in decoded], [96] * 5)

    def test_detects_sqlite_by_header_not_extension(self):
        """A store copied off a phone is often renamed; trusting the suffix would send it to json.load."""
        path = self._store([make_v18(sleep_state=2, aux_byte_82=95).hex()])
        renamed = path + ".capture"
        os.rename(path, renamed)
        self.addCleanup(lambda: os.path.exists(renamed) and os.unlink(renamed))
        self.assertTrue(vs.looks_like_sqlite(renamed))
        self.assertEqual(len(vs.load_frame_records(renamed)), 1)

    def test_json_captures_still_load_unchanged(self):
        path = tempfile.mktemp(suffix=".json")
        with open(path, "w") as f:
            json.dump([{"hex": make_v18(sleep_state=2, aux_byte_82=94).hex()}], f)
        self.addCleanup(lambda: os.path.exists(path) and os.unlink(path))
        self.assertFalse(vs.looks_like_sqlite(path))
        self.assertEqual(len(vs.load_frame_records(path)), 1)

    def test_wrong_device_id_says_so_instead_of_reporting_zero_nights(self):
        """Silently finding nothing would read as 'the candidate does not track', which is the wrong
        conclusion to hand someone from a filter mismatch."""
        path = self._store([make_v18(sleep_state=2, aux_byte_82=96).hex()], device_id=2)
        with self.assertRaises(SystemExit) as cm:
            vs.load_frame_records(path, device_id=99)
        self.assertIn("device-id", str(cm.exception))

    def test_a_sqlite_file_that_is_not_a_frame_store_is_rejected_clearly(self):
        path = tempfile.mktemp(suffix=".db")
        con = sqlite3.connect(path)
        con.execute("CREATE TABLE unrelated (x INT)")
        con.commit()
        con.close()
        self.addCleanup(lambda: os.path.exists(path) and os.unlink(path))
        with self.assertRaises(SystemExit) as cm:
            vs.load_frame_records(path)
        self.assertIn("not a whoop_sync.py frame store", str(cm.exception))


class SqliteV18FilterTest(unittest.TestCase):
    """Newer 5/MG firmware serves a v20 (2140 B) + v21 (1244 B) pair every second alongside the
    124-byte v18, so `inner_type=47` alone loads mostly bytes this tool discards — only v18 carries
    @82. Filtering by version in SQL took a mixed 20k-usable-record corpus from 115 MB to 28 MB."""

    def _mixed_store(self, n_v18=5, n_v20=5, device_id=2):
        path = tempfile.mktemp(suffix=".db")
        con = sqlite3.connect(path)
        con.execute("CREATE TABLE frames (device_id INT, inner_type INT, hex TEXT)")
        for i in range(n_v18):
            f = make_v18(unix=1780000000 + i * 60, sleep_state=2, aux_byte_82=96)
            con.execute("INSERT INTO frames VALUES (?,47,?)", (device_id, f.hex()))
        for _ in range(n_v20):
            v20 = bytearray(2140)
            v20[0], v20[8], v20[9] = 0xAA, 47, 20
            con.execute("INSERT INTO frames VALUES (?,47,?)", (device_id, bytes(v20).hex()))
        con.commit()
        con.close()
        self.addCleanup(lambda: os.path.exists(path) and os.unlink(path))
        return path

    def test_v20_v21_rows_are_filtered_in_sql_not_after_loading(self):
        recs = vs.load_frame_records(self._mixed_store(n_v18=5, n_v20=5))
        self.assertEqual(len(recs), 5, "v20 rows should never reach Python")
        self.assertTrue(all(bytes.fromhex(r["hex"])[9] == 18 for r in recs))

    def test_a_store_with_type47_but_no_v18_says_so(self):
        """Different fix from an empty store: the frames are there, they are the wrong layout."""
        with self.assertRaises(SystemExit) as cm:
            vs.load_frame_records(self._mixed_store(n_v18=0, n_v20=3))
        msg = str(cm.exception)
        self.assertIn("none are v18", msg)
        self.assertIn("3 type-47 frames", msg)

    def test_wrong_device_id_still_reports_the_device_id_cause(self):
        """The v18 filter must not mask the pre-existing device-id diagnostic."""
        with self.assertRaises(SystemExit) as cm:
            vs.load_frame_records(self._mixed_store(n_v18=5), device_id=99)
        self.assertIn("device-id", str(cm.exception))


class DutyCycleDetectionTests(unittest.TestCase):
    """@82 is duty-cycled: on the reference corpus (18,650 v18 records, 18,602 of them from
    @digitalerdude's public PacketLogger capture) it is nonzero in 450 records — 15 runs, every one
    exactly 30 records long, every one starting at the same `unix % 1200`.

    The *existence* of a periodic window is the robust fact. The period and especially the phase are
    not: these tests plant schedules that are nothing like 1200/337 and require the tool to measure
    them, so a hard-coded constant would fail here rather than silently mis-score someone's strap."""

    def _records(self, frames):
        return list(vs.iter_v18_records(frames))

    def test_recovers_period_phase_and_window_without_being_told(self):
        t0 = _utc(2026, 3, 2, 0, 0, 0)
        frames = _plant_duty_night(t0, t0 + 6 * 900, 96, period=900, phase=111, window=20)
        duty = vs.detect_duty_cycle(self._records(frames))
        self.assertEqual(duty["mode"], "duty_cycled")
        self.assertEqual(duty["period_s"], 900)
        self.assertEqual(duty["window_len_s"], 20)
        self.assertEqual(duty["phase_s"], 111 % 900)
        self.assertEqual(duty["windows_observed"], 6)
        self.assertEqual(duty["phase_jitter_s"], 0)
        self.assertTrue(duty["window_len_stable"])

    def test_a_second_unrelated_schedule_is_recovered_too(self):
        """Two different plants must give two different answers — the guard against a constant."""
        t0 = _utc(2026, 3, 3, 0, 0, 0)
        frames = _plant_duty_night(t0, t0 + 8 * 600, 95, period=600, phase=42, window=10)
        duty = vs.detect_duty_cycle(self._records(frames))
        self.assertEqual(
            (duty["period_s"], duty["phase_s"], duty["window_len_s"]), (600, 42, 10)
        )

    def test_a_capture_where_82_is_always_on_is_not_reweighted(self):
        """No duty cycle to correct for ⇒ 'continuous', and the per-second path is left alone."""
        t0 = _utc(2026, 3, 4, 0, 0, 0)
        duty = vs.detect_duty_cycle(self._records(_plant_night(t0, t0 + 3600, 97)))
        self.assertEqual(duty["mode"], "continuous")
        self.assertIsNone(duty["period_s"])

    def test_a_flat_zero_capture_reports_absent(self):
        t0 = _utc(2026, 3, 5, 0, 0, 0)
        duty = vs.detect_duty_cycle(self._records(_plant_night(t0, t0 + 3600, 0)))
        self.assertEqual(duty["mode"], "absent")
        self.assertEqual(duty["n_nonzero"], 0)

    def test_scattered_firings_with_no_period_are_called_irregular_not_duty_cycled(self):
        """Claiming a period the data does not support would reweight nights on an invented schedule."""
        t0 = _utc(2026, 3, 6, 0, 0, 0)
        frames = []
        for i, gap in enumerate([0, 137, 490, 601, 1900, 2050]):
            f = bytearray(make_v18(unix=t0 + gap, sleep_state=2, aux_byte_82=95, length=124))
            frames.append({"hex": bytes(f).hex()})
        for u in range(t0, t0 + 3000):          # bulk of zero records around them
            frames.append({"hex": make_v18(unix=u, sleep_state=2, aux_byte_82=0).hex()})
        duty = vs.detect_duty_cycle(self._records(frames))
        self.assertIn(duty["mode"], ("irregular", "duty_cycled"))
        if duty["mode"] == "duty_cycled":
            self.fail(f"scattered firings should not be claimed as a schedule: {duty}")


class WindowCoverageTests(unittest.TestCase):
    """The failure mode this closes: a capture not aligned to the duty phase reads all zeros and is
    indistinguishable from a strap with the feature off. Measured, not assumed — a plausible
    contributor to the contradictory cross-device evidence on #103."""

    def setUp(self):
        self.t0 = _utc(2026, 4, 1, 23, 0, 0)
        self.t1 = self.t0 + 4 * 3600
        self.period, self.phase, self.window = 1200, 337, 30
        self.frames = _plant_duty_night(
            self.t0, self.t1, 96,
            period=self.period, phase=self.phase, window=self.window,
        )
        self.records = list(vs.iter_v18_records(self.frames))
        self.duty = vs.detect_duty_cycle(self.records)

    def test_an_aligned_capture_covers_every_window(self):
        covered, expected = vs.night_window_coverage(self.records, self.t0, self.t1, self.duty)
        self.assertEqual(expected, 12)          # 4 h / 20 min
        self.assertEqual(covered, expected)

    def test_a_phase_misaligned_sample_reads_as_no_feature_at_all(self):
        """One record per minute, landing outside the window every time: zero nonzero @82, zero
        coverage. Reported as such instead of as a device whose candidate does not track."""
        stride = [f for f in self.frames if _unix_of(f) % 60 == 30]
        recs = list(vs.iter_v18_records(stride))
        self.assertEqual(vs.detect_duty_cycle(recs)["n_nonzero"], 0)
        covered, expected = vs.night_window_coverage(recs, self.t0, self.t1, self.duty)
        self.assertEqual(covered, 0)
        self.assertEqual(expected, 12)

    def test_coverage_is_reported_per_night_and_low_nights_are_flagged(self):
        # Capture only the first hour, then claim the whole 4-hour night in the export.
        frames = [f for f in self.frames if _unix_of(f) < self.t0 + 3600]
        with tempfile.TemporaryDirectory() as td:
            cap = os.path.join(td, "capture.json")
            with open(cap, "w") as fh:
                json.dump(frames, fh)
            start = datetime.fromtimestamp(self.t0, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
            exp = _write_export(td, [(start, 96.0, self.t0, self.t1)])
            res = vs.validate_device(cap, exp, device="partial")
        night = res["nights"][0]
        self.assertEqual(night["windows_expected"], 12)
        self.assertEqual(night["windows_sampled"], 3)       # 1 h of a 4 h night
        self.assertAlmostEqual(night["coverage"], 0.25)
        self.assertTrue(night["low_coverage"])
        self.assertFalse(res["checklist"]["window_coverage"])
        self.assertTrue(any("duty" in w or "window" in w for w in vs.coverage_warnings(res)))

    def test_the_nightly_aggregate_is_per_window_not_per_second(self):
        """A 30-second burst is one measurement the strap took, not 30 independent ones.

        Windows contribute unequal numbers of *in-band* samples for a reason visible on the reference
        corpus: only 148 of the 450 in-window values there are in 70–100 — the rest are out-of-band
        sentinels (0x80, 0xA0, 0x20). Here window A yields 30 in-band samples and windows B and C
        yield 3 each. Per-second averaging hands the night to A; per-window averaging does not."""
        frames = []
        for u in range(0, 3600):
            in_window = (u - 337) % 1200 < 30
            if not in_window:
                v = 0
            elif u < 1200:
                v = 90                                     # window A: every second in-band
            else:
                v = 100 if (u % 1200) in (337, 347, 357) else 128   # B/C: 3 in-band, rest sentinel
            frames.append({"hex": make_v18(unix=u, sleep_state=2, aux_byte_82=v).hex()})
        recs = list(vs.iter_v18_records(frames))
        duty = vs.detect_duty_cycle(recs)
        self.assertEqual(duty["mode"], "duty_cycled")
        self.assertEqual((duty["period_s"], duty["phase_s"], duty["window_len_s"]), (1200, 337, 30))
        per_second = vs.night_mean_at_offset(recs, 0, 3600, 82)
        per_window = vs.night_mean_at_offset(recs, 0, 3600, 82, duty=duty)
        self.assertAlmostEqual(per_second[0], (30 * 90 + 6 * 100) / 36)   # 91.67, burst-weighted
        self.assertAlmostEqual(per_window[0], (90 + 100 + 100) / 3)       # 96.67, window-weighted
        self.assertEqual(per_window[1], 36)      # sample count still reported honestly


class VarianceFloorTests(unittest.TestCase):
    """`value in 70..100` is not a specific screen. On a real subscription-free strap six offsets pass
    an in-band-only screen on a majority of records — @17, @33, @59, @69, @71, @107 — and each is
    either an already-decoded non-SpO₂ field (@33 cardiac_flags, @59 step_cadence, @69/@71 the aux
    thermal channels) or near-constant (@17 is byte 2 of the u32 unix timestamp). A nightly SpO₂
    cannot have 2 distinct values."""

    def _device(self, td, *, spo2s, neighbor_offset, neighbor_values, jitter):
        base = _utc(2026, 2, 1, 0, 0, 0)
        frames, exports = [], []
        for i, spo2 in enumerate(spo2s):
            t0 = base + i * 86400 + 23 * 3600
            t1 = t0 + 6 * 3600
            night = _plant_night(t0, t1, spo2 + jitter[i])
            for rec in night:                    # a 2-valued byte that tracks export perfectly
                f = bytearray(bytes.fromhex(rec["hex"]))
                f[neighbor_offset] = neighbor_values[i]
                rec["hex"] = bytes(f).hex()
            frames.extend(night)
            start = datetime.fromtimestamp(t0, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
            exports.append((start, float(spo2), t0, t1))
        cap = os.path.join(td, "capture.json")
        with open(cap, "w") as f:
            json.dump(frames, f)
        return cap, _write_export(td, exports)

    def test_a_near_constant_in_band_byte_cannot_win_the_specificity_scan(self):
        """@84 holds two values that correlate perfectly with the export; @82 tracks it imperfectly.
        Without a variance floor the flag wins and the tool reports 'not specific to @82'."""
        spo2s = [94, 95, 96, 97, 98, 99]
        with tempfile.TemporaryDirectory() as td:
            cap, exp = self._device(
                td,
                spo2s=spo2s,
                neighbor_offset=84,
                neighbor_values=[80, 80, 80, 81, 81, 81],   # 2 distinct values, monotone with export
                jitter=[1, -1, 1, -1, 1, 0],                # @82 deliberately noisier
            )
            res = vs.validate_device(cap, exp, device="floor")
        self.assertEqual(res["best_specificity_offset"], 82)
        rejected = {s["offset"]: s for s in res["specificity_rejected_low_variance"]}
        self.assertIn(84, rejected)
        self.assertEqual(rejected[84]["distinct"], 2)

    def test_the_floor_also_gates_82_itself(self):
        """If @82 is the near-constant one, the checklist says so instead of trusting its r."""
        base = _utc(2026, 2, 10, 0, 0, 0)
        frames, exports = [], []
        for i, spo2 in enumerate([94, 95, 96, 97, 98, 99]):
            t0 = base + i * 86400 + 23 * 3600
            t1 = t0 + 6 * 3600
            frames.extend(_plant_night(t0, t1, 97 if i < 3 else 98))   # only 2 distinct values
            start = datetime.fromtimestamp(t0, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
            exports.append((start, float(spo2), t0, t1))
        with tempfile.TemporaryDirectory() as td:
            cap = os.path.join(td, "capture.json")
            with open(cap, "w") as f:
                json.dump(frames, f)
            res = vs.validate_device(cap, _write_export(td, exports), device="flat82")
        self.assertEqual(res["inband_distinct_82"], 2)
        self.assertFalse(res["checklist"]["value_variance"])
        self.assertFalse(res["checklist"]["pass"])

    def test_a_real_spread_clears_the_floor(self):
        with tempfile.TemporaryDirectory() as td:
            cap, exp = self._device(
                td,
                spo2s=[93, 95, 96, 97, 98, 100],
                neighbor_offset=90,
                neighbor_values=[0] * 6,
                jitter=[0] * 6,
            )
            res = vs.validate_device(cap, exp, device="spread")
        self.assertGreaterEqual(res["inband_distinct_82"], vs.MIN_DISTINCT_INBAND)
        self.assertTrue(res["checklist"]["value_variance"])


class FeatureAbsentClassificationTests(unittest.TestCase):
    """A subscription-free strap reads @82 = 0x00 on 100 % of records, including genuine deep sleep.
    That device has not failed a correlation — it has no data to correlate. It must be classified,
    and must count as neither a PASS nor a FAIL in the multi-device promote gate for #103."""

    def _flat_zero_device(self, td, label, *, n_records=851, step_s=5):
        t0 = _utc(2026, 1, 5, 23, 0, 0)
        frames = [
            {"hex": make_v18(unix=t0 + i * step_s, sleep_state=2, hr=52, aux_byte_82=0).hex()}
            for i in range(n_records)
        ]
        cap = os.path.join(td, f"{label}.json")
        with open(cap, "w") as f:
            json.dump(frames, f)
        exp_dir = os.path.join(td, label)
        os.makedirs(exp_dir)
        start = datetime.fromtimestamp(t0, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
        _write_export(exp_dir, [(start, 96.0, t0, t0 + n_records * step_s)])
        return {"device": label, "capture": cap, "export": exp_dir}

    def test_a_flat_zero_strap_is_classified_not_failed(self):
        with tempfile.TemporaryDirectory() as td:
            d = self._flat_zero_device(td, "no-feature")
            res = vs.validate_device(d["capture"], d["export"], device="no-feature")
        self.assertEqual(res["duty"]["mode"], "absent")
        self.assertEqual(res["classification"], "feature_absent")
        self.assertFalse(res["checklist"]["pass"])
        self.assertIn("FEATURE ABSENT", vs.format_summary(res))
        self.assertTrue(any("feature absent" in w for w in vs.coverage_warnings(res)))

    def test_a_short_all_zero_capture_is_not_enough_to_claim_absence(self):
        """Below the evidence bar this is 'we did not see it', which is the very confusion the duty
        cycle creates — so it stays a plain FAIL rather than an absence claim."""
        with tempfile.TemporaryDirectory() as td:
            d = self._flat_zero_device(td, "short", n_records=40, step_s=5)
            res = vs.validate_device(d["capture"], d["export"], device="short")
        self.assertEqual(res["duty"]["mode"], "absent")
        self.assertEqual(res["classification"], "fail")

    def test_an_absent_device_is_neither_a_pass_nor_a_fail_in_the_promote_gate(self):
        def passing(td, label, spo2s):
            base = _utc(2026, 1, 20, 0, 0, 0)
            frames, exports = [], []
            for i, spo2 in enumerate(spo2s):
                t0 = base + i * 86400 + 23 * 3600
                t1 = t0 + 7 * 3600
                frames.extend(_plant_night(t0, t1, spo2))
                start = datetime.fromtimestamp(t0, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
                exports.append((start, float(spo2), t0, t1))
            cap = os.path.join(td, f"{label}.json")
            with open(cap, "w") as f:
                json.dump(frames, f)
            exp_dir = os.path.join(td, label)
            os.makedirs(exp_dir)
            _write_export(exp_dir, exports)
            return {"device": label, "capture": cap, "export": exp_dir}

        with tempfile.TemporaryDirectory() as td:
            entries = [
                passing(td, "strap-a", [95, 96, 97, 98, 94, 99]),
                passing(td, "strap-b", [93, 94, 95, 96, 97, 98]),
                self._flat_zero_device(td, "strap-c"),
            ]
            results = [
                vs.validate_device(e["capture"], e["export"], device=e["device"]) for e in entries
            ]
        blob = vs.format_postable(results)
        self.assertIn("multi_device_eligible=2", blob)   # the absent strap is not eligible…
        self.assertIn("all_pass=True", blob)             # …and does not drag all_pass down
        self.assertIn("feature_absent=1", blob)
        self.assertIn("strap-c,feature_absent,", blob)

    def test_a_cadence_coarser_than_a_window_cannot_claim_absence(self):
        """Duration bars do not catch aliasing: missing the window is a PHASE problem.

        851 records over 71 hours clears both ABSENT_MIN_RECORDS and ABSENT_MIN_ASLEEP_SPAN_S, but at
        a 300 s cadence the capture only ever occupies 4 residues mod a 1200 s period — so it either
        always lands in the window or never does. All-zero here is not evidence of anything.
        """
        with tempfile.TemporaryDirectory() as td:
            d = self._flat_zero_device(td, "coarse", step_s=300)
            res = vs.validate_device(d["capture"], d["export"], device="coarse")
        self.assertEqual(res["duty"]["mode"], "absent")
        self.assertGreaterEqual(res["duty"]["n_records"], vs.ABSENT_MIN_RECORDS)
        self.assertEqual(res["classification"], "fail")
        self.assertIn("NOT claiming feature_absent", vs.format_duty_line(res))

    def test_an_aliased_capture_of_a_WORKING_strap_is_not_reported_absent(self):
        """The case the duration bars let through: @82 is duty-cycling perfectly, the capture just
        never samples inside the window. Reporting this strap as lacking the feature would drop a real
        device out of the multi-device gate and make promotion easier."""
        period, phase, window = 1200, 337, 30
        with tempfile.TemporaryDirectory() as td:
            frames, nights = [], []
            for i in range(4):
                t0 = _utc(2026, 4, 1 + i, 23, 0, 0)
                t1 = t0 + 8 * 3600
                frames += _plant_duty_night(
                    t0, t1, 95, period=period, phase=phase, window=window, step_s=300
                )
                start = datetime.fromtimestamp(t0, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
                nights.append((start, 95.0, t0, t1))
            cap = os.path.join(td, "aliased.json")
            with open(cap, "w") as f:
                json.dump(frames, f)
            res = vs.validate_device(cap, _write_export(td, nights), device="aliased")
        self.assertEqual(res["duty"]["n_nonzero"], 0)      # the strap works; the capture missed it
        self.assertEqual(res["duty"]["mode"], "absent")
        self.assertNotEqual(res["classification"], "feature_absent")

    def test_a_dense_burst_plus_one_far_later_record_cannot_claim_absence(self):
        """Wall-clock span is not observation. 120 records at 1 Hz plus a single record eight hours
        later clears the record count, spans 8 h, and has a 1 s median cadence — but the capture only
        ever watched the strap for ~2 minutes, which is no evidence of anything."""
        t0 = _utc(2026, 5, 1, 23, 0, 0)
        stamps = list(range(t0, t0 + 120)) + [t0 + 8 * 3600]
        with tempfile.TemporaryDirectory() as td:
            frames = [
                {"hex": make_v18(unix=u, sleep_state=2, hr=52, aux_byte_82=0).hex()} for u in stamps
            ]
            cap = os.path.join(td, "sparse.json")
            with open(cap, "w") as f:
                json.dump(frames, f)
            exp_dir = os.path.join(td, "sparse")
            os.makedirs(exp_dir)
            start = datetime.fromtimestamp(t0, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
            _write_export(exp_dir, [(start, 96.0, t0, t0 + 8 * 3600)])
            res = vs.validate_device(cap, exp_dir, device="sparse")
        self.assertEqual(res["duty"]["mode"], "absent")
        self.assertGreaterEqual(res["duty"]["n_records"], vs.ABSENT_MIN_RECORDS)   # count bar clears
        self.assertLessEqual(res["duty"]["record_interval_s"], vs.NOMINAL_DUTY_WINDOW_S)  # cadence too
        self.assertEqual(res["classification"], "fail")

    def _asleep_device(self, td, label, stamps):
        frames = [
            {"hex": make_v18(unix=u, sleep_state=st, hr=52, aux_byte_82=0).hex()} for u, st in stamps
        ]
        cap = os.path.join(td, f"{label}.json")
        with open(cap, "w") as f:
            json.dump(frames, f)
        exp_dir = os.path.join(td, label)
        os.makedirs(exp_dir)
        t0 = min(u for u, _ in stamps)
        t1 = max(u for u, _ in stamps)
        start = datetime.fromtimestamp(t0, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
        _write_export(exp_dir, [(start, 96.0, t0, t1)])
        return vs.validate_device(cap, exp_dir, device=label)

    def test_repeated_timestamps_do_not_inflate_observed_sleep(self):
        """A resume/reconnect in whoop_sync.py can re-deliver the same historical rows. Counting
        records rather than distinct seconds turns 200 s of sleep repeated twenty times into 4000 s of
        'observation' — enough to clear the bar off 200 s of real data."""
        t0 = _utc(2026, 6, 1, 22, 0, 0)
        dupes = [(t0 + i, 2) for i in range(200) for _ in range(20)]
        with tempfile.TemporaryDirectory() as td:
            res = self._asleep_device(td, "dupes", dupes)
        self.assertEqual(res["duty"]["mode"], "absent")
        self.assertEqual(res["observed_asleep_s"], 200)      # distinct seconds, not 4000 records
        self.assertEqual(res["classification"], "fail")

    def test_a_dense_awake_stretch_cannot_hide_an_aliasing_sleep_cadence(self):
        """The gate has to read the ASLEEP cadence. A capture that is 1 Hz awake and 300 s asleep has
        a 1 s whole-capture median, which would sail through the window gate while the only part that
        matters aliases against the duty period."""
        t0 = _utc(2026, 6, 1, 22, 0, 0)
        awake = [(t0 + i, 0) for i in range(5000)]
        asleep = [(t0 + 5000 + i * 300, 2) for i in range(4000)]
        with tempfile.TemporaryDirectory() as td:
            res = self._asleep_device(td, "mixed", awake + asleep)
        self.assertEqual(res["duty"]["record_interval_s"], 1.0)   # whole-capture median says 1 Hz…
        self.assertEqual(res["asleep_interval_s"], 300.0)         # …the part that matters does not
        self.assertEqual(res["classification"], "fail")
        self.assertIn("asleep cadence", vs.format_duty_line(res))

    def test_a_cadence_at_the_window_length_can_still_claim_absence(self):
        """Boundary: a cadence at or below the window length cannot skip a window whatever the phase,
        so a flat-zero capture there IS evidence. Guards the gate against being over-tightened."""
        with tempfile.TemporaryDirectory() as td:
            d = self._flat_zero_device(td, "edge", step_s=vs.NOMINAL_DUTY_WINDOW_S)
            res = vs.validate_device(d["capture"], d["export"], device="edge")
        self.assertEqual(res["classification"], "feature_absent")

    def test_postable_still_carries_no_raw_spo2_values(self):
        """The duty/coverage columns are device timing, not health data — the privacy property of
        --postable has to survive everything added here.

        Uses a device with REAL, distinct per-night values. The flat-zero fixture this used to run on
        has no SpO₂ readings to leak, so it passed whatever the formatter did with them.
        """
        spo2s = [91, 93, 95, 97, 92, 98]
        with tempfile.TemporaryDirectory() as td:
            frames, nights = [], []
            base = _utc(2026, 8, 1, 0, 0, 0)
            for i, s in enumerate(spo2s):
                t0 = base + i * 86400 + 23 * 3600
                t1 = t0 + 7 * 3600
                frames += _plant_duty_night(t0, t1, s, period=900, phase=111, window=20)
                start = datetime.fromtimestamp(t0, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
                nights.append((start, float(s), t0, t1))
            cap = os.path.join(td, "vals.json")
            with open(cap, "w") as f:
                json.dump(frames, f)
            res = vs.validate_device(cap, _write_export(td, nights), device="vals")
        blob = vs.format_postable([res])
        self.assertEqual(res["paired_nights"], len(spo2s))   # the values really were there to leak
        for s in spo2s:
            self.assertNotIn(f"{s}.00", blob)
            self.assertNotIn(f"{float(s):.1f}", blob)

    def test_postable_on_a_flat_zero_device_is_still_clean(self):
        with tempfile.TemporaryDirectory() as td:
            d = self._flat_zero_device(td, "priv")
            res = vs.validate_device(d["capture"], d["export"], device="priv")
        blob = vs.format_postable([res])
        self.assertNotIn("96.00", blob)
        self.assertNotIn("cycle_start", blob.lower())
        self.assertIn("duty_mode", blob)


# --- NOOP app store (#845/#103) --------------------------------------------------------------------

def _pack_v18_aux(values: dict) -> bytes:
    """Build a `v18AuxSample.fields` blob the way the Swift/Kotlin codecs do."""
    bitmap = 0
    body = b""
    for i, (name, width) in enumerate(vs.V18_AUX_SLOTS):
        if name in values:
            bitmap |= 1 << i
            body += int(values[name]).to_bytes(width, "little")
    if bitmap == 0:
        return b""
    return bytes([vs.V18_AUX_FORMAT_VERSION]) + bitmap.to_bytes(4, "little") + body


def _write_app_db(folder: str, rows, *, device: str = "strap-a", name: str = "noop.sqlite") -> str:
    """A minimal NOOP app store: just the two tables this reader touches, same columns as the
    GRDB migration (`Database.swift` v23)."""
    path = os.path.join(folder, name)
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE v18AuxSample (deviceId TEXT NOT NULL, ts INTEGER NOT NULL, "
                "fields BLOB NOT NULL, PRIMARY KEY(deviceId, ts))")
    con.execute("CREATE TABLE sleepStateSample (deviceId TEXT NOT NULL, ts INTEGER NOT NULL, "
                "state INTEGER NOT NULL, rawByte INTEGER, PRIMARY KEY(deviceId, ts))")
    for ts, raw82, state in rows:
        con.execute("INSERT INTO v18AuxSample VALUES (?,?,?)",
                    (device, ts, _pack_v18_aux({"aux_byte_82": raw82})))
        con.execute("INSERT INTO sleepStateSample VALUES (?,?,?,?)", (device, ts, state, 0x20))
    con.commit()
    con.close()
    return path


class V18AuxCodecTests(unittest.TestCase):
    """The Python reader must decode what the SHIPPED Swift codec writes, not merely round-trip
    itself. Both fixtures below are the literal output of `V18AuxCodec.pack` run in
    `Packages/WhoopStore` — if the wire format changes, these fail rather than silently mis-slicing
    real rows into plausible-looking numbers."""

    # V18AuxSample(ts:1700000000, recordIndex:7, rrCount:3, cardiacFlags:0x81, hrQualityFlags:0x80,
    #   heartRateAlt:58, rrPacked:0x1234, cardiacStatus:255, stepCadence:40, statusWord:0x0550,
    #   statusWord1:0x0331, statusWord2:0x0442, auxByte82:96, opticalBaselineA:31,
    #   opticalBaselineB:33, opticalAmpA:128, opticalAmpB:128, unknownF32Bits:0xC0A93B1F)
    SWIFT_FULL = bytes.fromhex("02ffff0100070000000381803a3412ff28500531034204601f2180801f3ba9c0")
    # V18AuxSample(ts:1, auxByte82:96) — one slot present.
    SWIFT_SPARSE = bytes.fromhex("020008000060")

    def test_decodes_every_slot_the_swift_codec_packs(self):
        self.assertEqual(vs.unpack_v18_aux(self.SWIFT_FULL), {
            "record_index": 7, "rr_count": 3, "cardiac_flags": 0x81, "hr_quality_flags": 0x80,
            "heart_rate_alt": 58, "rr_packed": 0x1234, "cardiac_status": 255, "step_cadence": 40,
            "status_word": 0x0550, "status_word_1": 0x0331, "status_word_2": 0x0442,
            "aux_byte_82": 96, "optical_baseline_a": 31, "optical_baseline_b": 33,
            "optical_amp_a": 128, "optical_amp_b": 128, "unknown_f32_113": 0xC0A93B1F,
        })

    def test_absent_slots_are_omitted_not_zero(self):
        # The whole point of the presence bitmap: "the strap did not report this" must not read as 0.
        got = vs.unpack_v18_aux(self.SWIFT_SPARSE)
        self.assertEqual(got, {"aux_byte_82": 96})
        self.assertNotIn("optical_amp_a", got)

    def test_malformed_blobs_yield_nothing_rather_than_raising(self):
        for bad in (b"", b"\x02", bytes([1]) + b"\x00" * 4, bytes([99]) + b"\x00" * 4):
            self.assertEqual(vs.unpack_v18_aux(bad), {})

    def test_truncated_body_keeps_what_decoded(self):
        got = vs.unpack_v18_aux(self.SWIFT_FULL[:9])
        self.assertEqual(got["record_index"], 7)
        self.assertNotIn("aux_byte_82", got)


class AppDbReaderTests(unittest.TestCase):
    def test_app_store_is_told_apart_from_a_capture_store(self):
        with tempfile.TemporaryDirectory() as td:
            app = _write_app_db(td, [(1700000000, 96, 2)])
            self.assertTrue(vs.looks_like_app_db(app))
            cap = os.path.join(td, "cap.json")
            with open(cap, "w") as f:
                json.dump([], f)
            self.assertFalse(vs.looks_like_app_db(cap))

    def test_reads_banked_aux_byte_and_sleep_state(self):
        with tempfile.TemporaryDirectory() as td:
            app = _write_app_db(td, [(1700000000 + i, 95 + i, 2) for i in range(4)])
            recs = vs.load_app_db_records(app)
        self.assertEqual(len(recs), 4)
        self.assertEqual([r["spo2_candidate_82"] for r in recs], [95, 96, 97, 98])
        self.assertTrue(all(r["sleep_state"] == vs.SLEEP_ASLEEP for r in recs))

    def test_out_of_band_values_are_not_candidates(self):
        with tempfile.TemporaryDirectory() as td:
            app = _write_app_db(td, [(1700000000, 0, 2), (1700000001, 96, 2)])
            recs = vs.load_app_db_records(app)
        self.assertIsNone(recs[0]["spo2_candidate_82"])
        self.assertEqual(recs[0]["aux_byte_82"], 0)
        self.assertEqual(recs[1]["spo2_candidate_82"], 96)

    def test_several_straps_refuse_to_pool_without_an_explicit_pick(self):
        with tempfile.TemporaryDirectory() as td:
            app = _write_app_db(td, [(1700000000, 96, 2)], device="strap-a")
            con = sqlite3.connect(app)
            con.execute("INSERT INTO v18AuxSample VALUES (?,?,?)",
                        ("strap-b", 1700000000, _pack_v18_aux({"aux_byte_82": 90})))
            con.commit()
            con.close()
            with self.assertRaises(SystemExit):
                vs.load_app_db_records(app)
            # ...but naming one is fine, and reads only that strap.
            recs = vs.load_app_db_records(app, device_id="strap-b")
        self.assertEqual([r["aux_byte_82"] for r in recs], [90])

    def test_only_offset_82_is_answerable_without_the_frame(self):
        # The app banks decoded slots, not frame bytes, so the specificity scan cannot run — and
        # "cannot know" must be None rather than 0, or it would manufacture out-of-band samples.
        with tempfile.TemporaryDirectory() as td:
            app = _write_app_db(td, [(1700000000, 96, 2)])
            rec = vs.load_app_db_records(app)[0]
        self.assertEqual(vs.byte_at_offset(rec, vs.OFF_SPO2_CANDIDATE), 96)
        for off in (74, 81, 83, 92):
            self.assertIsNone(vs.byte_at_offset(rec, off))

    def test_end_to_end_validate_device_against_an_app_store(self):
        """The point of the whole path: a NOOP user with only their synced app DB can run the gate."""
        nights, rows = [], []
        base = _utc(2026, 3, 1, 23, 0, 0)
        for night in range(6):
            t0 = base + night * 86400
            t1 = t0 + 6 * 3600
            spo2 = 95.0 + night * 0.5
            start = datetime.fromtimestamp(t0, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
            nights.append((start, spo2, t0, t1))
            for k in range(40):
                rows.append((t0 + k * 60, int(round(spo2)), vs.SLEEP_ASLEEP))
        with tempfile.TemporaryDirectory() as td:
            app = _write_app_db(td, rows)
            res = vs.validate_device(app, _write_export(td, nights), device="app")
        self.assertEqual(res["source"], "noop_app_db")
        self.assertEqual(res["specificity_scan"], "unavailable_app_db")
        self.assertEqual(res["paired_nights"], 6)
        self.assertIsNotNone(res["r"])
        self.assertGreater(res["r"], 0.9)
        # The scan could not run, so it must not be recorded as "@82 lost".
        self.assertTrue(res["checklist"]["offset_82_wins"])
        self.assertIsNone(res["best_specificity_offset"])

    def test_a_capture_still_runs_the_specificity_scan(self):
        """Guard the other direction: the app path must not disable the scan for real captures."""
        with tempfile.TemporaryDirectory() as td:
            d = self._six_night_capture(td)
            res = vs.validate_device(d["capture"], d["export"], device="cap")
        self.assertEqual(res["source"], "capture")
        self.assertEqual(res["specificity_scan"], "ran")

    def _six_night_capture(self, td: str) -> dict:
        frames, nights = [], []
        base = _utc(2026, 3, 1, 23, 0, 0)
        for night in range(6):
            t0 = base + night * 86400
            t1 = t0 + 6 * 3600
            spo2 = 95.0 + night * 0.5
            start = datetime.fromtimestamp(t0, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
            nights.append((start, spo2, t0, t1))
            for k in range(40):
                frames.append({"hex": make_v18(t0 + k * 60, aux_byte_82=int(round(spo2)),
                                               sleep_state=vs.SLEEP_ASLEEP).hex()})
        cap = os.path.join(td, "cap.json")
        with open(cap, "w") as f:
            json.dump(frames, f)
        return {"capture": cap, "export": _write_export(td, nights)}
