import Foundation
import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// Whole HR-only sessions (#1801) and the physiology they report (#1884).
///
/// The ORACLE twin of the Kotlin `SleepStagerHrOnlySessionsTest`: the same synthetic night and the same
/// expectations, so a divergence in the null contract fails on one platform and not the other. The Apple
/// side had no twin of this file until #1884, which is exactly how the two `restingHR`/`avgHRV` spellings
/// could have drifted apart unnoticed — Swift structs have no `copy()`, so each rebuild respells the
/// field list and a field is lost by omission rather than by an edit anyone reviews.
///
/// The night is synthetic: a slow HR drift well under the window median, so the spine puts it in the
/// sleep band. That exercises assembly and the reporting contract; it is NOT a claim that the staging is
/// accurate on a real night, which no test here can establish.
final class SleepStagerHrOnlySessionsTests: XCTestCase {

    /// A field-shaped window: `aH` hours awake around 74 +/- 11 bpm, then `nH` hours asleep around
    /// 64 +/- 5 — the shape the #1801 report shows, and the same generator the Kotlin twin uses.
    private func window(aH: Int = 16, nH: Int = 8) -> ([HRSample], [RRInterval]) {
        let t0 = 1_788_300_000
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        for i in 0..<(aH * 3600) {
            let bpm = 74 + Int(sin(Double(i) / 500.0) * 11)
            hr.append(HRSample(ts: t0 + i, bpm: bpm))
            rr.append(RRInterval(ts: t0 + i, rrMs: 60000 / bpm))
        }
        for j in 0..<(nH * 3600) {
            let bpm = 64 + Int(sin(Double(j) / 900.0) * 5)
            let t = t0 + aH * 3600 + j
            hr.append(HRSample(ts: t, bpm: bpm))
            rr.append(RRInterval(ts: t, rrMs: 60000 / bpm))
        }
        return (hr, rr)
    }

    func testLowHRNightBecomesAtLeastOneStagedSession() {
        let (hr, rr) = window()
        let out = SleepStager.hrOnlySessions(hr: hr, rr: rr, resp: [])
        XCTAssertFalse(out.isEmpty, "expected at least one night, got \(out.count)")
        XCTAssertTrue(out.allSatisfy { !$0.stages.isEmpty }, "every session must carry stages")
        XCTAssertTrue(out.allSatisfy { ($0.end - $0.start) >= SleepStager.minSleepMin * 60 },
                      "every session must span at least minSleepMin")
        // Conservative by design: it may under-read a night, but must never invent more sleep than the
        // window holds.
        XCTAssertLessThanOrEqual(out.reduce(0) { $0 + ($1.end - $1.start) }, 8 * 3600,
                                 "total must not exceed the 8 h actually asleep")
    }

    /// #1884 reversed the null contract #1801 established, so the reasoning is worth keeping beside it.
    ///
    /// #1801 withheld `restingHR` and `avgHRV` here on the grounds that a baseline is the one thing a
    /// false positive cannot be unwound from. The field logs showed the withholding was the more damaging
    /// error: the values are MEASURED, not inferred. The BOUNDS are what heart rate infers — which is why
    /// the session still marks itself `hrOnly` — but each RMSSD is computed over its own 5-minute window,
    /// so fuzzy bounds change WHICH windows are included, not whether any one of them is valid. Resting HR
    /// is HR-derived, and an HR-only night is precisely the night with plenty of HR.
    ///
    /// The marker travels with the session, so a consumer that wants to weigh these down still can.
    func testHrOnlySessionReportsMeasuredRestingHRAndHRVAndStillMarksItself() throws {
        let (hr, rr) = window()
        let s = try XCTUnwrap(SleepStager.hrOnlySessions(hr: hr, rr: rr, resp: []).first)
        XCTAssertTrue(s.hrOnly, "must still be flagged hrOnly")
        XCTAssertNotNil(s.restingHR, "restingHR is HR-derived and must be reported")
        XCTAssertNotNil(s.avgHRV, "avgHRV must be reported when R-R is present")
    }

    /// The honest boundary of the change: reporting is driven by whether the INPUT exists, not by the
    /// `hrOnly` flag. With no R-R there is nothing to compute an RMSSD from, so HRV is still absent — and
    /// resting HR, which needs only HR, is still reported. A regression that re-blanked HRV wholesale
    /// would pass the case above if it also happened to blank on missing R-R; this separates them.
    func testHrOnlySessionWithoutRRStillReportsRestingHR() throws {
        let (hr, _) = window()
        let s = try XCTUnwrap(SleepStager.hrOnlySessions(hr: hr, rr: [], resp: []).first)
        XCTAssertTrue(s.hrOnly, "must still be flagged hrOnly")
        XCTAssertNotNil(s.restingHR, "restingHR needs only HR")
        XCTAssertNil(s.avgHRV, "no R-R means no RMSSD to report")
    }
}
