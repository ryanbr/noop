import pathlib
import struct
import tempfile

import whoop_activity as wa


def make_v18(unix=1000, hr=60, motion=0, wear=0, sleep_state=0,
             hr_flags=0, hr_alt=0, rr_packed=0, cardiac_flags=0, cardiac_status=0,
             record_index=0, step_cadence=0, status_word=0, aux_f32=0.0,
             temp_aux_1=0, temp_aux_2=0, status_word_1=0, status_word_2=0,
             onwrist=0, wake_quality=0, aux_byte_82=0,
             version=18, length=124):
    """Build a synthetic v18 type-47 frame with fields at their real offsets."""
    f = bytearray(length)
    f[0] = 0xAA
    f[9] = version
    struct.pack_into("<I", f, 11, record_index & 0xFFFFFFFF)   # @11 record_index (u32)
    struct.pack_into("<I", f, 15, unix)
    f[22] = hr & 0xFF
    f[36] = hr_flags & 0xFF                               # @36 hr_quality_flags (a flag byte)
    f[37] = hr_alt & 0xFF                                 # @37 heart_rate_alt (duplicate of hr@22)
    struct.pack_into("<H", f, 38, rr_packed & 0xFFFF)    # @38 rr_packed
    f[33] = cardiac_flags & 0xFF                          # @33 cardiac_flags
    f[40] = cardiac_status & 0xFF                         # @40 cardiac_status
    struct.pack_into("<H", f, 57, motion & 0xFFFF)
    f[59] = step_cadence & 0xFF                           # @59 step_cadence
    f[63] = wear & 0xFF                                   # @63 motion_wear_quality
    struct.pack_into("<h", f, 69, temp_aux_1)             # @69 temp_aux_1_raw (i16)
    struct.pack_into("<h", f, 71, temp_aux_2)             # @71 temp_aux_2_raw (i16)
    struct.pack_into("<H", f, 75, status_word & 0xFFFF)   # @75 status_word
    struct.pack_into("<H", f, 77, status_word_1 & 0xFFFF)  # @77 status_word_1
    struct.pack_into("<H", f, 79, status_word_2 & 0xFFFF)  # @79 status_word_2
    # @81: b0-1 onwrist, b2-3 wake_quality, b4-5 sleep_state (low nibble sub-flags otherwise ignored)
    f[81] = (onwrist & 3) | ((wake_quality & 3) << 2) | ((sleep_state & 3) << 4)
    f[82] = aux_byte_82 & 0xFF                            # @82 aux_byte_82
    struct.pack_into("<f", f, 113, aux_f32)               # @113 unknown_f32_113 (f32 LE)
    return bytes(f)


def test_decode_v18_roundtrips_fields():
    d = wa.decode_v18(make_v18(unix=1700000000, hr=58, motion=4000, wear=1, sleep_state=2))
    assert d == {"record_index": 0, "unix": 1700000000, "hr": 58,
                 "onwrist": 0, "wake_quality": 0, "sleep_state": 2, "aux_byte_82": 0,
                 "spo2_candidate_82": None,  # 0 is out-of-band (not 70–100)
                 "motion_count": 4000, "step_cadence": 0, "motion_wear_quality": 1,
                 "hr_quality_flags": 0, "heart_rate_alt": 0,
                 "rr_packed": 0, "cardiac_flags": 0, "cardiac_status": 0,
                 "temp_aux_1_raw": 0, "temp_aux_2_raw": 0,
                 "status_word": 0, "status_word_1": 0, "status_word_2": 0,
                 "unknown_f32_113": 0.0}


def test_decode_v18_spo2_candidate_82_tri_mode():
    # Mirrors Swift testHistoricalV18Spo2Candidate82TriMode: in-band 70–100 only.
    assert wa.decode_v18(make_v18(aux_byte_82=0))["spo2_candidate_82"] is None
    assert wa.decode_v18(make_v18(aux_byte_82=90))["spo2_candidate_82"] == 90
    assert wa.decode_v18(make_v18(aux_byte_82=70))["spo2_candidate_82"] == 70
    assert wa.decode_v18(make_v18(aux_byte_82=100))["spo2_candidate_82"] == 100
    for raw in (0x80, 0xA0, 0x20, 69, 101):
        d = wa.decode_v18(make_v18(aux_byte_82=raw))
        assert d["spo2_candidate_82"] is None
        assert d["aux_byte_82"] == raw


def test_decode_v18_byte36_is_a_flag_byte_not_a_fixed_point_hr():
    # @36/@37 was read as one u16 `hr_fixed_8_8` with bpm = value/256. Over 18,650 real v18 records that
    # model is false: bit 4 of @36 is NEVER set (a genuine 8.8 fraction sets it ~50% of the time) and it
    # is the only bit never set; 95.02% of values land in 0x80-0x8F (uniform would be 6.25%). @36 is a
    # flag byte whose bit 7 reads as a validity bit, and @37 is a DUPLICATE heart rate (equal to hr@22 in
    # 99.575% of records). The old "corr 0.989 with hr@22" was circular — the u16 is just hr@22 plus this
    # flag byte over 256, leaving a flat +0.504 ± 0.189 residual.
    d = wa.decode_v18(make_v18(hr=102, hr_flags=0x8D, hr_alt=101))
    assert "hr_fixed_8_8" not in d
    assert d["hr_quality_flags"] == 0x8D
    assert d["hr_quality_flags"] & 0x10 == 0     # bit 4 is never set
    assert d["hr_quality_flags"] & 0x80          # bit 7 = valid
    assert d["heart_rate_alt"] == 101            # duplicate of hr@22 (102 here)
    # The two bytes are independent: moving the flag byte must not move the duplicate HR (under the
    # retired u16 model every @36 step shifted the reported "bpm" by 1/256).
    assert wa.decode_v18(make_v18(hr=102, hr_flags=0x02, hr_alt=101))["heart_rate_alt"] == 101


def test_decode_v18_late_fields():
    d = wa.decode_v18(make_v18(record_index=25_500_000, step_cadence=130, aux_f32=-1.875))
    assert d["record_index"] == 25_500_000      # @11 per-record counter
    assert d["step_cadence"] == 130             # @59 cadence-like byte (raw)
    assert d["unknown_f32_113"] == -1.875       # @113 f32 LE (purpose unknown; exact in float32)


def test_decode_v18_reads_sleep_state_high_nibble_only():
    f = bytearray(make_v18(sleep_state=3))
    f[81] = (3 << 4) | 0x05      # state 3 + sub-flags 0x05
    assert wa.decode_v18(bytes(f))["sleep_state"] == 3


def test_decode_v18_temp_aux_channels():
    # @69/@71 signed i16 LE; °C = value/10. Use a body-temp-like value (34.0 °C -> 340).
    d = wa.decode_v18(make_v18(temp_aux_1=340, temp_aux_2=337))
    assert d["temp_aux_1_raw"] == 340 and d["temp_aux_1_raw"] / 10.0 == 34.0
    assert d["temp_aux_2_raw"] == 337 and d["temp_aux_2_raw"] / 10.0 == 33.7


def test_decode_v18_temp_aux_signed():
    # i16 (not u16): a value above 0x7FFF must come back negative.
    d = wa.decode_v18(make_v18(temp_aux_1=-50, temp_aux_2=-1))
    assert d["temp_aux_1_raw"] == -50
    assert d["temp_aux_2_raw"] == -1


def test_decode_v18_status_word_siblings():
    d = wa.decode_v18(make_v18(status_word=0x0080, status_word_1=0x0081, status_word_2=0x0082))
    assert d["status_word"] == 0x0080      # @75
    assert d["status_word_1"] == 0x0081    # @77 (low nibble = 1)
    assert d["status_word_2"] == 0x0082    # @79 (low nibble = 2)


def test_decode_v18_byte_81_bitfields():
    # @81 packs onwrist(b0-1), wake_quality(b2-3), sleep_state(b4-5).
    d = wa.decode_v18(make_v18(onwrist=1, wake_quality=2, sleep_state=3))
    assert d["onwrist"] == 1
    assert d["wake_quality"] == 2
    assert d["sleep_state"] == 3


def test_decode_v18_aux_byte_82():
    d = wa.decode_v18(make_v18(aux_byte_82=0x2A))
    assert d["aux_byte_82"] == 0x2A        # @82 raw


def test_decode_v18_rejects_non_v18_and_short():
    assert wa.decode_v18(make_v18(version=26)) is None       # wrong version byte
    assert wa.decode_v18(b"\xaa" + b"\x00" * 40) is None     # too short to hold the late fields


def _recs(seq, start=1000):
    """seq = list of (motion, wear, sleep_state) at 1 Hz from `start`."""
    return [wa.decode_v18(make_v18(unix=start + i, motion=m, wear=w, sleep_state=s))
            for i, (m, w, s) in enumerate(seq)]


def test_step_deltas_wrap_aware():
    recs = _recs([(65530, 1, 0), (4, 1, 0)])     # 65530 -> 4 wraps: (4-65530)&0xffff = 10
    assert wa.step_deltas(recs) == [(1001, 10)]


def test_step_deltas_drops_sanity_jumps_and_gaps():
    recs = _recs([(0, 0, 0), (5000, 0, 0)])      # delta 5000 >= sanity_max -> dropped
    assert wa.step_deltas(recs) == []
    gapped = [wa.decode_v18(make_v18(unix=1000, motion=0)),
              wa.decode_v18(make_v18(unix=1100, motion=20))]   # >max_gap_s gap, not bridged
    assert wa.step_deltas(gapped) == []


def test_steps_total_and_by_hour():
    recs = _recs([(0, 1, 0), (2, 1, 0), (5, 1, 0)])   # diffs 2,3 -> total 5
    assert wa.steps_total(recs) == 5
    by_hour = wa.steps_by_hour(recs)
    assert sum(by_hour.values()) == 5


def test_wear_quality_minutes():
    recs = _recs([(0, 0, 0)] * 120 + [(0, 1, 0)] * 60 + [(0, 0xFF, 0)] * 60)
    wm = wa.wear_quality_minutes(recs)
    assert wm["good"] == 2 and wm["fair"] == 1 and wm["invalid"] == 1


def test_sleep_segments_collapse():
    # wake(2s) -> asleep(3s) -> up(1s) -> asleep(2s)
    seq = [(0, 0, 0), (0, 0, 0), (0, 0, 2), (0, 0, 2), (0, 0, 2), (0, 0, 3), (0, 0, 2), (0, 0, 2)]
    recs = _recs(seq, start=2000)
    segs = wa.sleep_segments(recs)
    states = [s[0] for s in segs]
    assert states == ["wake", "asleep", "up", "asleep"]
    assert segs[0] == ("wake", 2000, 2001)        # (state, start_unix, end_unix)
    assert segs[1] == ("asleep", 2002, 2004)


def test_sleep_state_minutes():
    seq = [(0, 0, 2)] * 180 + [(0, 0, 0)] * 60 + [(0, 0, 3)] * 60
    recs = _recs(seq, start=3000)
    m = wa.sleep_state_minutes(recs)
    assert m["asleep"] == 3 and m["wake"] == 1 and m["up"] == 1


import os
import sqlite3
import json
import subprocess
import sys


def _make_db(path, frames):
    """frames = list of (unix, frame_bytes) -> minimal frames table like whoop_sync's."""
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE frames (device_id INT, inner_type INT, unix INT, hex TEXT)")
    con.executemany("INSERT INTO frames VALUES (2, 47, ?, ?)",
                    [(u, fb.hex()) for u, fb in frames])
    con.commit()
    con.close()


def test_records_reads_and_decodes():
    with tempfile.TemporaryDirectory() as _td:
        _run_test_records_reads_and_decodes(pathlib.Path(_td))


def _run_test_records_reads_and_decodes(tmp_path):
    db = tmp_path / "t.db"
    frames = [(1000 + i, make_v18(unix=1000 + i, motion=i, sleep_state=2)) for i in range(5)]
    frames.append((2000, make_v18(unix=2000, version=26)))   # non-v18 -> skipped
    _make_db(str(db), frames)
    recs = wa.records(str(db), device_id=2)
    assert len(recs) == 5 and all(r["sleep_state"] == 2 for r in recs)


def test_cli_steps_json():
    with tempfile.TemporaryDirectory() as _td:
        _run_test_cli_steps_json(pathlib.Path(_td))


def _run_test_cli_steps_json(tmp_path):
    db = tmp_path / "t.db"
    frames = [(1000 + i, make_v18(unix=1000 + i, motion=i, wear=1)) for i in range(5)]
    _make_db(str(db), frames)
    here = os.path.dirname(wa.__file__)
    out = subprocess.check_output(
        [sys.executable, os.path.join(here, "whoop_activity.py"), "steps",
         "--db", str(db), "--device", "2", "--json"], text=True)
    data = json.loads(out)
    assert data["steps_total"] == 4          # diffs 1,1,1,1
    assert data["wear_quality_minutes"].get("fair", 0) == 0   # 5 s < 1 min


def test_cli_sleep_json():
    with tempfile.TemporaryDirectory() as _td:
        _run_test_cli_sleep_json(pathlib.Path(_td))


def _run_test_cli_sleep_json(tmp_path):
    db = tmp_path / "t.db"
    frames = [(1000 + i, make_v18(unix=1000 + i, sleep_state=(2 if i < 3 else 0))) for i in range(5)]
    _make_db(str(db), frames)
    here = os.path.dirname(wa.__file__)
    out = subprocess.check_output(
        [sys.executable, os.path.join(here, "whoop_activity.py"), "sleep",
         "--db", str(db), "--device", "2", "--json"], text=True)
    data = json.loads(out)
    assert [s[0] for s in data["segments"]] == ["asleep", "wake"]


def test_integration_real_db_if_present():
    db = os.path.join(os.path.dirname(wa.__file__), "..", "..", "captures", "whoop4.db")
    if not os.path.exists(db):
        # unittest.SkipTest, not pytest.skip: pytest honours SkipTest, unittest does not honour
        # pytest.skip, and pytest is not in requirements.txt. One spelling works under both runners.
        import unittest
        raise unittest.SkipTest("real capture DB not present")
    import datetime as dt
    def u(s): return int(dt.datetime.fromisoformat(s).replace(tzinfo=dt.timezone.utc).timestamp())
    recs = wa.records(db, device_id=2, start=u("2026-06-09T00:00:00"), end=u("2026-06-10T00:00:00"))
    assert recs, "expected v18 records for 2026-06-09"
    total = wa.steps_total(recs)
    assert 1000 < total < 60000, f"daily steps out of sane range: {total}"
    assert wa.sleep_state_minutes(recs).get("asleep", 0) > 0


# ── unittest collection ───────────────────────────────────────────────────────────────────────────
# This module is written pytest-style: bare `def test_*` functions with plain `assert`, and no
# `unittest.TestCase`. `python3 -m unittest` — the command the linux-capture README documents, and the
# only runner guaranteed present (pytest is not in requirements.txt) — collects NOTHING from a module
# shaped that way. It exits 0 while running zero of these tests, which is indistinguishable from
# passing: that is how the @82 tri-mode decoder test below shipped without ever executing.
#
# `load_tests` is unittest's documented hook for exactly this. It wraps each module-level `test_*`
# callable in a FunctionTestCase so both runners see the same set, rather than rewriting 21 working
# tests into TestCase classes and risking a transcription error in the rewrite.
def load_tests(loader, tests, pattern):    # noqa: ARG001 — unittest protocol signature
    import unittest
    suite = unittest.TestSuite(tests)
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            suite.addTest(unittest.FunctionTestCase(fn, description=name))
    return suite
