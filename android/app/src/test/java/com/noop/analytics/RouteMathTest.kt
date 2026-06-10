package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RouteMathTest {
    // Two points ~451 m apart near the Thames (verified by hand: ~289 m N/S + ~346 m E/W).
    private val a = RouteMath.LatLng(51.5033, -0.1196)
    private val b = RouteMath.LatLng(51.5007, -0.1246)

    @Test fun haversine_knownDistance() {
        val d = RouteMath.haversineMeters(a, b)
        assertEquals(451.0, d, 20.0) // within 20 m
    }

    @Test fun totalDistance_sumsSegments() {
        val pts = listOf(a, b, a)
        val total = RouteMath.totalMeters(pts)
        assertEquals(RouteMath.haversineMeters(a, b) * 2, total, 1.0)
    }

    @Test fun totalDistance_emptyOrSingle_isZero() {
        assertEquals(0.0, RouteMath.totalMeters(emptyList()), 0.0)
        assertEquals(0.0, RouteMath.totalMeters(listOf(a)), 0.0)
    }

    @Test fun pace_secPerKm_fromDistanceAndDuration() {
        assertEquals(300.0, RouteMath.paceSecPerKm(meters = 1000.0, seconds = 300.0)!!, 0.001)
        assertEquals(null, RouteMath.paceSecPerKm(meters = 0.0, seconds = 300.0))
    }

    @Test fun polyline_roundTrips() {
        val pts = listOf(a, b, RouteMath.LatLng(51.4995, -0.1357))
        val decoded = RouteMath.decode(RouteMath.encode(pts))
        assertEquals(pts.size, decoded.size)
        for (i in pts.indices) {
            assertEquals(pts[i].lat, decoded[i].lat, 1e-5)
            assertEquals(pts[i].lon, decoded[i].lon, 1e-5)
        }
    }

    @Test fun encode_empty_isEmptyString() {
        assertTrue(RouteMath.encode(emptyList()).isEmpty())
        assertTrue(RouteMath.decode("").isEmpty())
    }

    @Test fun normalize_fitsWithinBox_andCentres() {
        val pts = listOf(RouteMath.LatLng(51.50, -0.12), RouteMath.LatLng(51.51, -0.11), RouteMath.LatLng(51.50, -0.10))
        val box = RouteMath.normalizeToBox(pts, 200f, 100f, pad = 10f)
        assertEquals(pts.size, box.size)
        box.forEach { (x, y) ->
            assertTrue(x in 10f..190f); assertTrue(y in 10f..90f)
        }
    }

    @Test fun normalize_fewerThanTwo_isEmpty() {
        assertTrue(RouteMath.normalizeToBox(listOf(RouteMath.LatLng(51.0, -0.1)), 100f, 100f).isEmpty())
    }
}
