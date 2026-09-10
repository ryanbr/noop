import XCTest
@testable import Strand

/// #1948: the 5/MG keep-alive must not send battery commands the allowlist refuses.
///
/// Both commands that block used to send are rejected on a 5/MG before they leave the app: the send
/// allowlist has no clause for `.getBatteryLevel` at all, and admits `.getBatteryPackInfo` only while a
/// user-initiated probe is in flight. So a 5/MG paid two dead sends and two skip lines per tick, under a
/// comment claiming the pack "rides the SAME cadence as the strap's own gauge".
///
/// A 5/MG needs neither: its percent comes from the 0x2A19 read `enableLiveNotifications` drives off this
/// same keep-alive, and its pack charge from the pushed pack-info event (109).
///
/// Pinned against the SOURCE, the way `DeviceRawSourceParityTests` pins its oracle, because the send sits
/// in a keep-alive body no unit test can drive. The Kotlin twin guard is in `ChargingAndReleaseTest`.
final class Whoop5BatteryPollGuardTests: XCTestCase {

    private func managerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Strand/BLE/BLEManager.swift"),
                          encoding: .utf8)
    }

    /// Whitespace-normalised on both sides. A Swift multiline literal strips indentation to its closing
    /// delimiter, so a literal written here could never carry the source's own leading spaces, and
    /// comparing raw text would fail for a reason that has nothing to do with the guard.
    private func normalised(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The poll is family-guarded, and the guard is on the SAME statement as the send — a nearby `if`
    /// that merely reads well would not stop the traffic.
    func testTheBatteryPollIsGuardedAwayFromWhoop5() throws {
        let src = try normalised(managerSource())
        let expected = normalised("""
            if selectedModel.deviceFamily != .whoop5,
            BLEManager.batteryPollDue(tick: keepAliveTick, charging: state.charging == true) {
            send(.getBatteryLevel, payload: [])
            }
            """)
        XCTAssertTrue(src.contains(expected),
                      "the keep-alive battery poll must be guarded away from the 5/MG (#1948)")
    }

    /// Nothing may send the pack opcode on a cadence. The user-initiated probe still may, so this asserts
    /// the absence in the keep-alive rather than in the file, which would forbid the probe too.
    func testNoCadencedPackInfoSendSurvives() throws {
        let src = try managerSource()
        // The WHOLE keep-alive, not just the battery block inside it. Anchoring at the battery comment
        // covered only what follows it, so a pack send added earlier in the same function would have
        // slipped past while the assertion still read as if it guarded the tick. The Kotlin twin was
        // widened for the mirror-image reason, and a control insertion proved it there.
        guard let start = src.range(of: "private func keepAliveFire() {"),
              let end = src.range(of: "private func startBackfillTimer") else {
            return XCTFail("the keep-alive function or its next landmark was not found")
        }
        // Comments in this block name the opcode while explaining why it is not sent, so judge the CODE
        // only — the same rule the Kotlin twin follows. Without this the guard fails on its own rationale.
        let block = String(src[start.lowerBound..<end.lowerBound])
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(block.contains("getBatteryPackInfo"),
                       "no part of the keep-alive may send the pack opcode (#1948): \(block)")
    }
}
