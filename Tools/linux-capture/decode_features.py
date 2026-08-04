"""Decode bridge: raw frames in captures/whoop.db -> per-second tables of the actual decoded values.

Stdlib only (no bleak) so the pure logic is unit-testable. The decoder of record is the Swift
`whoop-decode` CLI; this module never re-implements decoding. Best-effort + idempotent: it runs as a
final stage of `whoop_sync.py sync` (after the durable offload, never inside the ack loop) and as a
standalone `whoop_sync.py decode` subcommand.
"""
import json
import os
import shutil
import subprocess
import tempfile

FEATURE_SCHEMA = """
CREATE TABLE IF NOT EXISTS feat_second (
    device_id INTEGER NOT NULL, unix INTEGER NOT NULL,
    hr INTEGER, gx REAL, gy REAL, gz REAL,
    rr_count INTEGER, rr_mean_ms REAL, rmssd REAL,
    spo2_red INTEGER, spo2_ir INTEGER, skin_temp_raw INTEGER, skin_temp_c REAL, resp_raw INTEGER,
    record_version INTEGER,
    PRIMARY KEY (device_id, unix)
);
CREATE TABLE IF NOT EXISTS feat_rr (
    device_id INTEGER NOT NULL, unix INTEGER NOT NULL, idx INTEGER NOT NULL,
    rr_ms INTEGER NOT NULL,
    PRIMARY KEY (device_id, unix, idx)
);
CREATE TABLE IF NOT EXISTS feat_ppg (
    device_id INTEGER NOT NULL, unix INTEGER NOT NULL, sample_idx INTEGER NOT NULL,
    channel INTEGER NOT NULL, value INTEGER NOT NULL, burst_index INTEGER,
    PRIMARY KEY (device_id, unix, sample_idx, channel)
);
CREATE TABLE IF NOT EXISTS feat_event (
    device_id INTEGER NOT NULL, unix INTEGER NOT NULL, kind TEXT NOT NULL,
    event_num INTEGER, payload_json TEXT,
    PRIMARY KEY (device_id, unix, kind)
);
"""


def apply_schema(conn):
    """Create the value tables + indices on `conn` if absent (idempotent)."""
    conn.executescript(FEATURE_SCHEMA)
    # Idempotent migration for pre-existing DBs: add skin_temp_c (°C = skin_temp_raw / 128, the AS6221
    # sensor's native 7.8125 m°C/LSB scale) if an older feat_second lacks it.
    cols = {r[1] for r in conn.execute("PRAGMA table_info(feat_second)")}
    if "skin_temp_c" not in cols:
        conn.execute("ALTER TABLE feat_second ADD COLUMN skin_temp_c REAL")
    # Idempotent migration for pre-existing DBs (PR#553): add feat_ppg.burst_index — the raw per-burst
    # counter at v26 frame[21] (formerly mis-decoded as a 1..26 ppg_channel; a real capture read 65, so it
    # is NOT a channel id). v26 PPG rows now store channel=0 and carry the raw counter here for analysis.
    ppg_cols = {r[1] for r in conn.execute("PRAGMA table_info(feat_ppg)")}
    if "burst_index" not in ppg_cols:
        conn.execute("ALTER TABLE feat_ppg ADD COLUMN burst_index INTEGER")
    conn.commit()


def rr_stats(rr):
    """Return (count, mean_ms, rmssd) for a second's R-R intervals; rmssd is None if <2 intervals.

    Non-positive intervals are dropped (decoder emits 0 for absent slots). RMSSD = root-mean-square of
    successive differences — the standard short-window HRV summary, per second.
    """
    rr = [x for x in (rr or []) if x and x > 0]
    if not rr:
        return (0, None, None)
    n = len(rr)
    mean = sum(rr) / n
    if n < 2:
        return (n, mean, None)
    diffs = [rr[i + 1] - rr[i] for i in range(n - 1)]
    rmssd = (sum(d * d for d in diffs) / len(diffs)) ** 0.5
    return (n, mean, rmssd)


# Inner packet types that carry per-second biometric records.
_DATA_TYPES = (47, 40)   # HISTORICAL_DATA, REALTIME_DATA
_EVENT_TYPE = 48


def feature_to_rows(rec):
    """Map a normalized decoded record -> {second, rr[], ppg[], event}. See module/spec for rules."""
    out = {"second": None, "rr": [], "ppg": [], "event": None}
    if not rec.get("crc_ok", True):
        return out
    p = rec.get("parsed") or {}
    itype = rec.get("inner_type")
    unix = rec.get("unix")
    # Realtime (type-40) frames carry their unix in the decoded `timestamp` field, not the frames.unix
    # column (the capture's rec_unix only maps historical type-47). Fall back to it so realtime R-R
    # actually reaches feat_rr instead of being dropped as "no unix".
    if unix is None and itype == 40 and isinstance(p.get("timestamp"), int):
        unix = p["timestamp"]

    if itype in _DATA_TYPES:
        if unix is None:
            return out
        hr = p.get("heart_rate")
        if hr == 0:
            hr = None
        rr = [x for x in (p.get("rr_intervals") or []) if isinstance(x, int)]
        n, mean, rmssd = rr_stats(rr)
        # Skin temperature: the decoder emits the raw AS6221 register; °C is its native raw/128.
        st_raw = p.get("skin_temp_raw")
        st_c = (st_raw / 128.0) if isinstance(st_raw, (int, float)) else None
        out["second"] = {
            "unix": unix, "hr": hr,
            "gx": p.get("gravity_x"), "gy": p.get("gravity_y"), "gz": p.get("gravity_z"),
            "rr_count": (n or None), "rr_mean_ms": mean, "rmssd": rmssd,
            "spo2_red": p.get("spo2_red"), "spo2_ir": p.get("spo2_ir"),
            "skin_temp_raw": st_raw, "skin_temp_c": st_c, "resp_raw": p.get("resp_rate_raw"),
            "record_version": rec.get("version"),
        }
        for i, v in enumerate(rr):
            out["rr"].append({"unix": unix, "idx": i, "rr_ms": v})
        # v26 PPG (PR#553): frame[21] is a raw per-burst counter (`burst_index`), NOT a channel — a real
        # capture read 65, outside any 26-channel sweep. So the channel column is forced to 0 and the raw
        # counter is stored alongside (nullable; absent when the decoder didn't surface it).
        burst = p.get("burst_index")
        for i, v in enumerate(p.get("ppg_waveform") or []):
            out["ppg"].append({"unix": unix, "sample_idx": i, "channel": 0,
                               "value": v, "burst_index": burst})
        return out

    if itype == _EVENT_TYPE:
        ev = p.get("event")
        ts = unix if unix is not None else p.get("event_timestamp")
        if ev is None or ts is None:
            return out
        payload = {k: v for k, v in p.items() if k not in ("event", "event_timestamp")}
        out["event"] = {"unix": ts, "kind": str(ev),
                        "event_num": ev if isinstance(ev, int) else None,
                        "payload_json": json.dumps(payload, sort_keys=True)}
        return out

    return out


_SECOND_COLS = ["hr", "gx", "gy", "gz", "rr_count", "rr_mean_ms", "rmssd",
                "spo2_red", "spo2_ir", "skin_temp_raw", "skin_temp_c", "resp_raw", "record_version"]

_SECOND_SQL = (
    "INSERT INTO feat_second (device_id, unix, " + ", ".join(_SECOND_COLS) + ") "
    "VALUES (?, ?, " + ", ".join(["?"] * len(_SECOND_COLS)) + ") "
    "ON CONFLICT(device_id, unix) DO UPDATE SET " +
    ", ".join(f"{c} = COALESCE(excluded.{c}, feat_second.{c})" for c in _SECOND_COLS)
)


def apply_rows(conn, device_id, mapped):
    """Upsert a list of feature_to_rows() outputs for `device_id`. Coalescing on feat_second so
    partial rows at the same second merge; INSERT OR IGNORE on the multi-valued tables."""
    cur = conn.cursor()
    for m in mapped:
        s = m.get("second")
        if s:
            cur.execute(_SECOND_SQL,
                        (device_id, s["unix"], *[s[c] for c in _SECOND_COLS]))
        for r in m.get("rr", []):
            cur.execute("INSERT OR IGNORE INTO feat_rr (device_id, unix, idx, rr_ms) VALUES (?,?,?,?)",
                        (device_id, r["unix"], r["idx"], r["rr_ms"]))
        for r in m.get("ppg", []):
            cur.execute("INSERT OR IGNORE INTO feat_ppg "
                        "(device_id, unix, sample_idx, channel, value, burst_index) "
                        "VALUES (?,?,?,?,?,?)",
                        (device_id, r["unix"], r["sample_idx"], r["channel"], r["value"],
                         r.get("burst_index")))
        e = m.get("event")
        if e:
            cur.execute("INSERT OR IGNORE INTO feat_event (device_id, unix, kind, event_num, payload_json) "
                        "VALUES (?,?,?,?,?)",
                        (device_id, e["unix"], e["kind"], e["event_num"], e["payload_json"]))
    conn.commit()


# Field categories in whoop-decode --json that are envelope or raw-byte summaries, not decoded values.
_DROP_CATS = ("frame", "unknown")


def _flatten_fields(frame):
    """Flatten whoop-decode's frame.fields list into a {name: value} dict, dropping envelope/raw cats."""
    parsed = {}
    for f in frame.get("fields", []):
        if f.get("cat") in _DROP_CATS:
            continue
        parsed[f.get("name")] = f.get("value")
    return parsed


def normalize_decode_record(raw, src_frame, device_id):
    """Adapt one whoop-decode --json object + its source frames row -> the normalized record dict.

    whoop-decode emits {family, char, frame:{crcOK, seq, fields:[{name,value,cat,off},...]}}. We
    flatten frame.fields (minus envelope/raw cats) into `parsed`, take crc from frame.crcOK, version
    from the `hist_version` field (whoop4 historical has no such field and is always v24), take unix
    from the decoded `unix` field (falling back to the source frames row), and inner_type from the
    source frames row (id,hex,char,recv_ms,unix,hr,inner_type).
    """
    raw = raw if isinstance(raw, dict) else {}
    frame = raw.get("frame") or {}
    parsed = _flatten_fields(frame)
    # The R-R interval ARRAY lives only in the decoder's frame.parsed — the per-interval values appear
    # as rr[i] FIELDS, but the array itself is parsed-only, so _flatten_fields misses it. Carry it
    # through so feat_rr / rmssd populate (realtime type-40 and historical alike).
    rr = (frame.get("parsed") or {}).get("rr_intervals")
    if rr is not None:
        parsed["rr_intervals"] = rr
    crc_ok = bool(frame.get("crcOK", True))
    version = parsed.get("hist_version")
    if version is None and raw.get("family") == "whoop4":
        version = 24
    # Prefer the decoder's own unix (present for every record version incl. v26, whose timestamp the
    # capture-time light-decode could not place, leaving frames.unix NULL); fall back to the frame row.
    unix = parsed.get("unix")
    if unix is None:
        unix = src_frame[4]
    return {"device_id": device_id, "unix": unix, "inner_type": src_frame[6],
            "version": version, "crc_ok": crc_ok, "parsed": parsed}


def find_whoop_decode():
    """Locate the whoop-decode binary (env override, in-repo build dir, then PATH)."""
    env = os.environ.get("WHOOP_DECODE")
    if env and os.path.exists(env):
        return env
    here = os.path.dirname(os.path.abspath(__file__))
    for rel in ("../../Packages/WhoopProtocol/.build/x86_64-unknown-linux-gnu/debug/whoop-decode",
                "../../Packages/WhoopProtocol/.build/debug/whoop-decode"):
        cand = os.path.abspath(os.path.join(here, rel))
        if os.path.exists(cand):
            return cand
    found = shutil.which("whoop-decode")
    if found:
        return found
    raise FileNotFoundError(
        "whoop-decode not found. Build it: cd noop/Packages/WhoopProtocol && "
        "swift build --product whoop-decode  (or set WHOOP_DECODE).")


def run_whoop_decode(frames_json, binary=None):
    """Run whoop-decode --json over capture records [{hex,char,ts_ms,hr},...]; return its JSON list."""
    binary = binary or find_whoop_decode()
    fd, path = tempfile.mkstemp(suffix=".json")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(frames_json, f)
        r = subprocess.run([binary, "--json", "--family", "auto", path],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f"whoop-decode exited {r.returncode}: {r.stderr[:300]}")
        data = json.loads(r.stdout)
        return data if isinstance(data, list) else data.get("frames", [])
    finally:
        os.unlink(path)


def decode_new(db, device_id, full=False, decode_fn=None):
    """Decode frames after the device's cursor into the value tables; advance the cursor.

    db: a WhoopDB (needs .db, .state(did), .set_state(did,k,v), .frames_after(did, after_id)).
    decode_fn: list-of-records -> list-of-decoded (injected in tests; defaults to run_whoop_decode).
    Idempotent + best-effort: re-running, or running after a partial run, never duplicates rows.
    """
    apply_schema(db.db)
    cursor = 0 if full else int(db.state(device_id).get("last_decoded_frame_id", 0))
    frames = db.frames_after(device_id, cursor)
    if not frames:
        return {"frames": 0, "decoded": 0, "skipped": 0, "cursor": cursor}
    decode_fn = decode_fn or run_whoop_decode
    records = [{"hex": h, "char": c, "ts_ms": (rm or 0), "hr": hr}
               for (_id, h, c, rm, _u, hr, _it) in frames]
    decoded = decode_fn(records)
    if len(decoded) != len(frames):
        raise RuntimeError(
            f"whoop-decode returned {len(decoded)} objects for {len(frames)} frames; "
            "refusing to advance cursor (would silently skip frames)")
    mapped, skipped = [], 0
    for src, raw in zip(frames, decoded):
        m = feature_to_rows(normalize_decode_record(raw, src, device_id))
        if m["second"] is None and not m["rr"] and not m["ppg"] and m["event"] is None:
            skipped += 1
        mapped.append(m)
    apply_rows(db.db, device_id, mapped)
    new_cursor = max(f[0] for f in frames)
    db.set_state(device_id, "last_decoded_frame_id", str(new_cursor))
    return {"frames": len(frames), "decoded": len(frames) - skipped,
            "skipped": skipped, "cursor": new_cursor}
