import XCTest
@testable import PolarProtocol

/// Pins the clean-room Polar PMD decode against hand-built frames in the documented byte layout. Pure —
/// no CoreBluetooth, no strap; the Kotlin twin (`com.noop.polar.PmdDecoderTest`) asserts the same vectors.
final class PmdDecoderTests: XCTestCase {

    /// Little-endian bytes for the 8-byte PMD frame timestamp 0x0102030405060708.
    private let tsBytes: [UInt8] = [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]
    private let tsValue: UInt64 = 0x0102030405060708

    /// Build a PPI frame header (measurement 0x03, frame type 0) followed by `samples` raw bytes.
    private func ppiFrame(_ samples: [UInt8]) -> [UInt8] {
        [0x03] + tsBytes + [0x00] + samples
    }

    // MARK: - Header

    func testHeaderParsesTypeTimestampAndFrameType() {
        // ECG (0x00), compressed bit set on the frame-type byte (0x80 | 0x01).
        let frame: [UInt8] = [0x00] + tsBytes + [0x81]
        let h = PolarPmdDecoder.header(frame)
        XCTAssertEqual(h?.measurement, .ecg)
        XCTAssertEqual(h?.timestampNs, tsValue)          // 8-byte LE assembled correctly
        XCTAssertEqual(h?.frameType, 0x01)               // low 7 bits
        XCTAssertEqual(h?.isCompressed, true)            // high bit
    }

    func testHeaderRejectsUnknownMeasurementType() {
        // 0x7F is not a type NOOP recognises → no wrong guess.
        XCTAssertNil(PolarPmdDecoder.header([0x7F] + tsBytes + [0x00]))
    }

    func testHeaderRejectsTooShort() {
        XCTAssertNil(PolarPmdDecoder.header([0x03, 0x00, 0x00]))
    }

    // MARK: - PPI

    func testDecodesSinglePpiSample() {
        // hr=60, ppi=800ms (0x0320 LE), err=5ms, flags=0x06 (skinContact + supported, no blocker).
        let frame = ppiFrame([60, 0x20, 0x03, 0x05, 0x00, 0x06])
        let samples = PolarPmdDecoder.decodePPI(frame)
        XCTAssertEqual(samples?.count, 1)
        let s = samples![0]
        XCTAssertEqual(s.heartRate, 60)
        XCTAssertEqual(s.ppiMs, 800)
        XCTAssertEqual(s.errorEstimateMs, 5)
        XCTAssertFalse(s.blocker)
        XCTAssertTrue(s.skinContact)
        XCTAssertTrue(s.skinContactSupported)
    }

    func testDecodesMultiplePpiSamplesInOrder() {
        let frame = ppiFrame([
            62, 0x0A, 0x03, 0x00, 0x00, 0x07,   // hr 62, ppi 778, all flags set (incl. blocker)
            48, 0xE8, 0x03, 0x02, 0x00, 0x00,   // hr 48, ppi 1000, err 2, no flags
        ])
        let samples = PolarPmdDecoder.decodePPI(frame)
        XCTAssertEqual(samples?.count, 2)
        XCTAssertEqual(samples?[0].ppiMs, 778)
        XCTAssertTrue(samples?[0].blocker ?? false)     // bit0 set → unreliable interval
        XCTAssertEqual(samples?[1].heartRate, 48)
        XCTAssertEqual(samples?[1].ppiMs, 1000)
        XCTAssertFalse(samples?[1].skinContactSupported ?? true)
    }

    func testZeroHeartRateSampleIsKeptNotDropped() {
        // hr=0 (no valid beat) must survive as an honest sample, not be filtered or faked.
        let frame = ppiFrame([0, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(PolarPmdDecoder.decodePPI(frame)?.first?.heartRate, 0)
    }

    func testTrailingPartialSampleIsIgnored() {
        // One full 6-byte sample + 3 stray bytes → exactly one sample, no crash.
        let frame = ppiFrame([60, 0x20, 0x03, 0x00, 0x00, 0x00, 0xAA, 0xBB, 0xCC])
        XCTAssertEqual(PolarPmdDecoder.decodePPI(frame)?.count, 1)
    }

    func testEmptyPpiFrameDecodesToNoSamples() {
        XCTAssertEqual(PolarPmdDecoder.decodePPI(ppiFrame([]))?.count, 0)
    }

    func testDecodePpiRejectsNonPpiFrame() {
        // A well-formed ACC (0x02) header is not PPI → nil, even though the header itself parses.
        let acc: [UInt8] = [0x02] + tsBytes + [0x00, 0x11, 0x22, 0x33]
        XCTAssertNotNil(PolarPmdDecoder.header(acc))
        XCTAssertNil(PolarPmdDecoder.decodePPI(acc))
    }

    func testPmdEpochToUnixConversion() {
        // PMD counts ns since 2000-01-01 UTC, not the Unix epoch; the offset re-bases it to wall clock.
        XCTAssertEqual(PolarPmdFrameHeader.pmdEpochUnixOffsetNs, 946_684_800_000_000_000)
        let h = PolarPmdFrameHeader(measurement: .ppi, timestampNs: 1_000_000_000,
                                    frameType: 0, isCompressed: false)
        XCTAssertEqual(h.unixTimestampNs, 1_000_000_000 + PolarPmdFrameHeader.pmdEpochUnixOffsetNs)
    }
}
