package com.noop.analytics

import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Pure geo math for GPS workouts — no Android types, fully unit-testable. Distance via Haversine,
 * pace, and the Google "Encoded Polyline Algorithm Format" (precision 5) for compact route storage.
 */
object RouteMath {
    data class LatLng(val lat: Double, val lon: Double)

    private const val EARTH_R = 6_371_000.0 // metres

    fun haversineMeters(a: LatLng, b: LatLng): Double {
        val dLat = Math.toRadians(b.lat - a.lat)
        val dLon = Math.toRadians(b.lon - a.lon)
        val s = sin(dLat / 2) * sin(dLat / 2) +
            cos(Math.toRadians(a.lat)) * cos(Math.toRadians(b.lat)) * sin(dLon / 2) * sin(dLon / 2)
        return EARTH_R * 2 * atan2(sqrt(s), sqrt(1 - s))
    }

    fun totalMeters(points: List<LatLng>): Double {
        var sum = 0.0
        for (i in 1 until points.size) sum += haversineMeters(points[i - 1], points[i])
        return sum
    }

    /** Seconds per kilometre, or null when distance is zero (pace undefined). */
    fun paceSecPerKm(meters: Double, seconds: Double): Double? =
        if (meters <= 0.0) null else seconds / (meters / 1000.0)

    // --- Encoded Polyline Algorithm Format, precision 5 ---

    fun encode(points: List<LatLng>): String {
        val sb = StringBuilder()
        var prevLat = 0
        var prevLon = 0
        for (p in points) {
            val lat = (p.lat * 1e5).roundToInt()
            val lon = (p.lon * 1e5).roundToInt()
            encodeSigned(lat - prevLat, sb)
            encodeSigned(lon - prevLon, sb)
            prevLat = lat
            prevLon = lon
        }
        return sb.toString()
    }

    fun decode(encoded: String): List<LatLng> {
        val out = ArrayList<LatLng>()
        var i = 0
        var lat = 0
        var lon = 0
        while (i < encoded.length) {
            var result = 0
            var shift = 0
            var bch: Int
            do { bch = encoded[i++].code - 63; result = result or ((bch and 0x1f) shl shift); shift += 5 } while (bch >= 0x20)
            lat += if (result and 1 != 0) (result shr 1).inv() else result shr 1
            result = 0
            shift = 0
            do { bch = encoded[i++].code - 63; result = result or ((bch and 0x1f) shl shift); shift += 5 } while (bch >= 0x20)
            lon += if (result and 1 != 0) (result shr 1).inv() else result shr 1
            out.add(LatLng(lat / 1e5, lon / 1e5))
        }
        return out
    }

    private fun encodeSigned(v: Int, sb: StringBuilder) {
        var value = if (v < 0) (v shl 1).inv() else v shl 1
        while (value >= 0x20) { sb.append(((0x20 or (value and 0x1f)) + 63).toChar()); value = value shr 5 }
        sb.append((value + 63).toChar())
    }

    /**
     * Project lat/lon onto a [width]x[height] box (pixels), aspect-correct via cos(midLat), padded.
     * Returns screen points (origin top-left, y down). Empty / <2 points -> empty list.
     */
    fun normalizeToBox(points: List<LatLng>, width: Float, height: Float, pad: Float = 12f): List<Pair<Float, Float>> {
        if (points.size < 2) return emptyList()
        val midLat = points.sumOf { it.lat } / points.size
        val kx = cos(Math.toRadians(midLat))
        val xs = points.map { it.lon * kx }
        val ys = points.map { it.lat }
        val minX = xs.min(); val maxX = xs.max(); val minY = ys.min(); val maxY = ys.max()
        val spanX = (maxX - minX).coerceAtLeast(1e-9); val spanY = (maxY - minY).coerceAtLeast(1e-9)
        val w = width - 2 * pad; val h = height - 2 * pad
        val scale = minOf(w / spanX, h / spanY)
        val offX = pad + (w - spanX * scale) / 2
        val offY = pad + (h - spanY * scale) / 2
        return points.indices.map { idx ->
            val px = offX + (xs[idx] - minX) * scale
            // Invert Y: larger latitude = up = smaller pixel-y.
            val py = offY + (maxY - ys[idx]) * scale
            px.toFloat() to py.toFloat()
        }
    }
}
