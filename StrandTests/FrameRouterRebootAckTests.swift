import XCTest
@testable import Strand
import WhoopProtocol

/// bhelm/noop#4: the reboot-ack diagnostic must read the COMMAND_RESPONSE result byte at the FAMILY's
/// offset — WHOOP 4.0 @8, WHOOP 5/MG @12 (the "+4 shift"). Reading the fixed 4.0 offset on a 5/MG frame
/// hit the inner *type* byte (non-zero) and logged REJECTED on a successful reboot.
///
/// `@MainActor`: `FrameRouter` is a main-actor class, so its static helper is called from the main actor.
@MainActor
final class FrameRouterRebootAckTests: XCTestCase {

    func testCommandResultByteReadsTheFamilyOffset() {
        // Distinct sentinels at the two candidate result positions.
        var frame = [UInt8](repeating: 0, count: 16)
        frame[8]  = 0x24   // 5/MG inner TYPE byte (COMMAND_RESPONSE) — what the old fixed offset hit
        frame[12] = 0x01   // 5/MG result = SUCCESS(1)

        XCTAssertEqual(FrameRouter.commandResultByte(in: frame, family: .whoop5), 1,
                       "5/MG result lives at byte 12, not the 4.0 offset")
        XCTAssertEqual(FrameRouter.commandResultByte(in: frame, family: .whoop4), 0x24,
                       "4.0 result lives at byte 8")
        XCTAssertEqual(FrameRouter.commandResultByte(in: frame), 0x24,
                       "default family is .whoop4, so the WHOOP-4-only callers are unaffected")
    }

    func testShortFrameHasNoResultByte() {
        // A 5/MG frame too short to carry a byte-12 result → nil (the log prints "no result byte").
        XCTAssertNil(FrameRouter.commandResultByte(in: [UInt8](repeating: 0, count: 12), family: .whoop5))
    }
}
