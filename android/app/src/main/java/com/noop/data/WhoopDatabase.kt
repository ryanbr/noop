package com.noop.data

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

/**
 * Local Room database, the Android port of the GRDB store in
 * Packages/WhoopStore (Database.swift schema). Holds phone-collected raw streams
 * AND the offline cache of server-computed derived metrics.
 *
 * The schema bundles every Swift migration (v1..v9) into a single fresh shape, since the
 * Android app starts from an empty store (no in-place migration from a prior Android version).
 * version 2 added the v8 journal/workout/appleDaily caches. **v3 (#78)** adds the stepSample table
 * + dailyMetric.steps/activeKcalEst via a REAL additive migration (MIGRATION_2_3), NOT a destructive
 * rebuild, so a user's already-offloaded raw streams survive (the strap trims acked history and won't
 * re-send it). The destructive fallback is deliberately GONE: a hand-written-SQL mismatch would
 * otherwise SILENTLY wipe that history; without the fallback Room throws loudly instead, and
 * MigrationRoundTripTest guards the SQL in CI.
 */
@Database(
    entities = [
        DeviceRow::class,
        HrSample::class,
        RrInterval::class,
        EventRow::class,
        BatterySample::class,
        Spo2Sample::class,
        SkinTempSample::class,
        StepSample::class,
        SleepStateSampleEntity::class,
        RespSample::class,
        GravitySample::class,
        DailyMetric::class,
        SleepSession::class,
        MetricSeriesRow::class,
        ScoreInputProvenanceRow::class,
        JournalEntry::class,
        WorkoutRow::class,
        DismissedWorkout::class,
        DismissedSleep::class,
        AppleDaily::class,
        PpgHrSample::class,
        PairedDeviceRow::class,
        DayOwnershipRow::class,
        LabMarkerRow::class,
        LiveSessionRow::class,
        PpgWaveformSampleEntity::class,
        RawImuSampleEntity::class,
        V18AuxSampleEntity::class,
    ],
    version = 29,
    // #775: ON so Room's KSP processor writes the generated schema (every table's exact `CREATE TABLE`,
    // columns in declaration order with affinity/NOT NULL/default, PK and indices) as JSON. That export
    // is what lets a plain JVM test — no device, no Robolectric — read Android's REAL schema and compare
    // it to the shared Room<->GRDB `schema_oracle.json`. Written to the build directory, not the repo
    // (see `room.schemaLocation` in app/build.gradle.kts). Enabling the export changes NO runtime
    // behaviour: it emits a build artifact and nothing else. In particular it does NOT reinstate a
    // destructive migration fallback — the reasoning below stands unchanged.
    exportSchema = true,
)
abstract class WhoopDatabase : RoomDatabase() {
    abstract fun whoopDao(): WhoopDao

    companion object {
        const val DB_NAME = "noop_whoop.db"

        @Volatile
        private var instance: WhoopDatabase? = null

        /** Process-wide singleton. Safe to call from any thread. */
        fun get(context: Context): WhoopDatabase =
            instance ?: synchronized(this) {
                instance ?: build(context.applicationContext).also { instance = it }
            }

        /**
         * Close and forget the singleton so all file handles on [DB_NAME] are released.
         * The next [get] call rebuilds against whatever file is on disk, used by
         * [DataBackup.importFrom] to swap the database file underneath the app.
         */
        fun close() {
            synchronized(this) {
                instance?.close()
                instance = null
            }
        }

        /**
         * v2 → v3: ADDITIVE ONLY, adds the stepSample table + dailyMetric.steps/activeKcalEst.
         * A real (non-destructive) migration so an existing user's already-offloaded raw streams are
         * PRESERVED (the strap trims acked history chunks and will not re-send them, so a destructive
         * rebuild would lose that history permanently). The SQL MUST match Room's generated schema
         * exactly, NOT NULL for `synced` (Kotlin default, no SQL DEFAULT), nullable INTEGER/REAL for
         * the two new dailyMetric columns. Guarded by MigrationRoundTripTest.
         */
        internal val MIGRATION_2_3 = object : Migration(2, 3) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `stepSample` (`deviceId` TEXT NOT NULL, " +
                        "`ts` INTEGER NOT NULL, `counter` INTEGER NOT NULL, " +
                        "`synced` INTEGER NOT NULL, PRIMARY KEY(`deviceId`, `ts`))",
                )
                db.execSQL("ALTER TABLE `dailyMetric` ADD COLUMN `steps` INTEGER")
                db.execSQL("ALTER TABLE `dailyMetric` ADD COLUMN `activeKcalEst` REAL")
            }
        }

        /**
         * v3 -> v4: ADDITIVE, adds `workout.routePolyline` (nullable TEXT) for GPS routes. Nullable so
         * existing workouts migrate untouched; the SQL must match Room's generated schema for a `String?`
         * column exactly (TEXT, no NOT NULL, no default). Mirrors MIGRATION_2_3's additive form.
         */
        internal val MIGRATION_3_4 = object : Migration(3, 4) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `workout` ADD COLUMN `routePolyline` TEXT")
            }
        }

        /**
         * v4 -> v5: ADDITIVE, adds the `dismissedWorkout` table (#107): a durable marker that keeps a
         * dismissed auto-detected bout hidden after the engine re-derives it. CREATE TABLE only (no
         * data touched), so existing workouts/history are untouched. The SQL MUST match Room's
         * generated schema for the [DismissedWorkout] entity exactly, all three PK columns NOT NULL,
         * composite PRIMARY KEY in declaration order. Guarded by MigrationRoundTripTest like the others.
         */
        internal val MIGRATION_4_5 = object : Migration(4, 5) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `dismissedWorkout` (`deviceId` TEXT NOT NULL, " +
                        "`startTs` INTEGER NOT NULL, `endTs` INTEGER NOT NULL, " +
                        "PRIMARY KEY(`deviceId`, `startTs`))",
                )
            }
        }

        /**
         * v5 -> v6: ADDITIVE, adds the `ppgHrSample` table (#156): HR derived from the WHOOP 5/MG
         * v26 optical PPG waveform (autocorrelation). CREATE TABLE only (no existing data touched), so
         * already-offloaded raw streams survive (the strap trims acked history and won't re-send it).
         * The SQL MUST match Room's generated schema for [PpgHrSample] exactly, every column NOT NULL
         * (Kotlin defaults, no SQL DEFAULT), `conf` is REAL, composite PRIMARY KEY (deviceId, ts) in
         * declaration order. Guarded by MigrationRoundTripTest like the others.
         */
        internal val MIGRATION_5_6 = object : Migration(5, 6) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `ppgHrSample` (`deviceId` TEXT NOT NULL, " +
                        "`ts` INTEGER NOT NULL, `bpm` INTEGER NOT NULL, `conf` REAL NOT NULL, " +
                        "`synced` INTEGER NOT NULL, PRIMARY KEY(`deviceId`, `ts`))",
                )
            }
        }

        /**
         * v6 -> v7: ADDITIVE, adds `sleepSession.userEdited` + `sleepSession.startTsAdjusted` for
         * durable bed/wake editing (port of iOS PR #395, the GRDB v13 `userEdited` + v14
         * `startTsAdjusted` migrations). `userEdited` is a non-null Kotlin Boolean → Room stores it as
         * INTEGER NOT NULL DEFAULT 0; `startTsAdjusted` is a nullable Long → INTEGER (no NOT NULL).
         * Both are ALTER ... ADD COLUMN only (no data touched), so existing rows are untouched and read
         * back as userEdited=false / startTsAdjusted=null, exactly the additive, nullable-safe form of
         * MIGRATION_2_3. The SQL MUST match Room's generated schema for the new columns; like the
         * others this is the no-destructive-fallback path so a mismatch throws loudly instead of
         * silently wiping non-resendable strap history.
         */
        internal val MIGRATION_6_7 = object : Migration(6, 7) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `sleepSession` ADD COLUMN `userEdited` INTEGER NOT NULL DEFAULT 0")
                db.execSQL("ALTER TABLE `sleepSession` ADD COLUMN `startTsAdjusted` INTEGER")
            }
        }

        /**
         * v7 -> v8: ADDITIVE, adds the device registry (`pairedDevice` + `dayOwnership`), the Android
         * port of the Swift Database.swift v15 migration. CREATE TABLE only (no existing data touched),
         * so already-offloaded raw streams survive (the strap trims acked history and won't re-send it).
         *
         * The SQL MUST match Room's generated schema for [PairedDeviceRow]/[DayOwnershipRow] exactly:
         *  - pairedDevice: `nickname` is the only nullable column (TEXT, no NOT NULL); every other is
         *    NOT NULL with no SQL DEFAULT (Kotlin construction defaults don't emit a schema default).
         *  - dayOwnership: `locked` is a non-null Kotlin Boolean with a *constructor* default of false,          *    Room stores it as INTEGER NOT NULL with NO SQL DEFAULT (the Kotlin default never reaches the
         *    schema), so the migration must NOT add `DEFAULT 0` or MigrationRoundTripTest would flag a
         *    schema mismatch.
         *
         * Seeds the existing WHOOP with its unchanged id "my-whoop" (zero sample-row migration), brand/
         * model "WHOOP", sourceKind 'liveBLE', the full capability set, status 'active', and addedAt/
         * lastSeenAt = now (seconds). `INSERT OR IGNORE` so a re-run / backup-restore is a no-op. The
         * capabilities string + column order are byte-for-byte the Swift seed so a backup round-trips.
         * Like the others this is the no-destructive-fallback path: a mismatch throws loudly rather than
         * silently wiping non-resendable strap history; CI's MigrationRoundTripTest guards the SQL.
         */
        internal val MIGRATION_7_8 = object : Migration(7, 8) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `pairedDevice` (`id` TEXT NOT NULL, " +
                        "`brand` TEXT NOT NULL, `model` TEXT NOT NULL, `nickname` TEXT, " +
                        "`sourceKind` TEXT NOT NULL, `capabilities` TEXT NOT NULL, " +
                        "`status` TEXT NOT NULL, `addedAt` INTEGER NOT NULL, " +
                        "`lastSeenAt` INTEGER NOT NULL, PRIMARY KEY(`id`))",
                )
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `dayOwnership` (`day` TEXT NOT NULL, " +
                        "`deviceId` TEXT NOT NULL, `locked` INTEGER NOT NULL, PRIMARY KEY(`day`))",
                )
                val now = System.currentTimeMillis() / 1000
                db.execSQL(
                    "INSERT OR IGNORE INTO `pairedDevice` " +
                        "(`id`, `brand`, `model`, `nickname`, `sourceKind`, `capabilities`, " +
                        "`status`, `addedAt`, `lastSeenAt`) VALUES " +
                        "('my-whoop', 'WHOOP', 'WHOOP', NULL, 'liveBLE', " +
                        "'hr,hrv,spo2,skinTemp,sleep,strainLoad', 'active', $now, $now)",
                )
            }
        }

        /**
         * v8 -> v9: ADDITIVE, adds `pairedDevice.peripheralId` (nullable TEXT), the strap's stable BLE
         * peripheral identifier (the Android twin of the Swift Database.swift `peripheralId` migration).
         * On Android this is the [android.bluetooth.BluetoothDevice] MAC address; it lets the BLE client
         * pin a connect to ONE specific strap (multi-WHOOP) and lets a freshly-paired device be looked up
         * by its address.
         *
         * ALTER ... ADD COLUMN only (no data touched), so existing rows are untouched and read back with
         * `peripheralId = NULL`, including the seeded "my-whoop" row (WHOOP has no stored MAC until it is
         * (re)paired, fine). The SQL MUST match Room's generated column for a `String?` field exactly:
         * TEXT, no NOT NULL, no SQL DEFAULT (a Kotlin construction default never reaches the schema), the
         * additive, nullable-safe form of MIGRATION_3_4. Like the others this is the no-destructive-
         * fallback path: a mismatch throws loudly rather than silently wiping non-resendable strap history;
         * CI's MigrationRoundTripTest guards the SQL.
         */
        internal val MIGRATION_8_9 = object : Migration(8, 9) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `pairedDevice` ADD COLUMN `peripheralId` TEXT")
            }
        }

        /**
         * v9 -> v10: ADDITIVE, adds the `dismissedSleep` tombstone table (#33): a durable marker that
         * keeps a user-DELETED computed sleep night from regenerating on the next recompute. CREATE TABLE
         * only (no data touched), so already-offloaded raw streams survive. The SQL MUST match Room's
         * generated schema for [DismissedSleep] exactly, all three columns NOT NULL, composite PRIMARY
         * KEY (deviceId, startTs) in declaration order. Mirrors MIGRATION_4_5 (the dismissedWorkout table).
         */
        internal val MIGRATION_9_10 = object : Migration(9, 10) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `dismissedSleep` (`deviceId` TEXT NOT NULL, " +
                        "`startTs` INTEGER NOT NULL, `endTs` INTEGER NOT NULL, " +
                        "PRIMARY KEY(`deviceId`, `startTs`))",
                )
            }
        }

        /**
         * v10 -> v11: ADDITIVE, adds the `labMarker` table (Health Records "Lab Book" pillar), the
         * Android port of the Swift Database.swift v17 migration. One row per dated reading the USER
         * entered themselves; the daily `metricSeries` projection under source `lab-book` is how the
         * book talks to the rest of the app. CREATE TABLE + indexes only (no existing data touched),
         * so already-offloaded raw streams survive.
         *
         * NON-CLINICAL: the table holds ONLY user-entered values + an OPTIONAL user-entered
         * `referenceText` (their own report's range). No reference-range tables, no normality verdict.
         *
         * The SQL MUST match Room's generated schema for [LabMarkerRow] exactly:
         *  - PRIMARY KEY is the single TEXT `id`.
         *  - `value`, `valueText`, `note`, `referenceText` are the only nullable columns (Kotlin `?`,
         *    no NOT NULL); every other column is NOT NULL with NO SQL DEFAULT (a Kotlin construction
         *    default never reaches the schema).
         *  - Three indexes, byte-for-byte the Swift v17 indexes: a UNIQUE natural-key index plus two
         *    non-unique lookup indexes, with the exact names Room derives from the @Index annotations.
         * Like the others this is the no-destructive-fallback path: a mismatch throws loudly rather
         * than silently wiping non-resendable strap history.
         *
         * The SQL is exposed as the [LAB_MARKER_MIGRATION_SQL] constants (below) so a plain-JVM unit
         * test ([com.noop.data.LabMarkerMigrationTest]) can pin this shape WITHOUT needing Robolectric
         * or a fake SupportSQLiteDatabase. Edit the constants and the migration changes in lockstep.
         */
        internal val LAB_MARKER_CREATE_SQL =
            "CREATE TABLE IF NOT EXISTS `labMarker` (`id` TEXT NOT NULL, " +
                "`deviceId` TEXT NOT NULL, `markerKey` TEXT NOT NULL, " +
                "`category` TEXT NOT NULL, `day` TEXT NOT NULL, `takenAt` INTEGER NOT NULL, " +
                "`value` REAL, `valueText` TEXT, `unit` TEXT NOT NULL, `source` TEXT NOT NULL, " +
                "`note` TEXT, `referenceText` TEXT, PRIMARY KEY(`id`))"

        internal val LAB_MARKER_INDEX_SQL = listOf(
            "CREATE UNIQUE INDEX IF NOT EXISTS `idx_labMarker_natural` " +
                "ON `labMarker` (`deviceId`, `markerKey`, `takenAt`, `source`)",
            "CREATE INDEX IF NOT EXISTS `idx_labMarker_device_marker_takenAt` " +
                "ON `labMarker` (`deviceId`, `markerKey`, `takenAt`)",
            "CREATE INDEX IF NOT EXISTS `idx_labMarker_device_category` " +
                "ON `labMarker` (`deviceId`, `category`)",
        )

        /** All statements the migration runs, in order, the table then its indexes. */
        internal val LAB_MARKER_MIGRATION_SQL: List<String> =
            listOf(LAB_MARKER_CREATE_SQL) + LAB_MARKER_INDEX_SQL

        internal val MIGRATION_10_11 = object : Migration(10, 11) {
            override fun migrate(db: SupportSQLiteDatabase) {
                for (stmt in LAB_MARKER_MIGRATION_SQL) db.execSQL(stmt)
            }
        }

        /**
         * v11 -> v12: ADDITIVE, adds `sleepSession.motionJSON` + `sleepSession.sleepStateJSON` (nullable
         * TEXT), the Android port of the Swift WhoopStore v18 migration. Per-epoch analytics banked beside
         * the existing `stagesJSON` on the same row: the SleepStager's per-epoch motion magnitudes (H8) and
         * the decoded v18 band sleep_state per epoch (H2 persist half).
         *
         * ALTER ... ADD COLUMN only (no data touched), so existing rows are untouched and read back with
         * both columns = NULL, exactly the additive, nullable-safe form of MIGRATION_3_4 (already-offloaded
         * raw streams survive; the strap trims acked history and won't re-send it). The SQL MUST match Room's
         * generated column for a `String?` field exactly: TEXT, no NOT NULL, no SQL DEFAULT (a Kotlin
         * construction default never reaches the schema). Like the others this is the no-destructive-fallback
         * path: a mismatch throws loudly rather than silently wiping non-resendable history.
         *
         * The SQL is exposed as [SLEEP_MOTION_STATE_MIGRATION_SQL] so a plain-JVM unit test
         * ([com.noop.data.SleepMotionStateMigrationTest]) can pin this shape without Robolectric.
         */
        internal val SLEEP_MOTION_STATE_MIGRATION_SQL: List<String> = listOf(
            "ALTER TABLE `sleepSession` ADD COLUMN `motionJSON` TEXT",
            "ALTER TABLE `sleepSession` ADD COLUMN `sleepStateJSON` TEXT",
        )

        internal val MIGRATION_11_12 = object : Migration(11, 12) {
            override fun migrate(db: SupportSQLiteDatabase) {
                for (stmt in SLEEP_MOTION_STATE_MIGRATION_SQL) db.execSQL(stmt)
            }
        }

        /**
         * v12 -> v13: ADDITIVE, adds `stepSample.activityClass` (nullable INTEGER), the Android port of the
         * Swift WhoopStore v19 migration. The @63 activity-class enum (0=still, 1=walk, 2=run; null when the
         * byte was 0xFF/invalid/absent) the decoder ALREADY carries on [StepRow] but which was DROPPED at the
         * insert boundary, the v2_3 `stepSample` held only ts/counter, so a classed sample could never be
         * persisted, read, or shown. (#316)
         *
         * ALTER ... ADD COLUMN only (no data touched), so existing rows are untouched and read back with
         * `activityClass = NULL`, an absent class stays absent, never a fabricated 0/"still". The SQL MUST
         * match Room's generated column for an `Int?` field exactly: INTEGER, no NOT NULL, no SQL DEFAULT (a
         * Kotlin construction default never reaches the schema), the additive, nullable-safe form of
         * MIGRATION_3_4. Already-offloaded raw streams survive (the strap trims acked history and won't
         * re-send it). Like the others this is the no-destructive-fallback path: a mismatch throws loudly
         * rather than silently wiping non-resendable history.
         *
         * The SQL is exposed as [STEP_ACTIVITY_CLASS_MIGRATION_SQL] so a plain-JVM unit test
         * ([com.noop.data.StepActivityClassMigrationTest]) can pin this shape without Robolectric.
         */
        internal val STEP_ACTIVITY_CLASS_MIGRATION_SQL: List<String> = listOf(
            "ALTER TABLE `stepSample` ADD COLUMN `activityClass` INTEGER",
        )

        internal val MIGRATION_12_13 = object : Migration(12, 13) {
            override fun migrate(db: SupportSQLiteDatabase) {
                for (stmt in STEP_ACTIVITY_CLASS_MIGRATION_SQL) db.execSQL(stmt)
            }
        }

        /**
         * v13 -> v14: ADDITIVE, adds `journal.numericValue` (#322 / task #53). A journal entry can carry a
         * numeric value (caffeine mg, alcohol units) alongside the yes/no answer. A numeric log writes
         * answeredYes=1 AND numericValue=v, so the EffectRanker with/without split keeps working unchanged;
         * the value is carried for dose-response.
         *
         * ALTER ... ADD COLUMN only (no data touched): existing rows read back `numericValue = NULL`
         * (a plain yes/no answer with no numeric reading), an absent value stays absent, never a fabricated
         * 0. The SQL MUST match Room's generated column for a `Double?` field exactly: REAL, no NOT NULL, no
         * SQL DEFAULT, the additive, nullable-safe form of MIGRATION_3_4. Twin of the Swift WhoopStore v20
         * migration. No destructive fallback (see the class doc): a mismatch throws loudly rather than
         * silently wiping non-resendable strap history.
         *
         * The SQL is exposed as [JOURNAL_NUMERIC_MIGRATION_SQL] so a plain-JVM unit test
         * ([com.noop.data.JournalNumericMigrationTest]) can pin this shape without Robolectric.
         */
        internal val JOURNAL_NUMERIC_MIGRATION_SQL: List<String> = listOf(
            "ALTER TABLE `journal` ADD COLUMN `numericValue` REAL",
        )

        internal val MIGRATION_13_14 = object : Migration(13, 14) {
            override fun migrate(db: SupportSQLiteDatabase) {
                for (stmt in JOURNAL_NUMERIC_MIGRATION_SQL) db.execSQL(stmt)
            }
        }

        /**
         * v14 -> v15: ADDITIVE, adds the `sleepStateSample` table (#175). The strap's OWN band sleep_state
         * (the @81 high nibble: 0 wake/1 still/2 asleep/3 up) was DECODED but DROPPED at stream extraction,
         * so the band-state chain (the H7 morning-stillness re-onset CONFIRM guard + a Deep Timeline track)
         * had no source and the per-session `sleepStateJSON` column was never fed. This new RAW per-sample
         * table, keyed by (deviceId, ts) like stepSample/ppgHrSample, idempotently upserts a second's band
         * state from the offload stream. `state` is the raw 0-3 code carried VERBATIM — never a fabricated
         * value; a strap that never reports it simply has no rows.
         *
         * CREATE TABLE only (no existing data touched), so already-offloaded raw streams survive (the strap
         * trims acked history and won't re-send it). The SQL MUST match Room's generated schema for
         * [SleepStateSampleEntity] exactly, every column NOT NULL (Kotlin, no SQL DEFAULT), composite PRIMARY
         * KEY (deviceId, ts) in declaration order. Twin of the Swift WhoopStore v21 migration. No destructive
         * fallback (see the class doc). Exposed as [SLEEP_STATE_SAMPLE_MIGRATION_SQL] so a plain-JVM unit test
         * can pin the shape without Robolectric.
         */
        internal val SLEEP_STATE_SAMPLE_MIGRATION_SQL: List<String> = listOf(
            "CREATE TABLE IF NOT EXISTS `sleepStateSample` (`deviceId` TEXT NOT NULL, " +
                "`ts` INTEGER NOT NULL, `state` INTEGER NOT NULL, PRIMARY KEY(`deviceId`, `ts`))",
        )

        internal val MIGRATION_14_15 = object : Migration(14, 15) {
            override fun migrate(db: SupportSQLiteDatabase) {
                for (stmt in SLEEP_STATE_SAMPLE_MIGRATION_SQL) db.execSQL(stmt)
            }
        }

        /**
         * v15 -> v16: ADDITIVE, adds the `liveSession` table (Live Sessions). One row per silent-guardian
         * coaching session, natural key (deviceId, startTs); `endTs` null while in progress. Twin of the Swift
         * WhoopStore v22 migration. CREATE TABLE only (no existing data touched). The SQL MUST match Room's
         * generated schema for [LiveSessionRow] exactly: nullable `endTs`/`chargeAtStart` (no NOT NULL), the
         * rest NOT NULL (Kotlin non-null, no SQL DEFAULT), composite PRIMARY KEY (deviceId, startTs) in
         * declaration order. No destructive fallback (see the class doc). Exposed as [LIVE_SESSION_MIGRATION_SQL]
         * so a plain-JVM unit test can pin the shape without Robolectric.
         * See docs/superpowers/specs/2026-07-04-live-sessions-design.md.
         */
        internal val LIVE_SESSION_MIGRATION_SQL: List<String> = listOf(
            "CREATE TABLE IF NOT EXISTS `liveSession` (`deviceId` TEXT NOT NULL, " +
                "`startTs` INTEGER NOT NULL, `endTs` INTEGER, `chargeAtStart` REAL, " +
                "`floorBpm` REAL NOT NULL, `ceilingBpm` REAL NOT NULL, `inBandSec` REAL NOT NULL, " +
                "`belowSec` REAL NOT NULL, `aboveSec` REAL NOT NULL, `pushCount` INTEGER NOT NULL, " +
                "`easeCount` INTEGER NOT NULL, `hrSource` TEXT NOT NULL, " +
                "PRIMARY KEY(`deviceId`, `startTs`))",
        )

        internal val MIGRATION_15_16 = object : Migration(15, 16) {
            override fun migrate(db: SupportSQLiteDatabase) {
                for (stmt in LIVE_SESSION_MIGRATION_SQL) db.execSQL(stmt)
            }
        }

        /**
         * v16 -> v17: ADDITIVE, adds the WHOOP 4.0 raw SpO2 PPG ADC means (red/IR) to `dailyMetric`,
         * cached beside the other in-sleep aggregates (#93). Two nullable INTEGER columns, mirroring the
         * v7 spo2Pct/skinTempDevC/respRateBpm add and the Swift WhoopStore v23 migration. Existing rows
         * read NULL (ALTER ADD COLUMN, no table rebuild, no data loss), so an in-place upgrade of an older
         * database is unaffected — pre-upgrade rows + non-4.0 nights simply stay null. No destructive
         * fallback (see the class doc). Room's Int? maps to a nullable INTEGER (no NOT NULL / no DEFAULT),
         * so the SQL must match Room's generated schema exactly. Exposed for a plain-JVM unit test.
         */
        internal val DAILY_SPO2_RAW_MIGRATION_SQL: List<String> = listOf(
            "ALTER TABLE `dailyMetric` ADD COLUMN `spo2Red` INTEGER",
            "ALTER TABLE `dailyMetric` ADD COLUMN `spo2Ir` INTEGER",
        )

        internal val MIGRATION_16_17 = object : Migration(16, 17) {
            override fun migrate(db: SupportSQLiteDatabase) {
                for (stmt in DAILY_SPO2_RAW_MIGRATION_SQL) db.execSQL(stmt)
            }
        }

        /**
         * v17 -> v18: REBUILD `rrInterval` to add a `seq` tiebreaker column — PK
         * (deviceId, ts, rrMs) -> (deviceId, ts, rrMs, seq). The value-only key silently dropped the second
         * of two EQUAL successive R-R intervals that landed in the same 1-second `ts` bucket (insert is
         * `ON CONFLICT DO NOTHING`), removing a zero-difference beat pair and biasing RMSSD/HRV high (the bias
         * matters most at rest/sleep, when HRV is scored). `seq` distinguishes equal (ts, rrMs) beats; distinct
         * beats keep seq 0 and their existing key, so nothing already stored changes shape.
         *
         * A PK change needs a table rebuild (SQLite can't ALTER a PK), but it is **loss-less**: every existing
         * row is copied with `seq = 0`. That is exact because the OLD PK guaranteed a UNIQUE (deviceId, ts, rrMs)
         * per row, so seq 0 never collides. No window functions (minSdk 26 SQLite lacks `ROW_NUMBER`).
         * Already-offloaded R-R survives (the strap trims acked history and won't re-send it). The rebuilt
         * table's column order + PK MUST match Room's generated schema for [RrInterval] exactly
         * (deviceId, ts, rrMs, seq, synced; PK deviceId, ts, rrMs, seq) or the no-destructive-fallback open
         * would throw. Exposed as [RR_SEQ_MIGRATION_SQL] and pinned by [com.noop.data.RrSeqMigrationTest].
         * NOTE: this only stops FUTURE equal-beat drops; beats already dropped under the old key are
         * unrecoverable, so it does not retroactively correct historical HRV.
         */
        internal val RR_SEQ_MIGRATION_SQL: List<String> = listOf(
            "CREATE TABLE IF NOT EXISTS `rrInterval_new` (`deviceId` TEXT NOT NULL, `ts` INTEGER NOT NULL, " +
                "`rrMs` INTEGER NOT NULL, `seq` INTEGER NOT NULL, `synced` INTEGER NOT NULL, " +
                "PRIMARY KEY(`deviceId`, `ts`, `rrMs`, `seq`))",
            "INSERT INTO `rrInterval_new` (`deviceId`, `ts`, `rrMs`, `seq`, `synced`) " +
                "SELECT `deviceId`, `ts`, `rrMs`, 0, `synced` FROM `rrInterval`",
            "DROP TABLE `rrInterval`",
            "ALTER TABLE `rrInterval_new` RENAME TO `rrInterval`",
        )

        internal val MIGRATION_17_18 = object : Migration(17, 18) {
            override fun migrate(db: SupportSQLiteDatabase) {
                for (stmt in RR_SEQ_MIGRATION_SQL) db.execSQL(stmt)
            }
        }

        /**
         * v18 -> v19: Oura/WHOOP efficiency-unit HEAL, the Room twin of the Swift WhoopStore v26
         * `v26-efficiency-heal` GRDB migration (#376). UPDATE-only, NO schema change: the Oura API
         * importer and (pre-fix) the WHOOP CSV importer wrote a 0-100 integer efficiency straight into
         * `sleepSession.efficiency` / `dailyMetric.efficiency`, but NOOP's own sleep pipeline stores that
         * shared column as a 0-1 FRACTION everywhere it computes it (asleep ÷ in-bed) — same column, two
         * scales for rows written before the importer fix. Divides `efficiency` by 100 for every row
         * where it's > 1.5 — a threshold no genuine fraction can exceed (the column's convention caps at
         * 1.0) and no genuine percent-scale leftover can fall under (no real night is ≤1.5% efficient),
         * so the predicate can't touch an already-correct row and a second run finds nothing left:
         * idempotent. Deliberately NOT deviceId-scoped, matching the Swift heal: both known percent
         * writers (the Oura API importer's 'oura-api' rows and the WHOOP CSV importer's rows under
         * whatever strap deviceId the user imported into) are healed by the same predicate.
         *
         * This is REQUIRED, not optional (flagged in review): the Android CSV exporter does
         * `efficiency * 100` at write time, so an unhealed percent row (92) would export as 9200; and
         * without this heal, an iOS user and an Android user who imported the SAME WHOOP CSV would have
         * permanently different stored efficiency (iOS 0.92 after v26, Android 92 unhealed) — the
         * cross-platform parity contract (stored data must be byte-identical) needs the heal on both
         * platforms, not just the write-boundary fix.
         *
         * SEQUENCING CAVEAT: this claims Room version 18 -> 19 as the next free slot as of this PR. The
         * Swift v26 GRDB slot has the identical collision risk against other pending PRs (flagged in the
         * same review) — if another pending PR also lands a Room migration first, whichever merges
         * SECOND must renumber. Coordinate before merging both.
         *
         * The SQL is exposed as [EFFICIENCY_HEAL_MIGRATION_SQL] so a plain-JVM unit test
         * ([com.noop.data.EfficiencyHealMigrationTest]) can pin this shape without Robolectric.
         */
        internal val EFFICIENCY_HEAL_MIGRATION_SQL: List<String> = listOf(
            "UPDATE `sleepSession` SET `efficiency` = `efficiency` / 100.0 WHERE `efficiency` > 1.5",
            "UPDATE `dailyMetric` SET `efficiency` = `efficiency` / 100.0 WHERE `efficiency` > 1.5",
        )

        internal val MIGRATION_18_19 = object : Migration(18, 19) {
            override fun migrate(db: SupportSQLiteDatabase) {
                for (stmt in EFFICIENCY_HEAL_MIGRATION_SQL) db.execSQL(stmt)
            }
        }

        /**
         * v19 -> v20: ADDITIVE, adds the `ppgWaveformSample` table (issue #156 follow-up), the Android twin
         * of the Swift WhoopStore `v27-ppg-waveform` GRDB migration. Durable storage for the WHOOP 5.0 v26
         * optical PPG waveform: the strap's 24 Hz buffer was fully DECODED but only ever used to derive
         * `ppgHrSample` (v6) — the waveform itself was discarded right after. One row per (deviceId, ts),
         * the SAME shape as every other per-second decoded stream, but the samples are packed into a compact
         * BLOB (2 bytes/sample, little-endian i16, [StreamPersistence.packPpgSamples]) rather than 24 scalar
         * rows.
         *
         * CREATE TABLE only (no existing data touched), so already-offloaded raw streams survive. The SQL MUST
         * match Room's generated schema for [PpgWaveformSampleEntity] exactly: deviceId TEXT NOT NULL, ts
         * INTEGER NOT NULL, samples BLOB NOT NULL (all Kotlin non-null, no SQL DEFAULT), composite PRIMARY KEY
         * (deviceId, ts) in declaration order — matching the GRDB `t.column(...).notNull()` order deviceId, ts,
         * samples. No destructive fallback (see the class doc). Exposed as [PPG_WAVEFORM_MIGRATION_SQL] so a
         * plain-JVM unit test can pin the shape without Robolectric.
         *
         * SEQUENCING: this claims Room 19 -> 20 because MIGRATION_18_19 (efficiency-heal, Swift v26) already
         * took slot 19 on this branch; the GRDB twin is `v27-ppg-waveform` (Swift's next slot after v26), so
         * the two platforms' migration COUNTS stay aligned even though the table shape, not the number, is the
         * contract.
         */
        internal val PPG_WAVEFORM_MIGRATION_SQL: List<String> = listOf(
            "CREATE TABLE IF NOT EXISTS `ppgWaveformSample` (`deviceId` TEXT NOT NULL, " +
                "`ts` INTEGER NOT NULL, `samples` BLOB NOT NULL, PRIMARY KEY(`deviceId`, `ts`))",
        )

        internal val MIGRATION_19_20 = object : Migration(19, 20) {
            override fun migrate(db: SupportSQLiteDatabase) {
                for (stmt in PPG_WAVEFORM_MIGRATION_SQL) db.execSQL(stmt)
            }
        }

        /** #423: the WHOOP 5/MG raw-IMU offload-capture table. Additive; GRDB twin is `v28-raw-imu`
         *  (Swift's next slot after v27-ppg-waveform), so the migration COUNTS stay aligned. Column order ==
         *  [RawImuSampleEntity] field order, matching the GRDB schema's t.column(deviceId/ts/samples). */
        internal val RAW_IMU_MIGRATION_SQL: List<String> = listOf(
            "CREATE TABLE IF NOT EXISTS `rawImuSample` (`deviceId` TEXT NOT NULL, " +
                "`ts` INTEGER NOT NULL, `samples` BLOB NOT NULL, PRIMARY KEY(`deviceId`, `ts`))",
        )

        internal val MIGRATION_20_21 = object : Migration(20, 21) {
            override fun migrate(db: SupportSQLiteDatabase) {
                for (stmt in RAW_IMU_MIGRATION_SQL) db.execSQL(stmt)
            }
        }

        /** #515 follow-up: keep deleted-sleep suppression independent from the Android Sleep screen's
         *  recompute list. Existing markers remain visible after upgrade; hiding one only flips this
         *  additive flag and never removes the tombstone that protects against re-detection. */
        internal val DISMISSED_SLEEP_VISIBILITY_MIGRATION_SQL: List<String> = listOf(
            "ALTER TABLE `dismissedSleep` ADD COLUMN `managementVisible` INTEGER NOT NULL DEFAULT 1",
        )

        internal val MIGRATION_21_22 = object : Migration(21, 22) {
            override fun migrate(db: SupportSQLiteDatabase) {
                for (stmt in DISMISSED_SLEEP_VISIBILITY_MIGRATION_SQL) db.execSQL(stmt)
            }
        }

        /** Metric-level provenance for NOOP-computed scores. Additive and intentionally independent
         *  from dayOwnership, whose resolver semantics remain unchanged. */
        internal val SCORE_INPUT_PROVENANCE_MIGRATION_SQL: List<String> = listOf(
            "CREATE TABLE IF NOT EXISTS `scoreInputProvenance` (`deviceId` TEXT NOT NULL, " +
                "`day` TEXT NOT NULL, `key` TEXT NOT NULL, `sourceId` TEXT NOT NULL, " +
                "PRIMARY KEY(`deviceId`, `day`, `key`))",
            "CREATE INDEX IF NOT EXISTS `idx_scoreInputProvenance_source` " +
                "ON `scoreInputProvenance` (`sourceId`)",
        )

        internal val MIGRATION_22_23 = object : Migration(22, 23) {
            override fun migrate(db: SupportSQLiteDatabase) {
                for (stmt in SCORE_INPUT_PROVENANCE_MIGRATION_SQL) db.execSQL(stmt)
            }
        }

        /**
         * #823: record each R-R beat's EMISSION order within its second so reads can stop returning
         * them in magnitude order (which biases RMSSD down — see the RrInterval doc).
         *
         * Additive and nullable, the MIGRATION_3_4 form: no table rebuild, no row touched, and
         * critically NOT part of the primary key, which must stay (deviceId, ts, rrMs, seq) — an
         * insertion counter in the key would collide distinct beats across insert batches, the
         * data-loss regression assignRrSeq's doc warns about.
         *
         * Existing rows stay NULL. The order was never recorded, so it cannot be backfilled and a
         * guess would be worse than an admission; NULL sorts first in SQLite ASC, so a pre-v24
         * second ties on `ord` and falls through to the old (rrMs, seq) order unchanged.
         *
         * Exposed as [RR_ORD_MIGRATION_SQL] so a plain-JVM unit test can assert its shape without an
         * emulator, like the migrations above.
         */
        internal val RR_ORD_MIGRATION_SQL: List<String> = listOf(
            "ALTER TABLE `rrInterval` ADD COLUMN `ord` INTEGER",
        )

        internal val MIGRATION_23_24 = object : Migration(23, 24) {
            override fun migrate(db: SupportSQLiteDatabase) {
                for (stmt in RR_ORD_MIGRATION_SQL) db.execSQL(stmt)
            }
        }

        /**
         * Stop DISCARDING the per-second channels the 5/MG v18 decoder already produces. Twin of the
         * Swift GRDB migration `v31-deep-capture-channels`.
         *
         * `extractHistoricalStreams` is a narrow funnel — a field the decoder produces but the funnel
         * does not name is computed and dropped one line later. That drop is PERMANENT: the strap trims
         * its banked history as soon as NOOP acks the offload, so those seconds are not re-fetchable.
         *
         *   gravitySample.dynAccel     `dynamic_acceleration@41` (f32 g), the strap's OWN gravity-removed
         *                              motion magnitude, stored BESIDE the 1 Hz vector the motion spine
         *                              actually derives stillness from.
         *   sleepStateSample.rawByte   the WHOLE @81 flag byte. `state` remains exactly its high nibble,
         *                              so #175 behaviour is bit-identical; this keeps b0-1 `onwrist`,
         *                              b2-3 `wake_quality`, and the uninterpreted b6-7.
         *   skinTempSample.aux1Raw     `temp_aux_1_raw@69` / `temp_aux_2_raw@71` (i16, °C = value/10 — a
         *   skinTempSample.aux2Raw     DIFFERENT scale from the primary's /100).
         *   v18AuxSample               the remaining fifteen slots as one compact blob (see [V18AuxCodec]
         *                              for the wire format and the column-vs-blob tradeoff). Its own
         *                              table because no existing per-second table is guaranteed present
         *                              for a v18 record, and to keep unpinned bytes out of the tables
         *                              analytics read.
         *
         * Additive only, the MIGRATION_3_4 / MIGRATION_23_24 form: no table rebuild, no row touched, no
         * key changed. The three added columns are nullable with NO SQL DEFAULT, and `fields` is NOT NULL
         * only because a row is written solely when at least one slot is present — absence is encoded as
         * "no row" and, within a row, as a clear bitmap bit. Never a fabricated 0: a WHOOP 4.0 emits none
         * of these, and history banked before this migration cannot be backfilled (the strap already
         * trimmed it), so an absent channel must stay absent.
         *
         * The columns are appended by ALTER TABLE, which places them LAST — matching the entity field
         * order (each new field is declared after the existing ones), so a migrated schema and a
         * freshly-created one agree. The CREATE TABLE column order matches [V18AuxSampleEntity]'s field
         * order and the GRDB schema, so a `.noopbak` round-trips.
         *
         * INSTRUMENTATION ONLY. Nothing reads these: no analytic, no score, no gate, no UI.
         *
         * Retention: `v18AuxSample` is CAPPED at [WhoopRepository.V18_AUX_RETENTION_ROWS] rolling rows per
         * device, the same shape `rawImuSample` uses — it is the only genuinely new row growth here. The
         * three added columns widen rows that were already being written and add no rows at all.
         *
         * Exposed as [DEEP_CAPTURE_MIGRATION_SQL] so a plain-JVM unit test can assert its shape without
         * an emulator, like the migrations above.
         */
        internal val DEEP_CAPTURE_MIGRATION_SQL: List<String> = listOf(
            "ALTER TABLE `gravitySample` ADD COLUMN `dynAccel` REAL",
            "ALTER TABLE `sleepStateSample` ADD COLUMN `rawByte` INTEGER",
            "ALTER TABLE `skinTempSample` ADD COLUMN `aux1Raw` INTEGER",
            "ALTER TABLE `skinTempSample` ADD COLUMN `aux2Raw` INTEGER",
            "CREATE TABLE IF NOT EXISTS `v18AuxSample` (`deviceId` TEXT NOT NULL, " +
                "`ts` INTEGER NOT NULL, `fields` BLOB NOT NULL, " +
                "PRIMARY KEY(`deviceId`, `ts`))",
        )

        internal val MIGRATION_24_25 = object : Migration(24, 25) {
            override fun migrate(db: SupportSQLiteDatabase) {
                for (stmt in DEEP_CAPTURE_MIGRATION_SQL) db.execSQL(stmt)
            }
        }

        /**
         * #1071: record WHICH sensor channel produced each R-R beat. Twin of the Swift GRDB migration
         * `v32-rr-src-channel`.
         *
         * An Oura ring reports the SAME heartbeats on more than one tag, and every one of them decoded to
         * an R-R row and landed here untagged. Measured over one 488-min sleep window: 61,524 beats stored
         * where the measured HR curve allows 29,800 (2.06x), and sum(rrMs)/wall-clock = 2.17x. The two are
         * separable after the fact only by the accident that their quantisation grids differ (0x6E is
         * `byte * 8`, always a multiple of 8; 0x80 is an 11-bit value on the 1 ms grid), and the 8 ms
         * stream is ABSENT until SpO2 measurement starts and then tracks its duty cycle exactly — which is
         * what proves these are two channels rather than accumulated re-syncs.
         *
         * The damage is to the VARIABILITY statistics, not the level: a duplicated beat train leaves
         * meanNN (and so resting HR) correct while RMSSD/SDNN are built entirely from successive
         * differences and collapse. The app's own `hrv diag` line has been reporting it as
         * `coverage=2.21 rrIntegrity=crossSecondOverCount` with a non-physiological ~200 ms nocturnal SDNN.
         *
         * NOT a de-duplication: both rows are real measurements of the same beat by different optics, and
         * the second channel is the obvious future cross-check on the first. So nothing is deleted and
         * nothing is rewritten — the column labels the source and [WhoopDao.rrIntervals] filters at READ.
         *
         * Additive and nullable, the MIGRATION_3_4 / MIGRATION_23_24 form: no table rebuild, no row
         * touched, and NOT part of the primary key, which stays (deviceId, ts, rrMs, seq). Putting it in
         * the key would make the SAME beat insertable twice under two labels — the double-count being
         * fixed, arrived at from the other direction.
         *
         * Existing rows stay NULL and are still READ (a WHOOP row is legitimately NULL forever — one beat
         * source, no channel to name), so historical Oura rows keep their old inflated coverage. Not
         * backfillable: the channel was never recorded.
         *
         * Values are [com.noop.protocol.RrSourceChannel.code] (1 green / 2 spo2 / 3 ibiAmplitude), a
         * DURABLE wire format shared with Swift `RRSourceChannel`. INTEGER rather than a text label
         * because `rrInterval` is the highest-volume table in the schema (~60k rows a night) and this
         * column rides every one.
         *
         * ALTER TABLE appends the column LAST, matching the entity field order (declared after `ord`), so
         * a migrated schema and a freshly-created one agree.
         *
         * Exposed as [RR_SRC_CHANNEL_MIGRATION_SQL] so a plain-JVM unit test can assert its shape without
         * an emulator, like the migrations above.
         */
        internal val RR_SRC_CHANNEL_MIGRATION_SQL: List<String> = listOf(
            "ALTER TABLE `rrInterval` ADD COLUMN `srcChannel` INTEGER",
        )

        internal val MIGRATION_25_26 = object : Migration(25, 26) {
            override fun migrate(db: SupportSQLiteDatabase) {
                for (stmt in RR_SRC_CHANNEL_MIGRATION_SQL) db.execSQL(stmt)
            }
        }

        /**
         * v26 -> v27: ADDITIVE, adds `workout.steps` (nullable INTEGER) so an imported activity file can
         * carry its OWN step count (#1058). Before this, activity-file steps were stored only as a
         * whole-day `dailyMetric.steps` row keyed on (deviceId, day), so a SECOND file for the same day
         * overwrote the first's steps instead of adding. With steps on the session, the day total is
         * recomputed as SUM over that day's sessions — additive across files, idempotent on re-import.
         *
         * Additive and nullable, the MIGRATION_3_4 (`workout.routePolyline`) form: no table rebuild, no row
         * touched, not part of the primary key. ALTER TABLE appends the column LAST, matching the entity
         * field order (declared after `routePolyline`), so a migrated schema and a freshly-created one
         * agree. Byte-parity with Swift WhoopStore `v33-workout-steps`.
         *
         * Exposed as [WORKOUT_STEPS_MIGRATION_SQL] so a plain-JVM unit test can assert its shape without an
         * emulator, like the migrations above.
         */
        internal val WORKOUT_STEPS_MIGRATION_SQL: List<String> = listOf(
            "ALTER TABLE `workout` ADD COLUMN `steps` INTEGER",
        )

        internal val MIGRATION_26_27 = object : Migration(26, 27) {
            override fun migrate(db: SupportSQLiteDatabase) {
                for (stmt in WORKOUT_STEPS_MIGRATION_SQL) db.execSQL(stmt)
            }
        }

        /**
         * v27 -> v28: ADDITIVE, adds `sleepSession.stagingSparse` (nullable INTEGER) so the Sleep tab can
         * caption a night staged on SPARSE motion coverage as possibly incomplete (#345 — the "slept 8h,
         * shows 1h" reports). Boolean? -> INTEGER affinity, matching Swift GRDB's `.integer` twin (no
         * boolean-affinity divergence). Additive, nullable, not part of the PK; the MIGRATION_3_4 form. The
         * ALTER appends the column LAST, matching the entity field order (declared after `sleepStateJSON`).
         * Byte-parity with Swift WhoopStore `v34-sleep-staging-sparse`.
         */
        internal val SLEEP_STAGING_SPARSE_MIGRATION_SQL: List<String> = listOf(
            "ALTER TABLE `sleepSession` ADD COLUMN `stagingSparse` INTEGER",
        )

        internal val MIGRATION_27_28 = object : Migration(27, 28) {
            override fun migrate(db: SupportSQLiteDatabase) {
                for (stmt in SLEEP_STAGING_SPARSE_MIGRATION_SQL) db.execSQL(stmt)
            }
        }

        /**
         * v28 -> v29: ADDITIVE, adds `rrInterval.tsSuspect` (nullable INTEGER) and MARKS every stored beat
         * whose ts is in the FUTURE (#1073). An Oura ring's history timestamp is occasionally corrupt and,
         * before the OuraDriver gate was tightened to "now", converted to a date years ahead (measured on a
         * live ring: ~1,600 beats stamped 2026→2034) and was banked — lost to the night it was measured in
         * and queued to poison a future day. The ingest gate now rejects such samples; rows already stored
         * are marked here and `WhoopDao.rrIntervals` filters them at READ.
         *
         * NOT a delete: real beats with a wrong timestamp, kept inspectable/recoverable (the migration rule
         * warns against window-wide deletes). Additive nullable, the srcChannel (`MIGRATION_25_26`) form:
         * no table rebuild, no row/key touched, ALTER appends the column LAST to match the entity field
         * order. `strftime('%s','now')` runs once, at migration time; CAST so `ts` (INTEGER) > it is a
         * numeric compare. New rows are gated at ingest so never land future, staying NULL. Byte-parity
         * with Swift WhoopStore `v35-rr-future-quarantine`.
         *
         * Exposed as [RR_FUTURE_QUARANTINE_MIGRATION_SQL] so a plain-JVM unit test can assert its shape.
         */
        internal val RR_FUTURE_QUARANTINE_MIGRATION_SQL: List<String> = listOf(
            "ALTER TABLE `rrInterval` ADD COLUMN `tsSuspect` INTEGER",
            "UPDATE `rrInterval` SET `tsSuspect` = 1 WHERE `ts` > CAST(strftime('%s','now') AS INTEGER)",
        )

        internal val MIGRATION_28_29 = object : Migration(28, 29) {
            override fun migrate(db: SupportSQLiteDatabase) {
                for (stmt in RR_FUTURE_QUARANTINE_MIGRATION_SQL) db.execSQL(stmt)
            }
        }

        private fun build(appContext: Context): WhoopDatabase =
            Room.databaseBuilder(appContext, WhoopDatabase::class.java, DB_NAME)
                // #1014: replace ONLY the corruption handling of the default open-helper. The
                // platform default silently DELETES a corrupt database file (non-resendable strap
                // history gone without a trace); this factory logs + preserves the file instead.
                // Every migration/lifecycle callback is delegated to Room unchanged.
                .openHelperFactory(CorruptionPreservingOpenHelperFactory())
                // Real additive migration, NO destructive fallback (see the class doc): with
                // exportSchema=false a silent rebuild would lose already-acked, non-resendable strap
                // history on any schema mismatch. Room throws loudly instead; CI guards the SQL.
                .addMigrations(
                    MIGRATION_2_3, MIGRATION_3_4, MIGRATION_4_5,
                    MIGRATION_5_6, MIGRATION_6_7, MIGRATION_7_8, MIGRATION_8_9, MIGRATION_9_10,
                    MIGRATION_10_11, MIGRATION_11_12, MIGRATION_12_13, MIGRATION_13_14,
                    MIGRATION_14_15, MIGRATION_15_16, MIGRATION_16_17, MIGRATION_17_18,
                    MIGRATION_18_19, MIGRATION_19_20, MIGRATION_20_21, MIGRATION_21_22,
                    MIGRATION_22_23, MIGRATION_23_24, MIGRATION_24_25, MIGRATION_25_26,
                    MIGRATION_26_27, MIGRATION_27_28, MIGRATION_28_29,
                )
                // #1037: a FRESH install builds the schema straight at the current version and runs NO
                // migrations, so the MIGRATION_7_8 "my-whoop" registry seed never fires and the WHOOP,
                // though paired and streaming fine, never appears in the Devices list. Seed the canonical
                // row on create too (same idempotent INSERT OR IGNORE as the migration) so a first-ever
                // install still lists its WHOOP. iOS/GRDB re-runs migrations on a fresh DB, so it never hit this.
                .addCallback(object : RoomDatabase.Callback() {
                    override fun onCreate(db: SupportSQLiteDatabase) {
                        val now = System.currentTimeMillis() / 1000
                        db.execSQL(
                            "INSERT OR IGNORE INTO `pairedDevice` " +
                                "(`id`, `brand`, `model`, `nickname`, `sourceKind`, `capabilities`, " +
                                "`status`, `addedAt`, `lastSeenAt`) VALUES " +
                                "('my-whoop', 'WHOOP', 'WHOOP', NULL, 'liveBLE', " +
                                "'hr,hrv,spo2,skinTemp,sleep,strainLoad', 'active', $now, $now)",
                        )
                    }
                })
                .build()
    }
}
