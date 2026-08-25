package com.noop.ui

import android.content.Context
import android.content.SharedPreferences
import com.noop.data.HrSample

/**
 * Durable persistence for an in-flight MANUALLY-STARTED workout that is NOT GPS-tracked (#529).
 *
 * The GPS path already survives the screen turning off because the route lives in the process-level
 * [com.noop.location.GpsSession] fed by the foreground service, and the ViewModel rebuilds the active
 * card from it on relaunch ([AppViewModel.rehydrateActiveGpsWorkout]). A non-GPS session, by contrast,
 * lived ONLY in the ViewModel's in-memory `_activeWorkout`, so if Android killed the process mid-session
 * the whole thing was lost — you could never End + save it.
 *
 * This is the lighter, non-GPS analogue of that durability: a tiny snapshot (start time, sport, and the
 * accumulated HR samples + running stats) is written to its own SharedPreferences file on start and on
 * every sample update, and read back on launch so an interrupted session can still be ended and saved.
 * Mirrors the [com.noop.alarm.SmartAlarmStore] SharedPreferences pattern (own prefs file, simple keys).
 *
 * On-device only; nothing leaves the phone. The encode/decode is factored into the pure
 * [ActiveWorkoutPersistence] so the round-trip is unit-testable without a Context.
 */
class ActiveWorkoutStore(private val prefs: SharedPreferences) {

    /** Persist (overwrite) the active non-GPS workout snapshot. Cheap; called on start + each sample. */
    fun save(snapshot: ActiveWorkoutPersistence.Snapshot) {
        prefs.edit().putString(KEY_SNAPSHOT, ActiveWorkoutPersistence.encode(snapshot)).apply()
    }

    /** Read the persisted snapshot, or null if none is stored (or it was corrupt). */
    fun load(): ActiveWorkoutPersistence.Snapshot? =
        ActiveWorkoutPersistence.decode(prefs.getString(KEY_SNAPSHOT, null))

    /** Clear the snapshot — called the instant a session ends (saved or discarded). */
    fun clear() {
        prefs.edit().remove(KEY_SNAPSHOT).apply()
    }

    companion object {
        private const val PREFS = "noop_active_workout"
        private const val KEY_SNAPSHOT = "activeWorkout.snapshot"

        fun from(context: Context): ActiveWorkoutStore =
            ActiveWorkoutStore(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE))
    }
}

/**
 * Pure (Context-free) codec for the durable non-GPS active-workout snapshot. Kept separate from the
 * SharedPreferences wrapper so the persist/rehydrate round-trip can be unit-tested on the JVM.
 *
 * Serialization is a deliberately small, forward-tolerant line format — NOT a schema-versioned blob —
 * because the snapshot is ephemeral (it only ever survives one process death) and is rewritten in full
 * on every sample. A header line carries start/sport/derived stats; subsequent lines are `ts,bpm` HR
 * samples. Anything malformed decodes to null (treated as "no in-flight session"), so a corrupt or
 * partial write can never crash the rehydrate or revive a bogus card.
 */
object ActiveWorkoutPersistence {

    /** The minimal durable shape of an in-flight non-GPS workout. Distinct from
     *  [AppViewModel.ActiveWorkout] (which also carries GPS-only fields) — this only persists the
     *  non-GPS state, and the ViewModel maps between the two. */
    data class Snapshot(
        val startMs: Long,
        val sportName: String,
        val deviceId: String,
        val samples: List<HrSample>,
        val avgHr: Int,
        val peakHr: Int,
        val liveStrain: Double,
        val pausedAtMs: Long? = null,
        val pausedDurationMs: Long = 0L,
    )

    /** Encode a snapshot to the compact line format. */
    fun encode(s: Snapshot): String {
        val sb = StringBuilder()
        // Header: version | startMs | avgHr | peakHr | liveStrain | sportName | deviceId
        // sportName/deviceId go LAST so a name containing the delimiter can't shift the numeric fields
        // (deviceId is a stable token; sportName is the only free-ish text and is the final field).
        sb.append("v1").append(FIELD)
            .append(s.startMs).append(FIELD)
            .append(s.avgHr).append(FIELD)
            .append(s.peakHr).append(FIELD)
            .append(s.liveStrain).append(FIELD)
            .append(sanitize(s.sportName)).append(FIELD)
            .append(sanitize(s.deviceId)).append(FIELD)
            .append(s.pausedAtMs ?: 0L).append(FIELD)
            .append(s.pausedDurationMs)
        for (hr in s.samples) {
            sb.append(LINE).append(hr.ts).append(',').append(hr.bpm)
        }
        return sb.toString()
    }

    /** Decode the line format back to a snapshot. Returns null for null/blank/malformed input so a
     *  corrupt write is treated as "no session" rather than reviving a broken card. */
    fun decode(raw: String?): Snapshot? {
        if (raw.isNullOrBlank()) return null
        val lines = raw.split(LINE)
        val header = lines.firstOrNull()?.split(FIELD) ?: return null
        // version | startMs | avgHr | peakHr | liveStrain | sportName | deviceId
        if (header.size < 7 || header[0] != "v1") return null
        val startMs = header[1].toLongOrNull() ?: return null
        if (startMs <= 0L) return null
        val avgHr = header[2].toIntOrNull() ?: return null
        val peakHr = header[3].toIntOrNull() ?: return null
        val liveStrain = header[4].toDoubleOrNull() ?: return null
        val sportName = header[5]
        val deviceId = header[6]
        if (deviceId.isBlank()) return null
        val samples = ArrayList<HrSample>(lines.size - 1)
        for (i in 1 until lines.size) {
            val parts = lines[i].split(',')
            if (parts.size != 2) continue   // tolerate a torn final line — skip it, don't fail
            val ts = parts[0].toLongOrNull() ?: continue
            val bpm = parts[1].toIntOrNull() ?: continue
            // Bound-check untrusted persisted values: a plausible epoch-seconds ts and a real bpm only.
            if (ts <= 0L) continue
            if (bpm !in 1..300) continue
            samples.add(HrSample(deviceId = deviceId, ts = ts, bpm = bpm))
        }
        return Snapshot(
            startMs = startMs,
            sportName = sportName,
            deviceId = deviceId,
            samples = samples,
            avgHr = avgHr.coerceAtLeast(0),
            peakHr = peakHr.coerceAtLeast(0),
            liveStrain = if (liveStrain.isFinite()) liveStrain.coerceAtLeast(0.0) else 0.0,
            pausedAtMs = header.getOrNull(7)?.toLongOrNull()?.takeIf { it > 0L },
            pausedDurationMs = header.getOrNull(8)?.toLongOrNull()?.coerceAtLeast(0L) ?: 0L,
        )
    }

    /** Strip the two structural delimiters from a free-text field so it can't corrupt the framing. */
    private fun sanitize(s: String): String = s.replace(FIELD, " ").replace(LINE, " ")

    // Delimiters chosen to never appear in a sport name or device id: a unit/record separator pair.
    private const val FIELD = "\u001F"   // field separator (ASCII unit separator) within the header
    private const val LINE = "\u001E"    // record separator (ASCII record separator) between header and each sample
}
