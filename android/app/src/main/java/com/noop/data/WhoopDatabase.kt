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
        AppleDaily::class,
    ],
    version = 4,
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

        private fun build(appContext: Context): WhoopDatabase =
            Room.databaseBuilder(appContext, WhoopDatabase::class.java, DB_NAME)
                // Real additive migration — NO destructive fallback (see the class doc): with
                // exportSchema=false a silent rebuild would lose already-acked, non-resendable strap
                // history on any schema mismatch. Room throws loudly instead; CI guards the SQL.
                .addMigrations(MIGRATION_2_3, MIGRATION_3_4)
                .build()
    }
}
