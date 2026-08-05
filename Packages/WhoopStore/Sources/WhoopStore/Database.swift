import Foundation
import GRDB

extension WhoopStore {
    /// The schema migrator. v1 creates decoded-stream tables (durable) + the raw outbox.
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "device") { t in
                t.column("id", .text).primaryKey()
                t.column("mac", .text)
                t.column("name", .text)
                t.column("firstSeen", .integer)
                t.column("lastSeen", .integer)
            }
            try db.create(table: "hrSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("bpm", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "rrInterval") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("rrMs", .integer).notNull()
                t.primaryKey(["deviceId", "ts", "rrMs"])
            }
            try db.create(table: "event") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("payloadJSON", .text).notNull()
                t.primaryKey(["deviceId", "ts", "kind"])
            }
            try db.create(table: "battery") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("soc", .double)
                t.column("mv", .integer)
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "rawBatch") { t in
                t.column("batchId", .text).primaryKey()
                t.column("deviceId", .text).notNull()
                t.column("capturedAt", .integer).notNull()
                t.column("deviceClockRef", .integer).notNull()
                t.column("wallClockRef", .integer).notNull()
                t.column("startTs", .integer).notNull()
                t.column("endTs", .integer).notNull()
                t.column("frameCount", .integer).notNull()
                t.column("byteSize", .integer).notNull()
                t.column("framesBlob", .blob).notNull()
                t.column("syncedAt", .integer)
            }
        }
        migrator.registerMigration("v2") { db in
            try db.create(table: "cursors") { t in
                t.column("name", .text).primaryKey()
                t.column("value", .integer)
            }
        }
        migrator.registerMigration("v3") { db in
            // type-47 biometric streams (mirror the existing decoded tables, PK (deviceId, ts)).
            try db.create(table: "spo2Sample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("red", .integer).notNull()
                t.column("ir", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "skinTempSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("raw", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "respSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("raw", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "gravitySample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("x", .double).notNull()
                t.column("y", .double).notNull()
                t.column("z", .double).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }
        migrator.registerMigration("v4") { db in
            // Server-derived metrics cached locally (Task 3.1: History = union(phone, server)).
            // sleepSession: one row per sleep session, natural key (deviceId, startTs).
            try db.create(table: "sleepSession") { t in
                t.column("deviceId", .text).notNull()
                t.column("startTs", .integer).notNull()
                t.column("endTs", .integer).notNull()
                t.column("efficiency", .double)
                t.column("restingHr", .integer)
                t.column("avgHrv", .double)
                t.column("stagesJSON", .text)
                t.primaryKey(["deviceId", "startTs"])
            }
            // dailyMetric: one row per calendar day (YYYY-MM-DD), natural key (deviceId, day).
            try db.create(table: "dailyMetric") { t in
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("totalSleepMin", .double)
                t.column("efficiency", .double)
                t.column("deepMin", .double)
                t.column("remMin", .double)
                t.column("lightMin", .double)
                t.column("disturbances", .integer)
                t.column("restingHr", .integer)
                t.column("avgHrv", .double)
                t.column("recovery", .double)
                t.column("strain", .double)
                t.column("exerciseCount", .integer)
                t.primaryKey(["deviceId", "day"])
            }
        }
        migrator.registerMigration("v5") { db in
            // Per-row upload sync flag for the decoded streams (mirrors rawBatch.syncedAt).
            // The OLD upload path used a forward-only highwater per stream, which permanently
            // stranded backfilled (older-ts) rows once the highwater jumped to a recent ts.
            // The fix: `synced` is set to 1 only after a successful upload, so the Uploader can
            // drain WHERE synced=0 regardless of ts order. Existing rows default to 0 → they
            // re-upload once (idempotent server-side), catching up the currently-stranded rows.
            for table in ["hrSample", "rrInterval", "event", "battery",
                          "spo2Sample", "skinTempSample", "respSample", "gravitySample"] {
                try db.alter(table: table) { t in
                    t.add(column: "synced", .integer).notNull().defaults(to: 0)
                }
            }
        }
        migrator.registerMigration("v6") { db in
            // Charging flag for the dense BATTERY_LEVEL-event battery series (nullable: the
            // command-response battery path doesn't report it).
            try db.alter(table: "battery") { t in
                t.add(column: "charging", .boolean)
            }
        }
        migrator.registerMigration("v7") { db in
            // In-sleep signal aggregates cached from /v1/daily so the Sleep tab can display
            // SpO2, skin-temperature deviation, and respiration rate without a network round-trip.
            // All three are nullable: they require sufficient raw biometric data on the server.
            try db.alter(table: "dailyMetric") { t in
                t.add(column: "spo2Pct", .double)
                t.add(column: "skinTempDevC", .double)
                t.add(column: "respRateBpm", .double)
            }
        }
        migrator.registerMigration("v8") { db in
            // Journal, workouts, and Apple-Health daily aggregates.
            // journal: one row per (deviceId, day, question), user-answered daily prompts.
            try db.create(table: "journal") { t in
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("question", .text).notNull()
                t.column("answeredYes", .integer).notNull()
                t.column("notes", .text)
                t.primaryKey(["deviceId", "day", "question"])
            }
            // workout: one row per (deviceId, startTs, sport). All metric columns nullable.
            try db.create(table: "workout") { t in
                t.column("deviceId", .text).notNull()
                t.column("startTs", .integer).notNull()
                t.column("endTs", .integer).notNull()
                t.column("sport", .text).notNull()
                t.column("source", .text).notNull()
                t.column("durationS", .double)
                t.column("energyKcal", .double)
                t.column("avgHr", .integer)
                t.column("maxHr", .integer)
                t.column("strain", .double)
                t.column("distanceM", .double)
                t.column("zonesJSON", .text)
                t.column("notes", .text)
                t.primaryKey(["deviceId", "startTs", "sport"])
            }
            // appleDaily: Apple-Health-specific daily aggregates, one row per (deviceId, day).
            // All metric columns nullable.
            try db.create(table: "appleDaily") { t in
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("steps", .integer)
                t.column("activeKcal", .double)
                t.column("basalKcal", .double)
                t.column("vo2max", .double)
                t.column("avgHr", .integer)
                t.column("maxHr", .integer)
                t.column("walkingHr", .integer)
                t.column("weightKg", .double)
                t.primaryKey(["deviceId", "day"])
            }
        }
        migrator.registerMigration("v9") { db in
            // Generic long-format metric store: the substrate for a metric explorer where every
            // metric is queryable/comparable uniformly. One row per (deviceId, day, key); `value`
            // is always a REAL so any scalar metric (server-derived, Apple-Health, journal-encoded,
            // …) can be projected into a single tall table and read back by key with no per-metric
            // schema. Natural key (deviceId, day, key).
            try db.create(table: "metricSeries") { t in
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("key", .text).notNull()
                t.column("value", .double).notNull()
                t.primaryKey(["deviceId", "day", "key"])
            }
            // Per-metric range reads scan (deviceId, key) then walk days in order. The PK is
            // (deviceId, day, key) so it can't serve those reads efficiently; this index makes
            // metricSeries(key:from:to:) and metricDays(key:) index-only.
            try db.create(index: "idx_metricSeries_device_key_day",
                          on: "metricSeries", columns: ["deviceId", "key", "day"])
        }

        // v10 (#78): WHOOP5 step_motion_counter persistence (macOS parity with Android's MIGRATION_2_3).
        // Additive only, the strap trims acked history and won't re-send it, so a destructive rebuild
        // would lose it; this preserves every existing row. No `synced` column (unused; see StreamStore).
        migrator.registerMigration("v10") { db in
            try db.create(table: "stepSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("counter", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }

        // v11: on-device daily step total + whole-day calorie estimate on dailyMetric (macOS parity
        // with Android's MIGRATION_2_3). Additive only; both nullable, so existing rows are untouched
        // and an old reader that doesn't SELECT them keeps working.
        migrator.registerMigration("v11") { db in
            try db.alter(table: "dailyMetric") { t in
                t.add(column: "steps", .integer)
                t.add(column: "activeKcalEst", .double)
            }
        }

        // v12 (#156): PPG-derived per-second HR from the WHOOP 5.0 v26 optical buffer. Stored in its OWN
        // table (not hrSample) so the measured `hr` is never conflated with the derived estimate, reads
        // COALESCE hrSample first, ppgHrSample only where hrSample has no row. Additive only; bpm/conf
        // are REAL (bpm is a float estimate, conf is the 0–1 autocorrelation peak).
        migrator.registerMigration("v12") { db in
            try db.create(table: "ppgHrSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("bpm", .double).notNull()
                t.column("conf", .double).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }

        // v13 (#318-adjacent): user-corrected sleep times. A `userEdited` flag on sleepSession marks a
        // session whose wake/sleep bounds the user fixed by hand; the post-sync recompute pass preserves
        // those bounds instead of re-upserting the strap-detected session over them (mirrors Android's
        // `userEdited` guard in IntelligenceEngine, PR #367). Additive + nullable-safe: NOT NULL DEFAULT 0
        // so every existing row reads as un-edited and old readers that don't SELECT it keep working.
        migrator.registerMigration("v13") { db in
            try db.alter(table: "sleepSession") { t in
                t.add(column: "userEdited", .boolean).notNull().defaults(to: false)
            }
        }

        // v14 (#318): user-corrected sleep ONSET. `startTs` stays the immutable detected key (so the
        // recompute guard and daily override keep matching on it); the hand-set bedtime lives here.
        // Nullable, null means "onset not edited, use startTs". Additive, so existing rows/readers are
        // unaffected.
        migrator.registerMigration("v14") { db in
            try db.alter(table: "sleepSession") { t in
                t.add(column: "startTsAdjusted", .integer)
            }
        }

        // v15: the device registry. `deviceId` already keys every sample table (deviceId, ts), so it IS
        // the per-device discriminator, this just gives each device a row with brand/model/capabilities,
        // a single-active invariant (enforced in DeviceRegistryStore), and a dayOwnership override table so
        // one source owns a day's scores (never blended). Additive: the existing WHOOP is seeded with its
        // unchanged id "my-whoop" (zero sample-row migration). INSERT OR IGNORE so re-runs/restores are safe.
        migrator.registerMigration("v15-device-registry") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS pairedDevice (
                    id TEXT PRIMARY KEY NOT NULL,
                    brand TEXT NOT NULL, model TEXT NOT NULL, nickname TEXT,
                    sourceKind TEXT NOT NULL, capabilities TEXT NOT NULL,  -- comma-joined Metric rawValues
                    status TEXT NOT NULL, addedAt INTEGER NOT NULL, lastSeenAt INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS dayOwnership (
                    day TEXT PRIMARY KEY NOT NULL,   -- "YYYY-MM-DD" local day
                    deviceId TEXT NOT NULL,          -- which device owns this day's displayed/scored metrics
                    locked INTEGER NOT NULL DEFAULT 0 -- 1 = explicit (import-overlap decision / user); 0 = resolver default
                );
            """)
            // Seed the registry with the existing WHOOP so nothing is orphaned. selectedWhoopModel lives in
            // the app's UserDefaults; the store can't read it, so seed a neutral "WHOOP" row the app reconciles
            // on first launch from the live model.
            let now = Int(Date().timeIntervalSince1970)
            try db.execute(sql: """
                INSERT OR IGNORE INTO pairedDevice (id, brand, model, nickname, sourceKind, capabilities, status, addedAt, lastSeenAt)
                VALUES ('my-whoop', 'WHOOP', 'WHOOP', NULL, 'liveBLE', 'hr,hrv,spo2,skinTemp,sleep,strainLoad', 'active', \(now), \(now));
            """)
        }

        // v16: stable per-strap identity for multi-WHOOP support. `peripheralId` holds the BLE
        // CBPeripheral.identifier.uuidString (iOS/Mac) so NOOP can tell physical straps apart and
        // map a connected peripheral back to its registry row. Additive + nullable: the seeded
        // 'my-whoop' row keeps peripheralId NULL (it still connects to "any WHOOP" today; it adopts
        // its peripheral id later). New straps get id "whoop-<peripheralId>". Old readers that don't
        // SELECT it keep working.
        migrator.registerMigration("v16-paired-device-peripheral") { db in
            try db.execute(sql: "ALTER TABLE pairedDevice ADD COLUMN peripheralId TEXT")
        }

        // v17 (Lab Book): the Health Records "marker" store, one row per dated reading the USER
        // entered themselves (spec 2026-06-19-v5-health-records-design.md §"New"). This is the richer
        // source-of-truth behind the daily `metricSeries` projection: a single day can hold several
        // readings, each carries a precise `takenAt` instant and `unit`, and notes / qualitative
        // (`valueText`) results don't fit a REAL-only `metricSeries` cell. Additive only, a NEW table,
        // no existing row touched, so an old reader is unaffected.
        //
        // NON-CLINICAL: holds ONLY user-entered values + an OPTIONAL user-entered `referenceText`
        // (their own report's range, shown back verbatim). NOOP ships no reference-range tables and
        // never asserts normality.
        //
        // `id` is a client-generated stable identifier (so a single reading can be edited/deleted by id
        // and a backup round-trips). The natural key (deviceId, markerKey, takenAt, source) is enforced
        // by a UNIQUE index so re-importing the same reading is idempotent. `value` is nullable (a
        // qualitative entry stores only `valueText`); `day` is the pre-derived yyyy-MM-dd key for the
        // projection. The (deviceId, markerKey, takenAt) index serves per-marker history reads in order.
        migrator.registerMigration("v17-lab-book") { db in
            try db.create(table: "labMarker") { t in
                t.column("id", .text).primaryKey()
                t.column("deviceId", .text).notNull()
                t.column("markerKey", .text).notNull()
                t.column("category", .text).notNull()
                t.column("day", .text).notNull()              // yyyy-MM-dd (projection key)
                t.column("takenAt", .integer).notNull()       // epoch seconds (precise instant)
                t.column("value", .double)                    // nullable: qualitative entries use valueText
                t.column("valueText", .text)
                t.column("unit", .text).notNull()
                t.column("source", .text).notNull()
                t.column("note", .text)
                t.column("referenceText", .text)              // user-entered range, verbatim
            }
            // Idempotent re-import: one reading per (deviceId, markerKey, takenAt, source).
            try db.create(index: "idx_labMarker_natural",
                          on: "labMarker",
                          columns: ["deviceId", "markerKey", "takenAt", "source"],
                          unique: true)
            // Per-marker history reads scan (deviceId, markerKey) then walk takenAt in order.
            try db.create(index: "idx_labMarker_device_marker_takenAt",
                          on: "labMarker", columns: ["deviceId", "markerKey", "takenAt"])
            // Per-category grouping for the Lab Book screen.
            try db.create(index: "idx_labMarker_device_category",
                          on: "labMarker", columns: ["deviceId", "category"])
        }

        // v18 (H8 + H2-persist): per-SLEEP-SESSION analytics the stager/interpreter already compute then
        // discard, banked alongside the existing `stagesJSON` on the same row (deviceId, startTs).
        //   • `motionJSON`, a compact JSON array of per-epoch motion magnitudes (the SleepStager's
        //                        per-epoch restlessness signal), one entry per stage epoch, SAME 30 s grid
        //                        as `stagesJSON`. Persisting it lets restlessness/wake-fragmentation read a
        //                        real per-epoch series instead of recomputing the whole stager.
        //   • `sleepStateJSON`, a compact JSON array of the decoded v18 band state per epoch (the
        //                        Interpreter's `(sb>>4)&3`), so the strap's own banked sleep/wake band is
        //                        durable rather than dropped after decode (H2 persist half).
        // Both nullable TEXT: every existing row reads back null (no per-epoch series yet), old readers that
        // don't SELECT them keep working, and a session with no raw/banked epoch data simply stores null,         // an ABSENT signal stays absent, never a fabricated zero series. Additive ALTERs only (no data
        // touched), so already-offloaded raw streams survive (the strap trims acked history and won't
        // re-send it). Twin of Android's MIGRATION_11_12.
        migrator.registerMigration("v18-sleep-motion-state") { db in
            try db.alter(table: "sleepSession") { t in
                t.add(column: "motionJSON", .text)
                t.add(column: "sleepStateJSON", .text)
            }
        }

        // v19 (#316 / @63 activity class): the per-record activity-class enum the decoder ALREADY reads off
        // @63 (0=still, 1=walk, 2=run; 0xFF/invalid stores nothing) but which was DROPPED at the storage
        // boundary, `StepSample` carried `activityClass` yet the v10 stepSample INSERT only listed
        // (deviceId, ts, counter), so it could never be persisted, read, or shown. This ALTER adds a NULLABLE
        // `activityClass INTEGER` to stepSample: additive only, no DEFAULT (a null means "no class for this
        // record", an absent signal stays absent, never a fabricated 0/"still"), so every existing row reads
        // back null and an old reader that doesn't SELECT it keeps working. Already-offloaded raw streams
        // survive (the strap trims acked history and won't re-send it). Twin of Android's MIGRATION_12_13.
        migrator.registerMigration("v19-step-activity-class") { db in
            try db.alter(table: "stepSample") { t in
                t.add(column: "activityClass", .integer)
            }
        }

        // v20 (#322 / task #53 numeric journal): a journal entry can carry a NUMERIC value (e.g.
        // "caffeine mg", "alcohol units") alongside the yes/no answer, not only a toggle. This ALTER adds
        // a NULLABLE `numericValue REAL` to `journal`: additive only, no DEFAULT (a null means "this row is
        // a plain yes/no answer with no numeric reading", which is every existing row + every imported WHOOP
        // row, so history reads back unchanged). A numeric log writes answeredYes=1 AND numericValue=v, so
        // the existing BehaviorInsights with/without split keeps working untouched; the value is carried for
        // dose-response later. Twin of Android's MIGRATION_13_14.
        migrator.registerMigration("v20-journal-numeric") { db in
            try db.alter(table: "journal") { t in
                t.add(column: "numericValue", .double)
            }
        }

        // v21 (#175 band sleep-state stream): the strap's OWN per-record band sleep_state (Interpreter's
        // @81 `(sb>>4)&3`: 0 wake / 1 still / 2 asleep / 3 up) was DECODED but DROPPED at stream extraction —
        // so the whole band-state chain (the H7 morning-stillness re-onset CONFIRM guard + a Deep Timeline
        // display track) had no source, and the v18 `sleepStateJSON` per-session column was never fed. This
        // adds the RAW per-sample table, keyed by (deviceId, ts) exactly like stepSample/ppgHrSample, so a
        // second's band state is idempotently upserted (ON CONFLICT DO NOTHING) from the offload stream. New
        // table only (no existing data touched); already-offloaded history the strap has trimmed can't be
        // re-sent, so this is forward-looking for straps that emit the field (5/MG v18). `state` is the raw
        // 0-3 code carried VERBATIM — never a fabricated value; a strap that never reports it just has no rows.
        // Twin of Android's MIGRATION_14_15.
        migrator.registerMigration("v21-sleep-state-sample") { db in
            try db.create(table: "sleepStateSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("state", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }

        // v22 (Live Sessions): one row per silent-guardian coaching session. Natural key (deviceId, startTs).
        // Records the recovery-gated band it guarded (floor/ceiling bpm) + today's Charge at start, the time
        // split (in-band / below / above seconds), the two cue counts, and the HR source used, so the look-back
        // summary + the streak read entirely from here. `endTs` is nullable while a session is in progress
        // (a crash/kill leaves it open; the app closes it on next launch). All totals NOT NULL DEFAULT 0 so a
        // zero-length session reads cleanly. Additive, NEW table only (no existing row touched), so an old
        // reader is unaffected. See docs/superpowers/specs/2026-07-04-live-sessions-design.md. Twin of
        // Android's MIGRATION_15_16.
        migrator.registerMigration("v22-live-session") { db in
            try db.create(table: "liveSession") { t in
                t.column("deviceId", .text).notNull()
                t.column("startTs", .integer).notNull()
                t.column("endTs", .integer)
                t.column("chargeAtStart", .double)
                t.column("floorBpm", .double).notNull()
                t.column("ceilingBpm", .double).notNull()
                t.column("inBandSec", .double).notNull().defaults(to: 0)
                t.column("belowSec", .double).notNull().defaults(to: 0)
                t.column("aboveSec", .double).notNull().defaults(to: 0)
                t.column("pushCount", .integer).notNull().defaults(to: 0)
                t.column("easeCount", .integer).notNull().defaults(to: 0)
                t.column("hrSource", .text).notNull()
                t.primaryKey(["deviceId", "startTs"])
            }
        }
        migrator.registerMigration("v23-daily-spo2-raw") { db in
            // WHOOP 4.0 raw SpO2 PPG ADC means (red/IR) over detected sleep, cached beside the other
            // in-sleep aggregates (#93). ADDITIVE, mirroring v7's SpO2/skin-temp/resp add: two nullable
            // INTEGER columns. Existing rows read NULL (no rebuild, no data loss), so an older database
            // upgraded in place is unaffected — non-4.0 nights + pre-upgrade rows simply stay nil.
            try db.alter(table: "dailyMetric") { t in
                t.add(column: "spo2Red", .integer)
                t.add(column: "spo2Ir", .integer)
            }
        }
        migrator.registerMigration("v24-rr-seq") { db in
            // Widen rrInterval's PK to (deviceId, ts, rrMs, seq). The value-only key + ON CONFLICT DO
            // NOTHING silently dropped the second of two EQUAL successive R-R intervals in one 1-second
            // ts bucket, removing a zero-difference beat and biasing RMSSD/HRV high at rest/sleep (when
            // HRV is scored). `seq` distinguishes equal (ts, rrMs) beats; distinct beats keep seq 0.
            // Android parity: Room v18 (#163). SQLite can't ALTER a PK, so REBUILD — LOSS-LESS: every row
            // copied with seq = 0, exact because the old PK made (deviceId, ts, rrMs) unique per row.
            // Forward-only: already-dropped beats can't be recovered. rrInterval is a leaf table (no FKs
            // in or out), so the drop/rename is safe.
            try db.create(table: "rrInterval_new") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("rrMs", .integer).notNull()
                t.column("seq", .integer).notNull().defaults(to: 0)
                t.column("synced", .integer).notNull().defaults(to: 0)
                t.primaryKey(["deviceId", "ts", "rrMs", "seq"])
            }
            try db.execute(sql: """
                INSERT INTO rrInterval_new (deviceId, ts, rrMs, seq, synced)
                SELECT deviceId, ts, rrMs, 0, synced FROM rrInterval
                """)
            try db.execute(sql: "DROP TABLE rrInterval")
            try db.execute(sql: "ALTER TABLE rrInterval_new RENAME TO rrInterval")
        }

        // v25: Oura live-API raw payload archive (lossless) behind the opt-in cloud import. One row per
        // fetched page, keyed (deviceId, endpoint, documentId); payloadJSON holds the verbatim page body
        // so any field can be re-derived later without re-fetching from the API. Additive only — a NEW
        // table, no existing row touched, old readers unaffected. Numbered v25: upstream's v24-rr-seq
        // landed in the same window and registers first to keep the sequence.
        migrator.registerMigration("v25-oura-raw") { db in
            try db.create(table: "ouraRaw") { t in
                t.column("deviceId", .text).notNull()
                t.column("endpoint", .text).notNull()       // "sleep" | "daily_readiness" | "heartrate" | …
                t.column("documentId", .text).notNull()     // synthesized page key (endpoint + window + index)
                t.column("day", .text)                       // YYYY-MM-DD when day-keyed (nullable)
                t.column("payloadJSON", .text).notNull()     // verbatim page body
                t.column("fetchedAt", .integer).notNull()    // unix seconds
                t.primaryKey(["deviceId", "endpoint", "documentId"])
            }
            // Per-endpoint reads scan (deviceId, endpoint) then walk day in order.
            try db.create(index: "idx_ouraRaw_device_endpoint_day",
                          on: "ouraRaw", columns: ["deviceId", "endpoint", "day"])
        }

        // v26 (Oura efficiency unit heal): the Oura API importer (OuraApiParser.swift) wrote Oura's
        // native 0-100 integer `efficiency` straight into sleepSession.efficiency / dailyMetric.efficiency,
        // but NOOP's own sleep pipeline (StrandAnalytics) stores that shared column as a 0-1 FRACTION
        // everywhere it computes it (asleep ÷ in-bed) — same column, two scales for oura-api rows written
        // before the importer fix. UPDATE-only, NO schema change: divides `efficiency` by 100 for every
        // row where it's > 1.5 — a threshold no genuine fraction can exceed (the column's convention
        // caps at 1.0: `AnalyticsEngine` writes actual-sleep ÷ in-bed) and no genuine percent-scale
        // leftover can fall under (no real night is ≤1.5% efficient), so the predicate can't touch an
        // already-correct row and a second run finds nothing left: idempotent. Deliberately NOT
        // deviceId-scoped: both known percent writers are healed by the same predicate — the Oura API
        // importer ('oura-api' rows) and the WHOOP CSV importer (rows under whatever strap deviceId the
        // user imported into). No Android Room migration twin in this PR: the Kotlin CSV importer gets
        // the same write-boundary fix, but healing Android's historical rows needs a Room migration a
        // maintainer should own (schema-version bump + column-order pinning).
        migrator.registerMigration("v26-efficiency-heal") { db in
            try db.execute(sql: """
                UPDATE sleepSession SET efficiency = efficiency / 100.0
                WHERE efficiency > 1.5
                """)
            try db.execute(sql: """
                UPDATE dailyMetric SET efficiency = efficiency / 100.0
                WHERE efficiency > 1.5
                """)
        }

        // v27 (issue #156 follow-up): durable storage for the WHOOP 5.0 v26 optical PPG waveform. The
        // strap's 24 Hz buffer was fully DECODED (`ppg_waveform`, 24 i16 ADC samples/record) but only
        // ever used to derive a per-second HR estimate (`ppgHrSample`, v12) — the waveform itself was
        // discarded right after, and `rejectedHistoricalRecords` explicitly excludes v26 from the
        // undecodable-record reject archive ("known-and-unstored by design"), so it had no home at all.
        //
        // One row per (deviceId, ts) — the SAME shape as every other per-second decoded stream (hrSample,
        // spo2Sample, ppgHrSample, …) — but the 24 samples are packed into a compact BLOB (2 bytes/sample,
        // little-endian i16, `WhoopStore.packPpgSamples`/`unpackPpgSamples`) instead of 24 scalar rows.
        // That keeps a v26-heavy night to roughly the same order of magnitude as ONE extra per-second
        // stream (≈50 bytes/row), not 24x that. Additive only, a NEW table, no existing row touched.
        //
        // Retention: no pruning, matching every other durable per-second table (hrSample, spo2Sample, …
        // are never pruned either) — this is decoded biometric history, not the transient raw outbox.
        // `PrunePolicy`'s ~50 MB cap governs ONLY `rawBatch` (raw, pre-decode frames kept for re-decode /
        // re-sync); it is untouched by and unrelated to this table. Growth here is bounded by how much
        // v26 data a strap actually emits (firmware chooses v26 vs v18 per second, not every night is
        // v26-heavy), not by an artificial cap.
        //
        // CONSUMER STATUS — deliberately none, and stated here so nobody has to re-derive it. The writer is
        // live on both platforms (offload + archive replay + the Android capture importer), but the reader
        // `ppgWaveformSamples` has ZERO production callers on either platform: five test call sites on the
        // Swift side, none at all on Android. No analytic, no UI, no export, no diagnostic reads a waveform
        // row. That is the intended shape — the project's rule is to land unvalidated sensor work as
        // instrumentation (decode + store, never a score; see CLAUDE.md and the withdrawn #194 PPG->HR
        // estimate), and this table exists so a BETTER estimator, HRV-from-PPG, or a waveform viewer can
        // later run over the ORIGINAL samples rather than the derived bpm. Do NOT "clean up" the reader as
        // dead code: the rows are the point, and the reader is how they are reachable.
        //
        // Note the sharp distinction from `ppgHrSample` (v12), which is the DERIVED per-second HR estimate
        // and IS fully consumed in production (COALESCEd with measured HR in the primary series). The
        // derivation happens in memory inside `extractHistoricalStreams` and never reads back from this
        // table, so these rows are not on any scoring path at all.
        migrator.registerMigration("v27-ppg-waveform") { db in
            try db.create(table: "ppgWaveformSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("samples", .blob).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }

        // #423: WHOOP 5/MG raw-IMU offload capture (100 Hz 6-axis). `samples` is a packed i16 LE BLOB of
        // the six wire columns (ax…az,gx…gz). Twin of the Android `rawImuSample` table (MIGRATION_20_21);
        // same column order + PK so a `.noopbak` round-trips byte-for-byte.
        migrator.registerMigration("v28-raw-imu") { db in
            try db.create(table: "rawImuSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("samples", .blob).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }

        // v29: provenance for NOOP-computed headline scores. This is deliberately separate from
        // `dayOwnership`: ownership controls which device is allowed to supply a day's raw inputs,
        // while this table records which source actually supplied each persisted computed metric.
        // Metric-level keys keep mixed-source days honest and make missing legacy metadata explicit.
        migrator.registerMigration("v29-score-input-provenance") { db in
            try db.create(table: "scoreInputProvenance") { t in
                t.column("deviceId", .text).notNull()   // computed "-noop" namespace
                t.column("day", .text).notNull()
                t.column("key", .text).notNull()
                t.column("sourceId", .text).notNull()
                t.primaryKey(["deviceId", "day", "key"])
            }
            try db.create(index: "idx_scoreInputProvenance_source",
                          on: "scoreInputProvenance", columns: ["sourceId"])
        }

        // v30 (#823): record each R-R beat's EMISSION order within its second. Reads ordered by
        // `rrMs`, i.e. by VALUE, which makes successive beats similar by construction and biases
        // RMSSD — built entirely from successive differences — DOWNWARD. `seq` cannot serve here:
        // it counts repeats of an identical (ts, rrMs) beat, so every DISTINCT beat in a second
        // carries seq 0 and they all tie.
        //
        // Additive nullable column, no table rebuild, no existing row touched. Deliberately NOT in
        // the primary key, which stays (deviceId, ts, rrMs, seq) from v24 — an insertion counter in
        // the key would collide distinct beats arriving in separate batches, the data-loss
        // regression the v24 note warns about. `ord` only informs read order.
        //
        // Pre-v30 rows stay NULL: the order was never recorded, so it cannot be backfilled and a
        // guess would be worse than an admission. SQLite sorts NULL first in ASC, so an all-NULL
        // second ties on `ord` and falls through to the old (rrMs, seq) order, unchanged.
        //
        // Twin of Room MIGRATION_23_24. Both stores are SQLite, so NULL-ordering matches exactly.
        migrator.registerMigration("v30-rr-ord") { db in
            try db.alter(table: "rrInterval") { t in
                t.add(column: "ord", .integer)
            }
        }

        // v31: stop DISCARDING four per-second channels the 5/MG v18 decoder already produces.
        //
        // `extractHistoricalStreams` is a narrow funnel — a field the Interpreter decodes but the funnel
        // does not name is computed and dropped one line later. That drop is PERMANENT: the strap trims
        // its banked history as soon as NOOP acks the offload, so the seconds are not re-fetchable. The
        // four channels below have been decoded (and pinned by the cross-platform decoder oracle) since
        // the v18 layout was mapped, and stored nowhere.
        //
        //   gravitySample.dynAccel    `dynamic_acceleration@41` (f32 g) — the strap's OWN gravity-removed
        //                             motion magnitude, computed on-device from the full-rate IMU. NOOP's
        //                             motion spine instead derives stillness from `gravityDeltas`, the L2
        //                             distance between consecutive 1 Hz gravity vectors. That proxy sees
        //                             orientation CHANGE at 1 Hz, not acceleration, so the two are not the
        //                             same measurement; this column puts the strap's own number BESIDE the
        //                             incumbent, which is the only way a later comparison on real nights
        //                             becomes possible.
        //   sleepStateSample.rawByte  the WHOLE @81 flag byte. v21 stored only `(byte >> 4) & 3` as
        //                             `state`; b0-1 `onwrist` and b2-3 `wake_quality` are decoded and were
        //                             dropped, and b6-7 have no interpretation at all (0 across every
        //                             capture held here). `state` is untouched, so #175 behavior is
        //                             bit-identical.
        //   skinTempSample.aux1Raw    `temp_aux_1_raw@69` / `temp_aux_2_raw@71` (i16, °C = value/10, a
        //   skinTempSample.aux2Raw    DIFFERENT scale from the primary's /100). Two further thermal
        //                             channels that track the primary closely (corr ~0.92 / ~0.97) with
        //                             the same diurnal curve.
        //
        // Additive nullable ALTERs only: no table rebuild, no row touched, no key changed. Every existing
        // row reads back NULL and an old reader that does not SELECT the columns is unaffected. NULL is
        // load-bearing here and no column carries a DEFAULT — a WHOOP 4.0 never emits any of these, and
        // history banked before this migration cannot be backfilled (the strap already trimmed it), so an
        // absent channel must stay absent rather than become a fabricated 0.
        //
        // INSTRUMENTATION ONLY. Nothing reads these columns: no analytic, no score, no gate, no UI. That
        // is deliberate — see the "validate against the artifact, not one match" rule in CLAUDE.md. The
        // point of this migration is that the data starts accruing NOW so a validated consumer is possible
        // LATER; landing a consumer at the same time would be scoring on evidence that does not exist yet.
        //
        // CONSUMER STATUS — deliberately none, stated here so nobody has to re-derive it, and in the same
        // shape as the `ppgWaveformSample` note above (v27). The writers are live on both platforms, but
        // every `v18AuxSamples` call site on BOTH platforms is a TEST: no analytic, no score, no gate, no
        // UI, no export reads a row. **Do NOT "clean up" the reader as dead code** — the rows are the point,
        // and the reader is how they become reachable once a consumer is validated. The same applies to the
        // four named columns added just below (`gravitySample.dynAccel`, `sleepStateSample.rawByte`,
        // `skinTempSample.aux1Raw/aux2Raw`): they are SELECTed into their structs, and no consumer touches
        // the properties, on purpose.
        //
        // Why the rows still matter even unread: before this migration these fields were not merely unread,
        // they were DESTROYED. The strap trims its history the moment an offload is acked, so every one of
        // them was unrecoverable. This migration converts permanent loss into retained-but-unread, which is
        // the whole fix and is complete. Fifteen of the slots are unpinned bytes whose names deliberately
        // assert nothing; wiring them to anything before a census would be exactly the overclaiming this
        // project has already had to retract. The capture IS the deliverable.
        //
        // The remaining fifteen v18 slots go to their OWN narrow table rather than fifteen more columns
        // (see `V18AuxCodec` for the wire format and the column-vs-blob tradeoff). Three reasons this is
        // a table and not another column on an existing row:
        //   1. No existing per-second table is guaranteed present. `gravitySample` needs `gravity_x` to
        //      decode, `skinTempSample` needs @73 to clear its thermal gate, `hrSample` skips bpm=0. A v18
        //      record can carry aux fields while every one of those gated out, so hanging the blob off any
        //      of them would silently drop records.
        //   2. It keeps fifteen unpinned bytes out of the tables analytics actually read.
        //   3. It can be dropped or re-shaped later without touching a scored table.
        // `fields` is NOT NULL because a row is only written when at least one slot is present — absence is
        // encoded as "no row", and within a row as a clear bitmap bit, never as a fabricated 0.
        //
        // Retention: `v18AuxSample` is CAPPED, `rawImuSample`-style, at `WhoopStore.v18AuxRetentionRows`
        // rows per device (rolling, newest-first). It is the only genuinely new row growth here — the four
        // named columns widen rows that were already being written (~14 B on a gravity/skinTemp/sleepState
        // row that exists either way) and add no rows at all, so they inherit whatever retention their
        // tables have. `PrunePolicy`'s ~50 MB cap governs only `rawBatch`. The table is also added to the
        // storage-stats readout, because visible growth and bounded growth are different guarantees and
        // an instrumentation table nothing reads should have both.
        //
        // Twin of Room MIGRATION_24_25.
        migrator.registerMigration("v31-deep-capture-channels") { db in
            try db.alter(table: "gravitySample") { t in
                t.add(column: "dynAccel", .double)
            }
            try db.alter(table: "sleepStateSample") { t in
                t.add(column: "rawByte", .integer)
            }
            try db.alter(table: "skinTempSample") { t in
                t.add(column: "aux1Raw", .integer)
                t.add(column: "aux2Raw", .integer)
            }
            try db.create(table: "v18AuxSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("fields", .blob).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }

        // v32 (#1071): record WHICH sensor channel produced each R-R beat.
        //
        // An Oura ring reports the SAME heartbeats on more than one tag, and every one of them decoded to
        // `OuraEvent.ibi` and landed here untagged. Measured over one 488-min sleep window: 61,524 beats
        // stored where the measured HR curve allows 29,800 (2.06x), and sum(rrMs)/wall-clock = 2.17x. The
        // two are separable after the fact only by the accident that their quantisation grids differ
        // (0x6E is `byte * 8`, always a multiple of 8; 0x80 is an 11-bit value on the 1 ms grid), and the
        // 8 ms stream is ABSENT until SpO2 measurement starts and then tracks its duty cycle exactly —
        // which is what proves these are two channels rather than accumulated re-syncs.
        //
        // The damage is to the VARIABILITY statistics, not the level: a duplicated beat train leaves
        // meanNN (and so resting HR) correct while RMSSD/SDNN are built entirely from successive
        // differences and collapse. The app's own `hrv diag` line has been reporting it as
        // `coverage=2.21 rrIntegrity=crossSecondOverCount` with a non-physiological ~200 ms nocturnal SDNN.
        //
        // NOT a de-duplication: both rows are real measurements of the same beat by different optics, and
        // the second channel is the obvious future cross-check on the first. So nothing is deleted and
        // nothing is rewritten — the column labels the source and `Reads.rrIntervals` filters at READ.
        //
        // Additive nullable column, the v30-rr-ord form: no table rebuild, no existing row touched, and
        // deliberately NOT in the primary key, which stays (deviceId, ts, rrMs, seq) from v24. Putting it
        // in the key would make the SAME beat insertable twice under two labels, the data-loss/duplication
        // regression the v24 note warns about from the other direction.
        //
        // Pre-v32 rows stay NULL and are still READ (a WHOOP row is legitimately NULL forever — one beat
        // source, no channel to name — so a filter that dropped NULL would silently delete every WHOOP
        // night from scoring). Historical Oura rows therefore keep their old inflated coverage; they were
        // never labelled, and a backfill would be a guess. For the record, since this is how the defect
        // was diagnosed: in an existing DB the two channels remain separable by `rrMs % 8`, an 0x6E row
        // always being a multiple of 8 and an 0x80 row landing there only 1 time in 8 by chance.
        //
        // Values are `RRSourceChannel.rawValue` (1 green / 2 spo2 / 3 ibiAmplitude), a DURABLE wire format
        // shared with Kotlin `RrSourceChannel`. INTEGER rather than a text label because `rrInterval` is
        // the highest-volume table in the schema (~60k rows a night) and this column rides every one.
        //
        // Twin of Room MIGRATION_25_26.
        migrator.registerMigration("v32-rr-src-channel") { db in
            try db.alter(table: "rrInterval") { t in
                t.add(column: "srcChannel", .integer)
            }
        }
        // #1058: per-session step count on a workout. Activity-file imports previously stored steps only
        // as a whole-day DailyMetric row keyed on (deviceId, day), so a SECOND file for the same day
        // overwrote the first's steps instead of adding. With steps on the session, the day total is
        // recomputed as SUM over that day's sessions — additive across files, idempotent on re-import.
        // Nullable; only foot-sport activity-file sessions populate it (a strap never writes it).
        migrator.registerMigration("v33-workout-steps") { db in
            try db.alter(table: "workout") { t in
                t.add(column: "steps", .integer)
            }
        }
        return migrator
    }
}
