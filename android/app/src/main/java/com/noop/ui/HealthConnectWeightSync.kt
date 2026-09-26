package com.noop.ui

import android.content.Context
import com.noop.analytics.ProfileWeightSync
import com.noop.analytics.WeightReading
import com.noop.data.AppleDaily
import com.noop.data.WhoopRepository
import com.noop.ingest.HealthConnectImporter

/**
 * "Use weight from Health Connect": copies the newest Health Connect weight into the profile, so every
 * analytics reader of [ProfileStore.toUserProfile] (calories, workout energy, BMR) uses the weight the
 * user actually measured instead of a manual figure nobody updates.
 *
 * It reads the whole stored Health Connect history rather than the rows of the import that just ran, so
 * switching the toggle on still picks up a weigh-in older than the import window.
 */
object HealthConnectWeightSync {

    /**
     * The profile write, separated from the database read so it runs as a plain JVM test. A no-op that
     * returns null when the toggle is OFF or no Health Connect row carries a weight; otherwise writes
     * [ProfileStore.weightKg] and [ProfileStore.healthConnectWeightDay] and returns the reading applied.
     */
    internal fun apply(profile: ProfileStore, healthConnectRows: List<AppleDaily>): WeightReading? {
        if (!profile.useHealthConnectWeight) return null
        val newest = ProfileWeightSync.newest(weightReadings(healthConnectRows)) ?: return null
        profile.weightKg = newest.kg
        profile.healthConnectWeightDay = newest.day
        return newest
    }

    /** Runs after every Health Connect import, and once when the toggle is switched on. */
    suspend fun syncFromRepository(context: Context, repo: WhoopRepository): WeightReading? {
        val profile = ProfileStore.from(context)
        // Checked again inside apply(); this early return only skips the full-table read when OFF.
        if (!profile.useHealthConnectWeight) return null
        return apply(profile, repo.appleDaily(HealthConnectImporter.HC_DEVICE, "0000-01-01", "9999-12-31"))
    }

    internal fun weightReadings(rows: List<AppleDaily>): List<WeightReading> =
        rows.mapNotNull { row -> row.weightKg?.let { WeightReading(row.day, it) } }
}
