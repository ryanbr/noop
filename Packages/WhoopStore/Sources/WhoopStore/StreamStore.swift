import Foundation
import GRDB
import WhoopProtocol

extension WhoopStore {
    /// Deterministic JSON for an event payload (sorted keys so the same payload always
    /// serializes byte-identically, important for the natural-key dedupe and parity).
    static func encodePayload(_ payload: [String: ParsedValue]) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    /// Pack a decoded v26 PPG waveform's samples as little-endian i16 (2 bytes/sample) — a single
    /// compact BLOB per (deviceId, ts) row instead of 24 scalar rows (issue #156 follow-up, v27). Any
    /// sample count is handled (a truncated frame can decode fewer than 24); each value is truncated to
    /// Int16's range, matching the wire format it came from (`readI16` in the decoder never produces
    /// anything wider).
    static func packPpgSamples(_ samples: [Int]) -> Data {
        var buf = Data(capacity: samples.count * 2)
        for s in samples {
            let v = Int16(truncatingIfNeeded: s)
            buf.append(UInt8(truncatingIfNeeded: v))
            buf.append(UInt8(truncatingIfNeeded: v >> 8))
        }
        return buf
    }

    /// Inverse of `packPpgSamples`. A trailing odd byte (a corrupt/truncated blob) is dropped rather
    /// than thrown — a read path never crashes on a malformed row.
    static func unpackPpgSamples(_ data: Data) -> [Int] {
        let bytes = [UInt8](data)
        var out = [Int](); out.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            let u = UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
            out.append(Int(Int16(bitPattern: u)))
            i += 2
        }
        return out
    }

    /// #423: pack the raw-IMU i16 columns to a little-endian BLOB (same wire encoding as `packPpgSamples`,
    /// an `[Int16]` source — the 6×100 columns ax…az,gx…gz). Byte-identical to Kotlin `packImuColumns`.
    static func packImuColumns(_ cols: [Int16]) -> Data {
        var buf = Data(capacity: cols.count * 2)
        for v in cols { buf.append(UInt8(truncatingIfNeeded: v)); buf.append(UInt8(truncatingIfNeeded: v >> 8)) }
        return buf
    }

    /// Inverse of `packImuColumns`; a trailing odd byte is dropped so a malformed row never crashes a read.
    static func unpackImuColumns(_ data: Data) -> [Int16] {
        let bytes = [UInt8](data)
        var out = [Int16](); out.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count { out.append(Int16(bitPattern: UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8))); i += 2 }
        return out
    }

    /// #423 rolling retention for the raw-IMU capture table (twin of Kotlin `RAW_IMU_RETENTION_ROWS`):
    /// ~1 h at 1 row/strap-second (~4 MB) hard-caps the table during a multi-day offload replay.
    public static let rawImuRetentionRows = 3600

    /// v31 rolling retention for the v18 aux-slot table (twin of Kotlin `V18_AUX_RETENTION_ROWS`).
    ///
    /// `rawImuSample` is the closest precedent — raw instrumentation banked as a blob, capped rather than
    /// unbounded — and the same reasoning applies here: nothing reads these rows yet, so a cap is far
    /// cheaper to RELAX later than to impose once users have a year of history. Unbounded, this table is
    /// the one genuinely new source of row growth in v31 (the four named channels only WIDEN rows that
    /// were already being written: ~14 bytes on a `gravitySample`/`skinTempSample`/`sleepStateSample` row
    /// that exists either way, adding no rows at all).
    ///
    /// 604,800 = 7 × 86,400, i.e. a week of strap-seconds if the strap emitted v18 every second of every
    /// day. At ~85 B/row (a ≤30 B blob plus row and primary-key-index overhead) that is a **~50 MB hard
    /// ceiling**; in practice v18 seconds are a fraction of a day, so the same cap spans considerably
    /// longer in wall-clock terms. Per device, newest-first — a multi-device store gets the cap each.
    ///
    /// This does re-introduce a bounded version of the loss this migration exists to stop: a slot older
    /// than the window is gone again. That is the deliberate trade — a census needs weeks of records, not
    /// years, and the alternative is an invisible table that can outgrow everything a user actually reads.
    public static let v18AuxRetentionRows = 604_800

    /// Rows to bank before running the retention sweep again. The sweep walks up to
    /// `v18AuxRetentionRows` index entries, so running it per insert batch was the cost; the table may sit
    /// this many rows (plus the crossing batch) above the cap in exchange, well under a MB against its
    /// ~50 MB ceiling.
    public static let v18AuxPruneEveryRows = 10_000

    /// Insert or update a device row (natural key = id).
    public func upsertDevice(id: String, mac: String?, name: String?) async throws {
        let now = Int(Date().timeIntervalSince1970)
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO device (id, mac, name, firstSeen, lastSeen)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    mac = excluded.mac,
                    name = excluded.name,
                    lastSeen = excluded.lastSeen
                """, arguments: [id, mac, name, now, now])
        }
    }

    /// #423: persist decoded 5/MG raw-IMU offload buffers (one row per strap-second, packed i16 BLOB),
    /// then bound the table to the newest `retentionRows` for the device (rolling retention). Written from
    /// the deep-buffer capture seam, not the normal stream path, so it inserts directly (idempotent by ts).
    /// Twin of Kotlin `WhoopRepository.insertRawImu`.
    public func insertRawImu(deviceId: String, rows: [(ts: Int, cols: [Int16])], retentionRows: Int) async throws {
        guard !rows.isEmpty else { return }
        try syncWrite { db in
            let ins = try db.cachedStatement(sql: """
                INSERT INTO rawImuSample (deviceId, ts, samples) VALUES (?, ?, ?)
                ON CONFLICT(deviceId, ts) DO NOTHING
                """)
            // Pack the raw i16 columns to the LE BLOB HERE (packImuColumns is module-internal), so the
            // caller passes plain [Int16] and never needs the packer. Mirrors how `insert` packs ppgWaveform.
            for r in rows { try ins.execute(arguments: [deviceId, r.ts, WhoopStore.packImuColumns(r.cols)]) }
            try db.execute(sql: """
                DELETE FROM rawImuSample WHERE deviceId = ? AND ts < (
                    SELECT MIN(ts) FROM (SELECT ts FROM rawImuSample WHERE deviceId = ? ORDER BY ts DESC LIMIT ?))
                """, arguments: [deviceId, deviceId, retentionRows])
        }
    }

    /// Idempotent upsert of decoded streams by natural key. Returns the number of rows
    /// ACTUALLY inserted per stream (0 for rows that already existed).
    ///
    /// NOTE: the `synced` column (added by migration v5 for a since-removed server-upload feature)
    /// is intentionally NOT written here, it is unused and defaults to 0. The column is left in the
    /// schema to avoid a DROP COLUMN migration over existing data; nothing reads it.
    @discardableResult
    public func insert(_ streams: Streams, deviceId: String) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
        try await insert(streams, deviceId: deviceId,
                         v18AuxRetentionRows: WhoopStore.v18AuxRetentionRows,
                         v18AuxPruneEveryRows: WhoopStore.v18AuxPruneEveryRows)
    }

    /// `insert(_:deviceId:)` with the v31 aux-table cap made explicit. Internal and a SEPARATE overload
    /// rather than a defaulted parameter on the public entry point: `StoreWriting` / `BackfillStoreWriting`
    /// require `insert(_:deviceId:)` exactly, and a Swift witness must match the requirement's parameter
    /// list — a default argument does not satisfy it. Exists so a test can prove the rolling delete with a
    /// small cap instead of writing 600k rows; every production caller goes through the wrapper above.
    @discardableResult
    func insert(_ streams: Streams, deviceId: String, v18AuxRetentionRows: Int,
                v18AuxPruneEveryRows: Int) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
        // Banked rows, accumulated across batches so the sweep does not run on every one.
        var v18Written = 0
        let result: (Int, Int, Int, Int, Int, Int, Int, Int) = try syncWrite { db in
            var hr = 0, rr = 0, ev = 0, bat = 0
            var spo2 = 0, skin = 0, resp = 0, grav = 0
            // Reuse one prepared statement per table instead of recompiling the same SQL on every
            // row. This is the hottest write path (every Collector.flush + every Backfiller chunk
            // over potentially millions of historical rows). cachedStatement persists the compiled
            // statement on the connection across insert() calls too. Each loop is guarded so empty
            // streams (the common live case) compile nothing.
            if !streams.hr.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.hr {
                    try stmt.execute(arguments: [deviceId, s.ts, s.bpm])
                    hr += db.changesCount
                }
            }
            if !streams.rr.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO rrInterval (deviceId, ts, rrMs, seq, ord, srcChannel)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts, rrMs, seq) DO NOTHING
                    """)
                // v24 (#163): number EQUAL (ts, rrMs) beats 0, 1, … within this batch so both survive;
                // distinct beats keep seq 0 and their own (ts, rrMs, 0) key, so a distinct beat is never
                // dropped even across batches (rrMs stays in the key). Re-syncing identical rows reproduces
                // the same (ts, rrMs, seq) → still idempotent. Nested dict = (ts, rrMs) occurrence counter.
                //
                // v30 (#823): `ord` is the beat's position among ALL beats sharing this ts in this batch —
                // its emission order. `seq` cannot express it (it keys on (ts, rrMs), so distinct beats in
                // a second are all 0). Not in the key, never changes which rows survive; it exists so reads
                // return beats in heart order rather than sorted by value, which biases RMSSD down. Same
                // batch-local caveat as seq: a second split across two live flushes restarts ord at 0 and
                // DO NOTHING keeps the first row. The historical path delivers a second atomically.
                // Twin of Kotlin assignRrSeq.
                //
                // v32 (#1071): `srcChannel` is the sensor channel that measured the beat, carried from the
                // decoder that produced it. NULL for every WHOOP row (one beat source — there is no channel
                // to name, and that is honest rather than a placeholder) and for any source that does not
                // report one. Like `ord` it is OUTSIDE the key: two channels measuring the same beat can
                // yield the same (ts, rrMs), and keying on the label would store both — which is precisely
                // the double-count this fixes. `DO NOTHING` therefore keeps whichever arrived first and the
                // second channel's copy of THAT exact beat is dropped at insert; the read filter is what
                // separates the streams in general.
                var seqByTsRr: [Int: [Int: Int]] = [:]
                var ordByTs: [Int: Int] = [:]
                for r in streams.rr {
                    let seq = seqByTsRr[r.ts]?[r.rrMs] ?? 0
                    seqByTsRr[r.ts, default: [:]][r.rrMs] = seq + 1
                    let ord = ordByTs[r.ts] ?? 0
                    ordByTs[r.ts] = ord + 1
                    try stmt.execute(arguments: [deviceId, r.ts, r.rrMs, seq, ord,
                                                 r.srcChannel?.rawValue])
                    rr += db.changesCount
                }
            }
            if !streams.events.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO event (deviceId, ts, kind, payloadJSON) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts, kind) DO NOTHING
                    """)
                for e in streams.events {
                    let json = try WhoopStore.encodePayload(e.payload)
                    try stmt.execute(arguments: [deviceId, e.ts, e.kind, json])
                    ev += db.changesCount
                }
            }
            if !streams.battery.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO battery (deviceId, ts, soc, mv, charging) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for b in streams.battery {
                    try stmt.execute(arguments: [deviceId, b.ts, b.soc, b.mv, b.charging])
                    bat += db.changesCount
                }
            }
            if !streams.spo2.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO spo2Sample (deviceId, ts, red, ir) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.spo2 {
                    try stmt.execute(arguments: [deviceId, s.ts, s.red, s.ir])
                    spo2 += db.changesCount
                }
            }
            // `aux1Raw`/`aux2Raw` (v31) are the two auxiliary thermal channels riding the same v18 record
            // as the primary reading. nil (a WHOOP 4.0, or a byte that failed the decoder's thermal gate)
            // stores SQL NULL, so an absent channel stays absent.
            if !streams.skinTemp.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO skinTempSample (deviceId, ts, raw, aux1Raw, aux2Raw) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.skinTemp {
                    try stmt.execute(arguments: [deviceId, s.ts, s.raw, s.aux1Raw, s.aux2Raw])
                    skin += db.changesCount
                }
            }
            if !streams.resp.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO respSample (deviceId, ts, raw) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.resp {
                    try stmt.execute(arguments: [deviceId, s.ts, s.raw])
                    resp += db.changesCount
                }
            }
            // `dynAccel` (v31) is the strap's OWN gravity-removed motion magnitude for the same second —
            // stored BESIDE the vector, never in place of it, and read by nothing. nil (a WHOOP 4.0, or an
            // f32 outside the decoder's [0, 8] g gate) stores SQL NULL.
            if !streams.gravity.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO gravitySample (deviceId, ts, x, y, z, dynAccel) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.gravity {
                    try stmt.execute(arguments: [deviceId, s.ts, s.x, s.y, s.z, s.dynAccel])
                    grav += db.changesCount
                }
            }
            // WHOOP5 step counter (#78). Persist-only, the count is not surfaced in the return tuple
            // (no consumer reads it; keeping the 8-field tuple avoids touching any caller/test).
            // `activityClass` (#316, v19 column) is the @63 activity-class enum (0=still/1=walk/2=run) the
            // decoder already carries on each StepSample; it was dropped here before v19. Bound as `s.activityClass`
            //, nil (the byte was 0xFF/invalid/absent) stores SQL NULL, so an absent class stays absent.
            if !streams.steps.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO stepSample (deviceId, ts, counter, activityClass) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.steps {
                    try stmt.execute(arguments: [deviceId, s.ts, s.counter, s.activityClass])
                }
            }
            // Band sleep_state (#175). Persist-only, same as steps — the strap's OWN @81 high-nibble state
            // (0 wake/1 still/2 asleep/3 up), decoded and streamed but dropped at storage until now. Keyed by
            // (deviceId, ts); ON CONFLICT DO NOTHING keeps the first-seen state for a second so a re-sync is
            // idempotent. The raw 0-3 code is stored verbatim — a strap that never reports it inserts nothing.
            // `rawByte` (v31) is the WHOLE @81 byte; `state` remains exactly its high nibble, so every
            // existing #175 consumer is bit-identical. nil stores SQL NULL.
            if !streams.sleepState.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO sleepStateSample (deviceId, ts, state, rawByte) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.sleepState {
                    try stmt.execute(arguments: [deviceId, s.ts, s.state, s.rawByte])
                }
            }
            // PPG-derived HR from the v26 optical buffer (#156). Persist-only, same as steps, the count
            // is not added to the 8-field return tuple (the Backfiller call site reads that tuple by name;
            // extending it would ripple), so it is inserted without being counted. ON CONFLICT DO NOTHING
            // keeps the FIRST estimate for a second; the measured hrSample is never touched here.
            if !streams.ppgHr.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO ppgHrSample (deviceId, ts, bpm, conf) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.ppgHr {
                    try stmt.execute(arguments: [deviceId, s.ts, s.bpm, s.conf])
                }
            }
            // RAW v26 optical PPG waveform (#156 follow-up) — the samples `ppgHr` above is derived FROM.
            // Persist-only, same as steps/sleepState/ppgHr: not added to the 8-field return tuple. ON
            // CONFLICT DO NOTHING keeps the FIRST-seen waveform for a second, matching every other
            // per-second stream's dedupe rule. Packed into one compact BLOB per row (see
            // `packPpgSamples`) rather than 24 scalar rows, so this insert is O(records), not O(samples).
            if !streams.ppgWaveform.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO ppgWaveformSample (deviceId, ts, samples, burstIndex) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.ppgWaveform {
                    try stmt.execute(arguments: [deviceId, s.ts, WhoopStore.packPpgSamples(s.samples),
                                                 s.burstIndex])
                }
            }
            // Every remaining v18 slot (v31), one compact blob per strap-second. Persist-only, same as
            // steps/sleepState/ppgHr/ppgWaveform: not added to the 8-field return tuple. A sample whose
            // slots are all absent packs to empty and is SKIPPED rather than banking a meaningless row —
            // which is also what keeps a WHOOP 4.0 offload from writing here at all.
            if !streams.v18Aux.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO v18AuxSample (deviceId, ts, fields) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.v18Aux {
                    let blob = V18AuxCodec.pack(s)
                    if blob.isEmpty { continue }
                    try stmt.execute(arguments: [deviceId, s.ts, blob])
                    v18Written += 1
                }
            }
            return (hr, rr, ev, bat, spo2, skin, resp, grav)
        }

        // Rolling retention (the `insertRawImu` shape, #423) but AMORTISED. The delete finds the
        // Nth-newest row by rank, so it walks up to `v18AuxRetentionRows` index entries; `insertRawImu`
        // keeps 3,600 so that is free, this keeps 604,800 and an offload inserts once per chunk. Swept
        // once per `v18AuxPruneEveryRows` rows instead, which keeps newest-N-rows exactly (a time window
        // would not — a sporadically-worn strap's rows span far more than a week, and the census wants
        // that). Counter is per device because the delete is.
        if v18Written > 0 {
            let banked = (v18AuxRowsSincePrune[deviceId] ?? 0) + v18Written
            v18AuxRowsSincePrune[deviceId] = banked
            // BEST-EFFORT, and it has to be: the rows above are already committed, because the sweep is
            // now its own transaction rather than riding the insert's. A throw here would surface as an
            // insert failure and make Backfiller re-send a chunk it has already banked. Leaving the budget
            // unspent instead means the next batch simply retries the sweep.
            if banked >= v18AuxPruneEveryRows,
               (try? syncWrite { db in
                   try db.execute(sql: """
                       DELETE FROM v18AuxSample WHERE deviceId = ? AND ts < (
                           SELECT MIN(ts) FROM (
                               SELECT ts FROM v18AuxSample WHERE deviceId = ? ORDER BY ts DESC LIMIT ?))
                       """, arguments: [deviceId, deviceId, v18AuxRetentionRows])
               }) != nil {
                v18AuxRowsSincePrune[deviceId] = 0
            }
        }
        return result
    }

    // MARK: - Raw sensor CSV export (diagnostic)

    /// Long-format CSV column order. One stream's columns are filled per row; the rest stay blank.
    private static let rawCSVHeader =
        "unix_s,iso_utc,stream,hr_bpm,rr_ms,grav_x,grav_y,grav_z,step_counter," +
        "ppg_bpm,ppg_conf,spo2_red,spo2_ir,skintemp_raw,resp_raw,band_sleep_state,event_kind,event_payload"

    /// One assembled CSV line: the 16 columns AFTER the `unix_s,iso_utc` prefix, joined with commas.
    /// `cols[0]` is the `stream` name; `cols[1...15]` are the per-stream value slots, only the ones
    /// that belong to this row's stream are non-empty.
    private struct RawCSVRow {
        let ts: Int
        var cols: [String]
        init(ts: Int) { self.ts = ts; self.cols = Array(repeating: "", count: 16) }
    }

    /// Export the decoded per-sample sensor streams NOOP already stores to ONE combined long-format CSV
    /// (header + one row per sample, all streams interleaved and sorted by ts ascending). On-device,
    /// plain text, no BLE hex, a diagnostic so power users / external devs can prototype sleep/activity/
    /// VBT algorithms on real data without a BLE stream (#308/#276/#322).
    ///
    /// `since` is a unix-seconds floor (caller passes now-24h); rows with `ts >= since` for `deviceId`
    /// are included. Writes to a temp file and returns its URL (caller hands it to the share/save flow).
    public func exportRawCSV(deviceId: String, since: TimeInterval) async throws -> URL {
        let floor = Int(since)
        let rows: [RawCSVRow] = try syncRead { db in
            var out: [RawCSVRow] = []

            // hr: stream=hr → hr_bpm (col 3).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, bpm FROM hrSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "hr"
                row.cols[1] = WhoopStore.intStr(r["bpm"])
                out.append(row)
            }
            // rr: stream=rr → rr_ms (col 4). Same-second beats need the #823 tiebreak here too, and
            // more so: bare "ORDER BY ts" left their order UNDEFINED, so a raw export could differ
            // between runs over identical data. Emission order first, then the pre-v30 fallback.
            //
            // DELIBERATELY UNFILTERED by `srcChannel`, unlike the scoring read (#1071). This is the raw
            // dump: both optical channels are real measurements, and the whole point of keeping the
            // second one is that it can be inspected against the first. A raw export that silently hid
            // half the stored rows would make the duplication that motivated v32 un-diagnosable from an
            // export — which is exactly how it WAS diagnosed.
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, rrMs FROM rrInterval WHERE deviceId = ? AND ts >= ? " +
                "ORDER BY ts, ord, rrMs, seq",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "rr"
                row.cols[2] = WhoopStore.intStr(r["rrMs"])
                out.append(row)
            }
            // gravity: stream=gravity → grav_x/y/z (cols 5–7).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, x, y, z FROM gravitySample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "gravity"
                row.cols[3] = WhoopStore.dblStr(r["x"])
                row.cols[4] = WhoopStore.dblStr(r["y"])
                row.cols[5] = WhoopStore.dblStr(r["z"])
                out.append(row)
            }
            // steps: stream=steps → step_counter (col 8).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, counter FROM stepSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "steps"
                row.cols[6] = WhoopStore.intStr(r["counter"])
                out.append(row)
            }
            // ppghr: stream=ppghr → ppg_bpm/ppg_conf (cols 9–10).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, bpm, conf FROM ppgHrSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "ppghr"
                row.cols[7] = WhoopStore.dblStr(r["bpm"])
                row.cols[8] = WhoopStore.dblStr(r["conf"])
                out.append(row)
            }
            // spo2: stream=spo2 → spo2_red/spo2_ir (cols 11–12).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, red, ir FROM spo2Sample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "spo2"
                row.cols[9] = WhoopStore.intStr(r["red"])
                row.cols[10] = WhoopStore.intStr(r["ir"])
                out.append(row)
            }
            // skintemp: stream=skintemp → skintemp_raw (col 13).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, raw FROM skinTempSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "skintemp"
                row.cols[11] = WhoopStore.intStr(r["raw"])
                out.append(row)
            }
            // resp: stream=resp → resp_raw (col 14).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, raw FROM respSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "resp"
                row.cols[12] = WhoopStore.intStr(r["raw"])
                out.append(row)
            }
            // band sleep_state (#175): stream=band_sleep_state → band_sleep_state (col 15). The strap's
            // OWN @81 high-nibble state (0 wake/1 still/2 asleep/3 up), carried verbatim.
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, state FROM sleepStateSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "band_sleep_state"
                row.cols[13] = WhoopStore.intStr(r["state"])
                out.append(row)
            }
            // event: stream=event → event_kind/event_payload (cols 16–17). Payload is free-form JSON,
            // so it always goes through the CSV-quote escaper (commas/quotes/newlines).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, kind, payloadJSON FROM event WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "event"
                row.cols[14] = WhoopStore.csvField(r["kind"] ?? "")
                row.cols[15] = WhoopStore.csvField(r["payloadJSON"] ?? "")
                out.append(row)
            }

            // Stable sort by ts ascending. `sorted` is not guaranteed stable, but ties only occur across
            // different streams at the same second, any interleaving of those is acceptable here.
            out.sort { $0.ts < $1.ts }
            return out
        }

        // Stream the rows straight to disk through a FileHandle, flushing in ~64 KB chunks, instead of
        // building the whole CSV as one in-memory String: a busy 24 h export otherwise held tens of MB
        // twice, the assembled String plus its UTF-8 Data copy that `write(to:)` makes, and could OOM
        // (#406, parity with the Android exporter's streaming fix).
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "UTC")
        iso.formatOptions = [.withInternetDateTime]

        let stamp = Int(Date().timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-raw-sensors-\(stamp).csv")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        try handle.write(contentsOf: Data((WhoopStore.rawCSVHeader + "\n").utf8))
        var buf = String()
        buf.reserveCapacity(72 * 1024)
        for row in rows {
            let isoStr = iso.string(from: Date(timeIntervalSince1970: TimeInterval(row.ts)))
            buf += "\(row.ts),\(isoStr),"
            buf += row.cols.joined(separator: ",")
            buf += "\n"
            if buf.utf8.count >= 64 * 1024 {
                try handle.write(contentsOf: Data(buf.utf8))
                buf.removeAll(keepingCapacity: true)
            }
        }
        if !buf.isEmpty { try handle.write(contentsOf: Data(buf.utf8)) }
        return url
    }

    /// Format an Int-valued GRDB column (blank for NULL) without the "Optional(...)" wrapper text.
    private static func intStr(_ v: Int?) -> String { v.map(String.init) ?? "" }

    /// Format a Double-valued GRDB column (blank for NULL). Plain decimal, `String(Double)` is
    /// round-trippable and locale-independent, which the comma-delimited CSV needs.
    private static func dblStr(_ v: Double?) -> String { v.map { String($0) } ?? "" }

    /// RFC-4180 CSV field: wrap in double quotes and double any embedded quote ONLY when the value
    /// contains a comma, quote, or newline. Used for the free-form event columns.
    private static func csvField(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Test helpers

    public func storageStats_rowCountsForTest() async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
        // Bind each count to its own `let` before assembling the tuple. Returning the whole tuple of
        // inline `try Int.fetchOne(...) ?? 0` expressions made Swift's type-checker time out on some
        // toolchains/machines (reported by a contributor building locally); splitting it is
        // behaviour-identical and trivial to type-check.
        try syncRead { db in
            let hr = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hrSample") ?? 0
            let rr = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rrInterval") ?? 0
            let events = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event") ?? 0
            let battery = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM battery") ?? 0
            let spo2 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM spo2Sample") ?? 0
            let skinTemp = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM skinTempSample") ?? 0
            let resp = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM respSample") ?? 0
            let gravity = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM gravitySample") ?? 0
            return (hr, rr, events, battery, spo2, skinTemp, resp, gravity)
        }
    }

    public func stepCountForTest() async throws -> Int {
        try syncRead { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stepSample") ?? 0 }
    }

    /// The strap's OWN banked band sleep_state samples (#175) in `[from, to]` for one device, ascending by
    /// ts. Each `(ts, state)` is the raw @81 high-nibble code (0 wake/1 still/2 asleep/3 up) carried
    /// verbatim off the offload stream. Empty when the strap never reported it (a WHOOP 4.0, or a not-yet-
    /// offloaded window). Feeds the Deep Timeline band-state track and the per-session grid the H7 guard reads.
    public func sleepStateSamples(deviceId: String, from: Int, to: Int, limit: Int = 200_000) async throws
        -> [SleepStateSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, state, rawByte FROM sleepStateSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                // rawByte (v31) is the whole @81 byte; nil on any pre-v31 row. `state` is unchanged, so
                // the H7 guard and the Deep Timeline track see exactly what they saw before.
                .map { SleepStateSample(ts: $0["ts"], state: $0["state"], rawByte: $0["rawByte"]) }
        }
    }

    public func sleepStateCountForTest() async throws -> Int {
        try syncRead { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sleepStateSample") ?? 0 }
    }

    /// The remaining 5/MG v18 per-second fields (v31) in `[from, to]` for one device, ascending by ts.
    /// Each row is one strap-second's slots, decoded from the compact blob by `V18AuxCodec`. Empty for a
    /// WHOOP 4.0 and for any window offloaded before v31. INSTRUMENTATION: no analytic calls this — it
    /// exists so the banked bytes are reachable for a census, and so the write path has a round-trip test.
    public func v18AuxSamples(deviceId: String, from: Int, to: Int, limit: Int = 200_000) async throws
        -> [V18AuxSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, fields FROM v18AuxSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { V18AuxCodec.unpack($0["fields"] ?? Data(), ts: $0["ts"]) }
        }
    }

    public func v18AuxCountForTest() async throws -> Int {
        try syncRead { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v18AuxSample") ?? 0 }
    }

    public func ppgHrCountForTest() async throws -> Int {
        try syncRead { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ppgHrSample") ?? 0 }
    }

    /// The RAW v26 optical PPG waveform (#156 follow-up), one record per second, in `[from, to]` for one
    /// device, ascending by ts. `samples` are the raw i16 ADC counts the strap sent, unpacked from the
    /// compact on-disk BLOB (`packPpgSamples`/`unpackPpgSamples`). Empty when the strap never emitted
    /// v26 (the WHOOP 4.0 / v18-only common case) or the window has no v26-heavy stretch.
    public func ppgWaveformSamples(deviceId: String, from: Int, to: Int, limit: Int = 200_000) async throws
        -> [PpgWaveformSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, samples, burstIndex FROM ppgWaveformSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { PpgWaveformSample(ts: $0["ts"],
                                         samples: WhoopStore.unpackPpgSamples($0["samples"]),
                                         burstIndex: $0["burstIndex"]) }
        }
    }

    public func ppgWaveformCountForTest() async throws -> Int {
        try syncRead { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ppgWaveformSample") ?? 0 }
    }

    public func deviceRowForTest(id: String) async throws -> (mac: String?, name: String?)? {
        try syncRead { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT mac, name FROM device WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return (row["mac"], row["name"])
        }
    }

    /// Write an R-R row the way a PRE-v30 build did: `ord` left NULL, emission order never recorded.
    /// The normal insert path always stamps `ord`, so there is otherwise no way to construct the
    /// legacy shape — and the read-order fallback for existing user data is exactly the branch most
    /// worth testing rather than assuming. Test-only (#823).
    public func insertLegacyRrWithoutOrdForTest(deviceId: String, ts: Int, rrMs: Int) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO rrInterval (deviceId, ts, rrMs, seq, ord) VALUES (?, ?, ?, 0, NULL)
                ON CONFLICT(deviceId, ts, rrMs, seq) DO NOTHING
                """, arguments: [deviceId, ts, rrMs])
        }
    }

    /// The stored `ord` values for one second, in read order. Test-only (#823).
    public func rrOrdValuesForTest(deviceId: String, ts: Int) async throws -> [Int?] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ord FROM rrInterval WHERE deviceId = ? AND ts = ?
                ORDER BY ts ASC, ord ASC, rrMs ASC, seq ASC
                """, arguments: [deviceId, ts]).map { $0["ord"] }
        }
    }

    /// Every STORED R-R row for a device as `(rrMs, srcChannel)`, bypassing the scoring read's channel
    /// filter. Test-only (#1071): the fix is "filter at read, keep both channels on disk", and the only
    /// way to assert the second half is to look at the table itself rather than through `rrIntervals`.
    public func rrRowsWithChannelForTest(deviceId: String) async throws -> [(rrMs: Int, srcChannel: Int?)] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT rrMs, srcChannel FROM rrInterval WHERE deviceId = ?
                ORDER BY ts ASC, ord ASC, rrMs ASC, seq ASC
                """, arguments: [deviceId]).map { (rrMs: $0["rrMs"], srcChannel: $0["srcChannel"]) }
        }
    }

    /// Run the `v35-rr-future-quarantine` backfill predicate with an EXPLICIT `now` (the migration itself
    /// uses `strftime('%s','now')`; a test needs a fixed instant). Marks every stored R-R beat whose ts is
    /// after `nowSeconds`. Test-only (#1073).
    public func markFutureRrSuspectForTest(nowSeconds: Int) async throws {
        try syncWrite { db in
            try db.execute(sql: "UPDATE rrInterval SET tsSuspect = 1 WHERE ts > ?", arguments: [nowSeconds])
        }
    }

    /// Every STORED R-R row for a device as `(ts, tsSuspect)`, bypassing the scoring read's filter — so a
    /// test can assert which rows were quarantined AND that none were deleted. Test-only (#1073).
    public func rrSuspectRowsForTest(deviceId: String) async throws -> [(ts: Int, tsSuspect: Int?)] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, tsSuspect FROM rrInterval WHERE deviceId = ? ORDER BY ts ASC
                """, arguments: [deviceId]).map { (ts: $0["ts"], tsSuspect: $0["tsSuspect"]) }
        }
    }
}
