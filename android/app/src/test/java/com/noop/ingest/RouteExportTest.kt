package com.noop.ingest

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.xmlpull.v1.XmlPullParser

/**
 * RouteExport (GPX/FIT) is validated by ROUND-TRIP through [ActivityFileImporter]: a route + metadata is
 * exported, then re-parsed, and the decoded track/summary must match. This pins the encoders against the
 * app's own decoders (the same decoders that read real Strava/Garmin files), so a byte-layout regression
 * in either format is caught off-device. The Swift twin (`RouteExporterTests`) asserts the same shape.
 */
class RouteExportTest {

    // The GPX path parses via ActivityFileImporter's pull-parser seam; android.util.Xml is a throwing
    // stub off-device, so swap in kXML2 exactly like ActivityFileImporterTest.
    @Before fun installRealParser() {
        ActivityFileImporter.newPullParser = {
            Class.forName("org.kxml2.io.KXmlParser").getDeclaredConstructor().newInstance() as XmlPullParser
        }
    }

    @After fun resetParser() { ActivityFileImporter.newPullParser = { android.util.Xml.newPullParser() } }

    private val route = listOf(
        RouteExport.Point(37.334900, -122.009000),
        RouteExport.Point(37.335200, -122.008400),
        RouteExport.Point(37.335900, -122.007700),
        RouteExport.Point(37.336500, -122.006900),
    )
    private val startTs = 1_723_000_000L
    private val endTs = 1_723_001_800L // +30 min

    @Test fun gpxRoundTripsThroughTheImporter() {
        val bytes = RouteExport.buildGpx(route, startTs, endTs, "running", distanceM = 1234.5)
            .toByteArray(Charsets.UTF_8)
        assertEquals(ActivityFileImporter.Format.GPX, ActivityFileImporter.detectFormat(bytes))
        val a = ActivityFileImporter.parse(bytes, "route.gpx").activity
        assertNotNull(a)
        assertEquals(route.size, a!!.route.size)
        for (i in route.indices) {
            assertEquals(route[i].lat, a.route[i].lat, 1e-5)
            assertEquals(route[i].lon, a.route[i].lon, 1e-5)
        }
        // Interpolated per-point times span the whole window, so start/end round-trip exactly.
        assertEquals(startTs, a.startTs)
        assertEquals(endTs, a.endTs)
    }

    @Test fun fitRoundTripsThroughTheImporter() {
        val bytes = RouteExport.buildFit(
            route, startTs, endTs, "cycling",
            distanceM = 1234.5, energyKcal = 210.0, avgHr = 142, maxHr = 171,
        )
        assertEquals(ActivityFileImporter.Format.FIT, ActivityFileImporter.detectFormat(bytes))
        val a = ActivityFileImporter.parse(bytes, "route.fit").activity
        assertNotNull(a)
        assertEquals(route.size, a!!.route.size)
        for (i in route.indices) {
            assertEquals(route[i].lat, a.route[i].lat, 1e-5)
            assertEquals(route[i].lon, a.route[i].lon, 1e-5)
        }
        assertEquals("Cycling", a.sport)
        assertEquals(1234.5, a.distanceM!!, 0.5)
        assertEquals(210.0, a.energyKcal!!, 0.5)
        assertEquals(142, a.avgHr)
        assertEquals(171, a.maxHr)
        assertEquals(startTs, a.startTs)
        assertEquals(endTs, a.endTs)
    }

    @Test fun fitHasValidHeaderAndCrc() {
        val bytes = RouteExport.buildFit(route, startTs, endTs, "run")
        // 12-byte header, ".FIT" at offset 8, declared data size fits, trailing CRC matches.
        assertEquals(12, bytes[0].toInt() and 0xFF)
        assertEquals('.'.code, bytes[8].toInt() and 0xFF)
        assertEquals('F'.code, bytes[9].toInt() and 0xFF)
        val dataSize = (bytes[4].toInt() and 0xFF) or ((bytes[5].toInt() and 0xFF) shl 8) or
            ((bytes[6].toInt() and 0xFF) shl 16) or ((bytes[7].toInt() and 0xFF) shl 24)
        assertEquals(12 + dataSize + 2, bytes.size) // header + body + 2-byte CRC
        val crc = (bytes[bytes.size - 2].toInt() and 0xFF) or ((bytes[bytes.size - 1].toInt() and 0xFF) shl 8)
        assertEquals(RouteExport.fitCrc(bytes.copyOfRange(0, bytes.size - 2)), crc)
    }

    @Test fun singlePointAndEmptyDegradeGracefully() {
        // One point: still a valid file, one trackpoint at startTs.
        val one = RouteExport.buildFit(listOf(route.first()), startTs, endTs, "walk")
        val a = ActivityFileImporter.parse(one, "x.fit").activity
        assertNotNull(a)
        assertEquals(1, a!!.route.size)
        // Empty GPX is still well-formed (no trackpoints); the importer rejects it without throwing.
        val gpx = RouteExport.buildGpx(emptyList(), startTs, endTs, "run").toByteArray(Charsets.UTF_8)
        assertTrue(String(gpx).contains("<trkseg>"))
    }

    @Test fun fitWithoutHrDoesNotFabricateHr() {
        // Regression: the FIT "no HR" case must decode to NULL HR. validHr accepts 1..300, so a 0xFF
        // sentinel would be misread as a real HR of 255 — the fields must be OMITTED, not sentinelled.
        val bytes = RouteExport.buildFit(route, startTs, endTs, "walk") // no HR, no calories
        val a = ActivityFileImporter.parse(bytes, "x.fit").activity
        assertNotNull(a)
        assertNull(a!!.avgHr)
        assertNull(a.maxHr)
        assertNull(a.energyKcal)
    }

    @Test fun interpolatedTimesSpanTheWindow() {
        val t = RouteExport.interpolatedTimes(5, 1000L, 2000L)
        assertEquals(1000L, t.first())
        assertEquals(2000L, t.last())
        assertEquals(1500L, t[2]) // midpoint
        assertTrue((1 until t.size).all { t[it] >= t[it - 1] })
        assertEquals(longArrayOf(500L).toList(), RouteExport.interpolatedTimes(1, 500L, 900L).toList())
    }

    @Test fun canonicalSportCollapsesAliases() {
        assertEquals("run", RouteExport.canonicalSport("Running"))
        assertEquals("cycle", RouteExport.canonicalSport("bike"))
        assertEquals("walk", RouteExport.canonicalSport("Walking"))
        assertEquals("hike", RouteExport.canonicalSport("hiking"))
        assertEquals("other", RouteExport.canonicalSport(null))
    }
}
