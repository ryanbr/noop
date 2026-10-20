package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * GpxHrInject is the byte-for-byte twin of the Swift `GpxHrInjector` (`Packages/StrandImport`),
 * verified BY ORACLE per AGENTS.md: the expected strings below are the Swift implementation's stdout
 * over these exact fixtures (generated with a throwaway `swift test` printer on 2026-10-20), pasted
 * verbatim. A Kotlin-side change that alters any output byte fails here; the Swift side is pinned by
 * `GpxHrInjectorTests`' round-trip + preservation assertions. The oracle guards Kotlin→Swift drift
 * only in the direction it is written; the Swift suite guards the other.
 */
class GpxHrInjectTest {

    private val t0 = 1_760_000_000L

    private fun hr(vararg pairs: Pair<Long, Int>) =
        pairs.map { ActivityFileImporter.HrPoint(it.first, it.second) }

    // ── Fixture A: Strava-shaped export, 5 per-second points, exact-match HR 140…144 ─────────────

    private val fixtureA = """<?xml version="1.0" encoding="UTF-8"?>
<gpx creator="StravaGPX" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd" version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
 <metadata>
  <time>2025-10-09T08:53:20Z</time>
 </metadata>
 <trk>
  <name>Morning Run</name>
  <type>running</type>
  <trkseg>
   <trkpt lat="43.6532000" lon="-79.3832000">
    <ele>76</ele>
    <time>2025-10-09T08:53:20Z</time>
   </trkpt>
   <trkpt lat="43.6533000" lon="-79.3831000">
    <ele>77</ele>
    <time>2025-10-09T08:53:21Z</time>
   </trkpt>
   <trkpt lat="43.6534000" lon="-79.3830000">
    <ele>78</ele>
    <time>2025-10-09T08:53:22Z</time>
   </trkpt>
   <trkpt lat="43.6535000" lon="-79.3829000">
    <ele>79</ele>
    <time>2025-10-09T08:53:23Z</time>
   </trkpt>
   <trkpt lat="43.6536000" lon="-79.3828000">
    <ele>80</ele>
    <time>2025-10-09T08:53:24Z</time>
   </trkpt>
  </trkseg>
 </trk>
</gpx>"""

    private val expectedA = """<?xml version="1.0" encoding="UTF-8"?>
<gpx creator="StravaGPX" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd" version="1.1" xmlns="http://www.topografix.com/GPX/1/1" xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
 <metadata>
  <time>2025-10-09T08:53:20Z</time>
 </metadata>
 <trk>
  <name>Morning Run</name>
  <type>running</type>
  <trkseg>
   <trkpt lat="43.6532000" lon="-79.3832000">
    <ele>76</ele>
    <time>2025-10-09T08:53:20Z</time>
   <extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>140</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions></trkpt>
   <trkpt lat="43.6533000" lon="-79.3831000">
    <ele>77</ele>
    <time>2025-10-09T08:53:21Z</time>
   <extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>141</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions></trkpt>
   <trkpt lat="43.6534000" lon="-79.3830000">
    <ele>78</ele>
    <time>2025-10-09T08:53:22Z</time>
   <extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>142</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions></trkpt>
   <trkpt lat="43.6535000" lon="-79.3829000">
    <ele>79</ele>
    <time>2025-10-09T08:53:23Z</time>
   <extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>143</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions></trkpt>
   <trkpt lat="43.6536000" lon="-79.3828000">
    <ele>80</ele>
    <time>2025-10-09T08:53:24Z</time>
   <extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>144</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions></trkpt>
  </trkseg>
 </trk>
</gpx>"""

    @Test
    fun oracleA_stravaShapedExport_matchesSwiftByteForByte() {
        val out = GpxHrInject.inject(fixtureA, hr(*(0 until 5).map { (t0 + it) to (140 + it) }.toTypedArray()))
        assertEquals(5, out.matched)
        assertEquals(5, out.total)
        assertEquals(t0, out.startTs)
        assertEquals(t0 + 4, out.endTs)
        assertEquals(expectedA, out.gpx)
    }

    // ── Fixture B: existing <extensions> with power — TrackPointExtension goes inside it ─────────

    private val fixtureB = """<?xml version="1.0" encoding="UTF-8"?>
<gpx creator="test" version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
 <trk><trkseg>
  <trkpt lat="43.6532" lon="-79.3832"><time>2025-10-09T08:53:20Z</time><extensions><power>200</power></extensions></trkpt>
 </trkseg></trk>
</gpx>"""

    private val expectedB = """<?xml version="1.0" encoding="UTF-8"?>
<gpx creator="test" version="1.1" xmlns="http://www.topografix.com/GPX/1/1" xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
 <trk><trkseg>
  <trkpt lat="43.6532" lon="-79.3832"><time>2025-10-09T08:53:20Z</time><extensions><power>200</power><gpxtpx:TrackPointExtension><gpxtpx:hr>155</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions></trkpt>
 </trkseg></trk>
</gpx>"""

    @Test
    fun oracleB_existingExtensionsBlock_matchesSwiftByteForByte() {
        val out = GpxHrInject.inject(fixtureB, hr(t0 to 155))
        assertEquals(1, out.matched)
        assertEquals(1, out.total)
        assertEquals(expectedB, out.gpx)
    }

    // ── Fixture C: 10 s spacing; nearest sample 0 s / 4 s / 6 s away → 2 of 3 matched ───────────

    private val fixtureC = """<?xml version="1.0" encoding="UTF-8"?>
<gpx creator="test" version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
 <trk><trkseg>
  <trkpt lat="1.0" lon="2.0"><time>2025-10-09T08:53:20Z</time></trkpt>
  <trkpt lat="1.1" lon="2.1"><time>2025-10-09T08:53:30Z</time></trkpt>
  <trkpt lat="1.2" lon="2.2"><time>2025-10-09T08:53:40Z</time></trkpt>
 </trkseg></trk>
</gpx>"""

    private val expectedC = """<?xml version="1.0" encoding="UTF-8"?>
<gpx creator="test" version="1.1" xmlns="http://www.topografix.com/GPX/1/1" xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
 <trk><trkseg>
  <trkpt lat="1.0" lon="2.0"><time>2025-10-09T08:53:20Z</time><extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>130</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions></trkpt>
  <trkpt lat="1.1" lon="2.1"><time>2025-10-09T08:53:30Z</time><extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>161</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions></trkpt>
  <trkpt lat="1.2" lon="2.2"><time>2025-10-09T08:53:40Z</time></trkpt>
 </trkseg></trk>
</gpx>"""

    @Test
    fun oracleC_toleranceWindow_matchesSwiftByteForByte() {
        val out = GpxHrInject.inject(fixtureC, hr(t0 to 130, (t0 + 14) to 161, (t0 + 26) to 170))
        assertEquals(2, out.matched)
        assertEquals(3, out.total)
        assertEquals(expectedC, out.gpx)
    }

    // ── Behaviour pins beyond the oracle (same cases the Swift suite asserts) ─────────────────────

    @Test
    fun timeWindowReadsFirstToLastTimedPoint() {
        assertEquals(t0..(t0 + 20), GpxHrInject.timeWindow(fixtureC))
    }

    @Test
    fun equidistantNeighboursTakeTheEarlierSample() {
        val out = GpxHrInject.inject(fixtureB, hr((t0 - 2) to 111, (t0 + 2) to 222))
        assertTrue(out.gpx.contains("<gpxtpx:hr>111</gpxtpx:hr>"))
    }

    @Test
    fun unsortedSamplesAreHandled() {
        val out = GpxHrInject.inject(fixtureC, hr((t0 + 10) to 145, t0 to 140))
        assertEquals(2, out.matched)
    }

    @Test(expected = GpxHrInject.Failure.AlreadyHasHeartRate::class)
    fun refusesAFileThatAlreadyCarriesHeartRate() {
        val src = """<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1" xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
 <trk><trkseg>
  <trkpt lat="1" lon="2"><time>2025-10-09T08:53:20Z</time><extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>150</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions></trkpt>
 </trkseg></trk>
</gpx>"""
        GpxHrInject.inject(src, hr(t0 to 1))
    }

    @Test
    fun refusesWhenNoSampleFallsInTheWindow() {
        try {
            GpxHrInject.inject(fixtureC, hr((t0 + 3600) to 140))
            throw AssertionError("expected NoHeartRateMatched")
        } catch (e: GpxHrInject.Failure.NoHeartRateMatched) {
            assertEquals(t0, e.startTs)
            assertEquals(t0 + 20, e.endTs)
            assertEquals(3, e.points)
            assertEquals(1, e.samples)
        }
    }

    @Test(expected = GpxHrInject.Failure.NotGpx::class)
    fun refusesNonGpxData() {
        GpxHrInject.inject("not xml", hr(t0 to 1))
    }

    @Test(expected = GpxHrInject.Failure.NoTimedTrackpoints::class)
    fun refusesATrackWithNoTimestamps() {
        GpxHrInject.inject(
            """<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1"><trk><trkseg><trkpt lat="1" lon="2"><ele>10</ele></trkpt></trkseg></trk></gpx>""",
            hr(t0 to 1),
        )
    }

    @Test
    fun selfClosingTrackpointsAreSkippedNotFatal() {
        val src = """<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
 <trk><trkseg>
  <trkpt lat="1" lon="2"/>
  <trkpt lat="1" lon="2"><time>2025-10-09T08:53:20Z</time></trkpt>
 </trkseg></trk>
</gpx>"""
        val out = GpxHrInject.inject(src, hr(t0 to 133))
        assertEquals(1, out.matched)
        assertEquals(1, out.total)
    }
}
