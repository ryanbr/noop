import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import Strand

/// #900: the strap log must self-capture the one artefact the issue is blocked on — a real WHOOP 4.0
/// `GET_BATTERY_LEVEL` COMMAND_RESPONSE of known provenance. FrameRouter annotates a non-SUCCESS reply that
/// still carried a value (the #923 behaviour, brought to Swift here for parity) AND dumps the FULL raw frame
/// once per command per connection — full frame, because the disputed bytes are the `[seq][result]` prefix
/// that the post-prefix payload dump hides. Rate-limited so a 4.0's per-poll battery reads don't flood the
/// log, and re-armed each connection (when `family` is set). Twin of the Kotlin WhoopBleClient dump.
@MainActor
final class BatteryResultProvenanceDumpTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    /// The real 4.0 battery reply at the heart of #900: succeeds (42.5%) yet its `[seq][result]` prefix is
    /// zeroed, so `result` decodes to FAILURE(0). Same fixture as `Whoop4ResponseResultTests`.
    private let batteryFrameHex = "aa0f00c324141a0000a9010000000052cd1a49"

    private func rawDumpLines(_ live: LiveState) -> [String] {
        live.log.filter { $0.contains("raw frame (#900") }
    }

    func testNonSuccessBatteryReplyIsAnnotatedNotReportedAsABareFailure() {
        let live = LiveState()
        let router = FrameRouter(state: live)
        router.family = .whoop4
        router.handle(frame: bytes(batteryFrameHex))

        XCTAssertTrue(live.log.contains {
            $0.contains("Command response: GET_BATTERY_LEVEL")
                && $0.contains("battery 42.5%")
                && $0.contains("see #900")
        }, "a value-carrying non-SUCCESS battery reply must annotate, not read as a failure: \(live.log)")
    }

    func testRawFrameProvenanceIsDumpedOncePerConnection() {
        let live = LiveState()
        let router = FrameRouter(state: live)
        router.family = .whoop4

        router.handle(frame: bytes(batteryFrameHex))
        XCTAssertEqual(rawDumpLines(live).count, 1, "one raw-frame line on the first battery reply")
        XCTAssertTrue(rawDumpLines(live).first?.contains(batteryFrameHex) ?? false,
                      "the dump must carry the FULL frame incl. the [seq][result] prefix: \(rawDumpLines(live))")

        // Every subsequent poll this connection hits the same non-SUCCESS branch — but must NOT re-dump.
        router.handle(frame: bytes(batteryFrameHex))
        router.handle(frame: bytes(batteryFrameHex))
        XCTAssertEqual(rawDumpLines(live).count, 1, "rate-limited: no re-dump for the same command this session")
    }

    func testSettingFamilyReArmsTheDumpForTheNextConnection() {
        let live = LiveState()
        let router = FrameRouter(state: live)
        router.family = .whoop4
        router.handle(frame: bytes(batteryFrameHex))
        XCTAssertEqual(rawDumpLines(live).count, 1)

        // A fresh connection sets `family` again (BLEManager.connectCore) → fresh capture session.
        router.family = .whoop4
        router.handle(frame: bytes(batteryFrameHex))
        XCTAssertEqual(rawDumpLines(live).count, 2, "re-arming on connect lets the next session re-capture")
    }
}
