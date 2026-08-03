#!/usr/bin/env python3
"""whoop_sync.py — WHOOP historical offload over BLE on Linux (BlueZ via bleak), WHOOP 4.0 + 5.0.

Drains a strap's on-device historical store into a DURABLE, DEVICE-SCOPED SQLite store with
persist-before-ack semantics and auto-reconnect, and exports a capture.json that `whoop-decode`
understands. Family-aware via `--model whoop4|whoop5`.

Verified offload sequence (mirrors noop's Strand/BLE/BLEManager.swift on real WHOOP-4 hardware; the
WHOOP-5 transport + ack are verified via whoop_capture.py's --history-ack path):
  1. connect + subscribe the family's notify channels (and standard HR for ground-truth).
  2. (whoop5) write CLIENT_HELLO to open the session; quiet the live realtime flood on both families.
  3. write SEND_HISTORICAL_DATA (cmd 22), payload [0x00], CONFIRMED.
  4. strap streams METADATA(49) HISTORY_START → HISTORICAL_DATA(47) chunks → METADATA HISTORY_END.
     On each HISTORY_END: persist the chunk DURABLY, THEN ACK with HISTORICAL_DATA_RESULT (cmd 23),
     payload [0x01]+end_data, CONFIRMED. The ack lets the strap TRIM (delete) the chunk — committing
     first means a dropped frame is never lost to a trim. Without the ack the strap re-serves the same
     early chunk forever and the type-47 records past it never arrive.
  5. loop until METADATA HISTORY_COMPLETE (meta_type 3), or the offload goes idle.

FAMILY DIFFERENCES (all encapsulated in `Family`):
  - whoop4: 6108 service, CRC8 command framing, inner record @ byte 4, no session hello required.
  - whoop5: fd4b service, puffin/CRC16 framing, inner record @ byte 8, CLIENT_HELLO opens the session.
  WHOOP-4 metadata offsets = whoop5 offsets minus 4: meta_type @ inner+2, trim cursor @ inner+13.

  WHOOP-5 type-47 v18 (the layout this firmware emits) decodes: unix @ 15, heart_rate @ 22 (matches
  whoop-decode's parseFrameWhoop5; cross-validated against a 4C on the same person/window — HR corr
  0.96, ±1 bpm at rest). RR + gravity are decoded by whoop-decode. The optical channels (PPG/SpO₂/
  skin-temp) and a less-common v26 record layout remain unmapped → those stay NULL rather than guessed.

DEVICE SCOPING: every frame/label/cursor is tied to a `devices` row (MAC + name + subject), so multiple
straps — or a partner as a test subject — never mix. Dedup is per-device: UNIQUE(device_id, hex).

DURABILITY: each chunk is committed (WAL, synchronous=FULL → fsync) BEFORE its ack. The strap's trim
cursor (advanced by our acks) means a reconnect resumes where we left off; the cursor is also persisted.

CONNECT: a bonded strap BlueZ auto-connected isn't advertising, so bleak can't find it. We
force-disconnect, scan for the BLE *device object*, and connect to that (skipping bleak's in-connect
re-scan); an outer loop reconnects + resumes on mid-session drops.

READ-ONLY apart from the offload handshake + the HISTORY_END ack (which trims already-served chunks —
WHOOP's own app does the same). Use only on a strap you own.

Usage:
    python3 whoop_sync.py sync   --model whoop4 --address AA:BB:CC:DD:EE:FF --subject me --db captures/whoop.db
    python3 whoop_sync.py sync   --model whoop5 --address 11:22:33:44:55:66 --subject partner
    python3 whoop_sync.py status --db captures/whoop.db [--address ..]
    python3 whoop_sync.py devices --db captures/whoop.db
    python3 whoop_sync.py export --db captures/whoop.db --address .. --out all.json [--only-type 47]
    python3 whoop_sync.py label  --db .. --address .. --activity walking --start 19:58 --end 20:43
"""

import argparse
import asyncio
import datetime
import json
import os
import signal
import sqlite3
import struct
import subprocess
import sys
import time

import whoop_frame as wf
import decode_features

# `bleak` is imported lazily inside the BLE functions (run/_acquire) so this module's frame helpers,
# Family, and WhoopDB can be imported and unit-tested with no third-party deps (like test_whoop_frame).

HR_MEASUREMENT = "00002a37-0000-1000-8000-00805f9b34fb"   # standard HR, works unbonded

# packet types (shared across families; wire byte at the inner-record start)
PACKET_HISTORICAL_DATA = 47
PACKET_METADATA = 49
META_HISTORY_START = 1
META_HISTORY_END = 2
META_HISTORY_COMPLETE = 3
OFFLOAD_TYPES = (47, 48, 49, 50)   # HISTORICAL_DATA / EVENT / METADATA / CONSOLE_LOGS

CMD_SEND_HISTORICAL_DATA = 22
CMD_HISTORICAL_DATA_RESULT = 23
CMD_TOGGLE_REALTIME_HR = 3
CMD_SEND_R10_R11_REALTIME = 63


# whoop4 frame helpers (verify / HISTORY_END parse / ack builder) live in the shared whoop_frame
# module — see Family below. Kept there as the single source of truth so the sync tool and the
# capture/decode tools can't drift on the offsets.

# --- family abstraction ---------------------------------------------------------------------------

class Family:
    """All strap-generation-specific BLE/framing behaviour, selected by model name."""

    def __init__(self, model: str):
        self.model = model
        if model == "whoop4":
            self.service = "61080001-8d6d-82b8-614a-1c8cb0f8dcc6"
            self.cmd_write = "61080002-8d6d-82b8-614a-1c8cb0f8dcc6"
            self.notify = ["61080003-8d6d-82b8-614a-1c8cb0f8dcc6",
                           "61080004-8d6d-82b8-614a-1c8cb0f8dcc6",
                           "61080005-8d6d-82b8-614a-1c8cb0f8dcc6"]
            self.inner_off = 4
            self.opener = None                                  # hello not required to serve on 4.0
            self._cmd = wf.build_command_frame
            self._end_data = wf.history_end_data_whoop4         # shared 4.0 HISTORY_END parse (CRC-verified)
            self._ack = wf.build_history_ack_whoop4             # shared 4.0 ack builder
            self._unix_off = 11                                 # type-47 record unix (mapped)
            self._hr_off = 21                                   # type-47 heart_rate (mapped)
            self._hist_ver = None                               # whoop4 decodes regardless of version
            self._set_clock = wf.build_whoop4_set_clock         # 9-byte SET_CLOCK body (older 4.0 fw)
        elif model == "whoop5":
            self.service = "fd4b0001-cce1-4033-93ce-002d5875f58a"
            self.cmd_write = "fd4b0002-cce1-4033-93ce-002d5875f58a"
            self.notify = ["fd4b0003-cce1-4033-93ce-002d5875f58a",
                           "fd4b0004-cce1-4033-93ce-002d5875f58a",
                           "fd4b0005-cce1-4033-93ce-002d5875f58a",
                           "fd4b0007-cce1-4033-93ce-002d5875f58a"]
            self.inner_off = 8
            self.opener = wf.WHOOP5_CLIENT_HELLO                # confirmed write opens the puffin session
            self._cmd = wf.build_puffin_command
            self._end_data = wf.history_end_data                # whoop5 (trim @ 21:29), CRC16-verified
            self._ack = wf.build_history_ack                    # whoop5 puffin ack
            # whoop5 type-47 v18 (the layout this firmware emits): unix @ 15, heart_rate @ 22 — matches
            # whoop-decode's parseFrameWhoop5 and cross-validated against a 4C worn by the same person in
            # the same window (HR corr 0.96, ±1 bpm at rest). Guarded on hist_version @ 9 == 18 (a v26
            # record also occurs and has a different layout, so it stays NULL rather than mis-decoded).
            self._unix_off = 15
            self._hr_off = 22
            self._hist_ver = (9, 18)
            self._set_clock = wf.build_whoop5_set_clock         # 8-byte puffin SET_CLOCK body
        else:
            raise SystemExit(f"unknown model {model!r} (use whoop4 or whoop5)")

    # frame classification (inner type byte is family-shifted)
    def inner_type(self, frame):
        return frame[self.inner_off] if len(frame) > self.inner_off else None

    def is_offload(self, frame):
        return self.inner_type(frame) in OFFLOAD_TYPES

    def meta_type(self, frame):
        if len(frame) > self.inner_off + 2 and frame[self.inner_off] == PACKET_METADATA:
            return frame[self.inner_off + 2]
        return None

    def _hist_ok(self, frame):
        """True if the historical-record layout version matches what our offsets are mapped for
        (whoop5 → byte 9 must be 18; whoop4 → no version gate)."""
        if self._hist_ver is None:
            return True
        off, ver = self._hist_ver
        return len(frame) > off and frame[off] == ver

    def rec_unix(self, frame):
        if self._unix_off and self.inner_type(frame) == PACKET_HISTORICAL_DATA \
                and len(frame) > self._unix_off + 4 and self._hist_ok(frame):
            return struct.unpack_from("<I", frame, self._unix_off)[0]
        return None

    def rec_hr(self, frame):
        if self._hr_off and self.inner_type(frame) == PACKET_HISTORICAL_DATA \
                and len(frame) > self._hr_off and self._hist_ok(frame):
            return frame[self._hr_off]
        return None

    def history_end_data(self, frame):
        return self._end_data(frame)

    def build_ack(self, end_data, seq):
        return self._ack(end_data, seq=seq & 0xFF)

    def cmd(self, c, seq=0, payload=b"\x00"):
        return self._cmd(c, seq=seq & 0xFF, payload=payload)

    def set_clock(self, now_unix, seq=2):
        return self._set_clock(now_unix, seq=seq & 0xFF)


# --- durable, device-scoped store -----------------------------------------------------------------

SCHEMA = """
CREATE TABLE IF NOT EXISTS devices (
    id INTEGER PRIMARY KEY, address TEXT NOT NULL UNIQUE, name TEXT, subject TEXT,
    model TEXT, created_ms INTEGER);
CREATE TABLE IF NOT EXISTS frames (
    id INTEGER PRIMARY KEY, device_id INTEGER NOT NULL, recv_ms INTEGER NOT NULL, char TEXT,
    inner_type INTEGER, unix INTEGER, hr INTEGER, hex TEXT NOT NULL, UNIQUE(device_id, hex));
CREATE INDEX IF NOT EXISTS idx_frames_dev_unix ON frames(device_id, unix);
CREATE INDEX IF NOT EXISTS idx_frames_dev_type ON frames(device_id, inner_type);
CREATE TABLE IF NOT EXISTS sync_state (device_id INTEGER NOT NULL, k TEXT, v TEXT, PRIMARY KEY(device_id,k));
CREATE TABLE IF NOT EXISTS labels (
    id INTEGER PRIMARY KEY, device_id INTEGER NOT NULL, start_unix INTEGER NOT NULL,
    end_unix INTEGER NOT NULL, activity TEXT NOT NULL, note TEXT, created_ms INTEGER NOT NULL);
"""


class WhoopDB:
    """Durable, device-scoped SQLite store. WAL + synchronous=FULL so a chunk commit fsyncs before
    its ack. All record ops are scoped to a device_id (resolved via upsert_device/resolve_device)."""

    def __init__(self, path):
        os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.executescript(SCHEMA)
        decode_features.apply_schema(self.db)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.commit()

    def upsert_device(self, address, name=None, subject=None, model=None):
        address = address.upper()
        cur = self.db.cursor()
        cur.execute("INSERT INTO devices(address,name,subject,model,created_ms) VALUES(?,?,?,?,?) "
                    "ON CONFLICT(address) DO UPDATE SET "
                    " name=COALESCE(excluded.name,devices.name),"
                    " subject=COALESCE(excluded.subject,devices.subject),"
                    " model=COALESCE(excluded.model,devices.model)",
                    (address, name, subject, model, int(time.time() * 1000)))
        self.db.commit()
        return cur.execute("SELECT id FROM devices WHERE address=?", (address,)).fetchone()[0]

    def resolve_device(self, address=None):
        if address:
            r = self.db.execute("SELECT id FROM devices WHERE address=?", (address.upper(),)).fetchone()
            return r[0] if r else None
        rows = self.db.execute("SELECT id FROM devices").fetchall()
        return rows[0][0] if len(rows) == 1 else None

    def device_info(self, did):
        return self.db.execute("SELECT address,name,subject,model FROM devices WHERE id=?", (did,)).fetchone()

    def list_devices(self):
        return self.db.execute(
            "SELECT d.id,d.address,d.name,d.subject,d.model,"
            " (SELECT COUNT(*) FROM frames f WHERE f.device_id=d.id AND f.inner_type=47),"
            " (SELECT MIN(unix) FROM frames f WHERE f.device_id=d.id),"
            " (SELECT MAX(unix) FROM frames f WHERE f.device_id=d.id) "
            "FROM devices d ORDER BY d.id").fetchall()

    def commit_chunk(self, did, frames, trim, complete):
        cur = self.db.cursor()
        if frames:
            cur.executemany("INSERT OR IGNORE INTO frames(device_id,recv_ms,char,inner_type,unix,hr,hex) "
                            "VALUES(?,?,?,?,?,?,?)", [(did, *f) for f in frames])
        sets = {"updated_ms": str(int(time.time() * 1000))}
        if trim is not None:
            sets["last_trim"] = str(trim)
        if complete:
            sets["history_complete"] = "1"
        row = cur.execute("SELECT MIN(unix),MAX(unix) FROM frames WHERE device_id=? AND unix IS NOT NULL",
                          (did,)).fetchone()
        if row and row[0] is not None:
            sets["min_unix"], sets["max_unix"] = str(row[0]), str(row[1])
        for k, v in sets.items():
            cur.execute("INSERT INTO sync_state(device_id,k,v) VALUES(?,?,?) "
                        "ON CONFLICT(device_id,k) DO UPDATE SET v=excluded.v", (did, k, v))
        self.db.commit()

    def state(self, did):
        return dict(self.db.execute("SELECT k,v FROM sync_state WHERE device_id=?", (did,)).fetchall())

    def counts(self, did):
        return dict(self.db.execute("SELECT inner_type,COUNT(*) FROM frames WHERE device_id=? "
                                    "GROUP BY inner_type ORDER BY COUNT(*) DESC", (did,)).fetchall())

    def coverage(self, did):
        return self.db.execute("SELECT MIN(unix),MAX(unix),COUNT(*) FROM frames "
                               "WHERE device_id=? AND unix IS NOT NULL", (did,)).fetchone()

    def export_json(self, did, out_path, only_type=None, since=None):
        import json
        q, args = "SELECT hex,char,recv_ms,hr FROM frames WHERE device_id=?", [did]
        if only_type is not None:
            q += " AND inner_type=?"; args.append(only_type)
        if since is not None:
            q += " AND (unix IS NULL OR unix>=?)"; args.append(since)
        q += " ORDER BY COALESCE(unix,recv_ms),id"
        rows = self.db.execute(q, args).fetchall()
        recs = [{"hex": h, "char": c, "ts_ms": (rm or 0), "hr": hr} for h, c, rm, hr in rows]
        os.makedirs(os.path.dirname(os.path.abspath(out_path)) or ".", exist_ok=True)
        tmp = out_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(recs, f, indent=1)
        os.replace(tmp, out_path)
        return len(recs)

    def frames_after(self, did, after_id):
        """Raw frames with id greater than `after_id`, in id order — the decode cursor read."""
        return self.db.execute(
            "SELECT id,hex,char,recv_ms,unix,hr,inner_type FROM frames "
            "WHERE device_id=? AND id>? ORDER BY id", (did, after_id)).fetchall()

    def set_state(self, did, k, v):
        """Upsert a per-device sync_state key (used to persist the decode cursor)."""
        self.db.execute("INSERT INTO sync_state(device_id,k,v) VALUES(?,?,?) "
                        "ON CONFLICT(device_id,k) DO UPDATE SET v=excluded.v", (did, k, str(v)))
        self.db.commit()

    def add_label(self, did, start_unix, end_unix, activity, note):
        self.db.execute("INSERT INTO labels(device_id,start_unix,end_unix,activity,note,created_ms) "
                        "VALUES(?,?,?,?,?,?)", (did, start_unix, end_unix, activity, note, int(time.time() * 1000)))
        self.db.commit()

    def labels(self, did):
        return self.db.execute("SELECT start_unix,end_unix,activity,note FROM labels "
                               "WHERE device_id=? ORDER BY start_unix", (did,)).fetchall()


# --- sync session ---------------------------------------------------------------------------------

class Sync:
    def __init__(self, db, did, fam):
        self.db, self.device_id, self.fam = db, did, fam
        self.latest_hr = None
        self.emit = None            # optional live frame stream-out (set in run() for --emit-frames)
        self.reassemblers = {}
        self.chunk = []
        self.commit_q = asyncio.Queue()
        self._last_end = None
        self._last_ack_ms = 0
        self.ack_retry_s = 2.0
        self.type47_count = self.history_start = self.history_end = self.history_complete = 0
        self.committed = 0
        self.last_frame_ms = self.last_offload_ms = 0
        # progress: anchor = newest record already stored before this run (set in run()); records
        # stream oldest→newest, so (last_rec_unix - anchor) / (now - anchor) is the backlog fraction.
        self.sync_start_unix = None
        self.last_rec_unix = 0
        self.type_counts = {}     # inner_type -> count seen this run (for the realtime progress line)

    def on_hr(self, _s, data):
        hr = wf.parse_standard_hr(bytes(data))
        if hr is not None:
            self.latest_hr = hr

    def on_frame_notify(self, sender, data):
        char = str(getattr(sender, "uuid", sender)).lower()
        ra = self.reassemblers.setdefault(char, wf.Reassembler(self.fam.model))
        now = int(time.time() * 1000)
        for frame in ra.feed(bytes(data)):
            self.last_frame_ms = now
            t = self.fam.inner_type(frame)
            if t is None:
                continue
            self.type_counts[t] = self.type_counts.get(t, 0) + 1
            ru = self.fam.rec_unix(frame)
            self.chunk.append((now, char, t, ru, self.fam.rec_hr(frame), frame.hex()))
            if self.fam.is_offload(frame):
                self.last_offload_ms = now
            if t == PACKET_HISTORICAL_DATA:
                self.type47_count += 1
                if ru:
                    self.last_rec_unix = ru
                    if self.sync_start_unix is None:   # empty device: anchor on the first record
                        self.sync_start_unix = ru
            elif t == PACKET_METADATA:
                mt = self.fam.meta_type(frame)
                if mt == META_HISTORY_START:
                    self.history_start += 1
                elif mt == META_HISTORY_END:
                    self.history_end += 1
                    self._queue_chunk(frame)
                elif mt == META_HISTORY_COMPLETE:
                    self.history_complete += 1
                    frames, self.chunk = self.chunk, []
                    self.commit_q.put_nowait((None, frames, True))

    def _queue_chunk(self, end_frame):
        end_data = self.fam.history_end_data(end_frame)
        if end_data is None:
            return
        now_ms = int(time.time() * 1000)
        if end_data == self._last_end and (now_ms - self._last_ack_ms) < self.ack_retry_s * 1000:
            return
        self._last_end, self._last_ack_ms = end_data, now_ms
        frames, self.chunk = self.chunk, []
        self.commit_q.put_nowait((end_data, frames, False))


async def _acquire(address, tries=6):
    """Return a BLEDevice for `address`, forcing it to advertise first. Connecting to the device
    OBJECT (not the address string) skips bleak's fragile in-connect re-scan."""
    from bleak import BleakScanner
    for i in range(tries):
        await asyncio.to_thread(subprocess.run, ["bluetoothctl", "disconnect", address], capture_output=True)
        dev = await BleakScanner.find_device_by_address(address, timeout=12.0)
        if dev:
            return dev
        print(f"  acquire: {address} not advertising (try {i + 1}/{tries})", flush=True)
    return None


async def preflight_clock(fam, args):
    """Before syncing, read the strap RTC and set it to now if it has drifted past
    `args.clock_threshold` seconds — mirrors the app's ClockPolicy (only write on real drift, so we
    don't gratuitously reset). A strap left offline for months loses its clock, which would otherwise
    mis-date every captured/recorded frame.

    Self-contained: its own short connection that reads the clock and (if needed) sets it, so it never
    perturbs the verified offload/realtime session. Best-effort — any failure is logged and the sync
    proceeds anyway. Skip entirely with `--no-clock-check`."""
    from bleak import BleakClient
    from bleak.exc import BleakError

    dev = await _acquire(args.address, tries=3)
    if dev is None:
        print("  clock-check: strap not advertising — skipping (the sync will acquire it next).", flush=True)
        return
    rtcs = []

    def on_n(_c, d):
        r = wf.frame_rtc(bytes(d), fam.model)
        if r is not None:
            rtcs.append(r)

    async def wait_rtc(window):
        rtcs.clear()
        waited = 0.0
        while waited < window and not rtcs:
            await asyncio.sleep(0.5)
            waited += 0.5
        return rtcs[-1] if rtcs else None

    try:
        async with BleakClient(dev) as client:
            for u in fam.notify:
                try:
                    await client.start_notify(u, on_n)
                except Exception:
                    pass
            if fam.opener is not None:
                await client.write_gatt_char(fam.cmd_write, fam.opener, response=True)
                await asyncio.sleep(0.5)
            # Enable the stream so timestamped EVENT/REALTIME frames flow (the clock read-back).
            for c, sq in ((CMD_SEND_R10_R11_REALTIME, 3), (CMD_TOGGLE_REALTIME_HR, 4)):
                try:
                    await client.write_gatt_char(fam.cmd_write, fam.cmd(c, seq=sq, payload=b"\x01"))
                except Exception:
                    pass

            rtc = await wait_rtc(10.0)
            if rtc is None:
                print("  clock-check: no timestamped frames to read — skipping.", flush=True)
                return
            drift = int(time.time()) - rtc
            print(f"  clock-check: strap RTC {rtc} ({_fmt(rtc)}), drift {drift:+d}s "
                  f"(threshold {args.clock_threshold}s)", flush=True)
            if abs(drift) <= args.clock_threshold:
                print("  clock-check: within threshold — OK.", flush=True)
                return

            now = int(time.time())
            await client.write_gatt_char(fam.cmd_write, fam.set_clock(now, seq=5), response=True)
            after = await wait_rtc(8.0)
            if after is not None and abs(int(time.time()) - after) <= max(5, args.clock_threshold):
                print(f"  clock-check: SET_CLOCK ok — strap now {after} ({_fmt(after)}).", flush=True)
            else:
                print("  clock-check: SET_CLOCK written but not confirmed (continuing anyway).", flush=True)
    except (BleakError, asyncio.TimeoutError, OSError, EOFError) as e:
        print(f"  clock-check: error ({e}) — continuing without it.", flush=True)


async def _session(client, s, db, fam, args, stop_all):
    """One connected offload session. Returns (outcome, frames_committed_this_session)."""
    try:
        await client.start_notify(HR_MEASUREMENT, s.on_hr)
    except Exception:
        pass
    for u in fam.notify:
        try:
            await client.start_notify(u, s.on_frame_notify)
        except Exception as e:
            print(f"  could not subscribe {u}: {e}", flush=True)

    async def w(frame, response=False, name=""):
        try:
            await client.write_gatt_char(fam.cmd_write, frame, response=response)
        except Exception as e:
            print(f"  write {name} failed: {e}", flush=True)

    if fam.opener is not None:                       # whoop5: CLIENT_HELLO opens the session
        await w(fam.opener, response=True, name="CLIENT_HELLO")
        await asyncio.sleep(0.8)
    await w(fam.cmd(CMD_TOGGLE_REALTIME_HR, seq=1, payload=b"\x00"), name="TOGGLE_REALTIME_HR(off)")
    await w(fam.cmd(CMD_SEND_R10_R11_REALTIME, seq=2, payload=b"\x00"), name="SEND_R10_R11_REALTIME(off)")
    await asyncio.sleep(1.0)
    await w(fam.cmd(CMD_SEND_HISTORICAL_DATA, seq=3, payload=b"\x00"), response=True, name="SEND_HISTORICAL_DATA")
    s.last_offload_ms = int(time.time() * 1000)

    outcome = {"v": "dropped"}
    sess_stop = asyncio.Event()
    start = s.committed

    async def committer():
        seq = 50
        while not sess_stop.is_set():
            try:
                end_data, frames, complete = await asyncio.wait_for(s.commit_q.get(), timeout=0.5)
            except asyncio.TimeoutError:
                continue
            trim = int.from_bytes(end_data[0:4], "little") if end_data else None
            try:
                await asyncio.to_thread(db.commit_chunk, s.device_id, frames, trim, complete)
                s.committed += len(frames)
            except Exception as e:
                print(f"  commit failed (NOT acking): {e}", flush=True)
                continue
            # persist-before-emit: only stream frames AFTER they are durably committed (mirrors
            # persist-before-ack). Consumers (e.g. a cloud-upload tool) receive the live frame feed
            # without this module taking on any upload/network dependency.
            if s.emit is not None:
                try:
                    for f in frames:                 # (recv_ms, char, inner_type, unix, hr, hex)
                        s.emit.write(json.dumps({"recv_ms": f[0], "char": f[1], "inner_type": f[2],
                                                 "unix": f[3], "hr": f[4], "hex": f[5]}) + "\n")
                    s.emit.flush()
                except Exception as e:
                    print(f"  emit-frames write failed (data persisted): {e}", flush=True)
            if end_data is not None:
                try:
                    await client.write_gatt_char(fam.cmd_write, fam.build_ack(end_data, seq), response=True)
                    # progress is shown by the reporter() task; only the COMPLETE ack gets a line
                    # so the log marks the end of stream even on a non-TTY (piped/tee) run.
                    if complete:
                        print(f"\r\x1b[K  ✓ COMPLETE — committed+ACK final chunk "
                              f"(type47={s.type47_count} END={s.history_end} stored={s.committed})", flush=True)
                except Exception as e:
                    print(f"\r\x1b[K  ack failed (data persisted; will re-ack on resend): {e}", flush=True)
                seq += 1

    async def stall_kicker():
        seq = 100
        while not sess_stop.is_set():
            await asyncio.sleep(2.0)
            if s.history_complete:
                continue
            if s.last_offload_ms and (int(time.time() * 1000) - s.last_offload_ms) > args.stall * 1000:
                await w(fam.cmd(CMD_SEND_HISTORICAL_DATA, seq=seq, payload=b"\x00"), response=True, name="re-kick")
                print(f"  re-kick SEND_HISTORICAL_DATA (stalled {args.stall}s)", flush=True)
                s.last_offload_ms = int(time.time() * 1000)
                seq += 1

    async def watchdog():
        while not sess_stop.is_set():
            await asyncio.sleep(1.0)
            if not client.is_connected:
                outcome["v"] = "dropped"; sess_stop.set(); return
            if s.history_complete and s.commit_q.empty():
                await asyncio.sleep(1.5); outcome["v"] = "complete"; sess_stop.set(); return
            if s.last_offload_ms and (int(time.time() * 1000) - s.last_offload_ms) > args.idle * 1000:
                outcome["v"] = "idle"; sess_stop.set(); return
            if stop_all.is_set():
                outcome["v"] = "idle"; sess_stop.set(); return

    async def reporter():
        """Throttled progress: one line with backlog %, current record time, rate and ETA.
        Updates in place on a TTY; emits a periodic line when piped (tee/background)."""
        is_tty = sys.stdout.isatty()
        interval = 2.0 if is_tty else 5.0
        prev_t, prev_count, prev_rec, rate = time.time(), s.type47_count, s.last_rec_unix, 0.0
        while not sess_stop.is_set():
            await asyncio.sleep(interval)
            now = time.time()
            dt = max(1e-3, now - prev_t)
            rate = 0.6 * ((s.type47_count - prev_count) / dt) + 0.4 * rate   # EMA, records/s
            # data-seconds advanced per wall-second; needs a real prior record, else the cold-start
            # baseline (prev_rec=0) makes cover astronomical and ETA collapse to 0 on the first tick.
            cover = (s.last_rec_unix - prev_rec) / dt if prev_rec else 0.0
            prev_t, prev_count, prev_rec = now, s.type47_count, s.last_rec_unix
            line = _progress_line(s, int(now), rate, cover, args.model)
            if is_tty:
                sys.stdout.write("\r\x1b[K" + line); sys.stdout.flush()
            else:
                print(line, flush=True)

    tasks = [asyncio.create_task(t()) for t in (committer, stall_kicker, watchdog, reporter)]
    await sess_stop.wait()
    for t in tasks:
        t.cancel()
    if sys.stdout.isatty():
        sys.stdout.write("\n"); sys.stdout.flush()   # leave the in-place progress line intact
    await asyncio.sleep(0.2)
    if s.chunk:
        try:
            await asyncio.to_thread(db.commit_chunk, s.device_id, s.chunk, None, False)
            s.committed += len(s.chunk); s.chunk = []
        except Exception:
            pass
    return outcome["v"], s.committed - start


# --- realtime capture session ---------------------------------------------------------------------

async def _realtime_session(client, s, db, fam, args, stop_all, deadline):
    """One connected REALTIME session: enable the live streams (type-40 REALTIME_DATA = HR + R-R,
    type-43 raw IMU), persist every frame continuously, and hold the link open with a keep-alive
    re-arm. Returns (outcome, frames_committed_this_session).

    Why the keep-alive: a one-shot realtime enable makes the 4C stream a short burst then go quiet,
    after which the idle BLE link hits supervision timeout and drops (observed on a real 4C).
    Periodically re-issuing SEND_R10_R11_REALTIME + TOGGLE_REALTIME_HR both keeps the stream flowing
    and keeps the link warm."""
    try:
        await client.start_notify(HR_MEASUREMENT, s.on_hr)         # 2A37 — the app keeps this up too
    except Exception:
        pass
    for u in fam.notify:
        try:
            await client.start_notify(u, s.on_frame_notify)
        except Exception as e:
            print(f"  could not subscribe {u}: {e}", flush=True)

    async def w(frame, response=False, name=""):
        try:
            await client.write_gatt_char(fam.cmd_write, frame, response=response)
        except Exception as e:
            print(f"  write {name} failed: {e}", flush=True)

    if fam.opener is not None:                                     # whoop5: CLIENT_HELLO opens puffin
        await w(fam.opener, response=True, name="CLIENT_HELLO")
        await asyncio.sleep(0.8)

    async def arm(seq):
        await w(fam.cmd(CMD_SEND_R10_R11_REALTIME, seq=seq, payload=b"\x01"), name="R10_R11_REALTIME(on)")
        await w(fam.cmd(CMD_TOGGLE_REALTIME_HR, seq=seq + 1, payload=b"\x01"), name="TOGGLE_REALTIME_HR(on)")
    await arm(1)

    outcome = {"v": "dropped"}
    sess_stop = asyncio.Event()
    start = s.committed

    async def committer():
        while not sess_stop.is_set():
            await asyncio.sleep(args.flush)
            if s.chunk:
                frames, s.chunk = s.chunk, []
                try:
                    await asyncio.to_thread(db.commit_chunk, s.device_id, frames, None, False)
                    s.committed += len(frames)
                except Exception as e:
                    print(f"  commit failed: {e}", flush=True)

    async def keepalive():
        seq = 10
        while not sess_stop.is_set():
            await asyncio.sleep(args.keepalive)
            if sess_stop.is_set() or not client.is_connected:
                continue
            await arm(seq)
            seq = (seq + 2) & 0xFF

    async def watchdog():
        last_report = 0
        while not sess_stop.is_set():
            await asyncio.sleep(1.0)
            if not client.is_connected:
                outcome["v"] = "dropped"; sess_stop.set(); return
            if stop_all.is_set():
                outcome["v"] = "stopped"; sess_stop.set(); return
            if time.time() >= deadline:                # enforce --duration even on a never-dropping link
                outcome["v"] = "done"; sess_stop.set(); return
            now = int(time.time() * 1000)
            if now - last_report >= 5000:
                last_report = now
                c = s.type_counts
                print(f"  …live: type40(R-R)={c.get(40, 0)} type43(IMU)={c.get(43, 0)} "
                      f"stored={s.committed + len(s.chunk)} hr={s.latest_hr}", flush=True)

    tasks = [asyncio.create_task(t()) for t in (committer, keepalive, watchdog)]
    await sess_stop.wait()
    for t in tasks:
        t.cancel()
    await asyncio.sleep(0.2)
    if s.chunk:                                                    # final flush of the tail
        try:
            await asyncio.to_thread(db.commit_chunk, s.device_id, s.chunk, None, False)
            s.committed += len(s.chunk); s.chunk = []
        except Exception:
            pass
    return outcome["v"], s.committed - start


async def run_realtime(args):
    """Capture the live realtime stream (HR + R-R + IMU) into the durable store, reconnecting on drops
    until --duration elapses, then decode → feat_rr so HRV/RSA can run. The realtime counterpart of the
    offload `run()`; reuses the same _acquire + MTU-negotiated reconnect loop + WhoopDB."""
    from bleak import BleakClient
    from bleak.exc import BleakError
    fam = Family(args.model)
    db = WhoopDB(args.db)
    if not args.no_clock_check:
        await preflight_clock(fam, args)
    dev = await _acquire(args.address, tries=args.tries)
    if dev is None:
        print("could not find the strap advertising — wear/tap it (phone BT OFF) and retry.", flush=True)
        return
    did = db.upsert_device(args.address, name=dev.name, subject=args.subject, model=args.model)
    info = db.device_info(did)
    print(f"realtime: {info[0]} name={info[1]!r} subject={info[2]!r} model={info[3]} — "
          f"capturing {args.duration:.0f}s", flush=True)
    print("  NOTE: R-R (type-40) only streams from a WORN strap once the optical sensor locks a pulse "
          "(~30-60s of good skin contact); type-43 IMU streams regardless.", flush=True)

    s = Sync(db, did, fam)
    stop_all = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, stop_all.set)
        except NotImplementedError:
            pass

    deadline = time.time() + args.duration
    while not stop_all.is_set() and time.time() < deadline:
        if dev is None:
            dev = await _acquire(args.address, tries=args.tries)
            if dev is None:
                print("  strap not advertising — retrying…", flush=True)
                await asyncio.sleep(2.0)
                continue
        try:
            async with BleakClient(dev) as client:
                try:
                    if getattr(client, "mtu_size", 23) <= 23 and hasattr(client._backend, "_acquire_mtu"):
                        await client._backend._acquire_mtu()
                except Exception:
                    pass
                print(f"connected: {client.is_connected}  ATT MTU={getattr(client, 'mtu_size', '?')}", flush=True)
                outcome, got = await _realtime_session(client, s, db, fam, args, stop_all, deadline)
                print(f"  session ended: {outcome} (+{got} frames; {s.committed} total this run)", flush=True)
        except (BleakError, asyncio.TimeoutError, EOFError) as e:
            print(f"  connect/session error: {e} — reconnecting", flush=True)
        dev = None
        if not stop_all.is_set() and time.time() < deadline:
            await asyncio.sleep(1.0)

    cnts = db.counts(did)
    print(f"\nrealtime done: {s.committed} frames stored  db={args.db}  device={info[0]} ({args.model})", flush=True)
    print(f"  by type: {cnts}  (40=REALTIME_DATA w/ R-R, 43=raw IMU)", flush=True)
    if args.out:
        print(f"  exported {db.export_json(did, args.out)} frames → {args.out}", flush=True)
    try:
        res = decode_features.decode_new(db, did)
        rr = db.db.execute("SELECT COUNT(*) FROM feat_rr WHERE device_id=?", (did,)).fetchone()[0]
        print(f"  decoded: {res['decoded']} new frames into feat_* ({res['frames']} seen); "
              f"feat_rr now holds {rr} R-R intervals.", flush=True)
        print(f"  → per-second values are in feat_second / feat_rr (db={args.db}, device {did}) — "
              f"ready for HRV (RMSSD) analysis.", flush=True)
    except Exception as e:
        print(f"  decode skipped ({e}); run `whoop_sync.py decode --db {args.db}`.", flush=True)


async def run(args):
    from bleak import BleakClient
    from bleak.exc import BleakError
    fam = Family(args.model)
    db = WhoopDB(args.db)
    if not args.no_clock_check:
        await preflight_clock(fam, args)
    dev = await _acquire(args.address, tries=args.tries)
    if dev is None:
        print("could not find the strap advertising — nudge it (move it / off charger) and retry.", flush=True)
        return
    did = db.upsert_device(args.address, name=dev.name, subject=args.subject, model=args.model)
    info = db.device_info(did)
    cov = db.coverage(did)
    print(f"device: {info[0]} name={info[1]!r} subject={info[2]!r} model={info[3]}  "
          f"stored {cov[2] or 0} type-47, coverage {_fmt(cov[0])}→{_fmt(cov[1])}", flush=True)
    if args.model == "whoop5":
        print("  NOTE: whoop5 type-47 v18 decodes unix+HR (+RR/gravity via whoop-decode); the v26 "
              "layout + optical channels stay raw (NULL).", flush=True)

    s = Sync(db, did, fam)
    s.sync_start_unix = cov[1] or cov[0]   # newest stored record = where this run resumes from
    # Optional live frame stream-out. `-` = stdout (human logs then move to stderr so the stream is
    # clean for `whoop_sync … --emit-frames - | consumer`); a path = that file or FIFO (logs stay on
    # stdout). The consumer that uploads to the cloud lives in a separate project; this stays generic.
    emit_target = getattr(args, "emit_frames", None)
    if emit_target == "-":
        s.emit = sys.stdout
        sys.stdout = sys.stderr               # subsequent print() diagnostics → stderr
    elif emit_target:
        s.emit = open(emit_target, "w")
    if s.emit is not None:
        s.emit.write(json.dumps({"_header": {"device_id": did, "address": info[0],
                                             "name": info[1], "model": args.model}}) + "\n")
        s.emit.flush()
        print(f"  emit-frames: streaming persisted frames as JSONL → "
              f"{'stdout' if emit_target == '-' else emit_target}", flush=True)
    stop_all = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, stop_all.set)
        except NotImplementedError:
            pass

    deadline = time.time() + args.max
    dry = 0
    while not stop_all.is_set() and time.time() < deadline and not s.history_complete:
        if dev is None:
            dev = await _acquire(args.address, tries=args.tries)
            if dev is None:
                print("  lost the strap (not advertising) — stopping; resume later, cursor is saved.", flush=True)
                break
        got = 0
        try:
            async with BleakClient(dev) as client:
                # bleak's BlueZ backend does NOT auto-negotiate the ATT MTU (defaults to 23 → a
                # 104-byte type-47 frame becomes 6 notification packets). Negotiate it up so each
                # frame is one packet — the single biggest offload-throughput lever on Linux.
                try:
                    if getattr(client, "mtu_size", 23) <= 23 and hasattr(client._backend, "_acquire_mtu"):
                        await client._backend._acquire_mtu()
                except Exception as e:
                    print(f"  MTU negotiate failed: {e}", flush=True)
                mtu = getattr(client, "mtu_size", "?")
                print(f"connected: {client.is_connected}  ATT MTU={mtu} "
                      f"({'1 packet/frame' if isinstance(mtu, int) and mtu >= 110 else 'small → multi-packet frames'})",
                      flush=True)
                outcome, got = await _session(client, s, db, fam, args, stop_all)
                print(f"  session ended: {outcome} (+{got} frames this session)", flush=True)
        except (BleakError, asyncio.TimeoutError, EOFError) as e:
            print(f"  connect/session error: {e} — reconnecting", flush=True)
        dev = None
        if s.history_complete:
            break
        dry = dry + 1 if got == 0 else 0
        if dry >= 2:
            print("  two dry reconnects — store likely drained or strap asleep; stopping.", flush=True)
            break
        await asyncio.sleep(1.0)

    cov = db.coverage(did)
    print(f"\nstored this run: {s.committed} frames   db={args.db}  device={info[0]} ({args.model})", flush=True)
    print(f"  coverage: {_fmt(cov[0])} → {_fmt(cov[1])}  ({cov[2] or 0} type-47)", flush=True)
    print(f"  HISTORY_START={s.history_start} END={s.history_end} COMPLETE={s.history_complete}", flush=True)
    print(f"  drained to completion: {'yes' if s.history_complete else 'no (resume to continue)'}", flush=True)
    if args.out:
        print(f"  exported {db.export_json(did, args.out)} frames → {args.out}", flush=True)
    try:
        res = decode_features.decode_new(db, did)
        print(f"  decoded features: {res['frames']} new frames "
              f"({res['decoded']} into feat_*, {res['skipped']} skipped)", flush=True)
    except Exception as e:
        print(f"  decode stage skipped ({e}); raw frames are safe — "
              f"re-run `whoop_sync.py decode --db {args.db}`.", flush=True)


def _fmt(u):
    return datetime.datetime.fromtimestamp(int(u)).strftime("%m-%d %H:%M:%S") if u else "?"


def _fmt_eta(secs):
    if secs is None:
        return "—"
    secs = int(max(0, secs))
    if secs >= 3600:
        return f"{secs // 3600}h{(secs % 3600) // 60:02d}m"
    if secs >= 60:
        return f"{secs // 60}m{secs % 60:02d}s"
    return f"{secs}s"


def _bar(pct, n=10):
    filled = int(round(pct / 100 * n))
    return "▕" + "█" * filled + "░" * (n - filled) + "▏"


def _progress_line(s, now_unix, rate, cover, model):
    """Backlog % by record-time + current record clock + record rate + ETA. `cover` is how fast the
    record clock advances (data-seconds per wall-second); ETA = remaining data-seconds / cover, which
    naturally accounts for off-wrist gaps in the stream."""
    label = "5" if model == "whoop5" else "4C"
    anchor = s.sync_start_unix
    if not s.last_rec_unix or not anchor:
        return f"  sync {label}: handshaking… (stored {s.committed:,})"
    total = max(1, now_unix - anchor)
    done = max(0, min(total, s.last_rec_unix - anchor))
    pct = 100.0 if s.history_complete else done / total * 100
    remaining_data = max(0, now_unix - s.last_rec_unix)
    eta = _fmt_eta(remaining_data / cover) if cover > 0.05 and not s.history_complete else (
        "done" if s.history_complete else "—")
    return (f"  sync {label} {pct:4.0f}% {_bar(pct)} @{_fmt(s.last_rec_unix)}  "
            f"{rate:4.1f} rec/s  ETA {eta}  stored {s.committed:,}")


def _parse_time(s):
    s = str(s).strip()
    if s.isdigit():
        return int(s)
    try:
        return int(datetime.datetime.fromisoformat(s).timestamp())
    except ValueError:
        pass
    try:
        hh, mm = s.split(":")
        t = datetime.date.today()
        return int(datetime.datetime(t.year, t.month, t.day, int(hh), int(mm)).timestamp())
    except Exception:
        raise SystemExit(f"unparseable time: {s!r} (use epoch, ISO8601, or HH:MM)")


def _need_device(db, address):
    did = db.resolve_device(address)
    if did is None:
        raise SystemExit("specify --address (multiple or no devices in db); see `devices`")
    return did


def main():
    p = argparse.ArgumentParser(description="WHOOP 4.0/5.0 durable, device-scoped historical offload.")
    sub = p.add_subparsers(dest="cmd")

    sp = sub.add_parser("sync")
    sp.add_argument("--model", choices=["whoop4", "whoop5"], default="whoop4")
    sp.add_argument("--address", required=True, help="strap BLE MAC (from `bluetoothctl devices`)")
    sp.add_argument("--subject", default=None, help="person wearing this strap (e.g. me, partner)")
    sp.add_argument("--db", default="captures/whoop.db")
    sp.add_argument("--out", help="export this device's whole store to capture.json after the run")
    sp.add_argument("--idle", type=float, default=90.0)
    sp.add_argument("--stall", type=float, default=15.0)
    sp.add_argument("--max", type=float, default=3000.0)
    sp.add_argument("--tries", type=int, default=6)
    sp.add_argument("--emit-frames", default=None, metavar="PATH",
                    help="stream each PERSISTED frame as JSONL to PATH (a file or FIFO), or '-' for "
                         "stdout (diagnostics then go to stderr). Lets a separate consumer receive "
                         "the live frame feed; this tool stays upload-agnostic.")
    sp.add_argument("--clock-threshold", type=int, default=30, metavar="SECONDS",
                    help="set the strap clock first if it has drifted more than this (default 30)")
    sp.add_argument("--no-clock-check", action="store_true",
                    help="skip the pre-sync clock check (see whoop_setclock.py)")

    rp = sub.add_parser("realtime", help="capture the live HR + R-R + IMU stream into the store")
    rp.add_argument("--model", choices=["whoop4", "whoop5"], default="whoop4")
    rp.add_argument("--address", required=True, help="strap BLE MAC (from `bluetoothctl devices`)")
    rp.add_argument("--subject", default=None, help="person wearing this strap (e.g. me, partner)")
    rp.add_argument("--db", default="captures/whoop.db")
    rp.add_argument("--duration", type=float, default=300.0, help="capture seconds (overnight = e.g. 36000)")
    rp.add_argument("--keepalive", type=float, default=2.0,
                    help="re-arm the realtime stream every N s (holds the link open; lower if it drops)")
    rp.add_argument("--flush", type=float, default=2.0, help="persist buffered frames to the DB every N s")
    rp.add_argument("--tries", type=int, default=8, help="acquire/advertise retries per (re)connect")
    rp.add_argument("--out", default=None, help="also export this device's whole store to capture.json")
    rp.add_argument("--clock-threshold", type=int, default=30, metavar="SECONDS",
                    help="set the strap clock first if it has drifted more than this (default 30)")
    rp.add_argument("--no-clock-check", action="store_true",
                    help="skip the pre-capture clock check (see whoop_setclock.py)")

    ep = sub.add_parser("export")
    ep.add_argument("--db", default="captures/whoop.db")
    ep.add_argument("--address", default=None)
    ep.add_argument("--out", required=True)
    ep.add_argument("--only-type", type=int, default=None)
    ep.add_argument("--since", default=None)

    stp = sub.add_parser("status")
    stp.add_argument("--db", default="captures/whoop.db")
    stp.add_argument("--address", default=None)

    sub.add_parser("devices").add_argument("--db", default="captures/whoop.db")

    lp = sub.add_parser("label")
    lp.add_argument("--db", default="captures/whoop.db")
    lp.add_argument("--address", default=None)
    lp.add_argument("--activity", required=True)
    lp.add_argument("--start", required=True)
    lp.add_argument("--end", required=True)
    lp.add_argument("--note", default=None)

    dp = sub.add_parser("decode")
    dp.add_argument("--db", default="captures/whoop.db")
    dp.add_argument("--address", default=None)
    dp.add_argument("--full", action="store_true",
                    help="re-decode ALL frames (reset the cursor) instead of only new ones")

    args = p.parse_args()
    cmd = args.cmd or "sync"

    if cmd == "sync":
        try:
            asyncio.run(run(args))
        except KeyboardInterrupt:
            pass
    elif cmd == "realtime":
        try:
            asyncio.run(run_realtime(args))
        except KeyboardInterrupt:
            pass
    elif cmd == "export":
        db = WhoopDB(args.db); did = _need_device(db, args.address)
        since = _parse_time(args.since) if args.since else None
        print(f"exported {db.export_json(did, args.out, args.only_type, since)} frames → {args.out}")
    elif cmd == "status":
        db = WhoopDB(args.db); did = _need_device(db, args.address)
        info = db.device_info(did); st = db.state(did); cov = db.coverage(did)
        print(f"db: {args.db}")
        print(f"  device: {info[0]} name={info[1]!r} subject={info[2]!r} model={info[3]}")
        print(f"  cursor last_trim={st.get('last_trim','?')} history_complete={st.get('history_complete','0')}")
        print(f"  coverage: {_fmt(cov[0])} → {_fmt(cov[1])}  ({cov[2] or 0} type-47)")
        print(f"  counts by type: {db.counts(did)}")
        labs = db.labels(did)
        print(f"  labels ({len(labs)}):")
        for s_, e_, a_, n_ in labs:
            print(f"    {a_:12s} {_fmt(s_)} → {_fmt(e_)}  {n_ or ''}")
    elif cmd == "devices":
        db = WhoopDB(args.db)
        print(f"db: {args.db}")
        for did, addr, nm, subj, mdl, n47, mn, mx in db.list_devices():
            print(f"  [{did}] {addr} name={nm!r} subject={subj!r} model={mdl}  "
                  f"{n47} type-47  {_fmt(mn)}→{_fmt(mx)}")
    elif cmd == "label":
        db = WhoopDB(args.db); did = _need_device(db, args.address)
        s_, e_ = _parse_time(args.start), _parse_time(args.end)
        db.add_label(did, s_, e_, args.activity, args.note)
        print(f"labeled {args.activity}: {_fmt(s_)} → {_fmt(e_)} for device {db.device_info(did)[0]}")
    elif cmd == "decode":
        db = WhoopDB(args.db); did = _need_device(db, args.address)
        res = decode_features.decode_new(db, did, full=args.full)
        print(f"decode: {res['frames']} frames → feat_second updated "
              f"({res['decoded']} decoded, {res['skipped']} skipped); "
              f"cursor last_decoded_frame_id={res['cursor']}")


if __name__ == "__main__":
    main()
