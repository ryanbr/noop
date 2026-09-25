import XCTest
@testable import Strand

/// #2430: the personal daytime-stress lens reaches Stress detail and both Apple Today layouts.
///
/// The baseline math has package tests; this pins the app-target wiring that can otherwise compile
/// while silently omitting the preference at one call site.
final class StressPersonalBaselineSurfaceTests: XCTestCase {
    private func source(_ path: String, file: StaticString = #filePath) throws -> String {
        let testFile = URL(fileURLWithPath: "\(file)")
        let root = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testDetailAndTodayUseTheSameSelectedMode() throws {
        let detail = try source("Strand/Screens/StressView.swift")
        let producer = try source("Strand/Data/StressDayCurve.swift")
        let today = try source("Strand/Screens/TodayView.swift")
        let liquidToday = try source("Strand/Liquid/LiquidTodayView.swift")

        XCTAssertTrue(detail.contains("let mode = await DaytimeStressMode.selected("))
        XCTAssertTrue(producer.contains("let mode = await DaytimeStressMode.selected("))
        XCTAssertTrue(producer.contains("tzOffsetSeconds: tz, mode: mode,"))
        for body in [today, liquidToday] {
            XCTAssertTrue(body.contains(
                "personalBaseline: PuffinExperiment.stressPersonalBaselineEnabled"
            ))
        }
        // A slot per lens, not one slot that compares the lens: comparing made the two surfaces evict
        // each other on every alternation, so the fingerprint gate never held with the toggle on.
        XCTAssertTrue(producer.contains("memos[personalBaseline]"))
    }

    func testWidgetPublisherRetainsTheCheapDefaultMode() throws {
        let widget = try source("StrandiOS/Widgets/WidgetPublish.swift")
        XCTAssertFalse(widget.contains("personalBaseline:"))
    }
}
