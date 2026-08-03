"""Tests for hci_extract — btsnoop/pklg parsing, L2CAP/ATT reassembly, WHOOP frame extraction.

Run: python3 -m unittest -v   (no third-party deps; does not import bleak)

Fixtures are synthesised so the tests run without a real capture: we wrap known-good WHOOP frames
(built by whoop_frame) in ATT notifications, L2CAP, ACL and the container headers, then assert the
extractor recovers exactly those frames.
"""

import io
import json
import struct
import tempfile
import unittest

import hci_extract as hx
import whoop_frame as wf


def att_notify(handle: int, value: bytes) -> bytes:
    return bytes([hx.ATT_NOTIFY]) + struct.pack("<H", handle) + value


def att_write_cmd(handle: int, value: bytes) -> bytes:
    return bytes([hx.ATT_WRITE_CMD]) + struct.pack("<H", handle) + value


def l2cap_att(pdu: bytes) -> bytes:
    return struct.pack("<HH", len(pdu), hx.ATT_CID) + pdu


def acl_packet(conn: int, l2cap_payload: bytes, pb: int = 0b10) -> bytes:
    handle_flags = (conn & 0x0FFF) | (pb << 12)
    return struct.pack("<HH", handle_flags, len(l2cap_payload)) + l2cap_payload


def btsnoop_file(packets) -> bytes:
    """packets: list of (direction, acl_bytes). Wrap in a datalink-1002 btsnoop container."""
    out = bytearray(b"btsnoop\x00" + struct.pack(">II", 1, 1002))
    ts = hx.BTSNOOP_EPOCH_DELTA_US + 1_000_000
    for direction, acl in packets:
        pkt = bytes([hx.H4_ACL]) + acl
        flags = 1 if direction == "rx" else 0
        out += struct.pack(">IIIIq", len(pkt), len(pkt), flags, 0, ts)
        out += pkt
        ts += 10_000
    return bytes(out)


def pklg_file(packets) -> bytes:
    """packets: list of (direction, acl_bytes). Wrap in a big-endian PacketLogger container."""
    out = bytearray()
    secs = 1_700_000_000
    for direction, acl in packets:
        ptype = hx.PKLG_ACL_SENT if direction == "tx" else hx.PKLG_ACL_RECV
        body = struct.pack(">II", secs, 0) + bytes([ptype]) + acl
        out += struct.pack(">I", len(body)) + body
        secs += 1
    return bytes(out)


class BtsnoopParseTests(unittest.TestCase):
    def test_rejects_bad_magic(self):
        with self.assertRaises(ValueError):
            list(hx.parse_btsnoop(b"nope" + b"\x00" * 20))

    def test_direction_and_payload(self):
        acl = acl_packet(0x40, l2cap_att(att_notify(0x10, b"hello")))
        data = btsnoop_file([("rx", acl), ("tx", acl)])
        pkts = list(hx.parse_btsnoop(data))
        self.assertEqual(len(pkts), 2)
        self.assertEqual(pkts[0][1], "rx")
        self.assertEqual(pkts[1][1], "tx")
        self.assertEqual(pkts[0][2], acl)          # H4 type byte stripped

    def test_timestamp_is_unix_ms(self):
        acl = acl_packet(0x40, l2cap_att(att_notify(0x10, b"x")))
        pkts = list(hx.parse_btsnoop(btsnoop_file([("rx", acl)])))
        self.assertEqual(pkts[0][0], 1000)         # 1_000_000 µs after epoch delta → 1000 ms


class PklgParseTests(unittest.TestCase):
    def test_roundtrip_big_endian(self):
        acl = acl_packet(0x40, l2cap_att(att_notify(0x10, b"data")))
        pkts = list(hx.parse_pklg(pklg_file([("tx", acl), ("rx", acl)])))
        self.assertEqual([p[1] for p in pkts], ["tx", "rx"])
        self.assertEqual(pkts[0][2], acl)

    def test_skips_non_acl_records(self):
        # A type-0x00 (command) record between two ACLs must be ignored.
        acl = acl_packet(0x40, l2cap_att(att_notify(0x10, b"z")))
        good = pklg_file([("rx", acl)])
        cmd_body = struct.pack(">II", 1, 0) + bytes([0x00]) + b"\xde\xad"
        cmd = struct.pack(">I", len(cmd_body)) + cmd_body
        pkts = list(hx.parse_pklg(good[:0] + cmd + good))
        self.assertEqual(len(pkts), 1)


class L2capReassemblyTests(unittest.TestCase):
    def test_fragmented_pdu_reassembles(self):
        ra = hx.L2capReassembler()
        pdu = l2cap_att(att_notify(0x10, b"A" * 40))
        first = acl_packet(0x40, pdu[:20], pb=0b10)
        cont = acl_packet(0x40, pdu[20:], pb=0b01)
        self.assertEqual(ra.feed("rx", first), [])            # incomplete
        done = ra.feed("rx", cont)
        self.assertEqual(len(done), 1)
        conn, cid, payload = done[0]
        self.assertEqual(cid, hx.ATT_CID)
        self.assertEqual(payload, att_notify(0x10, b"A" * 40))

    def test_continuation_without_start_dropped(self):
        ra = hx.L2capReassembler()
        self.assertEqual(ra.feed("rx", acl_packet(0x40, b"orphan", pb=0b01)), [])


class HandleMapTests(unittest.TestCase):
    def test_read_by_type_maps_char_value_handle(self):
        hm = hx.HandleMap()
        uuid = "fd4b0003-cce1-4033-93ce-002d5875f58a"
        uuid_le = bytes.fromhex(uuid.replace("-", ""))[::-1]
        entry = struct.pack("<H", 0x0020) + bytes([0x10]) + struct.pack("<H", 0x0021) + uuid_le
        pdu = bytes([hx.ATT_READ_BY_TYPE_RSP, 21]) + entry
        hm.feed_att(pdu)
        self.assertEqual(hm.name(0x0021), uuid)

    def test_unknown_handle_falls_back_to_hex(self):
        self.assertEqual(hx.HandleMap().name(0x00AB), "handle-0x00ab")


class ExtractTests(unittest.TestCase):
    def _whoop5_frames(self):
        # A history-metadata frame + a couple of command frames, all CRC-valid puffin frames.
        f1 = wf.build_puffin_command(wf.PUFFIN_CMD_GET_BATTERY_LEVEL, seq=1)
        f2 = wf.build_puffin_command(wf.PUFFIN_CMD_REPORT_VERSION_INFO, seq=2)
        return [f1, f2]

    def test_extracts_only_crc_valid_streams(self):
        frames = self._whoop5_frames()
        # Strap notifications on handle 0x21 (WHOOP) + junk notifications on handle 0x99 (other device).
        packets = []
        for fr in frames:
            packets.append(("rx", acl_packet(0x40, l2cap_att(att_notify(0x21, fr)))))
        packets.append(("rx", acl_packet(0x41, l2cap_att(att_notify(0x99, b"\xaa\x01not a frame")))))
        records, stats = hx.extract(hx.parse_btsnoop(btsnoop_file(packets)), "whoop5")
        self.assertEqual(len(records), len(frames))            # junk stream dropped (no CRC-valid frame)
        self.assertTrue(all(r["char"].startswith("handle-0x0021") for r in records))
        self.assertEqual(sum(s["frames"] for s in stats.values()), len(frames))

    def test_captures_app_writes_with_direction(self):
        # The app's tx write (e.g. an enable-sequence command) must be captured and marked dir=tx.
        cmd = wf.build_puffin_command(wf.PUFFIN_CMD_GET_CLOCK, seq=0)
        pkt = ("tx", acl_packet(0x40, l2cap_att(att_write_cmd(0x22, cmd))))
        records, _stats = hx.extract(hx.parse_btsnoop(btsnoop_file([pkt])), "whoop5")
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["dir"], "tx")

    def test_hr_measurement_updates_latest_hr(self):
        # A standard-HR notification on the mapped 0x2A37 handle should annotate later frames' hr.
        hm_uuid = "00002a37-0000-1000-8000-00805f9b34fb"
        uuid_le = bytes.fromhex(hm_uuid.replace("-", ""))[::-1]
        decl = struct.pack("<H", 0x0030) + bytes([0x10]) + struct.pack("<H", 0x0031) + uuid_le
        find_rsp = bytes([hx.ATT_READ_BY_TYPE_RSP, 21]) + decl
        frame = wf.build_puffin_command(wf.PUFFIN_CMD_GET_BATTERY_LEVEL)
        packets = [
            ("rx", acl_packet(0x40, l2cap_att(find_rsp))),
            ("rx", acl_packet(0x40, l2cap_att(att_notify(0x31, bytes([0x00, 62]))))),  # HR 62 bpm
            ("rx", acl_packet(0x40, l2cap_att(att_notify(0x21, frame)))),
        ]
        records, _ = hx.extract(hx.parse_btsnoop(btsnoop_file(packets)), "whoop5")
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["hr"], 62)

    def test_end_to_end_via_load_hci_pklg(self):
        frame = wf.build_puffin_command(wf.PUFFIN_CMD_GET_BATTERY_LEVEL)
        data = pklg_file([("rx", acl_packet(0x40, l2cap_att(att_notify(0x21, frame))))])
        with tempfile.NamedTemporaryFile(suffix=".pklg", delete=False) as f:
            f.write(data)
            path = f.name
        records, _ = hx.extract(hx.load_hci(path), "whoop5")
        self.assertEqual(len(records), 1)
        self.assertEqual(bytes.fromhex(records[0]["hex"]), frame)


if __name__ == "__main__":
    unittest.main()
