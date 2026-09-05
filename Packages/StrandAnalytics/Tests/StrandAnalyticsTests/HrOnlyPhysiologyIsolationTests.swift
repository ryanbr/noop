import Foundation
import XCTest
@testable import StrandAnalytics

/// How an HR-only night reaches the day's physiology, guarded at the level it actually fails.
///
/// The twin of the Kotlin `HrOnlyPhysiologyIsolationTest`, which had no Apple counterpart until #1884 —
/// so the decision was pinned on one platform and free to drift on the other, which is precisely the
/// asymmetry the parity contract exists to prevent.
///
/// #1801 made this an EXCLUSION: an HR-only night was kept out of every physiological aggregate. #1884
/// made it a PREFERENCE, because the exclusion was discarding a computed HRV and leaving Charge with no
/// input at all. The night is still marked `hrOnly` for anything that wants to weigh it down; what it no
/// longer gets is a silent delete.
///
/// A nil `restingHR`/`avgHRV` only ever protected an aggregate that READS those fields. Two of the day's
/// physiological aggregates do not: the deep-window HRV pool and the SDNN index both re-derive from `rr`
/// over each session's own stages, so an HR-only night — which has stages — would be folded into both,
/// and from there into Charge and the HRV baseline. `deepHrvWindow` is a user setting, so that path is
/// reachable, not theoretical.
///
/// Read from the source because `physiologySessions` is a local inside `analyzeDay` and cannot be
/// observed directly, and because the failure this guards is a FUTURE aggregate reaching for `matched`
/// out of habit. A behavioural test on one path would not catch that; this does.
final class HrOnlyPhysiologyIsolationTests: XCTestCase {

    /// Walk up from this test file to the package root, so the lookup survives whatever directory the
    /// test runner happens to start in.
    private func engineSource() throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 {
            let f = dir.appendingPathComponent("Sources/StrandAnalytics/AnalyticsEngine.swift")
            if FileManager.default.fileExists(atPath: f.path) {
                return try String(contentsOf: f, encoding: .utf8)
            }
            dir = dir.deletingLastPathComponent()
        }
        XCTFail("AnalyticsEngine.swift not found — this test must not pass by default")
        throw CocoaError(.fileNoSuchFile)
    }

    /// The slice of `analyzeDay` running from just after the physiology set is named through the end of
    /// the SDNN call, which is the last of the four aggregates built from it.
    private func analyzeDayBody() throws -> String {
        let src = try engineSource()
        let decl = try XCTUnwrap(src.range(of: "let physiologySessions"),
                                 "analyzeDay must name the physiology-session set")
        // Start AFTER the declaration: those lines read `matched` legitimately, since defining the
        // preferred set is the one place the unfiltered one belongs.
        let from = try XCTUnwrap(src.range(of: "\n", range: decl.upperBound..<src.endIndex)).upperBound
        let sdnn = try XCTUnwrap(src.range(of: "let avgSDNNDaily", range: from..<src.endIndex),
                                 "expected the SDNN index to follow the physiology set")
        let seg = try XCTUnwrap(src.range(of: "segmentSec: 300", range: sdnn.lowerBound..<src.endIndex))
        let close = try XCTUnwrap(src.range(of: ")", range: seg.upperBound..<src.endIndex))
        return String(src[from..<close.upperBound])
    }

    /// #1884 changed this from an exclusion to a PREFERENCE. The Kotlin twin's old assertion could not
    /// tell the difference — it was a prefix `contains`, so appending the fallback reversed the guarantee
    /// while the guard stayed green. Both spellings are pinned whole here, so the next change to either
    /// has to be deliberate rather than accidental.
    func testPhysiologySetPrefersMotionBackedNightsAndFallsBackRatherThanEmptying() throws {
        let src = try engineSource()
        XCTAssertTrue(src.contains("let physiologyOnly = matched.filter { !$0.hrOnly }"),
                      "the hrOnly filter must survive the fallback")
        XCTAssertTrue(
            src.contains("let physiologySessions = physiologyOnly.isEmpty ? matched : physiologyOnly"),
            "physiologySessions must PREFER motion-backed sessions and fall back rather than emptying")
    }

    /// The four aggregates built from a night's physiology must read the preferred set. `matched` still
    /// has legitimate uses in `analyzeDay` — duration, stage totals, Rest, the onset — which is exactly
    /// why this checks the physiology region rather than banning the name outright.
    func testNoPhysiologicalAggregateReadsTheUnfilteredSessions() throws {
        let body = try analyzeDayBody()
        var offenders: [String] = []
        var i = body.startIndex
        while let hit = body.range(of: "matched.", range: i..<body.endIndex) {
            if hit.upperBound < body.endIndex, body[hit.upperBound].isLetter {
                offenders.append(String(body[hit.lowerBound...hit.upperBound]))
            }
            i = hit.upperBound
        }
        XCTAssertTrue(offenders.isEmpty,
                      "physiological aggregates must use physiologySessions, found: \(offenders)")
        for needle in ["restingHRDaily", "let deep", "let pairs", "avgSDNNDaily"] {
            XCTAssertTrue(body.contains(needle), "\(needle) must sit inside the guarded region")
        }
    }
}
