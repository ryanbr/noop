import XCTest
@testable import Strand

/// A readback with no stored frame says so, instead of printing no line at all.
///
/// `alarm.lastReportedRaw` only started being banked with #1707 on 2026-08-28, so any readback taken
/// before that has an epoch and no frame. Emitting the frame line only when the frame existed made the
/// two causes indistinguishable from outside: a reader could not tell a readback that predates the
/// capture from one whose write failed, and an absent line reads as "checked, nothing wrong". A
/// 2026-09-28 capture carrying a 2045 readback cost a trip through git history for that reason.
///
/// Twin of the Kotlin `AlarmReadbackFrameLineTest`, and the expected strings are the Kotlin ones: these
/// lines exist so an Android and an Apple report compare directly, so asserting each side against only
/// itself would prove nothing about the pair.
final class AlarmReadbackFrameLineTests: XCTestCase {

    private static let keys = [
        "alarm.lastArmSentEpoch", "alarm.lastArmAt",
        "alarm.lastReportedEpoch", "alarm.lastReportedAt", "alarm.lastReportedRaw",
    ]

    override func setUp() {
        super.setUp()
        for k in Self.keys { UserDefaults.standard.removeObject(forKey: k) }
    }

    override func tearDown() {
        for k in Self.keys { UserDefaults.standard.removeObject(forKey: k) }
        super.tearDown()
    }

    /// An arm plus a readback, with the frame set to `raw` or left absent when nil.
    private func seedReadback(raw: String?) {
        let d = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        d.set(Int(now) + 3600, forKey: "alarm.lastArmSentEpoch")
        d.set(now, forKey: "alarm.lastArmAt")
        d.set(Int(now) + 3600, forKey: "alarm.lastReportedEpoch")
        d.set(now, forKey: "alarm.lastReportedAt")
        if let raw { d.set(raw, forKey: "alarm.lastReportedRaw") }
    }

    private func frameLines() -> [String] {
        DebugDataDiagnostics.alarmLines().filter { $0.hasPrefix("Readback frame:") }
    }

    func testAStoredFrameIsPrintedVerbatim() {
        seedReadback(raw: "0a1b2c3d")
        XCTAssertEqual(frameLines(), ["Readback frame: 0a1b2c3d"])
    }

    func testAReadbackWithNoStoredFrameStillEmitsALineSayingWhy() {
        seedReadback(raw: nil)
        let lines = frameLines()
        XCTAssertEqual(lines.count, 1, "the absent frame must still produce exactly one line")
        let line = lines[0]
        XCTAssertTrue(line.contains("predates the frame capture"), line)
        XCTAssertTrue(line.contains("write failed"), line)
        // The Kotlin text, verbatim, so the two reports stay comparable line for line.
        XCTAssertEqual(line, "Readback frame: not stored (this readback predates the frame capture, or "
                       + "the write failed), so a genuinely-stored stale alarm cannot be told from a "
                       + "misdecode of a fixed response field here")
    }

    /// A blank frame is as uninformative as an absent one, so it takes the same branch.
    ///
    /// This is the half that diverged: Kotlin used `isNotBlank` while this side used `!isEmpty`, so a
    /// whitespace-only value printed a frame line carrying no bytes here and counted as absent there.
    func testABlankStoredFrameIsTreatedAsNotStored() {
        seedReadback(raw: "   ")
        let line = frameLines()[0]
        XCTAssertTrue(line.contains("not stored"),
                      "a blank frame must not be printed as if it were bytes: \(line)")
    }

    /// With no readback at all the block reports that instead, and emits no frame line.
    func testNoReadbackEmitsNoFrameLine() {
        let d = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        d.set(Int(now) + 3600, forKey: "alarm.lastArmSentEpoch")
        d.set(now, forKey: "alarm.lastArmAt")
        XCTAssertTrue(frameLines().isEmpty)
        XCTAssertTrue(DebugDataDiagnostics.alarmLines().contains("Strap reports: (no readback)"))
    }
}
