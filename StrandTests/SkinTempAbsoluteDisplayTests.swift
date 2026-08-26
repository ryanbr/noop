import XCTest
import SwiftUI
import StrandAnalytics
import WhoopStore
@testable import Strand

/// #1636: the skin-temp tile leads with the night's ABSOLUTE, with the deviation in the caption beneath.
///
/// A deviation with no anchor cannot be read — the reporter's flu night was "+0.94 Δ°F", which looks like
/// nothing, against 96.4 °F on a 94.4 °F mean, which reads as a fever. Both numbers are needed and
/// neither is sufficient.
///
/// `BodyVitalReading.stateCaption` is pure, so the ordering is asserted directly. Twin of Kotlin
/// `SkinTempAbsoluteDisplayTest`, which asserts the same two properties through its own pure seams
/// (`latestSkinAbsoluteC` / `skinTempSecondaryNote`) because Android's builder resolves resources and
/// cannot run in a JVM test.
final class SkinTempAbsoluteDisplayTests: XCTestCase {

    private func reading(secondary: String?, caveat: String? = nil) -> BodyVitalReading {
        BodyVitalReading(
            key: "skin", label: "Skin Temp", unit: "°C", value: 34.6,
            format: { String(format: "%.1f", $0) },
            banding: VitalBands.Result(band: .inRange, basis: .population, nights: 24),
            metricColor: .orange, day: "2026-08-25", source: .noopComputed,
            missingCaption: "none", caveat: caveat, secondary: secondary)
    }

    func testTheSecondaryLeadsTheCaptionSoItSitsUnderTheValue() {
        let caption = reading(secondary: "+0.9 Δ°F").stateCaption
        XCTAssertTrue(caption.hasPrefix("+0.9 Δ°F · "),
                      "the deviation must come first, directly under the headline — got \(caption)")
        XCTAssertTrue(caption.contains("25 Aug") || caption.contains("Aug 25"),
                      "the day must still be there — got \(caption)")
    }

    func testWithoutASecondaryTheCaptionIsUnchanged() {
        // Every other vital passes nil, so their captions must be byte-identical to before.
        let caption = reading(secondary: nil).stateCaption
        XCTAssertFalse(caption.hasPrefix(" · "), "a nil secondary must not leave an empty leading part")
        XCTAssertFalse(caption.contains("Δ"))
    }

    func testTheSecondaryIsIndependentOfTheCaveat() {
        // `caveat` says the reading is unreliable; `secondary` says what it means. A tile may carry
        // both, and they must not be confused for one another.
        let caption = reading(secondary: "+0.9 Δ°F", caveat: "unverified").stateCaption
        XCTAssertTrue(caption.hasPrefix("+0.9 Δ°F · "))
        XCTAssertTrue(caption.hasSuffix("unverified"))
    }

    /// The formatting the tile's secondary carries, pinned to the same helper Android formats with.
    func testTheDeviationNoteMatchesTheKotlinTwin() {
        func note(_ c: Double, fahrenheit: Bool) -> String {
            let n = SkinTempDisplay.numberString(c, kind: .deviation, fahrenheit: fahrenheit, decimals: 1)
            return "\(n) \(SkinTempDisplay.unitSymbol(kind: .deviation, fahrenheit: fahrenheit))"
        }
        XCTAssertEqual(note(0.52, fahrenheit: false), "+0.5 Δ°C")
        XCTAssertEqual(note(0.52, fahrenheit: true), "+0.9 Δ°F")
        XCTAssertEqual(note(-0.5, fahrenheit: false), "-0.5 Δ°C")
        XCTAssertEqual(note(-0.5, fahrenheit: true), "-0.9 Δ°F")
        // A whole degree of DEVIATION is 1.8 °F, never 33.8 — no +32 offset on a difference.
        XCTAssertEqual(note(1.0, fahrenheit: true), "+1.8 Δ°F")
    }
}
