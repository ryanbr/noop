import XCTest
@testable import WhoopStore

/// `HypnogramCoverage` — the ratio that tells a well-formed-looking stage timeline from one that
/// describes only part of the night it claims.
final class HypnogramCoverageTests: XCTestCase {

    /// Segments tiling `[0, span)` in 30 s steps, `n` of them, starting at `from`.
    private func segs(_ ranges: [(Int, Int, String)]) -> String {
        "[" + ranges.map { "{\"start\":\($0.0),\"end\":\($0.1),\"stage\":\"\($0.2)\"}" }
            .joined(separator: ",") + "]"
    }

    // MARK: - the ratio itself

    func testFractionIsCoveredOverSpan() {
        XCTAssertEqual(HypnogramCoverage.fraction(coveredSeconds: 300, spanSeconds: 600)!, 0.5, accuracy: 1e-12)
        XCTAssertEqual(HypnogramCoverage.fraction(coveredSeconds: 600, spanSeconds: 600)!, 1.0, accuracy: 1e-12)
    }

    /// Overlapping/overhanging segments would otherwise report more than a whole night. A completeness
    /// gate must read that as "complete", never manufacture a failure out of malformed input.
    func testFractionClampsAboveOne() {
        XCTAssertEqual(HypnogramCoverage.fraction(coveredSeconds: 900, spanSeconds: 600)!, 1.0, accuracy: 1e-12)
    }

    /// nil means "unknown, do not judge" — distinct from 0, which a caller comparing against
    /// `minCoverage` would read as a bad night.
    func testFractionNilWhenNothingToMeasure() {
        XCTAssertNil(HypnogramCoverage.fraction(coveredSeconds: 300, spanSeconds: 0))
        XCTAssertNil(HypnogramCoverage.fraction(coveredSeconds: 300, spanSeconds: -1))
        XCTAssertNil(HypnogramCoverage.fraction(coveredSeconds: 0, spanSeconds: 600))
    }

    // MARK: - from a stored payload

    func testTilingTimelineCoversItsSpan() {
        let json = segs([(0, 300, "light"), (300, 600, "deep")])
        XCTAssertEqual(HypnogramCoverage.fraction(stagesJSON: json, spanSeconds: 600)!, 1.0, accuracy: 1e-12)
        XCTAssertFalse(HypnogramCoverage.isHoled(stagesJSON: json, spanSeconds: 600))
    }

    /// The shape this whole change exists for: a hypnogram assembled from records that arrived
    /// incomplete. Many segments, all real, spanning a night they only partly describe. The measured
    /// worst case was 140 minutes of segments across a 601-minute span.
    func testHoledTimelineIsDetected() {
        let json = segs([(0, 4200, "light"), (4200, 8400, "deep")])   // 140 min over a 601 min span
        let span = 601.0 * 60.0
        let f = HypnogramCoverage.fraction(stagesJSON: json, spanSeconds: span)!
        XCTAssertEqual(f, 8400.0 / span, accuracy: 1e-12)
        XCTAssertLessThan(f, 0.24)
        XCTAssertTrue(HypnogramCoverage.isHoled(stagesJSON: json, spanSeconds: span))
    }

    /// A hole in the MIDDLE is the real failure mode (a page that never arrived), not a short tail.
    func testInteriorHoleCounts() {
        let json = segs([(0, 300, "light"), (900, 1200, "deep")])     // 600 s of 1200 s
        XCTAssertEqual(HypnogramCoverage.fraction(stagesJSON: json, spanSeconds: 1200)!, 0.5, accuracy: 1e-12)
    }

    func testThresholdBoundaryIsInclusive() {
        // exactly minCoverage is NOT holed; a hair under it is.
        let atGate = segs([(0, 950, "light")])
        let underGate = segs([(0, 949, "light")])
        XCTAssertFalse(HypnogramCoverage.isHoled(stagesJSON: atGate, spanSeconds: 1000))
        XCTAssertTrue(HypnogramCoverage.isHoled(stagesJSON: underGate, spanSeconds: 1000))
    }

    // MARK: - what must NOT be judged

    /// The imported minute-dict shape carries no timestamps, so coverage is unanswerable. It must come
    /// back nil (not 0), which is what keeps every WHOOP/Apple/Health-Connect import out of this gate.
    func testImportedMinuteDictIsUnmeasurable() {
        let dict = "{\"light\":300,\"deep\":100,\"rem\":80,\"awake\":40}"
        XCTAssertNil(HypnogramCoverage.fraction(stagesJSON: dict, spanSeconds: 3600))
        XCTAssertFalse(HypnogramCoverage.isHoled(stagesJSON: dict, spanSeconds: 3600))
    }

    func testEmptyAndMalformedAreUnmeasurable() {
        for payload in [nil, "", "   ", "[]", "not json"] as [String?] {
            XCTAssertNil(HypnogramCoverage.fraction(stagesJSON: payload, spanSeconds: 3600),
                         "payload \(String(describing: payload)) should be unmeasurable")
            XCTAssertFalse(HypnogramCoverage.isHoled(stagesJSON: payload, spanSeconds: 3600),
                           "an unmeasurable payload must never read as holed")
        }
    }

    /// Every guard built on this fails OPEN: unknown coverage keeps the previous behaviour rather than
    /// downgrading a night on no evidence.
    func testSessionOverloadUsesItsOwnSpan() {
        let holed = CachedSleepSession(startTs: 0, endTs: 1200, efficiency: nil, restingHr: nil,
                                       avgHrv: nil, stagesJSON: segs([(0, 300, "light")]))
        let whole = CachedSleepSession(startTs: 0, endTs: 1200, efficiency: nil, restingHr: nil,
                                       avgHrv: nil, stagesJSON: segs([(0, 1200, "light")]))
        let stageless = CachedSleepSession(startTs: 0, endTs: 1200, efficiency: nil, restingHr: nil,
                                          avgHrv: nil, stagesJSON: nil)
        XCTAssertTrue(HypnogramCoverage.isHoled(holed))
        XCTAssertFalse(HypnogramCoverage.isHoled(whole))
        XCTAssertFalse(HypnogramCoverage.isHoled(stageless))
    }

    // MARK: - shapes the two readers must agree on

    /// The four payloads on which Swift and Kotlin originally DISAGREED, found by compiling both and
    /// running them rather than by reading them side by side. Swift's whole-array cast makes one
    /// non-object element poison the payload; the Kotlin twin used to skip that element and measure the
    /// remainder, reading 0.1 and HOLED where this side read nil and not-holed. It now bails the same
    /// way. Kept here so the agreement is asserted from BOTH sides, not only in the Kotlin oracle.
    func testNonObjectElementMakesThePayloadUnmeasurable() {
        for json in [#"[{"start":0,"end":100,"stage":"deep"},5]"#,
                     #"[{"start":0,"end":100,"stage":"deep"},null]"#,
                     #"[{"start":0,"end":100,"stage":"deep"},"x"]"#] {
            XCTAssertNil(HypnogramCoverage.fraction(stagesJSON: json, spanSeconds: 1000),
                         "one non-object element must make the whole payload unmeasurable")
            XCTAssertFalse(HypnogramCoverage.isHoled(stagesJSON: json, spanSeconds: 1000))
        }
    }

    /// A string-valued bound is SKIPPED, not parsed: `NSString` is not an `NSNumber`. The Kotlin twin
    /// reached the same answer only after dropping `optDouble`, which parses `"0"` happily.
    func testStringBoundsAreNotCounted() {
        let json = #"[{"start":"0","end":"100","stage":"deep"}]"#
        XCTAssertNil(HypnogramCoverage.fraction(stagesJSON: json, spanSeconds: 1000))
    }

    /// A bool bound DOES convert, on both sides — `JSONSerialization` bridges `true` to `NSNumber` 1.
    /// Absurd in a stage payload and unreachable from any producer, pinned because it is the one case
    /// where the tidy-looking alignment (reject anything that is not a number) would have been wrong:
    /// under Foundation `{"start":0}` reports `is Bool == true`, so a bool exclusion would have thrown
    /// away every timeline whose first segment starts at zero.
    func testBoolBoundConvertsOnBothSides() {
        let json = #"[{"start":true,"end":100,"stage":"deep"}]"#
        XCTAssertEqual(HypnogramCoverage.fraction(stagesJSON: json, spanSeconds: 1000)!, 0.099, accuracy: 1e-12)
    }

    /// SCOPE: a timestamped import is judged like any other timeline. This is the Xiaomi Band shape —
    /// real `{start,end,stage}` segments whose span comes from separate bed/wake fields — and it is the
    /// one importer this gate reaches. Timestamp-free imports stay exempt, asserted above.
    func testTimestampedImportIsInScope() {
        let json = segs([(0, 3600, "light")])
        XCTAssertEqual(HypnogramCoverage.fraction(stagesJSON: json, spanSeconds: 28800)!, 0.125, accuracy: 1e-12)
        XCTAssertTrue(HypnogramCoverage.isHoled(stagesJSON: json, spanSeconds: 28800))
    }

    /// The ENGINE call site sums coverage off decoded segments, not off `stagesJSON`, so the payload
    /// shape rule that exempts timestamp-free imports at the merge does not run there. What actually
    /// protects them is this: a group with no timestamped stages at all covers zero, and zero cover is
    /// unmeasurable rather than bad. Holds only while a group is single-sourced — a group mixing a
    /// staged fragment with a minute-dict one covers part of its total span and reads as holed.
    func testGroupWithNoTimestampedStagesIsUnmeasurableNotHoled() {
        XCTAssertNil(HypnogramCoverage.fraction(coveredSeconds: 0, spanSeconds: 8 * 3600))
    }

    func testMixedSourceGroupReadsAsHoled() {
        // 8 h fully-staged fragment + a 2 h minute-dict fragment that decodes to no segments.
        let covered = 8.0 * 3600, span = 10.0 * 3600
        XCTAssertEqual(HypnogramCoverage.fraction(coveredSeconds: covered, spanSeconds: span)!, 0.8, accuracy: 1e-12)
        XCTAssertLessThan(0.8, HypnogramCoverage.minCoverage)
    }

    /// Health Connect's REAL payload shape. The `minute-dict` case above is the throwing
    /// `{light,deep,rem,awake}` object; HC emits an ARRAY of `{stage,min}` objects, which parses
    /// cleanly and reaches the segment loop. It is the live producer shape this gate claims to be
    /// exempt from, so it is pinned rather than argued: every element is an object (no whole-cast
    /// failure), none carries bounds (every segment skipped), cover stays 0, and zero cover is
    /// unmeasurable rather than bad.
    func testHealthConnectStageMinArrayIsUnmeasurable() {
        let json = #"[{"stage":"light","min":300},{"stage":"deep","min":100}]"#
        XCTAssertNil(HypnogramCoverage.fraction(stagesJSON: json, spanSeconds: 3600))
        XCTAssertFalse(HypnogramCoverage.isHoled(stagesJSON: json, spanSeconds: 3600))
    }

    /// A JSON null BOUND inside an otherwise well-formed object: the object is fine, so neither side
    /// bails; both fail to read the bound and skip the segment.
    func testNullBoundSkipsTheSegment() {
        XCTAssertNil(HypnogramCoverage.fraction(stagesJSON: #"[{"start":null,"end":100,"stage":"deep"}]"#,
                                                spanSeconds: 1000))
    }
}
