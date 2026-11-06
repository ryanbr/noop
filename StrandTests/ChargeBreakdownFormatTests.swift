import XCTest
import StrandAnalytics
import StrandDesign
@testable import Strand

/// LANE 2 (iOS UI) presentation helpers behind the "What shaped it" Charge breakdown, the score-
/// confidence tier chip, the calibrating countdown and the relative skin-temp label. Every helper is
/// PURE, so these assert the exact strings/colours the views render. No em-dashes.
final class ChargeBreakdownFormatTests: XCTestCase {

    // MARK: - A1: signed point-delta chip

    func testChipLabelCarriesExplicitSignAndPluralizes() {
        XCTAssertEqual(ChargeBreakdownFormat.chipLabel(deltaPoints: 6), "+6 pts")
        XCTAssertEqual(ChargeBreakdownFormat.chipLabel(deltaPoints: 1), "+1 pt")   // singular
        XCTAssertEqual(ChargeBreakdownFormat.chipLabel(deltaPoints: -3), "-3 pts")
        XCTAssertEqual(ChargeBreakdownFormat.chipLabel(deltaPoints: -1), "-1 pt")  // singular
        XCTAssertEqual(ChargeBreakdownFormat.chipLabel(deltaPoints: 0), "0 pts")
    }

    func testChipColorUsesRecoveryRampEndpoints() {
        // Positive -> the ramp's green peak; negative -> its red depleted end; neutral -> tertiary text.
        XCTAssertEqual(ChargeBreakdownFormat.chipColor(deltaPoints: 5), StrandPalette.recoveryColor(100))
        XCTAssertEqual(ChargeBreakdownFormat.chipColor(deltaPoints: -5), StrandPalette.recoveryColor(0))
        XCTAssertEqual(ChargeBreakdownFormat.chipColor(deltaPoints: 0), StrandPalette.textTertiary)
    }

    func testDriverAccessibilityLabelReadsRowVerbatim() {
        let d = ChargeDriver(label: "Resting heart rate", deltaPoints: 4,
                             valueText: "58 bpm", baselineText: "61 bpm baseline",
                             verdict: "below baseline, supporting recovery")
        XCTAssertEqual(
            ChargeBreakdownFormat.driverAccessibilityLabel(d),
            "Resting heart rate: up 4 points. 58 bpm, 61 bpm baseline. below baseline, supporting recovery.")
    }

    func testDriverAccessibilityLabelOmitsEmptyBaselineAndHandlesNegativeAndZero() {
        let neg = ChargeDriver(label: "Skin temperature", deltaPoints: -2,
                               valueText: "+0.4 C vs baseline", baselineText: "",
                               verdict: "warmer than baseline, limiting recovery")
        XCTAssertEqual(
            ChargeBreakdownFormat.driverAccessibilityLabel(neg),
            "Skin temperature: down 2 points. +0.4 C vs baseline. warmer than baseline, limiting recovery.")

        let zero = ChargeDriver(label: "Respiratory rate", deltaPoints: 0,
                                valueText: "14.0 br/min", baselineText: "14.0 br/min baseline",
                                verdict: "at baseline")
        XCTAssertEqual(
            ChargeBreakdownFormat.driverAccessibilityLabel(zero),
            "Respiratory rate: no change. 14.0 br/min, 14.0 br/min baseline. at baseline.")

        // singular point reads "point", not "points"
        let one = ChargeDriver(label: "HRV", deltaPoints: 1, valueText: "70 ms",
                               baselineText: "65 ms baseline", verdict: "above baseline, supporting recovery")
        XCTAssertTrue(ChargeBreakdownFormat.driverAccessibilityLabel(one).contains("up 1 point."))
    }

    /// The VoiceOver label now routes the engine's label + verdict (which are localization KEYS) through
    /// `String(localized:)` before interpolating, so a localized build reads them translated instead of
    /// leaking English. In the base (en) locale each key resolves to itself, so the sentence is unchanged:
    /// this pins that the localization wiring did not alter the en output (the parity fix must stay
    /// behaviour-preserving at source). The real engine label/verdict strings are used, so the assertion
    /// also proves those exact keys exist to localize.
    func testDriverAccessibilityLabelResolvesLabelAndVerdictThroughLocalization() {
        let d = ChargeDriver(label: "Heart rate variability", deltaPoints: 7,
                             valueText: "72 ms", baselineText: "64 ms baseline",
                             verdict: "above baseline, supporting recovery")
        // en: keys resolve to themselves -> identical to the pre-localization sentence.
        XCTAssertEqual(
            ChargeBreakdownFormat.driverAccessibilityLabel(d),
            "Heart rate variability: up 7 points. 72 ms, 64 ms baseline. above baseline, supporting recovery.")
    }

    // MARK: - A3: confidence tier chip (pure presentation of the EXISTING confidence)

    func testTierTagMapsConfidenceToShortTag() {
        XCTAssertEqual(ChargeBreakdownFormat.tierTag(.calibrating), "CALIBRATING")
        XCTAssertEqual(ChargeBreakdownFormat.tierTag(.building), "EST.")
        XCTAssertEqual(ChargeBreakdownFormat.tierTag(.solid), "REL.")
    }

    func testTierStateDotColorAgreesAndMapsLifecycleHues() {
        // Each confidence must map onto its lifecycle ScoreState (slate calibrating / blue building /
        // green solid); the dot colour reuses that state's hue so they never disagree on screen. We
        // assert the STATE mapping (Equatable), not the Color: SwiftUI dynamic-catalog colours mint a
        // fresh object per access, so Color == is unreliable even for the same palette token. The dot
        // colour is `tierState(confidence).color` by construction, so verifying the state mapping is
        // the honest, stable check.
        XCTAssertEqual(ChargeBreakdownFormat.tierState(.calibrating), .calibrating)
        XCTAssertEqual(ChargeBreakdownFormat.tierState(.building), .building)
        XCTAssertEqual(ChargeBreakdownFormat.tierState(.solid), .solid)
    }

    // MARK: - A4: calibrating countdown copy

    func testCalibrationCountdownPluralizes() {
        XCTAssertEqual(ChargeBreakdownFormat.calibrationCountdown(nightsRemaining: 2), "2 nights to go")
        XCTAssertEqual(ChargeBreakdownFormat.calibrationCountdown(nightsRemaining: 1), "1 night to go")
        XCTAssertEqual(ChargeBreakdownFormat.calibrationCountdown(nightsRemaining: 0), "0 nights to go")
    }

    func testCalibrationUnlockCopyNamesTheScore() {
        XCTAssertEqual(ChargeBreakdownFormat.calibrationUnlockCopy(scoreName: "Charge"),
                       "more overnight wear to unlock your Charge baseline")
    }

    func testCalibrationProgressReadsBankedOfSeed() {
        XCTAssertEqual(ChargeBreakdownFormat.calibrationProgress(banked: 1, seed: 4),
                       "Calibrating, 1 of 4 nights")
        XCTAssertEqual(ChargeBreakdownFormat.calibrationProgress(banked: 0, seed: 4),
                       "Calibrating, 0 of 4 nights")
    }

    // MARK: - A5: relative skin-temp label

    func testSkinTempDeviationLabelSignsAndRoundsToOneDecimal() {
        XCTAssertEqual(
            ChargeBreakdownFormat.skinTempDeviationLabel(SkinTempRelative(deviationC: 0.34, tier: .warmer)),
            "+0.3 °C vs your normal")
        XCTAssertEqual(
            ChargeBreakdownFormat.skinTempDeviationLabel(SkinTempRelative(deviationC: -0.42, tier: .cooler)),
            "-0.4 °C vs your normal")
        XCTAssertEqual(
            ChargeBreakdownFormat.skinTempDeviationLabel(SkinTempRelative(deviationC: 0.0, tier: .typical)),
            "+0.0 °C vs your normal")
    }

    /// Anything that rounds to zero prints "+0.0", as on Android. A negative zero once printed "+-0.0" (a
    /// hand-built sign) and Foundation's locale formatter prints "-+0.0" for it.
    func testSkinTempDeviationFigureZeroes() {
        XCTAssertEqual(ChargeBreakdownFormat.skinTempDeviationFigure(-0.0, unit: .celsius), "+0.0 °C")
        XCTAssertEqual(ChargeBreakdownFormat.skinTempDeviationFigure(0.0, unit: .celsius), "+0.0 °C")
        XCTAssertEqual(ChargeBreakdownFormat.skinTempDeviationFigure(-0.04, unit: .celsius), "+0.0 °C")
    }

    /// Ties round half away from zero on both platforms (Foundation alone printed 0.25 as "+0.2"; Java as
    /// "+0.3"). The same inputs and outputs are pinned in Kotlin's `ChargeDriverTempDeviationTest`.
    func testSkinTempDeviationFigureRoundsTiesAwayFromZero() {
        let cases: [(Double, TemperatureUnit, String)] = [
            (0.25, .celsius, "+0.3 °C"), (-0.25, .celsius, "-0.3 °C"), (0.05, .celsius, "+0.1 °C"),
            (-0.05, .celsius, "-0.1 °C"), (0.15, .celsius, "+0.2 °C"), (1.35, .celsius, "+1.4 °C"),
        ]
        for (dev, unit, expected) in cases {
            XCTAssertEqual(ChargeBreakdownFormat.skinTempDeviationFigure(dev, unit: unit), expected, "\(dev)")
        }
    }

    /// A Fahrenheit reader gets the deviation in °F: a difference scales by 9/5 with no +32 offset, from
    /// the unrounded figure (0.44 °C is 0.792 °F, so +0.8, not the +0.7 a rounded +0.4 would give).
    func testSkinTempDeviationFollowsTheTemperatureUnit() {
        XCTAssertEqual(ChargeBreakdownFormat.skinTempDeviationFigure(0.44, unit: .fahrenheit), "+0.8 °F")
        XCTAssertEqual(ChargeBreakdownFormat.skinTempDeviationFigure(-0.3, unit: .fahrenheit), "-0.5 °F")
        XCTAssertEqual(
            ChargeBreakdownFormat.skinTempDeviationLabel(SkinTempRelative(deviationC: 0.5, tier: .warmer), unit: .fahrenheit),
            "+0.9 °F vs your normal")
    }

    /// The skin-temperature driver row shows the reader's unit; its points and verdict are the engine's, and
    /// every other driver passes through untouched.
    func testDisplayDriverConvertsOnlyTheSkinTemperatureRow() {
        let skin = RecoveryScorer.chargeDrivers(
            hrv: 60, rhr: 58, resp: nil,
            hrvBaseline: BaselineState(baseline: 60, spread: 10, nValid: 30, nightsSinceUpdate: 0, status: .trusted),
            rhrBaseline: nil, respBaseline: nil, sleepPerf: nil, skinTempDev: 0.44)
            .first { $0.label == "Skin temperature" }!
        XCTAssertEqual(skin.valueText, "+0.4 C vs baseline", "The engine text stays Celsius by contract")
        let f = ChargeBreakdownFormat.displayDriver(skin, skinTempDevC: 0.44, unit: .fahrenheit)
        XCTAssertEqual(f.valueText, "+0.8 °F vs baseline")
        XCTAssertEqual(f.deltaPoints, skin.deltaPoints)
        XCTAssertEqual(f.verdict, skin.verdict)
        XCTAssertEqual(ChargeBreakdownFormat.displayDriver(skin, skinTempDevC: 0.44, unit: .celsius).valueText,
                       "+0.4 °C vs baseline", "Celsius keeps the engine's figure and gains the degree sign")
        XCTAssertEqual(ChargeBreakdownFormat.displayDriver(skin, skinTempDevC: nil, unit: .fahrenheit), skin)
        let hrv = ChargeDriver(label: "Heart rate variability", deltaPoints: 3, valueText: "72 ms",
                               baselineText: "64 ms baseline", verdict: "above baseline, supporting recovery")
        XCTAssertEqual(ChargeBreakdownFormat.displayDriver(hrv, skinTempDevC: 0.44, unit: .fahrenheit), hrv)
    }

    func testSkinTempTierWord() {
        XCTAssertEqual(ChargeBreakdownFormat.skinTempTierWord(.cooler), "Cooler than your baseline")
        XCTAssertEqual(ChargeBreakdownFormat.skinTempTierWord(.typical), "Typical for you")
        XCTAssertEqual(ChargeBreakdownFormat.skinTempTierWord(.warmer), "Warmer than your baseline")
    }

    // MARK: - Deep-sleep HRV window gap (#233)

    func testChargeDeepWindowGapTrueOnlyForDeepWindowNilHrvAndNoDeepSleep() {
        // The gap: Deep window selected, no HRV computed, and under ~5 minutes of deep sleep that night.
        XCTAssertTrue(ChargeBreakdownFormat.chargeDeepWindowGap(hrvWindow: .deep, avgHrv: nil, deepMin: 0))
        XCTAssertTrue(ChargeBreakdownFormat.chargeDeepWindowGap(hrvWindow: .deep, avgHrv: nil, deepMin: nil))
        XCTAssertTrue(ChargeBreakdownFormat.chargeDeepWindowGap(hrvWindow: .deep, avgHrv: nil, deepMin: 4.9))

        // Whole-night window: never the deep-window gap, regardless of HRV/deep-sleep values.
        XCTAssertFalse(ChargeBreakdownFormat.chargeDeepWindowGap(hrvWindow: .whole, avgHrv: nil, deepMin: 0))

        // HRV present: Charge isn't actually empty, so this isn't the gap.
        XCTAssertFalse(ChargeBreakdownFormat.chargeDeepWindowGap(hrvWindow: .deep, avgHrv: 55.0, deepMin: 0))

        // Enough deep sleep banked: the nil (if any) has some other cause, not "no deep sleep".
        XCTAssertFalse(ChargeBreakdownFormat.chargeDeepWindowGap(hrvWindow: .deep, avgHrv: nil, deepMin: 12.0))
    }
}
