package com.noop.location

import android.annotation.SuppressLint
import android.content.Context
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Looper
import com.noop.analytics.RouteMath
import com.noop.analytics.RouteMath.LatLng
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow

/** A raw GPS reading before filtering. */
data class RawFix(val lat: Double, val lon: Double, val accuracyM: Float, val tMs: Long)

/**
 * Pure, stateful filter: drops low-accuracy fixes and physically-impossible jumps, returns the
 * accepted [LatLng] or null. Keeps the last accepted fix to gate the next. Unit-tested.
 */
class TrackFilter(
    // 50 m is the realistic consumer-GPS gate during activity (Strava-class apps use ~50 m). The old
    // 30 m gate dropped most fixes on a weak-signal run, so a real 24-min run banked only 2 points and
    // ~38 m of distance (#324). The speed gate below still rejects teleports, so the looser accuracy
    // gate admits legitimate running fixes without letting GPS jumps inflate the track.
    private val maxAccuracyM: Float = 50f,
    private val maxSpeedMps: Double = 12.0, // ~43 km/h; well above running, below GPS teleports
) {
    private var last: RawFix? = null
    fun accept(fix: RawFix): LatLng? {
        if (fix.accuracyM > maxAccuracyM) return null
        val prev = last
        if (prev != null) {
            val dt = (fix.tMs - prev.tMs) / 1000.0
            if (dt > 0) {
                val d = RouteMath.haversineMeters(LatLng(prev.lat, prev.lon), LatLng(fix.lat, fix.lon))
                if (d / dt > maxSpeedMps) return null
            }
        }
        last = fix
        return LatLng(fix.lat, fix.lon)
    }
}

/**
 * Wraps platform GPS. The caller should request ACCESS_FINE_LOCATION before starting a GPS workout
 * (see rememberRequestLocation) — unlike BLE, fine location is NOT implicitly granted on Android 12+.
 * Fails SAFE: if the permission isn't held or the GPS provider is unavailable, the stream just ends
 * with no fixes instead of crashing, so the workout still records HR/strain without a route. (#101)
 */
class LocationTracker(private val context: Context) {
    @SuppressLint("MissingPermission")
    // minDistanceM defaults to 0: let the platform deliver every time-based fix (every minIntervalMs)
    // so TrackFilter does the gating. A non-zero platform minDistance compounds with the accuracy gate
    // and suppressed fixes on a weak-signal run, contributing to the under-collected route (#324).
    fun stream(minIntervalMs: Long = 2000, minDistanceM: Float = 0f): Flow<RawFix> = callbackFlow {
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val filter = TrackFilter()
        val listener = LocationListener { loc: Location ->
            val fix = RawFix(loc.latitude, loc.longitude, if (loc.hasAccuracy()) loc.accuracy else 0f, loc.time)
            if (filter.accept(fix) != null) trySend(fix)
        }
        try {
            lm.requestLocationUpdates(
                LocationManager.GPS_PROVIDER, minIntervalMs, minDistanceM, listener, Looper.getMainLooper(),
            )
        } catch (t: Throwable) {
            // SecurityException (ACCESS_FINE_LOCATION not held), IllegalArgumentException (no GPS
            // provider on this device), or an OEM quirk — never propagate out of the collecting
            // coroutine and crash the app. End the route stream cleanly. (#101)
            close()
            return@callbackFlow
        }
        awaitClose { runCatching { lm.removeUpdates(listener) } }
    }
}
