import SwiftUI
import StrandDesign
import StrandAnalytics

/// Intelligence — NOOP's own recovery/strain/sleep scores, computed on-device from raw strap data
/// using the WHOOP model shape. Makes the app independent of WHOOP's cloud for live-collected days.
///
/// i18n: the By-Day core labels (Effort/Charge/Rest/HRV/RHR) and the Charge-model "Effort" heading are
/// looked up via `String(localized:)` so non-English locales (e.g. German, issue #1020) actually
/// translate them instead of rendering the English literal. pt-PT catalog strings adopted from
/// tigercraft4's PR #1018 (marked needs_review — machine ES→PT conversion pending native review).
struct IntelligenceView: View {
    @EnvironmentObject var intelligence: IntelligenceEngine
    // NOTE: IntelligenceView deliberately does NOT observe `LiveState`. A connected strap publishes at
    // ~1 Hz, which would re-evaluate this body (and its lazy By-Day list) on every tick. The only live
    // dependency — the "Syncing strap history…" note shown over the empty state — owns its OWN
    // `@EnvironmentObject var live` in the `IntelSyncingNote` leaf below (mirrors the Today/Sleep
    // leaf-scoping pattern), so a tick refreshes only that note.

    @State private var range: IntelRange = .month

    // Effort display scale (#268) — routes every Effort value/label on this screen. Display-only.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    var body: some View {
        // `lazy` so the trailing By-Day `ForEach` renders day cards on demand. With an 800+ day
        // imported history, an eager VStack built every card up-front on the main thread and froze
        // the app when ALL was tapped (#345); LazyVStack only materialises what's on screen.
        ScreenScaffold(title: "Intelligence",
                       subtitle: "NOOP scores your charge, effort and rest itself: on-device, no cloud.",
                       lazy: true,
                       // Liquid finish: the same full-bleed day-of-sky backdrop Today + the other liquid
                       // tabs carry, so Intelligence sits in one atmosphere. Static + non-interactive; the
                       // frosted cards below sit on the opaque canvas and stay legible.
                       topBackground: liquidScaffoldSky()) {
            if let f = forecast { forecastCard(f) }
            explainerCard
            if intelligence.computing {
                NoopCard(padding: 20, tint: StrandPalette.chargeColor) {
                    HStack(spacing: NoopMetrics.rowSpacing) {
                        ProgressView().controlSize(.small)
                        Text("Crunching your raw streams…").font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            } else if let note = intelligence.note {
                NoopCard(padding: 20, tint: StrandPalette.chargeColor) {
                    HStack(alignment: .top, spacing: NoopMetrics.rowSpacing) {
                        Image(systemName: "moon.zzz.fill").foregroundStyle(StrandPalette.chargeColor)
                            .accessibilityHidden(true)
                        Text(note).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if intelligence.results.isEmpty {
                // While the strap is mid-offload, say so — "no days" reads as final otherwise (#77). The
                // note owns the `LiveState` observation in its own leaf so the chunk count ticks without
                // re-rendering Intelligence (identical output to the prior inline check).
                IntelSyncingNote()
                DataPendingNote(
                    title: "Building from your strap",
                    message: "This builds from the strap as it syncs. Effort and rest appear after you have worn it and slept a night. Charge needs about four nights of sleep to learn your baseline (you'll see \"Calibrating\" until then), and keeps sharpening over your first couple of weeks. On a WHOOP 5 or MG the strap banks little history, so the night count can climb slowly or sit at 0 of 4 until you have worn it across a few nights. That's its sync limit, not a fault. Import your WHOOP export to skip the wait.",
                    symbol: "brain.head.profile"
                )
            } else {
                // Header row: section label left, range control right. Narrows the per-day
                // list to a recent window (lexicographic yyyy-MM-dd compare == chronological).
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recent").strandOverline()
                        Text("By Day").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                    }
                    Spacer()
                    SegmentedPillControl(IntelRange.allCases, selection: $range) { $0.label }
                }
                // Whole-phrase variants per count so translators never see a stitched plural.
                Text(filtered.count == 1 ? "1 day" : "\(filtered.count) days")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if filtered.isEmpty {
                    NoopCard(padding: 18, tint: StrandPalette.chargeColor) {
                        Text("No scored days in this window. Widen the range or import more history.")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, day in
                        dayCard(day)
                            .staggeredAppear(index: index)
                    }
                }
            }
        }
        .task { if intelligence.results.isEmpty { await intelligence.analyzeRecent() } }
        .toolbar {
            ToolbarItem {
                Button { Task { await intelligence.analyzeRecent() } } label: {
                    Label("Recompute", systemImage: "arrow.clockwise")
                }
                .disabled(intelligence.computing)
            }
        }
    }

    /// The day list narrowed to the selected window. `nil` cutoff (ALL) shows everything.
    private var filtered: [IntelligenceEngine.Computed] {
        guard let n = range.days else { return intelligence.results }
        let date = Calendar.current.date(byAdding: .day, value: -(n - 1), to: Date()) ?? Date()
        let cutoff = Self.dayFmt.string(from: date)
        return intelligence.results.filter { $0.day >= cutoff }
    }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Evening forecast of tomorrow-morning Charge from tonight's known levers. Anchored to
    /// the recent Charge baseline, nudged by today's Effort vs your norm and how much sleep
    /// you typically bank, then mean-reverted. `results` is newest-first; the forecaster wants
    /// oldest→newest, so each series is reversed. `nil` (and the card hidden) until there are
    /// enough scored nights to anchor honestly — never a fabricated number.
    private var forecast: RecoveryForecast? {
        let charge = intelligence.results.compactMap { $0.recovery }.reversed()
        let effort = intelligence.results.compactMap { $0.strain }.reversed()
        // Planned sleep tonight = the recent typical night (the honest "if you sleep ~Xh"
        // assumption surfaced in the card), from the scored nights that have a sleep total.
        let sleeps = intelligence.results.compactMap { $0.sleepMin }
        let plannedHours = sleeps.isEmpty ? RecoveryForecaster.defaultNeedHours
            : (sleeps.reduce(0, +) / Double(sleeps.count)) / 60.0
        return RecoveryForecaster.forecast(recentCharge: Array(charge),
                                           recentEffort: Array(effort),
                                           todayEffort: intelligence.results.first?.strain,
                                           plannedSleepHours: plannedHours)
    }

    /// The forecast hero — tomorrow-morning Charge as the canonical liquid `LiquidVessel` gauge in the
    /// Charge tint, with the estimate counting up over it (the SAME hero language Sleep + Today use), on a
    /// frosted Charge-tinted card, with the plain-English estimate read-out beneath. A real forecast number,
    /// so it earns a liquid gauge. The number, ± band and copy are unchanged.
    private func forecastCard(_ f: RecoveryForecast) -> some View {
        let frac = min(max(f.charge / 100.0, 0), 1)
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Tomorrow's Charge", overline: "Evening forecast", trailing: String(localized: "Estimate"))
            NoopCard(padding: 20, tint: StrandPalette.chargeColor) {
                VStack(spacing: 14) {
                    // The signature liquid gauge: a filling vessel tinted to the forecast Charge, with the
                    // 0–100 estimate counting up over it and the ± band + state word beneath (Sleep's
                    // restHero idiom). Live so the fill actually flows on the hero surface.
                    ZStack {
                        LiquidVessel(value: frac, tint: StrandPalette.recoveryColor(f.charge), animated: true)
                            .frame(width: 184, height: 184)
                        VStack(spacing: 0) {
                            CountUpText(
                                value: f.charge,
                                format: { "\(Int($0.rounded()))" },
                                font: StrandFont.rounded(52),
                                color: StrandPalette.textPrimary
                            )
                            .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                            Text("± \(Int(f.band.rounded())) · \(StrandPalette.recoveryState(f.charge))")
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        .allowsHitTesting(false)   // taps fall through to the vessel → splash
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Tomorrow's Charge estimate \(Int(f.charge.rounded())) plus or minus \(Int(f.band.rounded()))")
                    VStack(alignment: .leading, spacing: 10) {
                        Text("You'll likely wake around \(Int(f.charge.rounded())) ± \(Int(f.band.rounded())) Charge if you sleep about \(sleepHoursLabel(f.plannedSleepHours)) tonight.")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Estimate from today's effort, your typical sleep and your \(f.nights)-night recovery baseline, not a measurement. Your real Charge is scored from tomorrow's HRV when you wake.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    /// "~7h" / "~7h 30m" for the planned-sleep assumption (hours rounded to the nearest 30 min).
    private func sleepHoursLabel(_ hours: Double) -> String {
        let half = (hours * 2).rounded() / 2
        let h = Int(half)
        let m = Int((half - Double(h)) * 60)
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    private var explainerCard: some View {
        NoopCard(padding: 20, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                HStack(spacing: NoopMetrics.rowSpacing) {
                    Image(systemName: "brain.head.profile").foregroundStyle(StrandPalette.chargeColor)
                        .accessibilityHidden(true)
                    Text("How this works").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                }
                Text("Charge weighs your HRV against your personal baseline (~55%), resting heart rate (~20%), rest quality (~15%), respiration (~5%) and skin-temperature deviation (~5%). Effort is a 0-\(UnitFormatter.effortScaleMax(effortScale)) cardiovascular load from time in heart-rate zones. Rest is staged from movement and heart rate. Everything is computed here from the strap's raw data. It works for any day NOOP collected raw streams.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                // The Charge model made concrete — the five weighted inputs, each its own metric accent.
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    Text("Charge model").strandOverline()
                    weightRow(String(localized: "Heart-rate variability"), "~55%", fraction: 0.55, color: StrandPalette.metricPurple)
                    weightRow(String(localized: "Resting heart rate"), "~20%", fraction: 0.20, color: StrandPalette.metricRose)
                    weightRow(String(localized: "Rest quality"), "~15%", fraction: 0.15, color: StrandPalette.metricCyan)
                    weightRow(String(localized: "Respiration"), "~5%", fraction: 0.05, color: StrandPalette.accent)
                    weightRow(String(localized: "Skin-temperature deviation"), "~5%", fraction: 0.05, color: StrandPalette.metricAmber)
                    HStack {
                        Text(String(localized: "Effort")).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        Spacer()
                        Text("0-\(UnitFormatter.effortScaleMax(effortScale)) scale")
                            .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.effortColor)
                    }
                    .padding(.top, 2)
                }
                .padding(.top, 2)
            }
        }
    }

    /// One weighted-input row: label + percent + a thin proportional meter on the inset well, tinted
    /// to the input's own metric accent. Presentation of the Charge model — no per-day data.
    private func weightRow(_ label: String, _ percent: String, fraction: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack {
                Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text(percent).font(StrandFont.captionNumber).foregroundStyle(color)
            }
            // The horizontal liquid tube — the same vessel Today's Key Metrics + Sleep's stage bars use —
            // tinted to the input's accent. The Charge weights span 0…0.55, so the tube reads each input's
            // share of the model. Static (posed): a still fill line, no live canvas per row.
            LiquidTube(frac: min(1, max(0, fraction / 0.55)), tint: color, height: 8, animated: false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(percent) of Charge")
    }

    private func dayCard(_ d: IntelligenceEngine.Computed) -> some View {
        NoopCard(padding: 18, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack {
                    // A small liquid vessel filled to the day's Charge (a real 0–100 metric, so it earns a
                    // gauge) leads the row — the same leading-gauge idiom Today + Insights use. Static
                    // (posed) so each day row costs a single cached frame, not a live canvas. Only shown
                    // once the night has a Charge to fill it; a calibrating night leads with the date alone.
                    if let r = d.recovery {
                        LiquidVessel(value: min(1, max(0, r / 100)), tint: StrandPalette.recoveryColor(r), animated: false)
                            .frame(width: 24, height: 24)
                            .accessibilityHidden(true)
                    }
                    Text(d.day).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    // A3: the existing per-day Charge confidence as a small dot + tier tag pill
                    // (CALIBRATING / EST. / REL.) next to the source badge. Pure presentation of
                    // `d.confidence` , only shown once there's a Charge to qualify.
                    if d.recovery != nil {
                        ConfidenceTierChip(confidence: d.confidence)
                    }
                    // The REAL source of the day's dashboard headline, not a hard-coded "NOOP-computed".
                    // The By-Day numbers are always NOOP's on-device scores, but when an import covers the
                    // day it WINS the dashboard merge, so the badge says so ("Whoop" / "Apple Health") and
                    // a strap-scored night reads "On-device". Dynamic String → wrap in "\()" so it's shown
                    // verbatim, not looked up as a LocalizedStringKey (the String≠LocalizedStringKey
                    // SwiftUI footgun). Imported rows use the accent tint to stand out from computed ones.
                    SourceBadge("\(d.source.badge)",
                                tint: d.source == .computed ? StrandPalette.chargeColor : StrandPalette.accent)
                }
                HStack(spacing: 0) {
                    stat(String(localized: "Charge"), d.recovery.map { "\(Int($0.rounded()))%" } ?? "—",
                         d.recovery.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textSecondary)
                    stat(String(localized: "Effort"), d.strain.map { UnitFormatter.effortDisplay($0, scale: effortScale) } ?? "—",
                         d.strain.map { StrandPalette.strainColor($0) } ?? StrandPalette.textSecondary)
                    stat(String(localized: "Rest"), d.sleepMin.map { "\(Int($0 / 60))h \(Int($0.truncatingRemainder(dividingBy: 60)))m" } ?? "—", StrandPalette.restColor)
                    stat(String(localized: "HRV"), d.hrv.map { "\(Int($0.rounded()))" } ?? "—", StrandPalette.metricPurple)
                    stat(String(localized: "RHR"), d.rhr.map { "\($0)" } ?? "—", StrandPalette.metricRose)
                }
                // Effort load meter (0–100) as a filling LiquidTube — the horizontal liquid vessel Today's
                // Key Metrics + Sleep's stage bars use — tinted along the strain ramp so it reads as
                // at-a-glance cardio load. Static (posed) so each day row costs a cached frame, not a live
                // canvas; a real metric, so it earns a liquid accent.
                if let s = d.strain {
                    LiquidTube(frac: min(1, max(0, s / 100)), tint: StrandPalette.strainColor(s),
                               height: 8, animated: false)
                        .accessibilityHidden(true)
                }
                // A1: "What shaped it" , one row per engine-supplied Charge driver. Gated on a non-empty
                // list so a cold-start / calibrating night (no real contributions to attribute) shows
                // nothing here rather than a fake breakdown. A5's relative skin-temp marker rides at the
                // foot when the night carries one.
                if !d.drivers.isEmpty {
                    ChargeBreakdownSection(drivers: d.drivers,
                                           confidence: d.confidence,
                                           skinTempRel: d.skinTempRel)
                        .padding(.top, NoopMetrics.space1)
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // `lineLimit` + `minimumScaleFactor` so a long label shrinks instead of running into its
            // neighbour. The five stats share the width as equal columns with NO gap between them
            // (`HStack(spacing: 0)` above), so a label wide enough to fill its column touches the next
            // one: "CHARGE" and "EFFORT" are the two longest and collide first, while REST / HRV / RHR
            // still look spaced. Reported from a device screenshot reading "CHARGEEFFORT".
            //
            // The VALUE below has carried this protection all along; only the label went without. The
            // Android twin's label already sets `maxLines = 1` with `TextOverflow.Ellipsis`, so this was
            // an iOS-only gap rather than a shared one.
            //
            // Scaled rather than truncated, matching how the value directly beneath is treated: "CHARG…"
            // reads worse than a slightly smaller "CHARGE". Larger Dynamic Type is where this bites, so
            // the floor has to leave room for the longest label at the widest text size.
            Text(label.uppercased())
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value).font(StrandFont.number(20)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

/// The "Syncing strap history…" note, shown only while a historical offload is running (#77). Owns the
/// `LiveState` observation in its own leaf (scroll-stutter isolation) so the chunk count ticks without
/// re-rendering IntelligenceView. Renders byte-for-byte what the prior inline `live.backfilling` check did.
private struct IntelSyncingNote: View {
    @EnvironmentObject private var live: LiveState
    var body: some View {
        if live.backfilling { SyncingHistoryNote(chunks: live.syncChunksThisSession) }
    }
}

/// Recent-window options for the By Day list. `days == nil` means show everything.
private enum IntelRange: Int, CaseIterable, Hashable {
    case week = 7, month = 30, quarter = 90, half = 180, year = 365, all = 0

    /// Trailing days the window spans; `nil` for ALL.
    var days: Int? { self == .all ? nil : rawValue }

    var label: String {
        switch self {
        case .week: return String(localized: "W")
        case .month: return String(localized: "M")
        case .quarter: return String(localized: "3M")
        case .half: return String(localized: "6M")
        case .year: return String(localized: "1Y")
        case .all: return String(localized: "ALL")
        }
    }
}
