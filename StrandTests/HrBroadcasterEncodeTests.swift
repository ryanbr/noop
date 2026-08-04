import XCTest
@testable import Strand

/// Pins the pure 0x2A37 Heart Rate Measurement *encoder* used by `HrBroadcaster` when NOOP re-broadcasts
/// its live strap HR back out as a standard Bluetooth HR peripheral (so a treadmill / Zwift / Peloton can
/// read it). The encoder is the inverse of `StandardHeartRate.parse`, so each case here is round-tripped
/// back through the parser to prove the two agree byte-for-byte. No CoreBluetooth is touched.
@MainActor
final class HrBroadcasterEncodeTests: XCTestCase {

    // MARK: - u8 path (the normal case: every realistic bpm < 256)

    func testU8FlagsAndValue() {
        // A normal HR encodes as flags=0x00 (8-bit value) + one bpm byte.
        XCTAssertEqual(HrBroadcaster.measurement(bpm: 72), [0x00, 72])
        XCTAssertEqual(HrBroadcaster.measurement(bpm: 60), [0x00, 60])
        XCTAssertEqual(HrBroadcaster.measurement(bpm: 0), [0x00, 0])
    }

    func testU8FlagBit0IsClearBelow256() {
        // For any value < 256, flags bit0 (u16 selector) must be CLEAR.
        for bpm in [1, 40, 120, 200, 254] {
            let m = HrBroadcaster.measurement(bpm: bpm)
            XCTAssertEqual(m.count, 2, "u8 payload is flags + one value byte")
            XCTAssertEqual(m[0] & 0x01, 0, "bit0 must be clear for a u8 value")
        }
    }

    // MARK: - u16 path (boundary: a value that won't fit in a byte)

    func testU16AtBoundary() {
        // 255 still fits a u8 (the encoder emits u8 for < 256).
        XCTAssertEqual(HrBroadcaster.measurement(bpm: 255), [0x00, 255])
        // 256 needs the u16 path: flags=0x01, little-endian 0x00,0x01.
        XCTAssertEqual(HrBroadcaster.measurement(bpm: 256), [0x01, 0x00, 0x01])
    }

    func testU16FlagAndLittleEndian() {
        // 320 = 0x0140 → flags=0x01, LE bytes 0x40,0x01.
        let m = HrBroadcaster.measurement(bpm: 320)
        XCTAssertEqual(m, [0x01, 0x40, 0x01])
        XCTAssertEqual(m[0] & 0x01, 1, "bit0 set selects the u16 value")
    }

    // MARK: - Clamping (untrusted / out-of-range input never overflows the encoding)

    func testNegativeClampsToZero() {
        XCTAssertEqual(HrBroadcaster.measurement(bpm: -5), [0x00, 0])
    }

    func testHugeValueClampsToU16Max() {
        // Anything past 16-bit clamps to 0xFFFF, never a malformed/overflowed packet.
        XCTAssertEqual(HrBroadcaster.measurement(bpm: 1_000_000), [0x01, 0xFF, 0xFF])
    }

    // MARK: - bind(to:) is idempotent (the duplicate-notification leak)

    /// `bind(to:)`'s only call site is `DataSourcesView.onAppear`, which fires on EVERY appearance — every
    /// tab switch back to Data Sources — while the broadcaster is a `@StateObject` that outlives all of
    /// them. Each bind used to append another sink, so a user who had visited the screen N times sent N
    /// duplicate 0x2A37 notifications per heartbeat. Binding must therefore be idempotent.
    func testRepeatedBindLeavesExactlyOneSubscription() {
        let broadcaster = HrBroadcaster(log: { _ in })
        let live = LiveState()
        XCTAssertEqual(broadcaster.cancellables.count, 0, "nothing subscribed before the first bind")
        broadcaster.bind(to: live)
        XCTAssertEqual(broadcaster.cancellables.count, 1)
        for _ in 0..<10 { broadcaster.bind(to: live) }
        XCTAssertEqual(broadcaster.cancellables.count, 1,
                       "eleven binds must leave ONE sink, not eleven — see DataSourcesView.onAppear")
    }

    /// Re-binding to a DIFFERENT LiveState must also leave one sink: the old screen's state should stop
    /// feeding the broadcaster entirely, not keep a second stream alive alongside the new one.
    func testRebindingToAnotherLiveStateReplacesTheSubscription() {
        let broadcaster = HrBroadcaster(log: { _ in })
        broadcaster.bind(to: LiveState())
        broadcaster.bind(to: LiveState())
        XCTAssertEqual(broadcaster.cancellables.count, 1)
    }

    // MARK: - Round-trip against the parser (the encoder is the parser's exact inverse)

    func testRoundTripThroughParser() {
        for bpm in [37, 55, 72, 100, 180, 254, 255, 256, 300] {
            let encoded = HrBroadcaster.measurement(bpm: bpm)
            let parsed = StandardHeartRate.parse(encoded)
            XCTAssertNotNil(parsed, "encoded \(bpm) must re-parse")
            XCTAssertEqual(parsed?.hr, bpm, "encode→parse round trip must preserve \(bpm)")
            XCTAssertEqual(parsed?.rr.count, 0, "NOOP broadcasts a plain HR with no R-R")
        }
    }
}
