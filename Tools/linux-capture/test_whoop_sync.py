"""Tests for whoop_sync — WHOOP 4.0/5.0 historical-offload helpers, the Family abstraction, and the
durable device-scoped WhoopDB.

Run: python3 -m unittest -v   (no third-party deps; does not import bleak — whoop_sync imports bleak
lazily inside its BLE functions, so the helpers + DB are testable stdlib-only.)

The whoop4 frame offsets exercised here (inner @ 4, meta_type @ 6, trim cursor @ 17:25) are the
verified whoop5 offsets minus 4, and match the on-hardware HISTORY_END the strap serves.
"""

import os
import tempfile
import unittest

import whoop_frame as wf
import whoop_sync as ws


def _make_whoop4_metadata(meta_type, end_data=b"\x11\x22\x33\x44\xAA\xBB\xCC\xDD"):
    """Build a CRC-valid WHOOP-4 METADATA frame with the given meta_type and 8-byte end_data placed
    at the trim-cursor offset (frame[17:25] = inner[13:21])."""
    inner = bytearray(21)
    inner[0] = ws.PACKET_METADATA          # frame[4]
    inner[2] = meta_type                   # frame[6]
    inner[13:21] = end_data                # frame[17:25]
    length = len(inner) + 4
    lb = bytes([length & 0xFF, (length >> 8) & 0xFF])
    return bytes([0xAA]) + lb + bytes([wf.crc8(lb)]) + bytes(inner) + \
        wf.crc32(bytes(inner)).to_bytes(4, "little")


class Whoop4FrameHelpers(unittest.TestCase):
    # The whoop4 helpers are module-private and exposed via Family; test them directly.
    def test_verify_roundtrip(self):
        f = wf.build_command_frame(ws.CMD_SEND_HISTORICAL_DATA, seq=3, payload=b"\x00")
        self.assertTrue(wf.verify_whoop4_frame(f))
        self.assertFalse(wf.verify_whoop4_frame(f[:-1] + b"\x00"))   # corrupt CRC32

    def test_history_end_data_extracts_trim_cursor(self):
        end = b"\x11\x22\x33\x44\xAA\xBB\xCC\xDD"
        frame = _make_whoop4_metadata(ws.META_HISTORY_END, end)
        self.assertEqual(wf.history_end_data_whoop4(frame), end)

    def test_history_start_is_not_acked(self):
        frame = _make_whoop4_metadata(ws.META_HISTORY_START)
        self.assertIsNone(wf.history_end_data_whoop4(frame))   # only HISTORY_END yields ack data

    def test_corrupt_history_end_rejected(self):
        frame = bytearray(_make_whoop4_metadata(ws.META_HISTORY_END))
        frame[18] ^= 0xFF                                # flip a byte → CRC fails
        self.assertIsNone(wf.history_end_data_whoop4(bytes(frame)))

    def test_ack_payload_is_0x01_plus_end_data(self):
        end = b"\x11\x22\x33\x44\xAA\xBB\xCC\xDD"
        ack = wf.build_history_ack_whoop4(end, seq=50)
        self.assertTrue(wf.verify_whoop4_frame(ack))
        self.assertEqual(ack[6], ws.CMD_HISTORICAL_DATA_RESULT)
        self.assertEqual(bytes(ack[7:7 + 9]), b"\x01" + end)


class FamilyTests(unittest.TestCase):
    def test_whoop4_offsets_and_builder(self):
        f = ws.Family("whoop4")
        self.assertEqual(f.inner_off, 4)
        self.assertIsNone(f.opener)                      # 4.0 needs no session hello
        frame = _make_whoop4_metadata(ws.META_HISTORY_END)
        self.assertEqual(f.meta_type(frame), ws.META_HISTORY_END)
        self.assertEqual(f.cmd(ws.CMD_SEND_HISTORICAL_DATA, seq=3)[0], 0xAA)

    def test_whoop5_offsets_and_puffin(self):
        f = ws.Family("whoop5")
        self.assertEqual(f.inner_off, 8)                 # whoop5 inner record starts 4 bytes later
        self.assertEqual(f.opener, wf.WHOOP5_CLIENT_HELLO)
        self.assertTrue(f.cmd(ws.CMD_SEND_HISTORICAL_DATA, seq=3).startswith(b"\xaa\x01"))  # puffin frame
        self.assertEqual((f._unix_off, f._hr_off), (15, 22))   # type-47 v18: unix @ 15, heart_rate @ 22

    def test_whoop5_v18_decode_with_version_guard(self):
        f = ws.Family("whoop5")
        # synth a whoop5 type-47 frame: inner type @ 8 = 47, hist_version @ 9, unix @ 15, hr @ 22
        frame = bytearray(60)
        frame[8] = ws.PACKET_HISTORICAL_DATA
        frame[15:19] = (1700000000).to_bytes(4, "little")
        frame[22] = 106
        frame[9] = 18                                    # v18 → decodes
        self.assertEqual(f.rec_unix(bytes(frame)), 1700000000)
        self.assertEqual(f.rec_hr(bytes(frame)), 106)
        frame[9] = 26                                    # v26 → different layout, must NOT mis-decode
        self.assertIsNone(f.rec_unix(bytes(frame)))
        self.assertIsNone(f.rec_hr(bytes(frame)))

    def test_unknown_model_rejected(self):
        with self.assertRaises(SystemExit):
            ws.Family("whoop6")


class WhoopDBTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.db = ws.WhoopDB(os.path.join(self.tmp, "t.db"))

    def _frame(self, hexstr, t=47, unix=1000, hr=60):
        return (1, "61080005", t, unix, hr, hexstr)   # (recv_ms, char, inner_type, unix, hr, hex)

    def test_upsert_device_is_idempotent(self):
        a = self.db.upsert_device("AA:BB:CC:DD:EE:FF", name="4C", subject="me", model="whoop4")
        b = self.db.upsert_device("aa:bb:cc:dd:ee:ff")   # case-insensitive, same device
        self.assertEqual(a, b)
        self.assertEqual(self.db.device_info(a)[2], "me")  # subject preserved (COALESCE)

    def test_commit_chunk_persists_and_dedups(self):
        did = self.db.upsert_device("AA:BB:CC:DD:EE:FF", model="whoop4")
        self.db.commit_chunk(did, [self._frame("aa01", unix=100), self._frame("aa02", unix=101)], trim=5, complete=False)
        self.db.commit_chunk(did, [self._frame("aa02", unix=101), self._frame("aa03", unix=102)], trim=6, complete=False)
        self.assertEqual(self.db.coverage(did)[2], 3)               # aa02 deduped, not double-counted
        self.assertEqual(self.db.state(did)["last_trim"], "6")      # cursor advanced + persisted
        self.assertEqual(self.db.coverage(did)[0], 100)            # min unix
        self.assertEqual(self.db.coverage(did)[1], 102)            # max unix

    def test_device_scoping_no_cross_contamination(self):
        d1 = self.db.upsert_device("AA:BB:CC:DD:EE:FF", model="whoop4")
        d2 = self.db.upsert_device("11:22:33:44:55:66", model="whoop5")
        # same hex on two devices must both persist (UNIQUE is per-device, not global)
        self.db.commit_chunk(d1, [self._frame("aabb")], trim=1, complete=False)
        self.db.commit_chunk(d2, [self._frame("aabb")], trim=1, complete=False)
        self.assertEqual(self.db.coverage(d1)[2], 1)
        self.assertEqual(self.db.coverage(d2)[2], 1)

    def test_history_complete_flag(self):
        did = self.db.upsert_device("AA:BB:CC:DD:EE:FF", model="whoop4")
        self.db.commit_chunk(did, [self._frame("aa01")], trim=9, complete=True)
        self.assertEqual(self.db.state(did)["history_complete"], "1")

    def test_export_json_roundtrip_and_filter(self):
        import json
        did = self.db.upsert_device("AA:BB:CC:DD:EE:FF", model="whoop4")
        self.db.commit_chunk(did, [self._frame("aa01", t=47, unix=100),
                                   self._frame("bb02", t=49, unix=None)], trim=1, complete=False)
        out = os.path.join(self.tmp, "o.json")
        n = self.db.export_json(did, out, only_type=47)
        self.assertEqual(n, 1)
        with open(out) as f:
            recs = json.load(f)
        self.assertEqual(recs[0]["hex"], "aa01")

    def test_labels(self):
        did = self.db.upsert_device("AA:BB:CC:DD:EE:FF", model="whoop4")
        self.db.add_label(did, 1000, 2000, "walking", "evening")
        labs = self.db.labels(did)
        self.assertEqual(labs, [(1000, 2000, "walking", "evening")])


class DecodeWiringTests(unittest.TestCase):
    """The decode_features wiring on WhoopDB: feature schema on open, the decode-cursor read
    (frames_after), and the persisted-cursor write (set_state) that decode_new relies on."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.db = ws.WhoopDB(os.path.join(self.tmp, "t.db"))

    def _frame(self, hexstr, t=47, unix=1000, hr=60):
        return (1, "61080005", t, unix, hr, hexstr)   # (recv_ms, char, inner_type, unix, hr, hex)

    def test_feature_schema_applied_on_open(self):
        # apply_schema ran in __init__ → the feature table exists.
        r = self.db.db.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='feat_second'").fetchone()
        self.assertIsNotNone(r)

    def test_frames_after_orders_and_filters_by_id(self):
        did = self.db.upsert_device("AA:BB:CC:DD:EE:FF", model="whoop4")
        self.db.commit_chunk(did, [self._frame("aa01", unix=100),
                                   self._frame("aa02", unix=101),
                                   self._frame("aa03", unix=102)], trim=1, complete=False)
        rows = self.db.frames_after(did, 0)
        self.assertEqual([r[1] for r in rows], ["aa01", "aa02", "aa03"])  # ascending id order
        ids = [r[0] for r in rows]
        self.assertEqual(ids, sorted(ids))
        first_id = ids[0]
        after = self.db.frames_after(did, first_id)
        self.assertEqual([r[1] for r in after], ["aa02", "aa03"])         # first excluded

    def test_set_state_persists_cursor(self):
        did = self.db.upsert_device("AA:BB:CC:DD:EE:FF", model="whoop4")
        self.db.set_state(did, "last_decoded_frame_id", "5")
        self.assertEqual(self.db.state(did)["last_decoded_frame_id"], "5")


class _FakeSync:
    """Minimal stand-in for Sync carrying just the fields _progress_line reads."""
    def __init__(self, anchor, last_rec, complete=0, committed=0):
        self.sync_start_unix = anchor
        self.last_rec_unix = last_rec
        self.history_complete = complete
        self.committed = committed


class ProgressTests(unittest.TestCase):
    def test_fmt_eta(self):
        self.assertEqual(ws._fmt_eta(None), "—")
        self.assertEqual(ws._fmt_eta(5), "5s")
        self.assertEqual(ws._fmt_eta(125), "2m05s")
        self.assertEqual(ws._fmt_eta(3725), "1h02m")
        self.assertEqual(ws._fmt_eta(-3), "0s")          # clamped, never negative

    def test_bar_endpoints(self):
        self.assertEqual(ws._bar(0).count("█"), 0)
        self.assertEqual(ws._bar(100).count("█"), 10)
        self.assertEqual(ws._bar(50).count("█"), 5)

    def test_progress_fraction_by_record_time(self):
        now = 1_700_000_000
        s = _FakeSync(anchor=now - 3600, last_rec=now - 1200, committed=100)   # 2400/3600 of backlog
        line = ws._progress_line(s, now, rate=11.0, cover=10.0, model="whoop4")
        self.assertIn(" 67%", line)
        self.assertIn("ETA 2m00s", line)                 # 1200 remaining data-s / 10 cover = 120s
        self.assertIn("sync 4C", line)

    def test_progress_complete_pins_100(self):
        now = 1_700_000_000
        s = _FakeSync(anchor=now - 3600, last_rec=now - 1200, complete=1)       # behind, but COMPLETE
        line = ws._progress_line(s, now, rate=0.0, cover=0.0, model="whoop5")
        self.assertIn("100%", line)
        self.assertIn("ETA done", line)
        self.assertIn("sync 5", line)

    def test_progress_handshaking_before_first_record(self):
        s = _FakeSync(anchor=None, last_rec=0, committed=0)
        self.assertIn("handshaking", ws._progress_line(s, 1_700_000_000, 0, 0, "whoop4"))

    def test_progress_clamps_when_record_ahead_of_now(self):
        now = 1_700_000_000
        s = _FakeSync(anchor=now - 100, last_rec=now + 50)   # clock skew: record "ahead" of now
        line = ws._progress_line(s, now, rate=5.0, cover=1.0, model="whoop4")
        self.assertIn("100%", line)                          # done clamped to total, no >100%


if __name__ == "__main__":
    unittest.main()
