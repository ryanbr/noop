import XCTest
@testable import StrandImport

/// GpxHrInjector is validated two ways: ROUND-TRIP through ``ActivityFileImporter`` (the merged file
/// must parse back with the injected HR on the same track, through the same decoder that reads real
/// Strava files), and PRESERVATION (stripping the inserted blocks must restore the source document
/// byte-for-byte — the merge is text surgery, never a reserialize). The Kotlin twin
/// (`GpxHrInjectTest`) asserts the same output bytes by oracle.
final class GpxHrInjectorTests: XCTestCase {

    private let t0 = 1_760_000_000 // 2025-10-09T09:33:20Z

    /// A Strava-shaped GPX export: StravaGPX creator, metadata time, trk name/type, per-second
    /// trkpts with ele + time and NO heart rate — exactly what "Export GPX" yields for a run
    /// recorded with no HR sensor.
    private func stravaGpx(points: Int, step: Int = 1) -> Data {
        var s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx creator="StravaGPX" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd" version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
         <metadata>
          <time>\(iso(t0))</time>
         </metadata>
         <trk>
          <name>Morning Run</name>
          <type>running</type>
          <trkseg>

        """
        for i in 0..<points {
            let lat = 43.6532 + Double(i) * 0.0001
            let lon = -79.3832 + Double(i) * 0.0001
            s += """
               <trkpt lat="\(String(format: "%.7f", lat))" lon="\(String(format: "%.7f", lon))">
                <ele>\(76 + i)</ele>
                <time>\(iso(t0 + i * step))</time>
               </trkpt>

            """
        }
        s += """
          </trkseg>
         </trk>
        </gpx>

        """
        return Data(s.utf8)
    }

    private func iso(_ ts: Int) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    private func hr(_ pairs: [(Int, Int)]) -> [ActivityHRSample] {
        pairs.map { ActivityHRSample(ts: $0.0, bpm: $0.1) }
    }

    // MARK: - Happy path

    func testInjectsHrIntoEveryTimedTrackpointAndRoundTrips() throws {
        let src = stravaGpx(points: 5)
        let samples = hr((0..<5).map { (t0 + $0, 140 + $0) })
        let out = try GpxHrInjector.inject(gpx: src, hr: samples)
        XCTAssertEqual(out.matched, 5)
        XCTAssertEqual(out.total, 5)
        XCTAssertEqual(out.startTs, t0)
        XCTAssertEqual(out.endTs, t0 + 4)

        let text = String(data: out.gpx, encoding: .utf8)!
        XCTAssertTrue(text.contains("xmlns:gpxtpx=\"http://www.garmin.com/xmlschemas/TrackPointExtension/v1\""))
        XCTAssertEqual(text.components(separatedBy: "<gpxtpx:hr>").count - 1, 5)
        XCTAssertTrue(text.contains("<gpxtpx:hr>140</gpxtpx:hr>"))
        XCTAssertTrue(text.contains("<gpxtpx:hr>144</gpxtpx:hr>"))

        // Round-trip through the app's own GPX decoder: track, times, and the injected HR all read back.
        let a = ActivityFileImporter.parse(data: out.gpx, filename: "run.gpx").activity
        XCTAssertNotNil(a)
        XCTAssertEqual(a!.route.count, 5)
        XCTAssertEqual(a!.hrSampleCount, 5)
        XCTAssertEqual(a!.hrSamples.map(\.bpm), [140, 141, 142, 143, 144])
        XCTAssertEqual(a!.avgHr, 142)
        XCTAssertEqual(Int(a!.start.timeIntervalSince1970), t0)
    }

    func testPreservesTheSourceDocumentOutsideTheInsertedBlocks() throws {
        let src = stravaGpx(points: 3)
        let samples = hr((0..<3).map { (t0 + $0, 150) })
        let out = try GpxHrInjector.inject(gpx: src, hr: samples)
        var text = String(data: out.gpx, encoding: .utf8)!
        // Strip exactly what the injector claims to add; the source must come back byte-for-byte.
        text = text.replacingOccurrences(
            of: "<extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>150</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions>",
            with: "")
        text = text.replacingOccurrences(
            of: " xmlns:gpxtpx=\"http://www.garmin.com/xmlschemas/TrackPointExtension/v1\"",
            with: "")
        XCTAssertEqual(Data(text.utf8), src)
    }

    func testUsesAnExistingExtensionsBlockInsteadOfAddingASecond() throws {
        let src = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx creator="test" version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
         <trk><trkseg>
          <trkpt lat="43.6532" lon="-79.3832"><time>\(iso(t0))</time><extensions><power>200</power></extensions></trkpt>
         </trkseg></trk>
        </gpx>
        """
        let out = try GpxHrInjector.inject(gpx: Data(src.utf8), hr: hr([(t0, 155)]))
        let text = String(data: out.gpx, encoding: .utf8)!
        XCTAssertEqual(text.components(separatedBy: "<extensions>").count - 1, 1)
        XCTAssertTrue(text.contains("<power>200</power><gpxtpx:TrackPointExtension><gpxtpx:hr>155</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions>"))
    }

    func testDoesNotRedeclareAnExistingGpxtpxNamespace() throws {
        let src = """
        <gpx creator="test" version="1.1" xmlns="http://www.topografix.com/GPX/1/1" xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
         <trk><trkseg><trkpt lat="1" lon="2"><time>\(iso(t0))</time></trkpt></trkseg></trk>
        </gpx>
        """
        let out = try GpxHrInjector.inject(gpx: Data(src.utf8), hr: hr([(t0, 120)]))
        let text = String(data: out.gpx, encoding: .utf8)!
        XCTAssertEqual(text.components(separatedBy: "xmlns:gpxtpx").count - 1, 1)
    }

    // MARK: - Matching rules

    func testMatchesNearestSampleWithinToleranceAndSkipsBeyondIt() throws {
        let src = stravaGpx(points: 3, step: 10) // t0, t0+10, t0+20
        // t0 exact; t0+10 nearest is 4 s away (within 5); t0+20 nearest is 6 s away (outside).
        let samples = hr([(t0, 130), (t0 + 14, 161), (t0 + 26, 170)])
        let out = try GpxHrInjector.inject(gpx: src, hr: samples)
        XCTAssertEqual(out.matched, 2)
        XCTAssertEqual(out.total, 3)
        let text = String(data: out.gpx, encoding: .utf8)!
        XCTAssertTrue(text.contains("<gpxtpx:hr>130</gpxtpx:hr>"))
        XCTAssertTrue(text.contains("<gpxtpx:hr>161</gpxtpx:hr>"))
        XCTAssertFalse(text.contains("<gpxtpx:hr>170</gpxtpx:hr>"))
    }

    func testEquidistantNeighboursTakeTheEarlierSample() throws {
        let src = stravaGpx(points: 1)
        let samples = hr([(t0 - 2, 111), (t0 + 2, 222)])
        let out = try GpxHrInjector.inject(gpx: src, hr: samples)
        XCTAssertTrue(String(data: out.gpx, encoding: .utf8)!.contains("<gpxtpx:hr>111</gpxtpx:hr>"))
    }

    func testUnsortedSamplesAreHandled() throws {
        let src = stravaGpx(points: 2)
        let samples = hr([(t0 + 1, 145), (t0, 140)])
        let out = try GpxHrInjector.inject(gpx: src, hr: samples)
        XCTAssertEqual(out.matched, 2)
    }

    // MARK: - Refusals (each must be LOUD and carry its numbers)

    func testRefusesAFileThatAlreadyCarriesHeartRate() {
        let src = """
        <gpx creator="test" version="1.1" xmlns="http://www.topografix.com/GPX/1/1" xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
         <trk><trkseg>
          <trkpt lat="1" lon="2"><time>\(iso(t0))</time><extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>150</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions></trkpt>
          <trkpt lat="1" lon="2"><time>\(iso(t0 + 1))</time></trkpt>
         </trkseg></trk>
        </gpx>
        """
        XCTAssertThrowsError(try GpxHrInjector.inject(gpx: Data(src.utf8), hr: hr([(t0, 1)]))) { error in
            XCTAssertEqual(error as? GpxHrInjector.Failure, .alreadyHasHeartRate(points: 1))
        }
    }

    func testRefusesWhenNoSampleFallsInTheWindow() {
        let src = stravaGpx(points: 3)
        let samples = hr([(t0 + 3600, 140)])
        XCTAssertThrowsError(try GpxHrInjector.inject(gpx: src, hr: samples)) { error in
            XCTAssertEqual(error as? GpxHrInjector.Failure,
                           .noHeartRateMatched(startTs: t0, endTs: t0 + 2, points: 3, samples: 1))
        }
    }

    func testRefusesWhenNoSamplesAreOfferedAtAll() {
        XCTAssertThrowsError(try GpxHrInjector.inject(gpx: stravaGpx(points: 2), hr: [])) { error in
            XCTAssertEqual(error as? GpxHrInjector.Failure,
                           .noHeartRateMatched(startTs: t0, endTs: t0 + 1, points: 2, samples: 0))
        }
    }

    func testRefusesATrackWithNoTimestamps() {
        let src = """
        <gpx creator="test" version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
         <trk><trkseg><trkpt lat="1" lon="2"><ele>10</ele></trkpt></trkseg></trk>
        </gpx>
        """
        XCTAssertThrowsError(try GpxHrInjector.inject(gpx: Data(src.utf8), hr: hr([(t0, 1)]))) { error in
            XCTAssertEqual(error as? GpxHrInjector.Failure, .noTimedTrackpoints)
        }
        XCTAssertThrowsError(try GpxHrInjector.timeWindow(gpx: Data(src.utf8)))
    }

    func testRefusesNonGpxData() {
        XCTAssertThrowsError(try GpxHrInjector.inject(gpx: Data("not xml".utf8), hr: hr([(t0, 1)]))) { error in
            XCTAssertEqual(error as? GpxHrInjector.Failure, .notGpx)
        }
    }

    // MARK: - Window

    func testTimeWindowReadsFirstToLastTimedPoint() throws {
        let window = try GpxHrInjector.timeWindow(gpx: stravaGpx(points: 4, step: 30))
        XCTAssertEqual(window, t0...(t0 + 90))
    }

    func testSelfClosingTrackpointsAreSkippedNotFatal() throws {
        let src = """
        <gpx creator="test" version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
         <trk><trkseg>
          <trkpt lat="1" lon="2"/>
          <trkpt lat="1" lon="2"><time>\(iso(t0))</time></trkpt>
         </trkseg></trk>
        </gpx>
        """
        let out = try GpxHrInjector.inject(gpx: Data(src.utf8), hr: hr([(t0, 133)]))
        XCTAssertEqual(out.matched, 1)
        XCTAssertEqual(out.total, 1)
    }
}
