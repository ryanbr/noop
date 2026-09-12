import XCTest
@testable import Strand
import WhoopProtocol

/// Scenario "Strukturelle Mindest- und Genaulänge je Gerätefamilie / Echte aufgezeichnete Rahmen
/// bleiben gültig", for the app target's own frame corpus.
///
/// The app-target corpus is not a resource directory — `StrandTests/Resources/` holds only a
/// capability table with no frame bytes. The real frames live as hex LITERALS inside three test files:
/// `RawHistoryArchiveReplayTests` and `BackfillerSessionTallyTests` (three real WHOOP 4.0 v25 records,
/// 84 bytes each) and `BatteryResultProvenanceDumpTests` (a real GET_BATTERY_LEVEL COMMAND_RESPONSE).
/// They are repeated here on purpose: those files assert what the frames DECODE to, this one asserts
/// that the tightened envelope rules still admit them at all. If a future change makes the verifier
/// stricter than the hardware, this is the test that says so — the other three would fail with a
/// decode error that reads like a decoder bug.
///
/// A tightened verifier that rejected any of these would mean real straps losing real records, which
/// is a strictly worse outcome than the forgery the change prevents.
final class AppTargetFrameCorpusIntegrityTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }

    /// Every WHOOP 4.0 frame literal in the app-target test corpus, with the file it is quoted from.
    private var corpus: [(name: String, hex: String)] {
        [
            ("RawHistoryArchiveReplayTests / BackfillerSessionTallyTests v25 #1",
             "aa50000c2f190013390000140d2b6a4075010068a2010032fdbcfd98fdd3fdccfd47ffb00366064f073e06c103d3016cffa2fc87fa2ffae5fdbe03140675060c0510012dff1bfec0018f3c500500010068dc8f44"),
            ("RawHistoryArchiveReplayTests / BackfillerSessionTallyTests v25 #2",
             "aa50000c2f190014390000150d2b6a487001003ab301008dfd6afdaffda9fdaffd68fddbfb0dfc09fd77fe89fe62febffec9fe91ff0bff81ff5fff3e00d600790078ff3dff4bff801d553c5005010000d7c016b3"),
            ("RawHistoryArchiveReplayTests / BackfillerSessionTallyTests v25 #3",
             "aa50000c2f190015390000160d2b6a586b01006d8f0100a3ff94ffc4ffbcffbeff22004a009400cb0048005d006b004400d700130115013301f20088001d0031ffd9fe5eff75ff0048933c50050001008bdf2c2c"),
            ("BatteryResultProvenanceDumpTests GET_BATTERY_LEVEL response",
             "aa0f00c324141a0000a9010000000052cd1a49"),
        ]
    }

    func testEveryAppTargetFrameLiteralStillVerifies() {
        XCTAssertEqual(corpus.count, 4, "the corpus is a fixed list; add here when a file gains a frame")
        for entry in corpus {
            let frame = bytes(entry.hex)
            let check = verifyFrame(frame, family: .whoop4)
            XCTAssertTrue(check.ok, "\(entry.name) must stay valid")
            XCTAssertEqual(check.reason, .none, "\(entry.name) must be rejected for no reason at all")
            XCTAssertEqual(check.crc8OK, true, "\(entry.name): header checksum")
            XCTAssertEqual(check.crc32OK, true, "\(entry.name): payload CRC32")
        }
    }

    /// The structural rules, spelled out on the same frames: each is at or above the family minimum
    /// and its byte count equals exactly `declared length + 4`.
    func testEveryAppTargetFrameLiteralIsExactlyItsDeclaredLength() {
        for entry in corpus {
            let frame = bytes(entry.hex)
            XCTAssertGreaterThanOrEqual(frame.count, FrameLimits.whoop4MinimumFrameBytes, entry.name)
            let declared = Int(frame[1]) | (Int(frame[2]) << 8)
            XCTAssertEqual(frame.count, declared + 4, "\(entry.name): no trailing or missing bytes")
        }
    }

    /// And they still parse to a positive verdict end to end, which is what every consumer gate reads.
    func testEveryAppTargetFrameLiteralParsesIntact() {
        for entry in corpus {
            let parsed = parseFrame(bytes(entry.hex), family: .whoop4)
            XCTAssertTrue(parsed.ok, "\(entry.name) must pass the gates the consumers apply")
            XCTAssertTrue(parsed.isParsable, entry.name)
            XCTAssertEqual(parsed.rejectReason, .none, entry.name)
        }
    }
}
