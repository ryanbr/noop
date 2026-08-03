"""Tests for correlate_ground_truth — CSV/alias loading and the known-plaintext field search.

Run: python3 -m unittest -v   (no third-party deps; does not import bleak)

The correlation test plants a known ground-truth value into synthetic records at a chosen offset and
encoding, then asserts the search recovers that exact (type, field, offset, encoding, scale).
"""

import io
import json
import os
import struct
import tempfile
import unittest
import zipfile

import correlate_ground_truth as cg
import whoop_frame as wf


class HeaderAliasTests(unittest.TestCase):
    def test_german_header_maps_to_canonical(self):
        self.assertEqual(cg._norm_header("Herzfrequenzvariabilität (ms)"), "heart_rate_variability_ms")
        self.assertEqual(cg._norm_header("Hauttemperatur (Celsius)"), "skin_temp_celsius")

    def test_english_headers_map_to_canonical(self):
        # Official English exports use title-case headers; without aliases, ground-truth fields
        # like blood_oxygen_pct were invisible to correlate_ground_truth (#103 SpO₂ work).
        self.assertEqual(cg._norm_header("Heart rate variability (ms)"),
                         "heart_rate_variability_ms")
        self.assertEqual(cg._norm_header("Blood oxygen %"), "blood_oxygen_pct")
        self.assertEqual(cg._norm_header("Skin temp (celsius)"), "skin_temp_celsius")
        self.assertEqual(cg._norm_header("Cycle start time"), "cycle_start_time")

    def test_bom_stripped(self):
        self.assertEqual(cg._norm_header("﻿Startzeit des Zyklus"), "cycle_start_time")


class CsvLoadingTests(unittest.TestCase):
    def test_load_german_cycles_from_zip(self):
        cycles = ("Startzeit des Zyklus,Herzfrequenzvariabilität (ms),"
                  "Ruheherzfrequenz (Schläge pro Minute)\n"
                  "2026-06-20 00:24:31,92,54\n"
                  "2026-06-18 23:30:56,101,53\n")
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            z.writestr("physiologische_zyklen.csv", cycles)
        with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as f:
            f.write(buf.getvalue())
            path = f.name
        rows = cg.load_ground_truth(path)
        self.assertEqual(len(rows), 2)
        truth = cg.truth_values(rows)
        self.assertEqual(sorted(truth["hrv_ms"]), [92.0, 101.0])
        self.assertEqual(sorted(truth["resting_hr_bpm"]), [53.0, 54.0])

    def test_load_english_cycles_spo2(self):
        cycles = (
            "Cycle start time,Blood oxygen %,Skin temp (celsius)\n"
            "2026-07-15 23:25:58,95.82,34.24\n"
            "2026-07-14 23:51:24,97.29,34.40\n"
        )
        folder = tempfile.mkdtemp()
        with open(os.path.join(folder, "physiological_cycles.csv"), "w") as f:
            f.write(cycles)
        rows = cg.load_ground_truth(folder)
        truth = cg.truth_values(rows)
        self.assertEqual(sorted(truth["spo2_pct"]), [95.82, 97.29])
        self.assertEqual(sorted(truth["skin_temp_c"]), [34.24, 34.40])

    def test_merges_cycles_and_sleep_on_cycle_start(self):
        cycles = "Startzeit des Zyklus,Herzfrequenzvariabilität (ms)\n2026-06-20 00:24:31,92\n"
        sleep = "Startzeit des Zyklus,Atemfrequenz (Atemzüge/Min.)\n2026-06-20 00:24:31,14.6\n"
        folder = tempfile.mkdtemp()
        with open(os.path.join(folder, "physiologische_zyklen.csv"), "w") as f:
            f.write(cycles)
        with open(os.path.join(folder, "Schlaf.csv"), "w") as f:
            f.write(sleep)
        rows = cg.load_ground_truth(folder)
        self.assertEqual(len(rows), 1)
        truth = cg.truth_values(rows)
        self.assertEqual(truth["hrv_ms"], [92.0])
        self.assertEqual(truth["respiratory_rate"], [14.6])


class CandidateExtractionTests(unittest.TestCase):
    def test_all_encodings_present(self):
        rec = struct.pack("<f", 34.93) + b"\x00" * 4
        c = cg.candidates_at(rec, 0)
        self.assertIn("f32le", c)
        self.assertAlmostEqual(c["f32le"], 34.93, places=4)
        self.assertIn("u16le", c)

    def test_close_rejects_nan_and_huge(self):
        self.assertFalse(cg._close(float("nan"), 50, 0.03))
        self.assertFalse(cg._close(1e12, 50, 0.03))
        self.assertTrue(cg._close(50.4, 50, 0.03))


class CorrelationTests(unittest.TestCase):
    def _plant(self, values, offset, fmt, reclen=32):
        """Build one record per value with `value` packed at `offset` in `fmt`, rest zero-ish noise."""
        records = []
        for i, v in enumerate(values):
            rec = bytearray([0x2F]) + bytes([(i * 7 + 3) & 0xFF]) * (reclen - 1)
            struct.pack_into(fmt, rec, offset, v)
            records.append(bytes(rec))
        return records

    def test_recovers_planted_u8_field(self):
        # Resting HR as a u8 at offset 10, one record per night.
        hrs = [54, 53, 60, 48, 55, 51, 58, 49]
        records = self._plant(hrs, 10, "<B")
        truth = {"resting_hr_bpm": [float(h) for h in hrs]}
        hits = cg.correlate({0x2F: records}, truth, "whoop5", tolerance=0.0, min_hits=5)
        top = next(h for h in hits if h["field"] == "resting_hr_bpm")
        self.assertEqual(top["offset"], 10)
        self.assertEqual(top["encoding"], "u8")
        self.assertEqual(top["type"], 0x2F)

    def test_recovers_planted_float_skin_temp(self):
        temps = [34.93, 33.26, 35.10, 34.01, 33.88, 34.55, 35.30, 33.40]
        records = self._plant(temps, 14, "<f")
        truth = {"skin_temp_c": temps}
        hits = cg.correlate({0x2F: records}, truth, "whoop5", tolerance=0.01, min_hits=5)
        top = next(h for h in hits if h["field"] == "skin_temp_c")
        self.assertEqual(top["offset"], 14)
        self.assertEqual(top["encoding"], "f32le")
        self.assertEqual(top["scale"], 1)

    def test_recovers_scaled_u16_respiratory_rate(self):
        # Respiratory rate stored as value×10 in a u16 LE (14.6 → 146).
        rr = [14.6, 14.4, 15.1, 13.8, 16.0, 14.9, 15.5, 13.2]
        records = self._plant([int(round(v * 10)) for v in rr], 20, "<H")
        truth = {"respiratory_rate": rr}
        hits = cg.correlate({0x2F: records}, truth, "whoop5", tolerance=0.01, min_hits=5)
        top = next(h for h in hits if h["field"] == "respiratory_rate")
        self.assertEqual(top["offset"], 20)
        self.assertEqual(top["scale"], 10)
        # value×10 stays < 256, so the u16-LE low byte equals the u8 value — both are correct
        # interpretations and u8 is tried first. Either is an acceptable recovery of this field.
        self.assertIn(top["encoding"], ("u8", "u16le"))

    def test_no_false_positive_on_random_records(self):
        import random
        rng = random.Random(1)
        records = [bytes([0x2F] + [rng.randint(0, 255) for _ in range(31)]) for _ in range(40)]
        # A ground truth that shares no relationship with the random bytes.
        truth = {"skin_temp_c": [34.93, 33.26, 35.10, 34.01, 33.88, 34.55, 35.30, 33.40]}
        hits = cg.correlate({0x2F: records}, truth, "whoop5", tolerance=0.001, min_hits=10)
        self.assertEqual(hits, [])

    def test_group_records_by_type_skips_invalid(self):
        good = wf.build_puffin_command(wf.PUFFIN_CMD_GET_BATTERY_LEVEL)
        bad = bytearray(good)
        bad[-1] ^= 0xFF                              # corrupt the CRC32
        by_type = cg.group_records_by_type(
            [{"hex": good.hex()}, {"hex": bytes(bad).hex()}], "whoop5")
        self.assertEqual(sum(len(v) for v in by_type.values()), 1)


if __name__ == "__main__":
    unittest.main()
