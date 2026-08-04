"""Extract WHOOP BLE frames from a phone's Bluetooth HCI capture → capture.json.

    btsnoop_hci.log / .pklg  →  hci_extract.py  →  capture.json  →  whoop-decode / correlate_ground_truth.py

Issue #103 asks 5/MG owners for an HCI capture of the OFFICIAL app doing a full history sync
(iOS PacketLogger → `.pklg`, or Android Developer Options → Bluetooth HCI snoop log →
`btsnoop_hci.log`). This tool turns such a capture into the same `capture.json` format that
`whoop_capture.py` writes, so the existing decode pipeline (`whoop-decode`, the parity tests,
`correlate_ground_truth.py`) works on official-app traffic unchanged.

Privacy: only ATT value traffic that reassembles into CRC-valid WHOOP frames is emitted — other
devices' traffic, GATT chatter and the phone's own commands to non-WHOOP peripherals never reach
the output. (The input HCI log still contains them; share the JSON, not the log, if in doubt.)

Stdlib-only, like whoop_frame.py. Usage:

    python3 hci_extract.py btsnoop_hci.log --out capture.json
    python3 hci_extract.py sync.pklg --family whoop5 --out capture.json
"""

import argparse
import json
import struct
import sys

import whoop_frame as wf

# --- HCI log container parsing ---------------------------------------------------------------------

# btsnoop timestamps are µs since year 0; this is the µs delta to the unix epoch (Wireshark's value).
BTSNOOP_EPOCH_DELTA_US = 0x00E03AB44A676000

# HCI H4 packet-type bytes (prefixed on datalink 1002; synthesised from flags on 1001).
H4_ACL = 0x02

# PacketLogger per-record type byte.
PKLG_ACL_SENT = 0x02
PKLG_ACL_RECV = 0x03


def parse_btsnoop(data: bytes):
    """Yield (ts_ms, direction, acl_bytes) for every ACL packet in a btsnoop file.

    direction: "tx" = host→controller (the phone app sending), "rx" = controller→host.
    Handles datalink 1001 (raw H1, type inferred from the flags word) and 1002 (H4, type byte
    prefixed). Command/event packets are skipped — frames ride on ACL only.
    """
    if len(data) < 16 or data[:8] != b"btsnoop\x00":
        raise ValueError("not a btsnoop file (bad magic)")
    _version, datalink = struct.unpack(">II", data[8:16])
    if datalink not in (1001, 1002):
        raise ValueError(f"unsupported btsnoop datalink {datalink}")
    off = 16
    while off + 24 <= len(data):
        _orig, incl, flags, _drops, ts = struct.unpack(">IIIIq", data[off:off + 24])
        off += 24
        if off + incl > len(data):
            break                                   # truncated capture — keep what we have
        pkt = data[off:off + incl]
        off += incl
        ts_ms = (ts - BTSNOOP_EPOCH_DELTA_US) // 1000
        direction = "rx" if (flags & 1) else "tx"
        if datalink == 1002:
            if not pkt or pkt[0] != H4_ACL:
                continue                            # command / event / SCO
            yield ts_ms, direction, pkt[1:]
        else:                                       # 1001: flags bit1 set = command-or-event
            if flags & 2:
                continue
            yield ts_ms, direction, pkt


def parse_pklg(data: bytes):
    """Yield (ts_ms, direction, acl_bytes) for every ACL packet in an Apple PacketLogger file.

    Record: [len u32][ts_secs u32][ts_usecs u32][type u8][payload…] where len covers everything
    after itself (8-byte timestamp + 1 type byte + payload). Both the classic big-endian and the
    newer little-endian length variant exist in the wild; sniffed from the first record.
    """
    if len(data) < 13:
        raise ValueError("not a pklg file (too short)")

    def plausible(fmt):
        ln = struct.unpack_from(fmt, data, 0)[0]
        return 9 <= ln <= len(data) - 4

    if plausible(">I"):
        len_fmt = ">I"
    elif plausible("<I"):
        len_fmt = "<I"
    else:
        raise ValueError("not a pklg file (implausible first record length)")

    off = 0
    while off + 13 <= len(data):
        ln = struct.unpack_from(len_fmt, data, off)[0]
        if ln < 9 or off + 4 + ln > len(data):
            break                                   # truncated / corrupt tail
        ts_secs, ts_usecs = struct.unpack_from(">II", data, off + 4)
        ptype = data[off + 12]
        payload = data[off + 13:off + 4 + ln]
        off += 4 + ln
        if ptype not in (PKLG_ACL_SENT, PKLG_ACL_RECV):
            continue                                # commands, events, log strings
        ts_ms = ts_secs * 1000 + ts_usecs // 1000
        yield ts_ms, ("tx" if ptype == PKLG_ACL_SENT else "rx"), payload


def load_hci(path: str):
    """Sniff the container format at `path` and yield (ts_ms, direction, acl_bytes)."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] == b"btsnoop\x00":
        return parse_btsnoop(data)
    return parse_pklg(data)


# --- ACL → L2CAP → ATT ------------------------------------------------------------------------------

ATT_CID = 0x0004
# ATT opcodes carrying a (handle, value) we care about.
ATT_NOTIFY = 0x1B
ATT_INDICATE = 0x1D
ATT_WRITE_REQ = 0x12
ATT_WRITE_CMD = 0x52
# GATT discovery responses — used to map ATT handles back to characteristic UUIDs.
ATT_FIND_INFO_RSP = 0x05
ATT_READ_BY_TYPE_RSP = 0x09


class L2capReassembler:
    """Recombine ACL fragments into complete L2CAP PDUs, per (connection handle, direction).

    The PB flag in the ACL header says whether a fragment starts a new L2CAP PDU (0b00/0b10) or
    continues one (0b01); the L2CAP length field says when the PDU is complete.
    """

    def __init__(self):
        self.pending = {}   # (conn_handle, direction) -> bytearray

    def feed(self, direction: str, acl: bytes):
        """Add one ACL packet; return a list of (conn_handle, cid, l2cap_payload) now complete."""
        if len(acl) < 4:
            return []
        handle_flags, dlen = struct.unpack_from("<HH", acl, 0)
        conn = handle_flags & 0x0FFF
        pb = (handle_flags >> 12) & 0x3
        body = acl[4:4 + dlen]
        key = (conn, direction)
        if pb == 0b01:                              # continuation fragment
            buf = self.pending.get(key)
            if buf is None:
                return []                           # missed the start — drop
            buf.extend(body)
        else:                                       # start of a (possibly fragmented) PDU
            self.pending[key] = bytearray(body)
            buf = self.pending[key]
        if len(buf) < 4:
            return []
        l2len, cid = struct.unpack_from("<HH", buf, 0)
        if len(buf) < 4 + l2len:
            return []                               # more fragments to come
        del self.pending[key]
        return [(conn, cid, bytes(buf[4:4 + l2len]))]


def _uuid128_str(le_bytes: bytes) -> str:
    """128-bit UUID from its little-endian wire form to canonical string."""
    b = le_bytes[::-1]
    h = b.hex()
    return f"{h[0:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}"


def _uuid16_str(v: int) -> str:
    return f"{v:08x}-0000-1000-8000-00805f9b34fb"


class HandleMap:
    """ATT handle → characteristic UUID, learned from GATT discovery responses in the capture.

    A phone that already knows the strap caches GATT, so discovery may be absent — then handles
    stay unmapped and frames are attributed to "handle-0xNNNN" instead. That's fine for decoding;
    the WHOOP channels are still identified by their frames being CRC-valid.
    """

    def __init__(self):
        self.map = {}       # value handle -> uuid string

    def feed_att(self, pdu: bytes):
        op = pdu[0]
        if op == ATT_FIND_INFO_RSP and len(pdu) >= 2:
            fmt = pdu[1]
            step = 4 if fmt == 1 else 18
            for i in range(2, len(pdu) - step + 1, step):
                handle = struct.unpack_from("<H", pdu, i)[0]
                if fmt == 1:
                    self.map.setdefault(handle, _uuid16_str(struct.unpack_from("<H", pdu, i + 2)[0]))
                else:
                    self.map.setdefault(handle, _uuid128_str(pdu[i + 2:i + 18]))
        elif op == ATT_READ_BY_TYPE_RSP and len(pdu) >= 2:
            # Characteristic-declaration entries: [decl handle u16][props u8][value handle u16][uuid],
            # entry length 7 (uuid16) or 21 (uuid128). Other read-by-type shapes just won't match.
            elen = pdu[1]
            if elen not in (7, 21):
                return
            for i in range(2, len(pdu) - elen + 1, elen):
                value_handle = struct.unpack_from("<H", pdu, i + 3)[0]
                if elen == 7:
                    self.map[value_handle] = _uuid16_str(struct.unpack_from("<H", pdu, i + 5)[0])
                else:
                    self.map[value_handle] = _uuid128_str(pdu[i + 5:i + 21])

    def name(self, handle: int) -> str:
        return self.map.get(handle, f"handle-0x{handle:04x}")


# --- Extraction -------------------------------------------------------------------------------------

def extract(packets, family: str):
    """Run the ACL stream through L2CAP/ATT and reassemble WHOOP frames per value handle.

    Returns (records, stats): `records` in the capture.json shape (+ a "dir" key: "rx" frames come
    from the strap, "tx" are the app's writes — the enable sequence / sync commands issue #103 is
    after), `stats` a per-stream {name: {"frames": n, "bytes": n}} summary.
    """
    l2cap = L2capReassembler()
    handles = HandleMap()
    verify = wf.verify_whoop5_frame if family == "whoop5" else wf.verify_whoop4_frame
    streams = {}    # (conn, handle, dir) -> {"ra": Reassembler, "records": [...], "valid": n}
    latest_hr = None
    records = []

    for ts_ms, direction, acl in packets:
        for conn, cid, pdu in l2cap.feed(direction, acl):
            if cid != ATT_CID or not pdu:
                continue
            op = pdu[0]
            if op in (ATT_FIND_INFO_RSP, ATT_READ_BY_TYPE_RSP):
                handles.feed_att(pdu)
                continue
            if op not in (ATT_NOTIFY, ATT_INDICATE, ATT_WRITE_REQ, ATT_WRITE_CMD) or len(pdu) < 3:
                continue
            handle = struct.unpack_from("<H", pdu, 1)[0]
            value = pdu[3:]
            uuid = handles.map.get(handle)
            if uuid is not None and uuid.startswith("00002a37"):
                hr = wf.parse_standard_hr(value)
                if hr is not None:
                    latest_hr = hr
                continue
            key = (conn, handle, direction)
            st = streams.get(key)
            if st is None:
                st = {"ra": wf.Reassembler(family), "records": [], "valid": 0}
                streams[key] = st
            for frame in st["ra"].feed(value):
                st["records"].append({
                    "hex": frame.hex(),
                    "char": handles.name(handle),
                    "ts_ms": ts_ms,
                    "hr": latest_hr,
                    "dir": direction,
                })
                if verify(frame):
                    st["valid"] += 1

    # Privacy / noise gate: keep only streams where at least one frame CRC-verifies as WHOOP —
    # non-WHOOP characteristics that happen to contain 0xAA bytes never make it to the output.
    stats = {}
    for (conn, handle, direction), st in sorted(streams.items()):
        if st["valid"] == 0:
            continue
        name = handles.name(handle)
        records.extend(st["records"])
        s = stats.setdefault(f"{name} [{direction}]", {"frames": 0, "bytes": 0})
        s["frames"] += len(st["records"])
        s["bytes"] += sum(len(r["hex"]) // 2 for r in st["records"])
    records.sort(key=lambda r: r["ts_ms"])
    return records, stats


def main():
    p = argparse.ArgumentParser(
        description="Extract WHOOP frames from an HCI capture (btsnoop / PacketLogger) to capture.json.")
    p.add_argument("input", help="btsnoop_hci.log or .pklg file")
    p.add_argument("--family", choices=["whoop4", "whoop5"], default="whoop5",
                   help="strap generation for framing/CRC rules (default: whoop5)")
    p.add_argument("--out", default="capture.json", help="output JSON (default: capture.json)")
    args = p.parse_args()

    records, stats = extract(load_hci(args.input), args.family)
    with open(args.out, "w") as f:
        json.dump(records, f, indent=1)

    if not records:
        print("no CRC-valid WHOOP frames found — wrong --family, or the capture has no strap traffic",
              file=sys.stderr)
        sys.exit(1)
    print(f"wrote {len(records)} frames → {args.out}")
    for name, s in stats.items():
        print(f"  {name}: {s['frames']} frames, {s['bytes']} bytes")
    inner_off = wf.WHOOP5_INNER_OFF if args.family == "whoop5" else wf.WHOOP4_INNER_OFF
    types = {}
    for r in records:
        b = bytes.fromhex(r["hex"])
        if len(b) > inner_off:
            types[b[inner_off]] = types.get(b[inner_off], 0) + 1
    print("  record types: " + ", ".join(f"{t} ×{n}" for t, n in sorted(types.items())))


if __name__ == "__main__":
    main()
