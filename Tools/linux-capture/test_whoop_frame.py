"""Tests for whoop_frame — framing, reassembly, and HR parsing.

Run: python3 -m unittest -v   (no third-party deps; does not import bleak)

The framing here is cross-checked against the Swift WhoopProtocol decoder: a GET_BATTERY_LEVEL frame
built by build_command_frame() decodes with ok=true and both CRCs valid via `whoop-decode`.
"""

import unittest

import whoop_frame as wf


class FramingTests(unittest.TestCase):
    def test_crc8_matches_known_table(self):
        # First few entries of the WHOOP CRC-8 table (poly 0x07).
        self.assertEqual(wf._CRC8_TABLE[1], 0x07)
        self.assertEqual(wf._CRC8_TABLE[2], 0x0E)
        self.assertEqual(wf._CRC8_TABLE[255], wf._CRC8_TABLE[255])  # table is fully built (no IndexError)
        self.assertEqual(len(wf._CRC8_TABLE), 256)

    def test_build_command_frame_battery(self):
        f = wf.build_command_frame(wf.CMD_GET_BATTERY_LEVEL)
        self.assertEqual(f[0], 0xAA)            # SOF
        self.assertEqual(f[4], wf.COMMAND_TYPE) # type=35
        self.assertEqual(f[5], 0)               # seq
        self.assertEqual(f[6], wf.CMD_GET_BATTERY_LEVEL)
        # crc8 over the two length bytes
        self.assertEqual(f[3], wf.crc8(f[1:3]))
        # crc32 (LE) over the inner [type][seq][cmd][payload]
        inner = f[4:-4]
        want = wf.crc32(inner)
        got = f[-4] | (f[-3] << 8) | (f[-2] << 16) | (f[-1] << 24)
        self.assertEqual(got, want)

    def test_client_hello_is_16_bytes(self):
        self.assertEqual(len(wf.WHOOP5_CLIENT_HELLO), 16)
        self.assertEqual(wf.WHOOP5_CLIENT_HELLO[0], 0xAA)


class PuffinCommandTests(unittest.TestCase):
    def test_crc16_modbus_on_client_hello_header(self):
        # The CLIENT_HELLO header bytes [0..6] check to the embedded CRC16 0x71E6 (LE e6 71).
        self.assertEqual(wf.crc16_modbus(wf.WHOOP5_CLIENT_HELLO[0:6]), 0x71E6)

    def test_build_puffin_command_structure(self):
        f = wf.build_puffin_command(3, seq=7, payload=bytes([0x01]))
        self.assertEqual(f[0], 0xAA)
        self.assertEqual(f[1], 0x01)            # format
        self.assertEqual(f[8], 35)              # inner type (COMMAND)
        self.assertEqual(f[9], 7)               # seq
        self.assertEqual(f[10], 3)              # cmd
        # header CRC16 over the first 6 bytes, LE at [6:8]
        self.assertEqual(f[6] | (f[7] << 8), wf.crc16_modbus(f[0:6]))
        # CRC32 over the inner [type][seq][cmd][payload], LE trailer
        inner = f[8:-4]
        got = f[-4] | (f[-3] << 8) | (f[-2] << 16) | (f[-1] << 24)
        self.assertEqual(got, wf.crc32(inner))

    def test_client_hello_is_a_puffin_command(self):
        # CLIENT_HELLO == puffinCommandFrame(cmd=145, seq=1, payload=[0x01]).
        self.assertEqual(wf.build_puffin_command(145, seq=1, payload=bytes([0x01])),
                         wf.WHOOP5_CLIENT_HELLO)


class HistoryAckTests(unittest.TestCase):
    # Real CRC-valid frames captured from a worn WHOOP 5 (capture_hist2.json).
    HISTORY_END = bytes.fromhex(
        "aa011c00010023d1316a0284a3266a0a373d00000041b601001000000000000044d21e3d")
    HISTORY_START = bytes.fromhex(
        "aa012c0001002cd1312c0184a3266ad7230d0000005200000000000000320000002600000001000000000000000b010034497926")

    def test_verify_real_frames(self):
        self.assertTrue(wf.verify_whoop5_frame(self.HISTORY_END))
        self.assertTrue(wf.verify_whoop5_frame(self.HISTORY_START))

    def test_history_end_data_extracts_trim_plus_next(self):
        end_data = wf.history_end_data(self.HISTORY_END)
        # trim u32 (112193) at frame[21], next u32 (16) at frame[25] — the verbatim 8 bytes to echo.
        self.assertEqual(end_data, bytes.fromhex("41b6010010000000"))
        self.assertEqual(int.from_bytes(end_data[0:4], "little"), 112193)
        self.assertEqual(int.from_bytes(end_data[4:8], "little"), 16)

    def test_history_start_is_not_acked(self):
        # Only HISTORY_END (meta_type 2) advances the cursor; START (meta_type 1) must return None.
        self.assertIsNone(wf.history_end_data(self.HISTORY_START))

    def test_corrupt_frame_is_not_acked(self):
        bad = bytearray(self.HISTORY_END)
        bad[22] ^= 0xFF                      # flip a trim byte → CRC32 fails
        self.assertIsNone(wf.history_end_data(bytes(bad)))

    def test_build_history_ack_shape_and_crc(self):
        end_data = wf.history_end_data(self.HISTORY_END)
        ack = wf.build_history_ack(end_data, seq=50)
        self.assertEqual(ack[8], 35)                                  # inner type COMMAND
        self.assertEqual(ack[10], wf.PUFFIN_CMD_HISTORICAL_DATA_RESULT)  # cmd 23
        self.assertEqual(ack[11], 0x01)                              # payload prefix
        self.assertEqual(ack[12:20], end_data)                       # echoed end_data
        self.assertTrue(wf.verify_whoop5_frame(ack))                 # ack is itself CRC-valid


def _whoop4_frame(type_: int, seq: int, cmd: int, payload: bytes) -> bytes:
    """Build a complete, CRC-valid WHOOP 4.0 frame of an arbitrary type — for synthesising a METADATA
    HISTORY_END the same way build_command_frame() builds a COMMAND. Inner [type][seq][cmd][payload]
    starts at offset 4; len = (3 + len(payload)) + 4; CRC8 over the len bytes; CRC32 over the inner."""
    inner = bytes([type_, seq, cmd]) + payload
    length = (3 + len(payload)) + 4
    len_bytes = bytes([length & 0xFF, (length >> 8) & 0xFF])
    trailer = wf.crc32(inner)
    return (bytes([0xAA]) + len_bytes + bytes([wf.crc8(len_bytes)]) + inner
            + bytes([trailer & 0xFF, (trailer >> 8) & 0xFF,
                     (trailer >> 16) & 0xFF, (trailer >> 24) & 0xFF]))


class Whoop4HistoryAckTests(unittest.TestCase):
    """WHOOP 4.0 offload handshake — the 4.0 image of the whoop5 helpers. The inner record starts at
    offset 4 (vs 5.0's 8), so the metadata fields sit 4 bytes earlier: meta_type at frame[6], trim at
    frame[17], end_data = frame[17:25] (vs 5.0's frame[21:29]). Acks use CRC8 framing, not CRC16.

    Synthetic frames (real field offsets, recomputed CRC): no real WHOOP 4 HISTORY_END is in hand yet
    (that needs a hardware offload), and a synthetic frame fully exercises the pure framing logic. The
    ack is additionally cross-checked byte-exact via `whoop-decode --family whoop4`.
    """

    # Synthetic METADATA HISTORY_END (type 49, meta_type 2). Payload places trim u32 = 200000 at
    # frame[17] (payload[10]) and next u32 = 281 at frame[21] (payload[14]).
    _PAYLOAD_END = (bytes(10) + (200000).to_bytes(4, "little") + (281).to_bytes(4, "little"))
    HISTORY_END = _whoop4_frame(wf.PACKET_METADATA, seq=0x31, cmd=wf.META_HISTORY_END,
                                payload=_PAYLOAD_END)
    HISTORY_START = _whoop4_frame(wf.PACKET_METADATA, seq=0x30, cmd=wf.META_HISTORY_START,
                                  payload=_PAYLOAD_END)

    def test_verify_whoop4_frame(self):
        self.assertTrue(wf.verify_whoop4_frame(self.HISTORY_END))
        self.assertTrue(wf.verify_whoop4_frame(self.HISTORY_START))

    def test_history_end_data_whoop4_extracts_trim_plus_next(self):
        end_data = wf.history_end_data_whoop4(self.HISTORY_END)
        self.assertEqual(end_data, self.HISTORY_END[17:25])
        self.assertEqual(int.from_bytes(end_data[0:4], "little"), 200000)
        self.assertEqual(int.from_bytes(end_data[4:8], "little"), 281)

    def test_history_start_whoop4_not_acked(self):
        # Only HISTORY_END (meta_type 2) advances the cursor; START (meta_type 1) → None.
        self.assertIsNone(wf.history_end_data_whoop4(self.HISTORY_START))

    def test_corrupt_whoop4_frame_not_acked(self):
        bad = bytearray(self.HISTORY_END)
        bad[18] ^= 0xFF                      # flip a trim byte → CRC32 fails
        self.assertIsNone(wf.history_end_data_whoop4(bytes(bad)))

    def test_build_history_ack_whoop4_shape_and_crc(self):
        end_data = wf.history_end_data_whoop4(self.HISTORY_END)
        ack = wf.build_history_ack_whoop4(end_data, seq=50)
        self.assertEqual(ack[4], wf.COMMAND_TYPE)                        # inner type COMMAND (35) @4
        self.assertEqual(ack[6], wf.PUFFIN_CMD_HISTORICAL_DATA_RESULT)   # cmd 23 @6
        self.assertEqual(ack[7], 0x01)                                  # payload prefix
        self.assertEqual(ack[8:16], end_data)                           # echoed end_data
        self.assertTrue(wf.verify_whoop4_frame(ack))                    # ack is itself CRC-valid


class ReassemblerTests(unittest.TestCase):
    def test_single_frame_across_fragments(self):
        hello = wf.WHOOP5_CLIENT_HELLO
        ra = wf.Reassembler("whoop5")
        out = ra.feed(hello[:5]) + ra.feed(hello[5:11]) + ra.feed(hello[11:])
        self.assertEqual(out, [hello])

    def test_two_frames_in_one_notification(self):
        hello = wf.WHOOP5_CLIENT_HELLO
        ra = wf.Reassembler("whoop5")
        self.assertEqual(ra.feed(hello + hello), [hello, hello])

    def test_resync_after_leading_garbage(self):
        hello = wf.WHOOP5_CLIENT_HELLO
        ra = wf.Reassembler("whoop5")
        self.assertEqual(ra.feed(b"\x00\xff" + hello), [hello])

    def test_whoop4_reassembly(self):
        bat = wf.build_command_frame(wf.CMD_GET_BATTERY_LEVEL)
        ra = wf.Reassembler("whoop4")
        self.assertEqual(ra.feed(bat[:2]) + ra.feed(bat[2:]), [bat])

    def test_absurd_length_is_dropped(self):
        # A stray 0xAA followed by a huge declared length must not hang or over-buffer.
        ra = wf.Reassembler("whoop5")
        out = ra.feed(bytes([0xAA, 0x01, 0xFF, 0xFF]) + wf.WHOOP5_CLIENT_HELLO)
        self.assertEqual(out, [wf.WHOOP5_CLIENT_HELLO])


class BuzzFrameTests(unittest.TestCase):
    def test_whoop5_buzz_matches_hardware_frame(self):
        # Exact frame verified to vibrate a real WHOOP 5 (seq=2). If this changes, the strap rejects it.
        self.assertEqual(
            wf.build_whoop5_buzz(2).hex(),
            "aa0114000001e1e1230213012f9800000000000000000000e1a1feb4",
        )

    def test_whoop5_buzz_is_crc_valid_and_4_aligned(self):
        f = wf.build_whoop5_buzz(7)
        self.assertTrue(wf.verify_whoop5_frame(f))
        self.assertEqual((len(f) - 12) % 4, 0)   # inner record padded to a 4-byte boundary

    def test_whoop5_buzz_uses_maverick_opcode_not_79(self):
        # Inner record starts at offset 8; the cmd byte is two past the type. Must be 0x13, never 79.
        self.assertEqual(wf.build_whoop5_buzz(0)[10], wf.MAVERICK_HAPTIC_CMD)
        self.assertEqual(wf.MAVERICK_HAPTIC_CMD, 0x13)

    def test_whoop4_buzz_opcode_and_payload(self):
        f = wf.build_whoop4_buzz(2, pattern=2, loops=3)
        self.assertEqual(f[0], 0xAA)
        self.assertEqual(f[4], wf.COMMAND_TYPE)              # inner type at offset 4 on 4.0
        self.assertEqual(f[6], wf.WHOOP4_RUN_HAPTICS_PATTERN)
        self.assertEqual(f[7:12], bytes([2, 3, 0, 0, 0]))   # [patternId, numLoops, 0, 0, 0]

    def test_buzz_frame_dispatch(self):
        self.assertEqual(wf.buzz_frame("whoop5", 2), wf.build_whoop5_buzz(2))
        self.assertEqual(wf.buzz_frame("whoop4", 2), wf.build_whoop4_buzz(2))
        with self.assertRaises(ValueError):
            wf.buzz_frame("whoopX", 0)


class SetClockTests(unittest.TestCase):
    def test_payload_is_exactly_8_bytes(self):
        # Length is load-bearing: a wrong-length SET_CLOCK is ack'd but not latched.
        self.assertEqual(len(wf.set_clock_payload(1781264461)), 8)

    def test_payload_is_unix_le_plus_zero_subseconds(self):
        p = wf.set_clock_payload(1781264461)
        self.assertEqual(int.from_bytes(p[0:4], "little"), 1781264461)
        self.assertEqual(p[4:8], bytes(4))

    def test_whoop4_set_clock_uses_9_byte_body(self):
        # fw 41.17.6.0 latches ONLY the 9-byte [u32+5 zero] form (hardware-verified). Frame = AA + len(2)
        # + crc8 + [type,seq,cmd] + 9-byte body + crc32(4) = 7 + 9 + 4 = 20 bytes; body is frame[7:16].
        f = wf.build_whoop4_set_clock(1781265100, seq=4)
        self.assertEqual(len(f), 20)
        body = f[7:16]
        self.assertEqual(len(body), 9)
        self.assertEqual(int.from_bytes(body[0:4], "little"), 1781265100)
        self.assertEqual(body[4:9], bytes(5))

    def test_whoop4_set_clock_frame_crc_and_opcode(self):
        f = wf.build_whoop4_set_clock(1781264461, seq=2)
        self.assertEqual(f[0], 0xAA)
        self.assertEqual(f[4], wf.COMMAND_TYPE)
        self.assertEqual(f[6], wf.CMD_SET_CLOCK)
        # CRC32 over the inner [type,seq,cmd,payload] must check out.
        self.assertEqual(f[-4] | (f[-3] << 8) | (f[-2] << 16) | (f[-1] << 24), wf.crc32(f[4:-4]))

    def test_whoop5_set_clock_is_valid_and_4_aligned(self):
        f = wf.build_whoop5_set_clock(1781264461, seq=2)
        self.assertTrue(wf.verify_whoop5_frame(f))
        self.assertEqual((len(f) - 12) % 4, 0)


class FrameRtcTests(unittest.TestCase):
    # Real frames captured from the WHOOP 4 — the RTC offset differs by type (REALTIME@6, EVENT@8).
    W4_REALTIME = bytes.fromhex("aa1800ff28024bd3e401185c000000000000000000000180839d1322")  # ts@6
    W4_EVENT = bytes.fromhex("aa100057304e2100a6dce401387f000051a29b91")                      # ts@8
    W4_EVENT_SET = bytes.fromhex("aa10005730051000c1f22b6a005800008954aea0")                  # post-SET_CLOCK

    def test_whoop4_realtime_rtc_at_offset_6(self):
        self.assertEqual(wf.frame_rtc(self.W4_REALTIME, "whoop4"), 31773515)

    def test_whoop4_event_rtc_at_offset_8(self):
        # The bug that broke clock verification: events are @8, not @6.
        self.assertEqual(wf.frame_rtc(self.W4_EVENT, "whoop4"), 31775910)

    def test_whoop4_event_reads_real_unix_after_set(self):
        self.assertEqual(wf.frame_rtc(self.W4_EVENT_SET, "whoop4"), 1781265089)  # 2026-06-12

    def test_non_event_frame_returns_none(self):
        # A COMMAND_RESPONSE (type 36) is neither EVENT nor REALTIME.
        self.assertIsNone(wf.frame_rtc(bytes.fromhex("aa010c00010027112439130202010100ece3b768"), "whoop4"))


class CommandResponseTests(unittest.TestCase):
    def test_detects_whoop5_haptic_ack(self):
        # Real captured COMMAND_RESPONSE acknowledging the maverick haptic on a WHOOP 5.
        resp = bytes.fromhex("aa010c00010027112439130202010100ece3b768")
        self.assertEqual(wf.command_response_cmd(resp, "whoop5"), 0x13)

    def test_buzz_frame_is_not_a_command_response(self):
        self.assertIsNone(wf.command_response_cmd(wf.build_whoop5_buzz(2), "whoop5"))

    def test_short_or_nonframe_is_none(self):
        self.assertIsNone(wf.command_response_cmd(b"", "whoop5"))
        self.assertIsNone(wf.command_response_cmd(b"\x00\x01\x02", "whoop4"))


class HRParseTests(unittest.TestCase):
    def test_u8(self):
        self.assertEqual(wf.parse_standard_hr(bytes([0x00, 62])), 62)

    def test_u16(self):
        self.assertEqual(wf.parse_standard_hr(bytes([0x01, 0x2C, 0x01])), 300)

    def test_empty(self):
        self.assertIsNone(wf.parse_standard_hr(b""))


if __name__ == "__main__":
    unittest.main()
