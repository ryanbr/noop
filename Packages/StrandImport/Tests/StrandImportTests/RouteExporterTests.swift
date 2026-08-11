import XCTest
@testable import StrandImport

/// RouteExporter (GPX/FIT) is validated by ROUND-TRIP through ``ActivityFileImporter``: a route + metadata
/// is exported, then re-parsed, and the decoded track/summary must match. This pins the encoders against
/// the app's own decoders (the same ones that read real Strava/Garmin files), so a byte-layout regression
/// in either format is caught in `swift-packages` CI. The Kotlin twin (`RouteExportTest`) asserts the same.
final class RouteExporterTests: XCTestCase {

    private let route = [
        RoutePoint(lat: 37.334900, lon: -122.009000),
        RoutePoint(lat: 37.335200, lon: -122.008400),
        RoutePoint(lat: 37.335900, lon: -122.007700),
        RoutePoint(lat: 37.336500, lon: -122.006900),
    ]
    private let startTs = 1_723_000_000
    private let endTs = 1_723_001_800 // +30 min

    func testGpxRoundTripsThroughTheImporter() {
        let data = RouteExporter.render(.gpx, route: route, startTs: startTs, endTs: endTs,
                                        sport: "running", distanceM: 1234.5)
        XCTAssertEqual(ActivityFileImporter.detectFormat(data: data), .gpx)
        let a = ActivityFileImporter.parse(data: data, filename: "route.gpx").activity
        XCTAssertNotNil(a)
        XCTAssertEqual(a!.route.count, route.count)
        for i in route.indices {
            XCTAssertEqual(a!.route[i].lat, route[i].lat, accuracy: 1e-5)
            XCTAssertEqual(a!.route[i].lon, route[i].lon, accuracy: 1e-5)
        }
        XCTAssertEqual(Int(a!.start.timeIntervalSince1970), startTs)
        XCTAssertEqual(Int(a!.end.timeIntervalSince1970), endTs)
    }

    func testFitRoundTripsThroughTheImporter() {
        let data = RouteExporter.render(.fit, route: route, startTs: startTs, endTs: endTs,
                                        sport: "cycling", distanceM: 1234.5, energyKcal: 210, avgHr: 142, maxHr: 171)
        XCTAssertEqual(ActivityFileImporter.detectFormat(data: data), .fit)
        let a = ActivityFileImporter.parse(data: data, filename: "route.fit").activity
        XCTAssertNotNil(a)
        XCTAssertEqual(a!.route.count, route.count)
        for i in route.indices {
            XCTAssertEqual(a!.route[i].lat, route[i].lat, accuracy: 1e-5)
            XCTAssertEqual(a!.route[i].lon, route[i].lon, accuracy: 1e-5)
        }
        XCTAssertEqual(a!.sport?.lowercased().contains("cycl"), true)
        XCTAssertEqual(a!.distanceM ?? 0, 1234.5, accuracy: 0.5)
        XCTAssertEqual(a!.energyKcal ?? 0, 210, accuracy: 0.5)
        XCTAssertEqual(a!.avgHr, 142)
        XCTAssertEqual(a!.maxHr, 171)
        XCTAssertEqual(Int(a!.start.timeIntervalSince1970), startTs)
        XCTAssertEqual(Int(a!.end.timeIntervalSince1970), endTs)
    }

    func testFitHasValidHeaderAndCrc() {
        let bytes = [UInt8](RouteExporter.render(.fit, route: route, startTs: startTs, endTs: endTs, sport: "run"))
        XCTAssertEqual(Int(bytes[0]), 12)                  // header size
        XCTAssertEqual(Array(bytes[8...11]), Array(".FIT".utf8)) // ".FIT"
        let dataSize = Int(bytes[4]) | (Int(bytes[5]) << 8) | (Int(bytes[6]) << 16) | (Int(bytes[7]) << 24)
        XCTAssertEqual(bytes.count, 12 + dataSize + 2)     // header + body + 2-byte CRC
        let crc = Int(bytes[bytes.count - 2]) | (Int(bytes[bytes.count - 1]) << 8)
        XCTAssertEqual(RouteExporter.fitCrc(Array(bytes[0..<(bytes.count - 2)])), crc)
    }

    func testFitWithoutHrDoesNotFabricateHr() {
        // Regression: the FIT "no HR" case must decode to nil HR. validHr accepts 1...300, so a 0xFF
        // sentinel would be misread as a real HR of 255 — the fields must be OMITTED, not sentinelled.
        let data = RouteExporter.render(.fit, route: route, startTs: startTs, endTs: endTs, sport: "walk")
        let a = ActivityFileImporter.parse(data: data, filename: "x.fit").activity
        XCTAssertNotNil(a)
        XCTAssertNil(a!.avgHr)
        XCTAssertNil(a!.maxHr)
        XCTAssertNil(a!.energyKcal)
    }

    func testInterpolatedTimesSpanTheWindow() {
        let t = RouteExporter.interpolatedTimes(5, 1000, 2000)
        XCTAssertEqual(t.first, 1000)
        XCTAssertEqual(t.last, 2000)
        XCTAssertEqual(t[2], 1500)
        XCTAssertEqual(RouteExporter.interpolatedTimes(1, 500, 900), [500])
    }

    func testIsoMatchesTheKotlinInstantFormat() {
        // Kotlin's Instant.ofEpochSecond(1_723_000_000).toString() == "2024-08-07T03:06:40Z".
        XCTAssertEqual(RouteExporter.iso(1_723_000_000), "2024-08-07T03:06:40Z")
        XCTAssertEqual(RouteExporter.iso(0), "1970-01-01T00:00:00Z")
    }

    func testCanonicalSportCollapsesAliases() {
        XCTAssertEqual(RouteExporter.canonicalSport("Running"), "run")
        XCTAssertEqual(RouteExporter.canonicalSport("bike"), "cycle")
        XCTAssertEqual(RouteExporter.canonicalSport("Walking"), "walk")
        XCTAssertEqual(RouteExporter.canonicalSport(nil), "other")
    }
}
