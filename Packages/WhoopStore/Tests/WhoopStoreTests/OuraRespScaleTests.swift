import XCTest
import WhoopProtocol
@testable import WhoopStore

/// `OuraRespScale` is the single seam between two different physical quantities that share the
/// `respSample` table: a WHOOP's raw respiration ADC waveform and an Oura ring's own per-window
/// RATE (0x6A `breath`). These pin the scale, and pin that a ring's rows are refused for scoring by
/// PROVENANCE — not by happening to be too sparse for the stager's window.
final class OuraRespScaleTests: XCTestCase {

    private let ring = "oura-2H3B2405003655"
    private let strap = "whoop-AABBCCDD"

    // MARK: - The scale

    /// The wire field is `u8 / 8`, so its whole alphabet is 0…31.875 bpm in 0.125 steps, and milli-bpm
    /// represents every one of them EXACTLY (`wireByte × 125`). This is the reason the scale is milli
    /// and not the codebase's usual centi: at centi, half the alphabet lands on `x.5` and needs a
    /// rounding rule both platforms would then have to agree about forever.
    func testEveryWireValueIsExactInMilliBpm() {
        for byte in 0...255 {
            let bpm = Double(byte) / 8.0
            let raw = OuraRespScale.milliBpm(fromBreathsPerMin: bpm)
            XCTAssertEqual(raw, byte * 125)
            XCTAssertEqual(OuraRespScale.breathsPerMin(raw: raw), bpm, accuracy: 1e-12)
        }
    }

    /// The values actually observed on real nights, spelled out so a scale change cannot pass quietly.
    func testObservedNightMediansMapAsWritten() {
        XCTAssertEqual(OuraRespScale.milliBpm(fromBreathsPerMin: 14.250), 14_250)
        XCTAssertEqual(OuraRespScale.milliBpm(fromBreathsPerMin: 14.375), 14_375)
        XCTAssertEqual(OuraRespScale.milliBpm(fromBreathsPerMin: 14.625), 14_625)
        XCTAssertEqual(OuraRespScale.milliBpm(fromBreathsPerMin: 15.000), 15_000)
    }

    // MARK: - Which owner's rows are a rate

    func testOnlyARingsRowsAreARate() {
        XCTAssertTrue(OuraRespScale.isRingRateStream(deviceId: ring))
        XCTAssertFalse(OuraRespScale.isRingRateStream(deviceId: strap))
        XCTAssertFalse(OuraRespScale.isRingRateStream(deviceId: "my-whoop"))
        XCTAssertFalse(OuraRespScale.isRingRateStream(deviceId: ""))
    }

    /// A ring row plots as breaths/min; a WHOOP row plots as the ADC count it always did. Without the
    /// scaling the Deep Timeline would draw a ring's 14.375 bpm as 14,375 on a track it labels
    /// "Respiration".
    func testDisplayValueScalesOnlyTheRingsRows() {
        XCTAssertEqual(OuraRespScale.displayValue(raw: 14_375, deviceId: ring), 14.375, accuracy: 1e-12)
        XCTAssertEqual(OuraRespScale.displayValue(raw: 14_375, deviceId: strap), 14_375, accuracy: 1e-12)
    }

    // MARK: - The scoring refusal

    /// The instrumentation disposition's hard half: stored, shown, never scored. The stager reads this
    /// stream as a ~1 Hz raw ADC waveform and runs a peak detector over it, which a per-window rate is
    /// not. A WHOOP's rows pass through untouched, so no existing night changes.
    func testRingRespirationIsRefusedForScoringAndWhoopIsUntouched() {
        let rows = [RespSample(ts: 1_000, raw: 14_375, unit: OuraRespScale.unitTag),
                    RespSample(ts: 1_296, raw: 14_500, unit: OuraRespScale.unitTag)]
        XCTAssertTrue(OuraRespScale.forScoring(rows, deviceId: ring).isEmpty)
        XCTAssertEqual(OuraRespScale.forScoring(rows, deviceId: strap), rows)
        XCTAssertEqual(OuraRespScale.forScoring([], deviceId: ring), [])
    }
}
