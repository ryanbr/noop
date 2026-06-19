package com.noop.data

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

/**
 * Local Room database — the Android port of the GRDB store in
 * Packages/WhoopStore (Database.swift schema). Holds phone-collected raw streams
 * AND the offline cache of server-computed derived metrics.
 *
 * The schema bundles every Swift migration (v1..v9) into a single fresh shape, since the
 * Android app starts from an empty store (no in-place migration from a prior Android version).
 * version 2 added the v8 journal/workout/appleDaily caches. **v3 (#78)** adds the stepSample table
 * + dailyMetric.steps/activeKcalEst via a REAL additive migration (MIGRATION_2_3) — NOT a destructive
 * rebuild — so a user's already-offloaded raw streams survive (the strap trims acked history and won't
 * re-send it). The destructive fallback is deliberately GONE: with exportSchema=false there's no
 * build-time schema check, so a hand-written-SQL mismatch would otherwise SILENTLY wipe that history;
 * without the fallback Room throws loudly instead, and MigrationRoundTripTest guards the SQL in CI.
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
        RespSample::class,
        GravitySample::class,
        DailyMetric::class,
        SleepSession::class,
        MetricSeriesRow::class,
        JournalEntry::class,
        WorkoutRow::class,
        DismissedWorkout::class,
        DismissedSleep::class,
        AppleDaily::class,
        PpgHrSample::class,
        PairedDeviceRow::class,
        DayOwnershipRow::class,
        LabMarkerRow::class,
    ],
    version = 11,
    exportSchema = false,
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
         * The next [get] call rebuilds against whatever file is on disk — used by
         * [DataBackup.importFrom] to swap the database file underneath the app.
         */
        fun close() {
            synchronized(this) {
                instance?.close()
                instance = null
            }
        }

        /**
         * v2 → v3: ADDITIVE ONLY — adds the stepSample table + dailyMetric.steps/activeKcalEst.
         * A real (non-destructive) migration so an existing user's already-offloaded raw streams are
         * PRESERVED (the strap trims acked history chunks and will not re-send them, so a destructive
         * rebuild would lose that history permanently). The SQL MUST match Room's generated schema
         * exactly — NOT NULL for `synced` (Kotlin default, no SQL DEFAULT), nullable INTEGER/REAL for
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
         * v3 -> v4: ADDITIVE — adds `workout.routePolyline` (nullable TEXT) for GPS routes. Nullable so
         * existing workouts migrate untouched; the SQL must match Room's generated schema for a `String?`
         * column exactly (TEXT, no NOT NULL, no default). Mirrors MIGRATION_2_3's additive form.
         */
        internal val MIGRATION_3_4 = object : Migration(3, 4) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `workout` ADD COLUMN `routePolyline` TEXT")
            }
        }

        /**
         * v4 -> v5: ADDITIVE — adds the `dismissedWorkout` table (#107): a durable marker that keeps a
         * dismissed auto-detected bout hidden after the engine re-derives it. CREATE TABLE only (no
         * data touched), so existing workouts/history are untouched. The SQL MUST match Room's
         * generated schema for the [DismissedWorkout] entity exactly — all three PK columns NOT NULL,
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
         * v5 -> v6: ADDITIVE — adds the `ppgHrSample` table (#156): HR derived from the WHOOP 5/MG
         * v26 optical PPG waveform (autocorrelation). CREATE TABLE only (no existing data touched), so
         * already-offloaded raw streams survive (the strap trims acked history and won't re-send it).
         * The SQL MUST match Room's generated schema for [PpgHrSample] exactly — every column NOT NULL
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
         * v6 -> v7: ADDITIVE — adds `sleepSession.userEdited` + `sleepSession.startTsAdjusted` for
         * durable bed/wake editing (port of iOS PR #395 — the GRDB v13 `userEdited` + v14
         * `startTsAdjusted` migrations). `userEdited` is a non-null Kotlin Boolean → Room stores it as
         * INTEGER NOT NULL DEFAULT 0; `startTsAdjusted` is a nullable Long → INTEGER (no NOT NULL).
         * Both are ALTER ... ADD COLUMN only (no data touched), so existing rows are untouched and read
         * back as userEdited=false / startTsAdjusted=null — exactly the additive, nullable-safe form of
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
         * v7 -> v8: ADDITIVE — adds the device registry (`pairedDevice` + `dayOwnership`), the Android
         * port of the Swift Database.swift v15 migration. CREATE TABLE only (no existing data touched),
         * so already-offloaded raw streams survive (the strap trims acked history and won't re-send it).
         *
         * The SQL MUST match Room's generated schema for [PairedDeviceRow]/[DayOwnershipRow] exactly:
         *  - pairedDevice: `nickname` is the only nullable column (TEXT, no NOT NULL); every other is
         *    NOT NULL with no SQL DEFAULT (Kotlin construction defaults don't emit a schema default).
         *  - dayOwnership: `locked` is a non-null Kotlin Boolean with a *constructor* default of false —
         *    Room stores it as INTEGER NOT NULL with NO SQL DEFAULT (the Kotlin default never reaches the
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
         * v8 -> v9: ADDITIVE — adds `pairedDevice.peripheralId` (nullable TEXT) — the strap's stable BLE
         * peripheral identifier (the Android twin of the Swift Database.swift `peripheralId` migration).
         * On Android this is the [android.bluetooth.BluetoothDevice] MAC address; it lets the BLE client
         * pin a connect to ONE specific strap (multi-WHOOP) and lets a freshly-paired device be looked up
         * by its address.
         *
         * ALTER ... ADD COLUMN only (no data touched), so existing rows are untouched and read back with
         * `peripheralId = NULL` — including the seeded "my-whoop" row (WHOOP has no stored MAC until it is
         * (re)paired — fine). The SQL MUST match Room's generated column for a `String?` field exactly:
         * TEXT, no NOT NULL, no SQL DEFAULT (a Kotlin construction default never reaches the schema) — the
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
         * v9 -> v10: ADDITIVE — adds the `dismissedSleep` tombstone table (#33): a durable marker that
         * keeps a user-DELETED computed sleep night from regenerating on the next recompute. CREATE TABLE
         * only (no data touched), so already-offloaded raw streams survive. The SQL MUST match Room's
         * generated schema for [DismissedSleep] exactly — all three columns NOT NULL, composite PRIMARY
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
         * v10 -> v11: ADDITIVE — adds the `labMarker` table (Health Records "Lab Book" pillar), the
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

        /** All statements the migration runs, in order — the table then its indexes. */
        internal val LAB_MARKER_MIGRATION_SQL: List<String> =
            listOf(LAB_MARKER_CREATE_SQL) + LAB_MARKER_INDEX_SQL

        internal val MIGRATION_10_11 = object : Migration(10, 11) {
            override fun migrate(db: SupportSQLiteDatabase) {
                for (stmt in LAB_MARKER_MIGRATION_SQL) db.execSQL(stmt)
            }
        }

        private fun build(appContext: Context): WhoopDatabase =
            Room.databaseBuilder(appContext, WhoopDatabase::class.java, DB_NAME)
                // Real additive migration — NO destructive fallback (see the class doc): with
                // exportSchema=false a silent rebuild would lose already-acked, non-resendable strap
                // history on any schema mismatch. Room throws loudly instead; CI guards the SQL.
                .addMigrations(
                    MIGRATION_2_3, MIGRATION_3_4, MIGRATION_4_5,
                    MIGRATION_5_6, MIGRATION_6_7, MIGRATION_7_8, MIGRATION_8_9, MIGRATION_9_10,
                    MIGRATION_10_11,
                )
                .build()
    }
}
