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
            // journal: one row per (deviceId, day, question) — user-answered daily prompts.
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
        // Additive only — the strap trims acked history and won't re-send it, so a destructive rebuild
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
        // table (not hrSample) so the measured `hr` is never conflated with the derived estimate — reads
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
        // Nullable — null means "onset not edited, use startTs". Additive, so existing rows/readers are
        // unaffected.
        migrator.registerMigration("v14") { db in
            try db.alter(table: "sleepSession") { t in
                t.add(column: "startTsAdjusted", .integer)
            }
        }

        // v15: the device registry. `deviceId` already keys every sample table (deviceId, ts), so it IS
        // the per-device discriminator — this just gives each device a row with brand/model/capabilities,
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

        // v17 (Lab Book): the Health Records "marker" store — one row per dated reading the USER
        // entered themselves (spec 2026-06-19-v5-health-records-design.md §"New"). This is the richer
        // source-of-truth behind the daily `metricSeries` projection: a single day can hold several
        // readings, each carries a precise `takenAt` instant and `unit`, and notes / qualitative
        // (`valueText`) results don't fit a REAL-only `metricSeries` cell. Additive only — a NEW table,
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
        return migrator
    }
}
