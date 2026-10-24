import XCTest
@testable import WhoopProtocol

/// #891/#1100: the type-43 REALTIME_RAW_DATA sample decoder, Swift side.
///
/// Twin of the Kotlin `Whoop5EcgRawRecordTest`. The offsets are a protocol fact, so both platforms carry the
/// decode and both pin it — the parity contract is that these two cannot drift, and a test only on the side
/// that happens to call it today would not stop Swift drifting.
final class Whoop5EcgRawRecordTests: XCTestCase {

    /// A 240-byte record with `samples` written i16-LE from the waveform offset.
    private func rawRecord(samples: [Int] = [], type: UInt8 = Whoop5Ecg.rawRecordType) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: Whoop5Ecg.rawRecordLength)
        f[Whoop5Ecg.rawTypeOffset] = type
        var i = Whoop5Ecg.rawWaveformStart
        for v in samples {
            if i + 1 >= Whoop5Ecg.rawWaveformEnd { break }
            let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
            f[i] = UInt8(u & 0xFF)
            f[i + 1] = UInt8((u >> 8) & 0xFF)
            i += 2
        }
        return f
    }

    func testTheRecordCarriesExactly100Samples() {
        // Load-bearing beyond arithmetic: this is the lag the BPM estimator has to refuse. It read 101 for
        // as long as the decoder walked to `rawBodyEnd`, which swept the alignment word in as a sample and
        // left the record's two self-consistent readings — this constant and `r17MaxSamples` — one apart.
        XCTAssertEqual(Whoop5Ecg.samplesPerRawRecord, 100)
        XCTAssertEqual(Whoop5Ecg.realtimeRawSamples(rawRecord())?.count, 100)

        // The two readings of this record's length, pinned equal. Both are literals so the parity scanner
        // can check each against its Kotlin twin by value; that leaves nothing asserting they agree with
        // EACH OTHER, which is the drift that produced the 101st sample. This is that assertion.
        XCTAssertEqual(Whoop5Ecg.samplesPerRawRecord, Whoop5Ecg.r17MaxSamples)
        XCTAssertEqual(Whoop5Ecg.rawWaveformEnd,
                       Whoop5Ecg.rawWaveformStart + Whoop5Ecg.r17MaxSamples * 2)
        // And the alignment word is exactly the gap the old bound swept in: one i16, not more.
        XCTAssertEqual(Whoop5Ecg.rawBodyEnd - Whoop5Ecg.rawWaveformEnd, 2)
    }

    func testOnlyA240ByteType43FrameIsARawRecord() {
        XCTAssertTrue(Whoop5Ecg.isRealtimeRawRecord(rawRecord()))
        XCTAssertFalse(Whoop5Ecg.isRealtimeRawRecord(rawRecord(type: 0x2F)))
        XCTAssertFalse(Whoop5Ecg.isRealtimeRawRecord(Array(rawRecord().prefix(200))))
        XCTAssertNil(Whoop5Ecg.realtimeRawSamples(rawRecord(type: 0x2F)))
        XCTAssertNil(Whoop5Ecg.realtimeRawBodyNonZeroBytes([0, 0, 0, 0]))
        XCTAssertNil(Whoop5Ecg.realtimeRawSignalPresent([]))
    }

    func testSamplesAreSignedLittleEndian() {
        let injected = [0, 1, -1, 32767, -32768, 258, -258]
        let got = Whoop5Ecg.realtimeRawSamples(rawRecord(samples: injected))!
        XCTAssertEqual(Array(got.prefix(injected.count)), injected)
        // Everything past what was written stays zero rather than being trimmed away.
        XCTAssertEqual(got[injected.count], 0)
    }

    func testZeroSamplesAreKeptNotTrimmed() {
        let got = Whoop5Ecg.realtimeRawSamples(rawRecord(samples: [50, 0, 0, 0]))!
        XCTAssertEqual(got.count, 100)
        XCTAssertEqual(got[0], 50)
        XCTAssertTrue(got.dropFirst().allSatisfy { $0 == 0 })
    }

    func testSignalPresentIsOneRuleSharedByEveryConsumer() {
        XCTAssertEqual(Whoop5Ecg.realtimeRawBodyNonZeroBytes(rawRecord()), 0)
        XCTAssertEqual(Whoop5Ecg.realtimeRawSignalPresent(rawRecord()), false)

        // Just AT the threshold is still not "present" — the rule is strictly greater.
        var atThreshold = rawRecord()
        for i in 0..<Whoop5Ecg.rawBodyActiveNonZeroBytes { atThreshold[Whoop5Ecg.rawBodyStart + i] = 7 }
        XCTAssertEqual(Whoop5Ecg.realtimeRawBodyNonZeroBytes(atThreshold), Whoop5Ecg.rawBodyActiveNonZeroBytes)
        XCTAssertEqual(Whoop5Ecg.realtimeRawSignalPresent(atThreshold), false)

        var over = atThreshold
        over[Whoop5Ecg.rawBodyStart + Whoop5Ecg.rawBodyActiveNonZeroBytes] = 7
        XCTAssertEqual(Whoop5Ecg.realtimeRawSignalPresent(over), true)
    }

    func testTheSubHeaderIsCountedForFillButNeverDecodedAsWaveform() {
        // Bytes 24..33 are a constant sub-header: they count toward "is this record filled" but must not
        // appear in the sample series, or the trace opens with five bogus spikes every record.
        var f = rawRecord()
        for i in Whoop5Ecg.rawBodyStart..<Whoop5Ecg.rawWaveformStart { f[i] = 0x7F }
        XCTAssertEqual(
            Whoop5Ecg.realtimeRawBodyNonZeroBytes(f),
            Whoop5Ecg.rawWaveformStart - Whoop5Ecg.rawBodyStart
        )
        XCTAssertTrue(Whoop5Ecg.realtimeRawSamples(f)!.allSatisfy { $0 == 0 })
    }

    func testTheAlignmentWordIsCountedForFillButNeverDecodedAsWaveform() {
        // The same rule as the sub-header above, at the other end of the body: bytes 234..235 are the
        // record's alignment word. Non-zero values are planted here precisely because the real word is
        // zero-valued — a decoder that walks past `rawWaveformEnd` appends a zero to every record at a
        // fixed position, so the bug is invisible against real bytes and only a planted word catches it.
        var f = rawRecord()
        for i in Whoop5Ecg.rawWaveformEnd..<Whoop5Ecg.rawBodyEnd { f[i] = 0x7F }
        XCTAssertEqual(
            Whoop5Ecg.realtimeRawBodyNonZeroBytes(f),
            Whoop5Ecg.rawBodyEnd - Whoop5Ecg.rawWaveformEnd
        )
        XCTAssertTrue(Whoop5Ecg.realtimeRawSamples(f)!.allSatisfy { $0 == 0 })
    }
}
