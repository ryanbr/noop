import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics

// RhythmView.swift — EXPERIMENTAL beat-to-beat regularity VISUALIZATION (v5 "Rhythm").
//
// Spec: docs/superpowers/specs/2026-06-19-v5-rhythm-screening-design.md (§6, §9, §11).
//
// WHAT THIS SHIPS (and deliberately does NOT):
//   This is the §11 "ship at most a clearly-labelled visualization" path. It draws the
//   Poincaré scatter of the night's R-R cloud and the DESCRIPTIVE stats from
//   `RhythmScreener` (SD1/SD2, normalised RMSSD, ectopic fraction) plus a NEUTRAL
//   regularity label ("looked steady" / "some variation" / "varied more than usual").
//   It has NO clinical verdict, NO "see a clinician" call-to-action, NO disease name,
//   NO red/alarm styling, and NO probability-of-condition — the screening heads-up is
//   HELD per §11 and is not part of this UI.
//
// SELF-CONTAINED: the view takes the engine results (`NightRhythmSummary` + the per-window
// `WindowResult`s) via init. It does NOT touch AppModel. The consent record is a local
// `@AppStorage` flag (mirroring the `TermsGateView` clickwrap), so the whole feature is
// OFF by default and only computes/shows after the user reads the experimental,
// non-diagnostic disclaimer and ticks the un-pre-checked box. Central wiring (Wave 3)
// mounts `RhythmView` as an experimental item under Settings / Health behind this gate —
// see the task's `wiringNeeded`.

// MARK: - Consent record (local, version-stamped — mirrors `Terms`)

/// The on-device consent record for the experimental Rhythm visualization. Mirrors the
/// `Terms` clickwrap pattern: a CURRENT version is stored once the user accepts; bumping
/// the version on a MATERIAL change to the disclaimer re-prompts. Nothing computes or shows
/// until `accepted` is true. Default OFF.
public enum RhythmConsent {
    /// Bump on a material change to the experimental/non-diagnostic wording to re-prompt.
    public static let currentVersion = "1.0"
    /// `@AppStorage` key holding the accepted consent version ("" = never accepted).
    public static let acceptedVersionKey = "noopRhythmConsentVersion"
    /// `@AppStorage` key for the feature on/off flag (the `noopRhythmScreening` flag, default OFF).
    public static let enabledKey = "noopRhythmScreening"

    /// True when the stored accepted version matches the current one.
    public static func isAccepted(_ storedVersion: String) -> Bool {
        !storedVersion.isEmpty && storedVersion == currentVersion
    }

    /// The points the user must read before turning the feature on (spec §9). Each is its
    /// own line (head + body), like `Terms.points`. No condition name, no diagnosis, no
    /// "consider a clinician" verdict — this is a visualization, not a screen.
    public static let points: [(String, String)] = [
        (String(localized: "Experimental, and not a medical device"),
         String(localized: "This is an experimental wellness visualization of your beat-to-beat timing. It is NOT an ECG, and it cannot diagnose, detect, or rule out any heart condition.")),
        (String(localized: "It is a picture, not a verdict"),
         String(localized: "It shows the shape of your heartbeat timing and a plain-language description of how steady it looked. It does not tell you whether anything is right or wrong.")),
        (String(localized: "Variation is normal and often benign"),
         String(localized: "Beat-to-beat timing varies for many ordinary reasons: breathing, movement, an imperfect optical reading, or the occasional extra or skipped beat that most healthy people have.")),
        (String(localized: "It is not a substitute for a professional"),
         String(localized: "If you feel unwell or are worried about your heart, contact a qualified professional; in an emergency, your local emergency service. Do not rely on NOOP.")),
        (String(localized: "Everything stays on your device"),
         String(localized: "All of this is computed on your own device from data you already have. No heartbeat data leaves it.")),
    ]
}

// MARK: - The experimental, non-diagnostic disclaimer block (permanent, non-dismissible)

/// The standing experimental + non-diagnostic note shown at the foot of the visualization
/// (spec §6 "permanent, non-dismissible disclaimer block", §7 wording). Calm titanium
/// styling — never red, never alarm. Reused at the bottom of every result state so the
/// framing is always present, even when the rhythm "looked steady".
private struct RhythmDisclaimerNote: View {
    var body: some View {
        StrandCard(padding: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "info.circle")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                Text("Experimental wellness visualization: not a diagnosis, not an ECG, and not a medical device. It cannot detect any heart condition. Beat-to-beat variation has many ordinary, benign causes. If you feel unwell or are worried, contact a qualified professional; in an emergency, your local emergency service. Everything is computed on your device.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Consent gate (clickwrap — mirrors `TermsGateView`)

/// Feature-specific consent gate, shown the FIRST time the user enables the Rhythm
/// visualization (and again if `RhythmConsent.currentVersion` changes). The user must tick
/// the un-pre-checked box and tap Accept; the accepted version is stored locally. Backing
/// out leaves the feature OFF. Mirrors `TermsGateView` exactly, but feature-scoped.
struct RhythmConsentGate: View {
    /// Called once the user accepts — the caller persists `RhythmConsent.currentVersion`
    /// and flips the feature on.
    let onAccept: () -> Void
    /// Called when the user backs out without accepting — the feature stays OFF.
    var onCancel: (() -> Void)? = nil

    @State private var checked = false

    var body: some View {
        ZStack {
            StrandPalette.surfaceBase.ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    Text("Before you turn on Rhythm")
                        .font(StrandFont.title1)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("An experimental picture of your beat-to-beat timing. Please read these first.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 36)
                .padding(.bottom, 22)
                .padding(.horizontal, 24)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(RhythmConsent.points, id: \.0) { point in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(point.0)
                                    .font(StrandFont.headline)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(point.1)
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text("This is a wellness visualization, not a screening test. It does not tell you to see a clinician and it names no condition. This is not legal or medical advice.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .padding(.top, 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 30)
                    .padding(.bottom, 18)
                }

                Rectangle()
                    .fill(StrandPalette.hairline)
                    .frame(height: 1)

                VStack(spacing: 16) {
                    Toggle(isOn: $checked) {
                        Text("I understand this is an experimental wellness feature, not a medical device or a diagnosis.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #endif

                    Button(action: onAccept) {
                        Text("Turn on Rhythm")
                    }
                    .buttonStyle(.noopPrimary)
                    .disabled(!checked)
                    .keyboardShortcut(.defaultAction)

                    if let onCancel {
                        Button("Not now", action: onCancel)
                            .buttonStyle(.noopGhost)
                    }
                }
                .padding(26)
            }
            .frame(maxWidth: 560, maxHeight: 680)
        }
    }
}

// MARK: - Poincaré scatter plot (Canvas, design-tokened)

/// The signature visualization: a Poincaré scatter of successive (NN[i], NN[i+1]) pairs.
/// A steady rhythm draws a tight elongated comet along the diagonal; a more variable one
/// draws a rounder, more diffuse cloud. Purely descriptive — drawn in the calm Rest blue
/// world (never red). The identity diagonal is shown for reference. Decorative for
/// accessibility (the numbers + label carry the meaning).
private struct PoincarePlot: View {
    let points: [RhythmScreener.PoincarePoint]
    /// The world colour the cloud + axes are drawn in (Rest blue — calm, never alarm).
    var tint: Color = StrandPalette.restColor
    var brightTint: Color = StrandPalette.restBright

    /// Fixed physiological plot bounds (ms) so the same rhythm always reads at the same
    /// scale night-to-night — 300…1500 ms covers ~40…200 bpm, the readable resting band.
    private let lo: Double = 300
    private let hi: Double = 1500

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            Canvas { ctx, size in
                let s = min(size.width, size.height)
                let inset: CGFloat = 8
                let plot = s - inset * 2

                func map(_ v: Double) -> CGFloat {
                    let clamped = Swift.min(Swift.max(v, lo), hi)
                    let frac = (clamped - lo) / (hi - lo)
                    return inset + CGFloat(frac) * plot
                }

                // Identity diagonal (NN[i] == NN[i+1]) — the line a perfectly metronomic
                // beat would sit on. Faint hairline, for reference only.
                var diag = Path()
                diag.move(to: CGPoint(x: inset, y: s - inset))
                diag.addLine(to: CGPoint(x: s - inset, y: inset))
                ctx.stroke(diag, with: .color(StrandPalette.hairlineStrong), lineWidth: 1)

                // The point cloud. Dots are small + semi-transparent so density reads as a
                // cloud; the bright world colour keeps it legible on the deep canvas.
                let r: CGFloat = 1.6
                for p in points {
                    let x = map(p.x)
                    // Canvas y grows downward; invert so higher NN[i+1] sits higher.
                    let y = s - map(p.y)
                    let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(brightTint.opacity(0.55)))
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(height: NoopMetrics.chartHeight)
        .accessibilityHidden(true)
    }
}

// MARK: - The visualization screen

/// The experimental Rhythm visualization. Self-contained: takes the engine outputs via
/// init (the night summary + the per-window results, whose `poincare` clouds + stats it
/// renders). Shows the consent gate first if consent hasn't been recorded for the current
/// version. NEVER edits AppModel.
struct RhythmView: View {

    /// The night's descriptive roll-up from `RhythmScreener.summarizeNight`, or nil when
    /// nothing readable has been computed yet (thin/garbage night, or feature just enabled).
    let night: RhythmScreener.NightRhythmSummary?
    /// The per-window results for the night, in time order. Their `poincare` clouds are
    /// pooled for the plot and their stats drive the descriptive tiles. May be empty.
    let windows: [RhythmScreener.WindowResult]
    /// Optional dismissal hook when presented as a sheet.
    var onClose: (() -> Void)? = nil

    init(night: RhythmScreener.NightRhythmSummary?,
         windows: [RhythmScreener.WindowResult],
         onClose: (() -> Void)? = nil) {
        self.night = night
        self.windows = windows
        self.onClose = onClose
    }

    // Local consent record — the feature is OFF until the user passes the gate. Mirrors the
    // Terms clickwrap; no AppModel involvement.
    @AppStorage(RhythmConsent.acceptedVersionKey) private var acceptedVersion = ""
    @AppStorage(RhythmConsent.enabledKey) private var enabled = false

    private var consentGiven: Bool {
        enabled && RhythmConsent.isAccepted(acceptedVersion)
    }

    var body: some View {
        Group {
            if consentGiven {
                visualization
            } else {
                RhythmConsentGate(
                    onAccept: {
                        acceptedVersion = RhythmConsent.currentVersion
                        enabled = true
                    },
                    onCancel: onClose
                )
            }
        }
    }

    // MARK: Visualization (post-consent)

    /// The readable window whose stats we headline — prefer the most-varied readable
    /// window so the "what a diffuse cloud looks like" example is the informative one;
    /// fall back to the first readable window, then nil.
    private var headlineWindow: RhythmScreener.WindowResult? {
        let readable = windows.filter { $0.label != .unreadable }
        return readable.first(where: { $0.label == .varied })
            ?? readable.first(where: { $0.label == .occasionalEctopy })
            ?? readable.first
    }

    /// All Poincaré points across the night's readable windows, pooled for one plot.
    private var allPoints: [RhythmScreener.PoincarePoint] {
        windows.flatMap { $0.poincare }
    }

    /// #1298: the temp .csv URL for the share sheet, written ONCE by `.task` (below) — not in `body`,
    /// so rendering never touches disk. nil until the write lands / when nothing is readable.
    @State private var rhythmExportURL: URL?

    /// Write the night's DESCRIPTIVE data to a temp .csv for the OS share sheet — the §11 "share with
    /// my clinician" path. Neutral data ONLY (`RhythmExport` forbids any verdict / condition name); nil
    /// when nothing readable. A tiny, atomic write, run off the render path from `.task`.
    private func buildRhythmExportURL() -> URL? {
        guard let night, !windows.isEmpty else { return nil }
        let csv = RhythmExport.csv(summary: night, windows: windows)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noop-rhythm.csv")
        return (try? csv.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }

    private var visualization: some View {
        ScreenScaffold(
            title: "Rhythm",
            subtitle: "An experimental picture of your beat-to-beat timing",
            // PERF: chart-heavy column (the Poincaré beat-to-beat scatter, the stats grid and the
            // methodology card). The LazyVStack path builds the off-screen cards — including the scatter
            // plot's point set — on demand; byte-identical layout.
            lazy: true,
            // Liquid finish: the day-of-sky backdrop, so the visualization sits in the same liquid
            // atmosphere as Today. The calm Rest-blue world of the cards stays unchanged over it.
            topBackground: liquidScaffoldSky(),
            trailing: { closeButton }
        ) {
            SourceBadge("Experimental", tint: StrandPalette.restColor)
                .task(id: windows.count) { rhythmExportURL = buildRhythmExportURL() }

            if allPoints.isEmpty {
                emptyState
            } else {
                summaryCard
                plotCard
                statsCard
                if let rhythmExportURL {
                    // #1298: hand the clinician the DATA, never a verdict. A neutral CSV export.
                    ShareLink(item: rhythmExportURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(StrandFont.subhead)
                    }
                    .tint(StrandPalette.restColor)
                }
            }

            methodologyCard
            RhythmDisclaimerNote()
        }
    }

    @ViewBuilder private var closeButton: some View {
        if let onClose {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Rhythm")
        }
    }

    // MARK: Summary card — the neutral, plain-language headline (NO verdict)

    /// OpenStrap-style status chip: a compact pill with an icon + the neutral regularity label. Modelled
    /// on `SourceBadge`, but in the calm Rest-blue palette — NEVER a warn/alarm colour (§11 forbids alarm
    /// styling; OpenStrap tints its chip amber, NOOP does not). States differ by icon + wording only, and
    /// the short `chipLabel` sits in the pill, the sentence `headlineDetail` reads below. Non-diagnostic.
    private var statusChip: some View {
        let label = night?.overall ?? headlineWindow?.label ?? .unreadable
        return HStack(spacing: 6) {
            Image(systemName: Self.statusIcon(label))
            Text(chipLabel(label))
        }
        .font(StrandFont.subhead)
        .foregroundStyle(StrandPalette.restBright)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(StrandPalette.restColor.opacity(0.16), in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(StrandPalette.restColor.opacity(0.34), lineWidth: 1))
    }

    /// The SHORT neutral status word inside the chip (the sentence-length `headlineDetail` reads below).
    /// Compact so the chip renders like OpenStrap's, not a full-width banner. Non-diagnostic wording.
    private func chipLabel(_ label: RhythmRegularity) -> String {
        switch label {
        case .steady:           return String(localized: "Steady")
        case .occasionalEctopy: return String(localized: "Some variation")
        case .varied:           return String(localized: "More varied")
        case .unreadable:       return String(localized: "No clear reading")
        }
    }

    /// A calm, non-alarm SF Symbol per neutral state — a check for steady, the ECG waveform for any
    /// variation (never a warning triangle), a question mark when unread. No red, no alarm (§11).
    private static func statusIcon(_ label: RhythmRegularity) -> String {
        switch label {
        case .steady:                    return "checkmark.circle.fill"
        case .occasionalEctopy, .varied: return "waveform.path.ecg"
        case .unreadable:                return "questionmark.circle"
        }
    }

    private var summaryCard: some View {
        StrandCard(padding: 18, tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("LAST NIGHT").strandOverline()
                    Spacer()
                    ScoreStatePill(confidenceState, text: confidenceText)
                }
                statusChip
                Text(headlineDetail)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Two calm liquid readouts of the night's real descriptive fractions (both 0–1, neutral —
                // never a verdict): the beat-to-beat variation index and the extra/skipped fraction. The
                // liquid tube idiom, drawn in the same Rest-blue world so it never reads as alarm. The
                // stats grid below still prints every exact number; these are a descriptive picture.
                if let hw = headlineWindow {
                    VStack(spacing: 8) {
                        liquidStatRow("Beat-to-beat variation", frac: hw.normRmssd,
                                      tint: StrandPalette.restBright)
                        liquidStatRow("Extra or skipped beats", frac: hw.ectopicFraction,
                                      tint: StrandPalette.restColor)
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    /// One calm liquid readout: an UPPERCASE overline label, the fraction as a percent, and a posed
    /// liquid tube filled to that fraction (clamped 0–1). Descriptive only — never a verdict, never red.
    /// Static tube so a page of them costs one cached frame each. Decorative for VoiceOver (the numbers
    /// grid carries the meaning).
    private func liquidStatRow(_ label: LocalizedStringKey, frac: Double?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                Text(percent(frac))
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            LiquidTube(frac: max(0, min(1, frac ?? 0)), tint: tint, height: 8, animated: false)
        }
        .accessibilityHidden(true)
    }

    // MARK: Plot card — the Poincaré scatter + the "comet vs cloud" reading note

    private var plotCard: some View {
        StrandCard(padding: 18, tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: 12) {
                Text("BEAT-TO-BEAT SCATTER").strandOverline()
                ZStack {
                    ScenicHeroBackground(domain: .rest, starCount: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    PoincarePlot(points: allPoints)
                        .padding(8)
                }
                .frame(height: NoopMetrics.chartHeight + 24)

                Text("Each dot pairs one heartbeat interval with the next. A tight line along the diagonal means a steady beat; a rounder, more spread-out cloud means the timing varied more.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Stats card — the descriptive numbers (equal-height tiles)

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("The numbers", overline: "DESCRIPTIVE STATS")
            HStack(spacing: NoopMetrics.gap) {
                StatTile(label: "SHORT AXIS",
                         value: fmt(headlineWindow?.sd1, "%.0f"),
                         caption: String(localized: "SD1 · ms"),
                         accent: StrandPalette.restBright)
                StatTile(label: "LONG AXIS",
                         value: fmt(headlineWindow?.sd2, "%.0f"),
                         caption: String(localized: "SD2 · ms"),
                         accent: StrandPalette.restColor)
            }
            HStack(spacing: NoopMetrics.gap) {
                StatTile(label: "CLOUD SHAPE",
                         value: fmt(headlineWindow?.sd1sd2, "%.2f"),
                         caption: String(localized: "SD1:SD2 ratio"),
                         accent: StrandPalette.metricCyan)
                StatTile(label: "BEAT-TO-BEAT",
                         value: percent(headlineWindow?.normRmssd),
                         caption: String(localized: "variation index"),
                         accent: StrandPalette.metricPurple)
            }
            HStack(spacing: NoopMetrics.gap) {
                StatTile(label: "EXTRA / SKIPPED",
                         value: percent(headlineWindow?.ectopicFraction),
                         caption: String(localized: "of beats"),
                         accent: StrandPalette.restColor)
                StatTile(label: "BEATS READ",
                         value: headlineWindow.map { "\($0.nBeats)" } ?? "—",
                         caption: String(localized: "clean intervals"),
                         accent: StrandPalette.textSecondary)
            }
        }
    }

    // MARK: Empty / thin-night state

    private var emptyState: some View {
        DataPendingNote(
            title: "No clear reading yet",
            message: "Rhythm only looks during quiet, still, resting windows, so it needs a calm night's worth of steady beats. Once there's a clean window, the scatter and its description show here.",
            symbol: "waveform.path"
        )
    }

    // MARK: Methodology

    private var methodologyCard: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("How this is measured").strandOverline()
                Text("During quiet, still, resting windows, NOOP looks at the timing between your heartbeats (R-R intervals) and draws their Poincaré scatter. From the cloud it computes its short and long axes (SD1, SD2) and a few plain regularity numbers. Movement and noisy windows are skipped, not shown. These are transparent, published descriptive statistics: a picture of your timing, never a clinical measurement.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Copy mapping (neutral, non-clinical — NO verdict, NO condition name)

    private var headlineDetail: String {
        switch night?.overall ?? headlineWindow?.label ?? .unreadable {
        case .steady:
            return String(localized: "Across the quiet windows we could read, your beat-to-beat timing held a tight, even shape.")
        case .occasionalEctopy:
            return String(localized: "Mostly steady, with a few isolated extra or skipped beats. Very common and usually nothing.")
        case .varied:
            return String(localized: "The scatter looked rounder and more spread out than a tight, steady beat. This has many ordinary causes and is not a diagnosis.")
        case .unreadable:
            return String(localized: "There wasn't a calm, still window clean enough to describe. Try again after a settled night.")
        }
    }

    /// Confidence pill state from the headline window's read certainty.
    private var confidenceState: ScoreState {
        switch headlineWindow?.confidence ?? .calibrating {
        case .solid:       return .solid
        case .building:    return .building
        case .calibrating: return .calibrating
        }
    }

    /// Honest confidence line so a thin night reads truthfully (spec §6).
    private var confidenceText: LocalizedStringKey {
        let readable = night?.readableWindows ?? windows.filter { $0.label != .unreadable }.count
        switch headlineWindow?.confidence ?? .calibrating {
        case .solid:       return "Solid"
        case .building:    return readable <= 1 ? "Building (1 window)" : "Building"
        case .calibrating: return "Calibrating"
        }
    }

    // MARK: - Formatting

    private func fmt(_ value: Double?, _ format: String) -> String {
        guard let value else { return "—" }
        return String(format: format, value)
    }

    /// A 0…1 fraction rendered as a whole-number percent (normalised RMSSD / ectopic fraction).
    private func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value * 100)
    }
}

#if DEBUG
#Preview("Rhythm — steady") {
    RhythmView(
        night: RhythmScreener.NightRhythmSummary(
            readableWindows: 6, steadyWindows: 6, occasionalWindows: 0,
            variedWindows: 0, variationRecurred: false, overall: .steady),
        windows: [
            RhythmScreener.WindowResult(
                label: .steady, sd1: 28, sd2: 74, sd1sd2: 0.38,
                normRmssd: 0.05, turningPointRate: 0.7, ectopicFraction: 0.01,
                nBeats: 240, confidence: .solid, agreedAcrossSources: false,
                poincare: (0..<240).map { i in
                    let base = 900.0 + sin(Double(i) * 0.3) * 30
                    return RhythmScreener.PoincarePoint(x: base, y: base + 18)
                })
        ]
    )
    .preferredColorScheme(.dark)
}
#endif
