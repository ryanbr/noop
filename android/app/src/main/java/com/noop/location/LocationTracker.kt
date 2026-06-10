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
    private val maxAccuracyM: Float = 30f,
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

/** Wraps platform GPS. Caller must hold ACCESS_FINE_LOCATION (already granted for BLE). */
class LocationTracker(private val context: Context) {
    @SuppressLint("MissingPermission")
    fun stream(minIntervalMs: Long = 2000, minDistanceM: Float = 5f): Flow<LatLng> = callbackFlow {
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val filter = TrackFilter()
        val listener = LocationListener { loc: Location ->
            filter.accept(RawFix(loc.latitude, loc.longitude, if (loc.hasAccuracy()) loc.accuracy else 0f, loc.time))
                ?.let { trySend(it) }
        }
        lm.requestLocationUpdates(
            LocationManager.GPS_PROVIDER, minIntervalMs, minDistanceM, listener, Looper.getMainLooper(),
        )
        awaitClose { lm.removeUpdates(listener) }
    }
}
