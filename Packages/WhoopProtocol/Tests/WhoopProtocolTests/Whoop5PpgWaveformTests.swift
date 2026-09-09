import XCTest
@testable import WhoopProtocol

/// WHOOP 5.0 type-47 **version-26** record — the high-rate optical PPG buffer.
///
/// v26 is the high-rate sibling of the v18 per-second summary: **24 little-endian i16 samples at bytes
/// [27:75]**, one record per second (`unix` u32 LE @15, the same slot v18 uses). It was verified to be
/// an OPTICAL PPG trace — not IMU/motion — using HR as *internal* ground truth (no external reference):
/// the concatenated waveform's autocorrelation peaks at the heart rate (lag 14 = 102.9 bpm vs a measured
/// 101.7 bpm), trough-detection gives a 563 ms inter-beat interval (≈106 bpm), the pulse stays HR-locked
/// even when the wrist is still, and its amplitude is not motion-driven. See
/// `Tools/linux-capture/analyze_v26_waveform.py` and `BLE_REVERSE_ENGINEERING.md` §5.
///
/// Samples are raw AC-coupled ADC counts — PPG has no absolute unit — so they are exposed verbatim with
/// no invented scale. Real type-47 frames carry no device name / serial / token, so the fixture is real.
final class Whoop5PpgWaveformTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }

    // Real v26 record (unix 1780917232; a clean PPG upstroke from −1432 toward 0).
    private let v26Hex =
        "aa015000010035412f1a80ad418401f0a3266aae470100c3c5050068faccfa8dfb46fc8bfd4c" +
        "febafedafe6dff56ffd5fffbff37ff6afce5f9d7f8dffa5efc98fddbfe5afe84fe15ff5cff40" +
        "5fb33c50080101006cb67c17"

    private let expectedWaveform = [
        -1432, -1332, -1139, -954, -629, -436, -326, -294, -147, -170, -43, -5,
        -201, -918, -1563, -1833, -1313, -930, -616, -293, -422, -380, -235, -164,
    ]

    func testV26DecodesAsHistoricalData() {
        let f = parseFrame(bytes(v26Hex), family: .whoop5)
        XCTAssertEqual(f.typeName, "HISTORICAL_DATA")
        XCTAssertEqual(f.crcOK, true)
        XCTAssertEqual(f.parsed["hist_version"]?.intValue, 26)
    }

    func testV26PpgWaveformAndUnix() {
        let p = parseFrame(bytes(v26Hex), family: .whoop5).parsed
        XCTAssertEqual(p["unix"]?.intValue, 1780917232)        // real unix, same @15 slot as v18
        XCTAssertEqual(p["ppg_sample_count"]?.intValue, 24)
        XCTAssertEqual(p["ppg_waveform"]?.intArrayValue, expectedWaveform)
        // @21 is the raw per-burst counter `burst_index` (PR#553), NOT a channel id — this fixture reads 1.
        XCTAssertEqual(p["burst_index"]?.intValue, 1)
        XCTAssertNil(p["ppg_channel"])                          // the old (wrong) channel field is gone
        // PR#563: record_index@11 is the only other named field; the rest stay raw/neutral.
        XCTAssertEqual(p["record_index"]?.intValue, 25444781)
        XCTAssertEqual(p["raw_u8_19"]?.intValue, 174)
    }

    /// A second real v26 frame captured in a separate 40 s burst ~19 min later. Its `burst_index` @21
    /// reads `2` (the first frame read `1`). An earlier decode read `frame[12]` = 0x41/0x46 and mistook a
    /// high-entropy counter byte for an optical channel, and a later capture showed @21 itself reaching 65
    /// — far outside any 26-channel sweep — so @21 is a raw per-burst counter, not a channel id (PR#553).
    /// Both frames' waveforms autocorrelate to the heart rate (lag 14 ≈ 103 bpm); no LED mapping is claimed.
    private let v26HexChannel46 =
        "aa015000010035412f1a803546840178a8266af54802004ca006007dfde1fde4fe9904" +
        "5009f40d7f0b380c5109e9013dff0dff19fd6efedafe8efe8cfca0fe98014002c9039f05" +
        "30059201d8abbe3d50080001006b6cb5a5"

    func testV26SecondBurstDecodes() {
        let p = parseFrame(bytes(v26HexChannel46), family: .whoop5).parsed
        XCTAssertEqual(p["hist_version"]?.intValue, 26)
        XCTAssertEqual(p["unix"]?.intValue, 1780918392)
        XCTAssertEqual(p["burst_index"]?.intValue, 2)          // per-burst counter (first frame read 1)
        XCTAssertNil(p["ppg_channel"])                          // no channel semantics asserted
        XCTAssertEqual(p["ppg_sample_count"]?.intValue, 24)
        // Still a smooth pulsatile trace (guards the [27:75] bounds on the other frame too).
        let w = p["ppg_waveform"]!.intArrayValue!
        let range = w.max()! - w.min()!
        let meanStep = zip(w, w.dropFirst()).map { abs($1 - $0) }.reduce(0, +) / (w.count - 1)
        XCTAssertLessThan(meanStep * 4, range)
    }

    func testV26WaveformIsSmoothNotNoise() {
        // A PPG pulse moves smoothly sample-to-sample, so the mean step is a small fraction of the
        // record's range — distinguishing a real decoded waveform from random/garbage bytes, and
        // guarding the [27:75] sample bounds.
        let w = parseFrame(bytes(v26Hex), family: .whoop5).parsed["ppg_waveform"]!.intArrayValue!
        let range = w.max()! - w.min()!
        let meanStep = zip(w, w.dropFirst()).map { abs($1 - $0) }.reduce(0, +) / (w.count - 1)
        XCTAssertLessThan(meanStep * 4, range)
    }

    // MARK: - Durable waveform persistence (issue #156 follow-up)
    //
    // Until now `extractHistoricalStreams` collected a v26 record's waveform into a transient local
    // buffer ONLY to derive a per-second HR estimate (`ppgHr`); the samples themselves were discarded
    // once that estimate was taken. These tests prove the raw waveform now survives as its OWN stream
    // (`Streams.ppgWaveform`), independently of whether the HR estimator had enough context to run.

    /// A single v26 record is one second of samples — nowhere near the >=3-consecutive-second run
    /// `PpgHr.derivePpgHr` requires, so `ppgHr` stays empty. Before this change that meant the ENTIRE
    /// record vanished (nothing else read `ppg_waveform`); now the raw waveform is still captured.
    func testExtractHistoricalStreamsPersistsRawPpgWaveform() {
        let f = parseFrame(bytes(v26Hex), family: .whoop5)
        let streams = extractHistoricalStreams([f], deviceClockRef: 1_780_917_232, wallClockRef: 1_780_917_232)
        XCTAssertEqual(streams.ppgWaveform,
                       [PpgWaveformSample(ts: 1_780_917_232, samples: expectedWaveform, burstIndex: 1,
                                          baseCode: expectedBaseCode)])
        XCTAssertTrue(streams.ppgHr.isEmpty, "a lone 1 s record is too short for a confident HR estimate")
        // Not "no rows at all" — the Backfiller's silent-data-loss diagnostic must see this as decoded.
        XCTAssertFalse(streams.isEmpty)
    }

    /// #2019: the absolute optical code the stored values are deltas FROM, at frame-abs 23. It is what
    /// makes the window reconstructable and what used to be discarded.
    private let expectedBaseCode = 378_307

    /// The reconstruction, on the real captured window. Every absolute sample must land inside the
    /// 20-bit ADC domain, which is the check that says the base and the deltas belong together: read as
    /// absolute values the stored deltas are all NEGATIVE, and no optical reading can be. The excursion
    /// is 4.2% of the base, an ordinary PPG perfusion index. Mirrored in Kotlin.
    func testTheWindowReconstructsIntoTheOpticalDomain() {
        let f = parseFrame(bytes(v26Hex), family: .whoop5)
        let streams = extractHistoricalStreams([f], deviceClockRef: 1_780_917_232,
                                               wallClockRef: 1_780_917_232)
        let row = try! XCTUnwrap(streams.ppgWaveform.first)
        let absolute = try! XCTUnwrap(ppgWaveformAbsolute(baseCode: row.baseCode, deltas: row.samples))
        XCTAssertEqual(absolute.count, 25, "one absolute code plus 24 deltas is a 25-sample window")
        XCTAssertEqual(absolute.first, expectedBaseCode)
        XCTAssertEqual(absolute.last, 362_532)
        XCTAssertTrue(absolute.allSatisfy { $0 >= 0 && $0 < (1 << 20) },
                      "every sample must sit in the 20-bit ADC domain")
        // A legacy row, whose base was never stored, is honestly unreconstructable rather than silently
        // reconstructed from a fabricated zero.
        XCTAssertNil(ppgWaveformAbsolute(baseCode: nil, deltas: row.samples))
    }

    func testExtractHistoricalStreamsCarriesEachBurstIndexWithItsWaveform() {
        let parsed = [v26Hex, v26HexChannel46].map { parseFrame(bytes($0), family: .whoop5) }
        let streams = extractHistoricalStreams(parsed,
                                               deviceClockRef: 1_780_917_232,
                                               wallClockRef: 1_780_917_232)
        XCTAssertEqual(streams.ppgWaveform.map(\.burstIndex), [1, 2])
    }

    /// `Streams.isEmpty` must count a waveform-only decode as non-empty even when `ppgHr` (derived FROM
    /// it) is empty — otherwise the Backfiller's #77 "this chunk carried no sensor records" diagnostic
    /// would misfire on a chunk that in fact persisted a raw waveform.
    func testStreamsIsEmptyConsidersPpgWaveform() {
        var s = Streams()
        XCTAssertTrue(s.isEmpty)
        s.ppgWaveform = [PpgWaveformSample(ts: 1, samples: [1, 2, 3])]
        XCTAssertFalse(s.isEmpty)
    }

    /// Streams decode tolerance: a JSON missing `ppg_waveform` still decodes (defaults to empty), and a
    /// present `ppg_waveform` round-trips, including negative (AC-coupled) sample values. Mirrors the
    /// decodeIfPresent guard for the other biometric keys (see PpgHrTests' ppg_hr analogue).
    func testStreamsDecodeToleratesMissingAndPresentPpgWaveform() throws {
        let dec = JSONDecoder()
        // Missing key → empty.
        let s1 = try dec.decode(Streams.self, from: Data(#"{"hr":[]}"#.utf8))
        XCTAssertTrue(s1.ppgWaveform.isEmpty)
        // Present key → decoded under the snake_case CodingKey.
        let json = #"{"ppg_waveform":[{"ts":1780917232,"samples":[-1432,-1332,12]}]}"#
        let s2 = try dec.decode(Streams.self, from: Data(json.utf8))
        XCTAssertEqual(s2.ppgWaveform, [PpgWaveformSample(ts: 1_780_917_232, samples: [-1432, -1332, 12])])
        XCTAssertNil(s2.ppgWaveform.first?.burstIndex, "legacy JSON has no burst index")
        // Round-trip encode → decode is identity.
        let withBurst = Streams(ppgWaveform: [PpgWaveformSample(ts: 1_780_917_232,
                                                                samples: [-1432, -1332, 12],
                                                                burstIndex: 4)])
        let round = try dec.decode(Streams.self, from: JSONEncoder().encode(withBurst))
        XCTAssertEqual(round.ppgWaveform, withBurst.ppgWaveform)
    }
}

/// #2019: the per-session optical census. Mirrored by the Kotlin `PpgWaveformCensusTest` against the
/// SAME literals, so the two platforms cannot report the same offload differently.
final class PpgWaveformCensusTests: XCTestCase {

    /// A session with no v26 windows says nothing at all: a 4.0, or a 5/MG that banked none, must not
    /// print a census of zero.
    func testNoWindowsIsSilent() {
        XCTAssertNil(ppgWaveformCensusLine(windows: 0, withBase: 0, saturatedWindows: 0,
                                           baseMin: nil, baseMax: nil))
    }

    /// The ordinary healthy session: every window carried a base, none saturated.
    func testEveryWindowReconstructable() {
        XCTAssertEqual(
            ppgWaveformCensusLine(windows: 412, withBase: 412, saturatedWindows: 0,
                                  baseMin: 361_204, baseMax: 379_881),
            "Backfill: v26 optical census: 412 window(s), 412 with a base, 0 saturated, base 361204..379881")
    }

    /// `withBase` below the window count is the signal that matters: those windows can never be
    /// reconstructed, and before this line existed they were banked with nothing said about it.
    func testWindowsMissingABaseAreVisible() {
        XCTAssertEqual(
            ppgWaveformCensusLine(windows: 10, withBase: 7, saturatedWindows: 0,
                                  baseMin: 100, baseMax: 200),
            "Backfill: v26 optical census: 10 window(s), 7 with a base, 0 saturated, base 100..200")
    }

    /// A saturated window earns the caveat inline, because the caveat is the reason to distrust the
    /// reconstruction and it is worthless if it only lives in a doc comment.
    func testSaturationCarriesItsCaveat() {
        let line = ppgWaveformCensusLine(windows: 5, withBase: 5, saturatedWindows: 2,
                                         baseMin: 1, baseMax: 2)
        XCTAssertEqual(line, "Backfill: v26 optical census: 5 window(s), 5 with a base, 2 saturated, "
                       + "base 1..2 (a saturated window reconstructs only approximately)")
    }

    /// An absent range reads as absent rather than as a fabricated zero.
    func testAbsentBaseRangeSaysSo() {
        XCTAssertEqual(
            ppgWaveformCensusLine(windows: 3, withBase: 0, saturatedWindows: 0,
                                  baseMin: nil, baseMax: nil),
            "Backfill: v26 optical census: 3 window(s), 0 with a base, 0 saturated, base n/a")
    }

    /// Both i16 rails count, and an ordinary delta does not.
    func testSaturationIsBothRails() {
        XCTAssertTrue(isSaturatedPpgDelta(-32_768))
        XCTAssertTrue(isSaturatedPpgDelta(32_767))
        XCTAssertFalse(isSaturatedPpgDelta(-1_833))
        XCTAssertFalse(isSaturatedPpgDelta(0))
    }
}

/// #2019 follow-up: the per-burst counter is a u16, not a u8. Mirrored by the Kotlin
/// `Whoop5BurstIndexWidthTest` against the same synthetic frames.
final class Whoop5BurstIndexWidthTests: XCTestCase {

    /// A counter past 255 is the whole reason for the width. Read as a u8 this frame reports 0, which is
    /// the sentinel meaning "absent", so a wrapped counter would not merely be wrong, it would vanish.
    func testACounterPastAByteSurvives() {
        let f = v26Frame(burstLow: 0x00, burstHigh: 0x01)   // 256
        let p = parseFrame(f, family: .whoop5)
        XCTAssertEqual(p.parsed["burst_index"]?.intValue, 256)
    }

    /// And the two readings agree exactly below 256, which is why every fixture we hold is unmoved: our
    /// captures carry byte 22 = 0, so they cannot tell a u16 from a u8 beside a constant zero.
    func testTheTwoReadingsAgreeBelow256() {
        for low in [1, 2, 65, 255] {
            let p = parseFrame(v26Frame(burstLow: UInt8(low), burstHigh: 0), family: .whoop5)
            XCTAssertEqual(p.parsed["burst_index"]?.intValue, low, "index \(low) must be unchanged")
        }
    }

    /// Zero stays the absent sentinel across both bytes, so a widened read cannot invent a burst.
    func testZeroIsStillAbsent() {
        let p = parseFrame(v26Frame(burstLow: 0, burstHigh: 0), family: .whoop5)
        XCTAssertNil(p.parsed["burst_index"])
    }

    /// The case where the two readings DISAGREE, pinned so the choice is deliberate rather than
    /// incidental. A low byte of 0 with a high byte set reads as absent under a u8 and as 1280 under a
    /// u16. If the high byte really is the counter's, 1280 is right and the u8 lost the burst entirely.
    /// If it is a separate field, this is where a fabricated index would come from, which is why the
    /// falsifiable prediction is a persisted index jumping by a multiple of 256.
    func testTheDivergentCaseIsPinned() {
        let p = parseFrame(v26Frame(burstLow: 0, burstHigh: 5), family: .whoop5)
        XCTAssertEqual(p.parsed["burst_index"]?.intValue, 1280)
    }

    /// A v26 frame with the counter bytes planted, sealed exactly as a strap seals one.
    private func v26Frame(burstLow: UInt8, burstHigh: UInt8) -> [UInt8] {
        var f = bytes(v26Hex)
        f[21] = burstLow
        f[22] = burstHigh
        let payloadEnd = f.count - 4
        let c = crc32(f, 8, payloadEnd)
        for b in 0..<4 { f[payloadEnd + b] = UInt8((c >> (8 * UInt32(b))) & 0xFF) }
        return f
    }

    private let v26Hex =
        "aa015000010035412f1a80ad418401f0a3266aae470100c3c5050068faccfa8dfb46fc8bfd4c"
        + "febafedafe6dff56ffd5fffbff37ff6afce5f9d7f8dffa5efc98fddbfe5afe84fe15ff5cff40"
        + "5fb33c50080101006cb67c17"

    private func bytes(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map {
            UInt8(s[s.index(s.startIndex, offsetBy: $0)...s.index(s.startIndex, offsetBy: $0 + 1)], radix: 16)!
        }
    }
}
