import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Charge breakdown presentation (pure, testable)
//
// LANE 2 (iOS UI) presentation helpers for the "What shaped it" Charge breakdown, the score-
// confidence tier chip, the calibrating countdown copy and the relative skin-temp label. Every
// helper here is PURE (no SwiftUI state, no I/O) so the chip formatter and countdown copy are
// unit-tested directly; the views below consume them. They are presentation only: nothing here
// recomputes a score, a confidence or a driver delta - those arrive from the engine
// (`ChargeDriver`, `ScoreConfidence`, `SkinTempRelative`) and are surfaced verbatim.
//
// No fabricated numbers, no em-dashes. Design-system tokens only (StrandPalette / StrandFont /
// NoopMetrics); the +N/-N chip uses the recovery ramp endpoints (green peak / red depleted) so a
// supporting term reads green and a limiting term reads red, matching the Charge colour world.

enum ChargeBreakdownFormat {

    // MARK: - Signed point-delta chip (A1)

    /// The chip label for a term's signed point contribution, e.g. +6 pts / -3 pts / 0 pts.
    /// Always carries an explicit sign for a non-zero delta so a positive term reads "+N" not "N".
    /// Pure + unit-tested (`ChargeBreakdownFormatTests`).
    static func chipLabel(deltaPoints: Int) -> String {
        // Whole-phrase variants per sign/count so translators never see a stitched unit fragment.
        if deltaPoints > 0 {
            return deltaPoints == 1 ? String(localized: "+\(deltaPoints) pt")
                                    : String(localized: "+\(deltaPoints) pts")
        }
        if deltaPoints < 0 {   // the minus sign rides the value
            return deltaPoints == -1 ? String(localized: "\(deltaPoints) pt")
                                     : String(localized: "\(deltaPoints) pts")
        }
        return String(localized: "0 pts")
    }

    /// The chip colour for a signed delta, sampled from the RECOVERY RAMP endpoints so the Charge
    /// colour world stays consistent: a term that supported recovery (positive) reads the ramp's
    /// green peak, one that limited it (negative) reads the red depleted end, and a neutral term
    /// reads tertiary text so it doesn't shout. Pure.
    static func chipColor(deltaPoints: Int) -> Color {
        if deltaPoints > 0 { return StrandPalette.recoveryColor(100) }   // green peak end of the ramp
        if deltaPoints < 0 { return StrandPalette.recoveryColor(0) }     // red depleted end of the ramp
        return StrandPalette.textTertiary
    }

    /// VoiceOver phrasing of one driver row: label, signed points, value vs baseline, verdict.
    /// Built from the engine row verbatim (no recompute). Pure.
    static func driverAccessibilityLabel(_ d: ChargeDriver) -> String {
        // Whole-phrase variants (direction x count, and with/without baseline) so translators see
        // complete sentences, never stitched direction/plural fragments.
        let pts: String
        if d.deltaPoints == 0 {
            pts = String(localized: "no change")
        } else {
            let n = abs(d.deltaPoints)
            switch (d.deltaPoints > 0, n == 1) {
            case (true, true):   pts = String(localized: "up 1 point")
            case (true, false):  pts = String(localized: "up \(n) points")
            case (false, true):  pts = String(localized: "down 1 point")
            case (false, false): pts = String(localized: "down \(n) points")
            }
        }
        // The engine's label + verdict are catalog KEYS (see ChargeDrivers.swift). Interpolating them
        // raw into a String(localized:) template would leave them English in a localized build (the
        // template is the lookup key, its substitutions are not re-localized), so look each up first
        // and interpolate the already-localized text. valueText/baselineText are numeric read-outs.
        let label = String(localized: String.LocalizationValue(d.label))
        let verdict = String(localized: String.LocalizationValue(d.verdict))
        if d.baselineText.isEmpty {
            return String(localized: "\(label): \(pts). \(d.valueText). \(verdict).")
        }
        return String(localized: "\(label): \(pts). \(d.valueText), \(d.baselineText). \(verdict).")
    }

    // MARK: - Score-confidence tier chip (A3)

    /// The short tier TAG surfaced on a score tile / breakdown header. Pure presentation of the
    /// EXISTING `ScoreConfidence` (never recomputed): calibrating -> CALIBRATING, building -> EST.,
    /// solid -> REL. (reliable). Unit-tested.
    static func tierTag(_ confidence: ScoreConfidence) -> String {
        switch confidence {
        case .calibrating: return String(localized: "CALIBRATING")
        case .building:    return String(localized: "EST.")
        case .solid:       return String(localized: "REL.")
        }
    }

    /// The `ScoreState` pill style that carries the tier chip, mapping the existing confidence onto
    /// the design system's score-lifecycle hues (slate / blue / green). Pure.
    static func tierState(_ confidence: ScoreConfidence) -> ScoreState {
        switch confidence {
        case .calibrating: return .calibrating
        case .building:    return .building
        case .solid:       return .solid
        }
    }

    /// The small confidence-dot colour, reusing the same lifecycle hue as the tier pill so the dot
    /// and the tag never disagree. Pure.
    static func confidenceDotColor(_ confidence: ScoreConfidence) -> Color {
        tierState(confidence).color
    }

    // MARK: - Calibrating countdown copy (A4)

    /// The hero countdown line shown in place of an empty/zero Charge while the baseline is still
    /// building, e.g. "2 nights to go". `nightsRemaining` is the EXISTING calibrating value (seed
    /// gate minus banked, clamped >= 1 by the caller); the singular/plural reads honestly. Pure +
    /// unit-tested.
    static func calibrationCountdown(nightsRemaining: Int) -> String {
        // Whole-phrase variants per count so translators never see a stitched plural fragment.
        let n = max(0, nightsRemaining)
        return n == 1 ? String(localized: "1 night to go") : String(localized: "\(n) nights to go")
    }

    /// #731: names WHY the countdown restarted when the user tapped "Recalibrate baseline".
    ///
    /// The count alone is not enough. A reporter sat at "Calibrating, 3 of 4 nights" with 15 valid HRV
    /// nights on file and tapped Recalibrate again — which discards every earlier night and resets the
    /// count to 0. Two weeks of that and Charge could never return. Seeing the countdown without knowing
    /// their own tap caused it makes re-tapping the natural move; naming the cause is what breaks the loop.
    ///
    /// A separate whole sentence rather than a fragment appended to the countdown, so translators never
    /// see a stitched string. Returns nil when no recalibration is set, so the card is unchanged for every
    /// user who never tapped it. Pure.
    static func calibrationRestartCause(recalibratedOn day: String?) -> String? {
        guard let day, !day.isEmpty else { return nil }
        return String(localized: "Restarted when you recalibrated on \(day) — no need to tap it again.")
    }

    /// The recalibration epoch as a short display day ("19 Jul"), or nil when none is set. Pure — the
    /// caller supplies the epoch (`Baselines.hrvBaselineEpoch()`), so this stays testable. Locale-aware
    /// via `DateFormatter.setLocalizedDateFormatFromTemplate`, so the day/month order follows the user.
    static func recalibrationDay(epoch: Double, locale: Locale = AppLanguage.activeLocale) -> String? {
        guard epoch > 0 else { return nil }
        let fmt = DateFormatter()
        fmt.locale = locale
        fmt.setLocalizedDateFormatFromTemplate("d MMM")
        return fmt.string(from: Date(timeIntervalSince1970: epoch))
    }

    /// Convenience for the calibrating cards: the restart-cause line for the CURRENT recalibration epoch,
    /// or nil when the user has never recalibrated. Keeps the single UserDefaults read in one place
    /// instead of repeating it at each card. (#731)
    static func currentCalibrationRestartCause() -> String? {
        calibrationRestartCause(recalibratedOn: recalibrationDay(epoch: Baselines.hrvBaselineEpoch()))
    }

    /// The supporting line under the countdown, naming the score whose baseline is unlocking. Pure.
    /// `scoreName` is the user-facing score word (e.g. "Charge"); kept a parameter so the same copy
    /// serves any baseline-building score honestly without hard-coding one.
    static func calibrationUnlockCopy(scoreName: String) -> String {
        String(localized: "more overnight wear to unlock your \(scoreName) baseline")
    }

    /// "Calibrating, 1 of 4 nights" progress label for the countdown card header. `banked` is the
    /// nights gathered so far, `seed` the gate (`Baselines.minNightsSeed`). Pure + unit-tested.
    static func calibrationProgress(banked: Int, seed: Int) -> String {
        String(localized: "Calibrating, \(max(0, banked)) of \(seed) nights")
    }

    // MARK: - Relative skin-temp label (A5)

    /// The relative skin-temp read-out, e.g. "+0.3 C vs your normal" / "-0.4 C vs your normal".
    /// Built from the engine's signed deviation; one decimal, explicit sign, never a fake absolute.
    /// Pure + unit-tested.
    static func skinTempDeviationLabel(_ rel: SkinTempRelative) -> String {
        let sign = rel.deviationC >= 0 ? "+" : ""
        return String(localized: "\(sign)\(String(format: "%.1f", rel.deviationC)) C vs your normal")
    }

    /// The plain-English tier word for the relative skin-temp marker. Pure.
    static func skinTempTierWord(_ tier: SkinTempRelative.Tier) -> String {
        switch tier {
        case .cooler:  return String(localized: "Cooler than your baseline")
        case .typical: return String(localized: "Typical for you")
        case .warmer:  return String(localized: "Warmer than your baseline")
        }
    }

    // MARK: - Deep-sleep HRV window gap (#233)

    /// True when a night's empty Charge is explained by the Deep-sleep HRV window finding no deep-stage
    /// sleep, rather than a generic missing-data gap. Charge needs a nightly HRV value (`avgHrv`); under
    /// the Deep window that value pools RMSSD over 5-min deep-stage windows only and is nil when the
    /// night banks under ~5 minutes of deep sleep (WHOOP 4.0 deep staging is often sparse/absent).
    /// `deepMin` is the night's OWN already-computed deep-sleep minutes, so this is a read-only
    /// presentation check over existing fields, not a new analytics path. Pure.
    static func chargeDeepWindowGap(hrvWindow: HrvWindow, avgHrv: Double?, deepMin: Double?) -> Bool {
        hrvWindow == .deep && avgHrv == nil && (deepMin ?? 0) < 5
    }

    /// The short title for the #233 deep-window gap note.
    static let chargeDeepWindowGapTitle = String(localized: "No deep sleep detected")

    /// The explanatory detail + next step: names the cause (Deep window, no deep sleep that night) and
    /// the two ways out, rather than leaving an unexplained blank ring.
    static let chargeDeepWindowGapDetail = String(localized: "The Deep sleep HRV window needs a night with deep-stage sleep to score Charge. Switch to Whole night in Settings, or wait for a night with more deep sleep.")

    /// VoiceOver plain string (title + detail).
    static var chargeDeepWindowGapAccessibility: String {
        "\(chargeDeepWindowGapTitle). \(chargeDeepWindowGapDetail)"
    }
}

// MARK: - A3: confidence dot + tier tag pill

/// A small confidence dot + tier tag pill (CALIBRATING / EST. / REL.) surfaced on score tiles and the
/// breakdown header. PURE presentation of the EXISTING `ScoreConfidence` , it never recomputes the
/// confidence; it maps it onto the design system's `ScoreState` hue + a short tag. Uses the same
/// rounded capsule chrome as `ScoreStatePill` so it sits consistently next to the source badge.
struct ConfidenceTierChip: View {
    let confidence: ScoreConfidence

    private var tag: String { ChargeBreakdownFormat.tierTag(confidence) }
    private var hue: Color { ChargeBreakdownFormat.confidenceDotColor(confidence) }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(hue)
                .frame(width: 7, height: 7)
                .shadow(color: hue.opacity(0.8), radius: 2)
                .accessibilityHidden(true)
            Text(tag)
                .font(StrandFont.overline)
                .tracking(0.4)
                .foregroundStyle(hue)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(hue.opacity(0.12)))
        .overlay(Capsule(style: .continuous).stroke(hue.opacity(0.32), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    private var accessibility: String {
        switch confidence {
        case .calibrating: return String(localized: "Confidence: calibrating")
        case .building:    return String(localized: "Confidence: estimate")
        case .solid:       return String(localized: "Confidence: reliable")
        }
    }
}

// MARK: - A1: "What shaped it" Charge breakdown

/// The "What shaped it" breakdown rendered under the Charge ring: a header carrying the confidence
/// tier chip, then one row per engine-supplied `ChargeDriver` (biggest mover first), and the A5
/// relative skin-temp marker at the foot when present. Every value is surfaced verbatim from the
/// engine; nothing here recomputes a score, a delta or a tier. The caller GATES on a non-empty driver
/// list, so this view assumes at least one row (a calibrating night shows the countdown instead).
struct ChargeBreakdownSection: View {
    let drivers: [ChargeDriver]
    let confidence: ScoreConfidence
    var skinTempRel: SkinTempRelative? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
            Divider().overlay(StrandPalette.hairline)
            HStack(alignment: .firstTextBaseline) {
                Text("What shaped it").strandOverline()
                Spacer()
                ConfidenceTierChip(confidence: confidence)
            }
            VStack(spacing: NoopMetrics.rowSpacing) {
                let maxMag = drivers.map { abs($0.deltaPoints) }.max() ?? 1
                ForEach(Array(drivers.enumerated()), id: \.offset) { _, driver in
                    ChargeDriverRow(driver: driver, maxMagnitude: maxMag)
                }
            }
            // A5 , the night's relative skin-temp marker, tagged REL., shown as a deviation from the
            // personal normal rather than a fake clinical absolute. Only when the night carries one.
            if let rel = skinTempRel {
                SkinTempDeviationRow(rel: rel)
                    .padding(.top, NoopMetrics.space1)
            }
        }
    }
}

/// One driver row: a signed point-delta chip (+N green / -N red), the value vs baseline, a thin
/// progress bar proportional to the term's magnitude, and the plain-English verdict line. The bar is
/// a presentation cue for "how big a mover" this term was, scaled within the day's own drivers.
struct ChargeDriverRow: View {
    let driver: ChargeDriver
    /// The largest |deltaPoints| in the same breakdown, so each bar reads as a share of the day's
    /// biggest mover. Defaults to this row's own magnitude (full bar) when not supplied.
    var maxMagnitude: Int? = nil

    private var chipText: String { ChargeBreakdownFormat.chipLabel(deltaPoints: driver.deltaPoints) }
    private var chipHue: Color { ChargeBreakdownFormat.chipColor(deltaPoints: driver.deltaPoints) }
    private var magnitude: Double { Double(abs(driver.deltaPoints)) }
    private var barMax: Double { Double(max(1, maxMagnitude ?? abs(driver.deltaPoints))) }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(LocalizedStringKey(driver.label))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 8)
                // The signed point-delta chip , green for a supporting term, red for a limiting one.
                Text(chipText)
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(chipHue)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(chipHue.opacity(0.14), in: Capsule(style: .continuous))
            }
            // value vs baseline , the baseline line is omitted for terms with no learned baseline.
            HStack(spacing: 6) {
                Text(driver.valueText)
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textSecondary)
                if !driver.baselineText.isEmpty {
                    Text("·").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    Text(driver.baselineText)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 0)
            }
            // A thin magnitude bar tinted to the chip hue, reading the term's share of the biggest mover.
            PipBar(value: magnitude, range: 0...barMax, segments: 16, tint: chipHue, height: 6)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(driver.verdict))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ChargeBreakdownFormat.driverAccessibilityLabel(driver))
    }
}

/// A5 , the relative skin-temp deviation row: "Skin temperature · +0.3 C vs your normal" with a REL.
/// tag pill (the relative tier is reliable presentation, never a clinical absolute). Tinted amber to
/// match the skin-temp accent used in the Charge model explainer.
struct SkinTempDeviationRow: View {
    let rel: SkinTempRelative

    private var deviationText: String { ChargeBreakdownFormat.skinTempDeviationLabel(rel) }
    private var tierWord: String { ChargeBreakdownFormat.skinTempTierWord(rel.tier) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "thermometer.medium")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StrandPalette.metricAmber)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Skin temperature")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(deviationText)
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.metricAmber)
                }
                Text(tierWord)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 0)
            // The relative tier is a reliable read of a measured deviation, so it carries the REL. tag.
            ConfidenceTierChip(confidence: .solid)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Skin temperature \(deviationText). \(tierWord). Reliable.")
    }
}

#if DEBUG
#Preview("Charge breakdown") {
    ScrollView {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            HStack(spacing: 10) {
                ConfidenceTierChip(confidence: .calibrating)
                ConfidenceTierChip(confidence: .building)
                ConfidenceTierChip(confidence: .solid)
            }
            NoopCard(padding: 18, tint: StrandPalette.chargeColor) {
                ChargeBreakdownSection(
                    drivers: [
                        ChargeDriver(label: "Heart rate variability", deltaPoints: 7,
                                     valueText: "72 ms", baselineText: "64 ms baseline",
                                     verdict: "above baseline, supporting recovery"),
                        ChargeDriver(label: "Resting heart rate", deltaPoints: -4,
                                     valueText: "60 bpm", baselineText: "56 bpm baseline",
                                     verdict: "above baseline, limiting recovery"),
                        ChargeDriver(label: "Sleep quality", deltaPoints: 2,
                                     valueText: "88%", baselineText: "",
                                     verdict: "a strong night, supporting recovery"),
                    ],
                    confidence: .building,
                    skinTempRel: SkinTempRelative(deviationC: 0.3, tier: .warmer))
            }
        }
        .padding(NoopMetrics.screenPadding)
    }
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}

/// DEBUG-only screenshot host for `--demo-screen chargebreakdown`: renders the "What shaped it" Charge
/// breakdown populated with deterministic demo drivers, exactly as it appears when the Today Charge ring is
/// tapped (confidence/tier chip in the header, signed point rows, the relative skin-temp marker). Stripped
/// from Release.
struct ChargeBreakdownDemoHost: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: NoopMetrics.gap) {
                    NoopCard(padding: 18, tint: StrandPalette.chargeColor) {
                        ChargeBreakdownSection(
                            drivers: [
                                ChargeDriver(label: "Heart rate variability", deltaPoints: 9,
                                             valueText: "78 ms", baselineText: "62 ms baseline",
                                             verdict: "above baseline, supporting recovery"),
                                ChargeDriver(label: "Resting heart rate", deltaPoints: 4,
                                             valueText: "53 bpm", baselineText: "58 bpm baseline",
                                             verdict: "below baseline, supporting recovery"),
                                ChargeDriver(label: "Sleep quality", deltaPoints: 2,
                                             valueText: "91%", baselineText: "",
                                             verdict: "a strong night, supporting recovery"),
                                ChargeDriver(label: "Respiratory rate", deltaPoints: 1,
                                             valueText: "14.2 br/min", baselineText: "15.0 br/min baseline",
                                             verdict: "below baseline, supporting recovery"),
                                ChargeDriver(label: "Skin temperature", deltaPoints: -1,
                                             valueText: "+0.4 C vs baseline", baselineText: "",
                                             verdict: "warmer than baseline, limiting recovery"),
                            ],
                            confidence: .solid,
                            skinTempRel: SkinTempRelative(deviationC: 0.4, tier: .warmer))
                    }
                }
                .padding(NoopMetrics.screenPadding)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle("What shaped your Charge")
        }
        .preferredColorScheme(.dark)
    }
}
#endif
