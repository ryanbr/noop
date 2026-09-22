import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// Twin of the Kotlin `SleepStagerHrOnlyTraceTest`. The expected strings are byte-identical on both
/// platforms on purpose — these lines exist to be read side by side.
final class SleepStagerHrOnlyTraceTests: XCTestCase {

    func testLineNamesTheDerivedThresholdAndLongestCandidate() {
        XCTAssertEqual(
            SleepStager.GateTrace.hrOnlyLine(day: "2026-09-23", anchorBpm: 61.0, bandBpm: 64.05, hrP50: 74.0, hrP90: 88.0, epochs: 3021, runs: 48,
                                             mergedRuns: 12, sleepRuns: 7, longestSleepMin: 41,
                                             staged: 0, kept: 0, minSleepMin: 60),
            "[sleep] hr-only spine day=2026-09-23 anchorBpm=61.0 bandBpm=64.1 hrP50=74.0 hrP90=88.0 "
                + "epochs=3021 runs=48 merged=12 "
                + "sleepRuns=7 longestMin=41 staged=0 kept=0 minSleepMin=60"
        )
    }

    func testAbsentAnchorPrintsNilRatherThanZero() {
        let line = SleepStager.GateTrace.hrOnlyLine(day: "2026-09-23", anchorBpm: nil, bandBpm: nil, hrP50: nil, hrP90: nil, epochs: 0, runs: 0,
                                                    mergedRuns: 0, sleepRuns: 0, longestSleepMin: 0,
                                                    staged: 0, kept: 0, minSleepMin: 60)
        XCTAssertTrue(line.contains("anchorBpm=nil bandBpm=nil"))
    }

    /// `epochs` counts EPOCHS, not samples — the axis every other number is measured on. Twin of the
    /// Kotlin test, which guards a bug I actually made: the first version reported the HR sample count.
    func testEpochsCountsEpochsNotSamples() {
        var lines: [String] = []
        // 10 epochs x 6 samples = 60 samples.
        var hr: [HRSample] = []
        for i in 0..<10 {
            let base = (1000 + i) * 60
            for k in 0..<6 { hr.append(HRSample(ts: base + k * 10, bpm: 120)) }
        }
        _ = SleepStager.hrOnlySessions(day: "2026-09-23", hr: hr, rr: [], resp: [], traceSink: { lines.append($0) })
        XCTAssertEqual(lines.count, 1, "exactly one funnel line per call")
        XCTAssertTrue(lines[0].contains("epochs=10 "), "got: \(lines[0])")
    }

    /// #2397: the night this line is about. A re-score emits one per night, twenty-one inside two
    /// seconds in the field log that prompted this, and every other number here describes a night that
    /// the line itself could not name.
    func testTheLineNamesItsNight() {
        var lines: [String] = []
        let hr = (0..<600).map { HRSample(ts: 1_000_000 + $0 * 10, bpm: 70) }
        _ = SleepStager.hrOnlySessions(day: "2026-09-23", hr: hr, rr: [], resp: [],
                                       traceSink: { lines.append($0) })
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("[sleep] hr-only spine day=2026-09-23 "), "got: \(lines[0])")
    }

    /// The gate line travels with the spine line, so it carries the same attribution.
    func testTheGateLineNamesItsNightToo() {
        XCTAssertEqual(
            SleepStager.GateTrace.hrOnlyGateLine(day: "2026-09-23", attempted: true,
                                                 reason: "no-motion-no-hypnogram",
                                                 gravRows: 0, storedNights: 0),
            "[sleep] hr-only gate day=2026-09-23 attempted=true reason=no-motion-no-hypnogram "
                + "grav=0 stored=0"
        )
    }

    /// The rounding is ARITHMETIC, not `printf`. A harness caught `String(format: "%.1f", 64.05)`
    /// giving 64.0 on Apple against Java's 64.1 — a divergence that `anchor * 1.05` would have hit
    /// constantly. These are the values that harness compared.
    func testOneDecimalRoundingMatchesTheKotlinTwin() {
        let cases: [(Double, String)] = [
            (64.05, "64.1"), (61.0, "61.0"), (77.7, "77.7"), (66.15, "66.2"),
            (71.4, "71.4"), (1.05, "1.1"), (0.0, "0.0"), (120.0, "120.0"),
        ]
        for (v, expected) in cases {
            let line = SleepStager.GateTrace.hrOnlyLine(day: "2026-09-23", anchorBpm: v, bandBpm: nil, hrP50: nil, hrP90: nil, epochs: 0, runs: 0,
                                                        mergedRuns: 0, sleepRuns: 0, longestSleepMin: 0,
                                                        staged: 0, kept: 0, minSleepMin: 60)
            XCTAssertTrue(line.contains("anchorBpm=\(expected) "), "\(v) -> expected \(expected), got: \(line)")
        }
    }
}
