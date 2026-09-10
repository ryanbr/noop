import Foundation
import XCTest
@testable import WhoopProtocol

/// The 4.0 serial decode (#1193) — twin of the Kotlin `Whoop4HelloSerialTest`, same cases, same values.
final class Whoop4HelloSerialTests: XCTestCase {

    /// A 131-byte cmd-35 response shaped like the captured one: a 9-char serial at 14, and the 54-char
    /// DEVICE KEY at 24 that must stay unreachable.
    private func capturedShape(serial: String = "WBB5AP053",
                               key: String = String(repeating: "K", count: 54)) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 131)
        for (i, c) in serial.utf8.enumerated() { p[14 + i] = c }
        for (i, c) in key.utf8.enumerated() { p[24 + i] = c }
        return p
    }

    func testReadsTheSerialFromTheCapturedShape() {
        XCTAssertEqual(Whoop4HelloSerial.decode(payload: capturedShape()), "WBB5AP053")
    }

    /// The headline safety property: the decoder reads a fixed 9-byte window, so the device key beside
    /// the serial cannot be returned no matter what it contains.
    func testNeverReturnsTheDeviceKey() {
        let out = Whoop4HelloSerial.decode(payload: capturedShape())
        XCTAssertEqual(out?.count, 9)
        XCTAssertFalse(out?.contains("K") ?? true)
    }

    /// A window that is not a clean alnum run is refused rather than guessed at — a moved field must
    /// cost a strap its stable id, never migrate its history onto junk.
    func testRefusesANonAlphanumericWindow() {
        var p = capturedShape()
        p[18] = 0x00
        XCTAssertNil(Whoop4HelloSerial.decode(payload: p))
        p = capturedShape()
        p[14] = 0x2D  // '-' is legal in an id but is NOT alnum, so this window is not a serial run
        XCTAssertNil(Whoop4HelloSerial.decode(payload: p))
    }

    func testRefusesAShortPayload() {
        XCTAssertNil(Whoop4HelloSerial.decode(payload: [UInt8](repeating: 0x41, count: 22)))
        XCTAssertNil(Whoop4HelloSerial.decode(payload: []))
    }

    /// Exactly long enough is enough — the window ends at 23, so a 23-byte payload decodes.
    func testAcceptsTheMinimumLength() {
        var p = [UInt8](repeating: 0x41, count: 23)
        for (i, c) in "ABC123XYZ".utf8.enumerated() { p[14 + i] = c }
        XCTAssertEqual(Whoop4HelloSerial.decode(payload: p), "ABC123XYZ")
    }
}

/// The two-sighting gate (#1193) — twin of the Kotlin `RepeatedSerialGateTest`.
final class RepeatedSerialGateTests: XCTestCase {

    /// The point of the gate: one sighting is never enough to act on.
    func testWithholdsUntilTheSameValueRepeats() {
        var g = RepeatedSerialGate()
        XCTAssertNil(g.offer("WBB5AP053"))
        XCTAssertEqual(g.offer("WBB5AP053"), "WBB5AP053")
    }

    /// The failure this exists to prevent: a per-session value never confirms, so it can never migrate
    /// a history onto a fresh id per connect.
    func testAValueThatKeepsChangingNeverConfirms() {
        var g = RepeatedSerialGate()
        for s in ["AAA111AAA", "BBB222BBB", "CCC333CCC", "DDD444DDD"] {
            XCTAssertNil(g.offer(s), "a changing value must never confirm")
        }
    }

    /// Confirms once, not on every later sighting — the caller adopts on a non-nil return, and adopting
    /// repeatedly would redo the migration on every connect.
    func testConfirmsExactlyOnce() {
        var g = RepeatedSerialGate()
        _ = g.offer("WBB5AP053")
        XCTAssertEqual(g.offer("WBB5AP053"), "WBB5AP053")
        XCTAssertNil(g.offer("WBB5AP053"))
        XCTAssertNil(g.offer("WBB5AP053"))
    }

    /// An interruption resets the run: two sightings must be consecutive, so alternating values cannot
    /// accumulate their way to a false confirmation.
    func testAlternatingValuesDoNotConfirm() {
        var g = RepeatedSerialGate()
        XCTAssertNil(g.offer("AAA111AAA"))
        XCTAssertNil(g.offer("BBB222BBB"))
        XCTAssertNil(g.offer("AAA111AAA"))
        XCTAssertEqual(g.offer("AAA111AAA"), "AAA111AAA")
    }
}
