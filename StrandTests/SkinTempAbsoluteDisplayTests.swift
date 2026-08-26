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

    // MARK: - The tile itself, not just the caption helper

    /// A day key `daysAgo` before the CURRENT logical day.
    ///
    /// Not a hardcoded date: `latest()` resolves through `Baselines.freshestCarried`, which only carries
    /// a reading within `vitalCarryDays` of today. A fixed fixture date passes now and silently stops
    /// resolving once the real clock moves past that window — a test that rots into a false green.
    private func dayKey(_ daysAgo: Int) -> String {
        Baselines.cutoffKey(todayKey: BodyVitalSigns.logicalDayKey(Date()), carryDays: daysAgo)
    }

    private func day(_ d: String, abs: Double? = nil, dev: Double? = nil) -> DailyMetric {
        DailyMetric(day: d, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                    recovery: nil, strain: nil, exerciseCount: nil,
                    skinTempDevC: dev, skinTempC: abs)
    }

    private func skinTile(_ days: [DailyMetric],
                          _ unit: TemperatureUnit = .celsius) throws -> BodyVitalReading {
        let all = BodyVitalSigns.readings(days: days, today: days.last, temperatureUnit: unit)
        return try XCTUnwrap(all.first { $0.key == "skin" })
    }

    /// The reported case: the night measured both, so the absolute leads and the deviation sits under it.
    func testANightWithBothLeadsWithTheAbsolute() throws {
        let tile = try skinTile([day(dayKey(0), abs: 34.6, dev: 0.52)])
        XCTAssertEqual(try XCTUnwrap(tile.value), 34.6, accuracy: 0.001)
        XCTAssertEqual(tile.unit, "°C")
        XCTAssertEqual(tile.secondary, "+0.5 Δ°C")
    }

    func testTheAbsoluteAndItsNoteFollowTheTemperatureSetting() throws {
        let tile = try skinTile([day(dayKey(0), abs: 34.6, dev: 0.52)], .fahrenheit)
        XCTAssertEqual(tile.unit, "°F")
        XCTAssertEqual(tile.secondary, "+0.9 Δ°F")
    }

    /// A night predating the column keeps exactly the tile that shipped before.
    func testADeviationOnlyNightIsUnchanged() throws {
        let tile = try skinTile([day(dayKey(0), dev: 0.52)])
        XCTAssertEqual(try XCTUnwrap(tile.value), 0.52, accuracy: 0.001)
        XCTAssertEqual(tile.unit, "Δ°C")
        XCTAssertNil(tile.secondary, "a deviation-led tile would only repeat its own headline")
    }

    /// Calibrating: the absolute is measured before the baseline is usable, so there is no deviation
    /// yet. The tile shows the temperature instead of "needs ~4 worn nights", and omits the note.
    func testACalibratingNightShowsTheAbsoluteWithNoNote() throws {
        let tile = try skinTile([day(dayKey(0), abs: 34.6)])
        XCTAssertEqual(try XCTUnwrap(tile.value), 34.6, accuracy: 0.001)
        XCTAssertEqual(tile.unit, "°C")
        XCTAssertNil(tile.secondary)
    }

    /// The regression the displayed-row rule exists for: an import-only night is NEWER than the last
    /// strap night. The tile must stay on the import rather than stepping back to a stale absolute.
    func testANewerImportOnlyNightDoesNotStepBackToAnOlderAbsolute() throws {
        let tile = try skinTile([
            day(dayKey(1), abs: 34.6, dev: 0.52),   // the strap's last scored night
            day(dayKey(0), dev: 0.20),              // a WHOOP CSV import: deviation only
        ])
        XCTAssertEqual(try XCTUnwrap(tile.value), 0.20, accuracy: 0.001,
                       "showing 34.6 here would be yesterday's reading dressed as today's")
        XCTAssertEqual(tile.day, dayKey(0))
        XCTAssertNil(tile.secondary)
    }

    /// The secondary must be THIS night's deviation. Reaching for the freshest one anywhere would
    /// print a previous night's number under tonight's temperature.
    func testTheNoteBelongsToTheDisplayedNight() throws {
        let tile = try skinTile([
            day(dayKey(1), abs: 33.9, dev: -0.40),
            day(dayKey(0), abs: 34.6, dev: 0.52),
        ])
        XCTAssertEqual(tile.secondary, "+0.5 Δ°C", "the note must not come from the previous night")
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
