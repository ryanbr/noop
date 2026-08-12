import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Stages (read-only Today host card) (#today-hosted-cards)
//
// The Sleep tab's "Stages" hero is deeply STATEFUL/INTERACTIVE (night ◀/▶ navigation, a wake-time edit
// button, and nap add/edit/delete), so it can NOT be mirrored onto the Today glance surface the way the
// other hosted cards are. Instead this file hosts a READ-ONLY latest-night Stages card: it renders the
// CURRENT `model.night` (the SAME night + intervals the Sleep tab shows) with none of the interactive
// chrome — a plain header (no chevrons), the sleep-window times (no wake-edit pencil), the shared stage
// chart + breakdown, and a read-only Main/Nap(s)/Total split (no Add/edit/delete).
//
// PARITY IS ON THE DATA: the stage chart is the SAME renderer the Sleep tab uses, lifted verbatim into
// the self-contained `StageDetailView` below (its own local `selectedStage` tap-highlight + `nightHR`
// state — transient per-instance UI, never SleepView's state). `SleepView` itself is UNCHANGED: it keeps
// its own fully-interactive `hero`/`stageCard`/`sleepWindowRow`/`napSection`. Only the Today host renders
// `StagesCard`.

/// The read-only "Stages" card hosted in Today: latest night's stage chart + breakdown, window times and
/// nap split, rendered from the shared [SleepModel] — no navigation, no edit, no nap mutation.
struct StagesCard: View {
    let model: SleepModel

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            // Read-only header: the night's relative label + span pill — NO ◀/▶ nav controls.
            SectionHeader("Stages", overline: "Last night", trailing: model.night.spanLabel)
            // The shared stage chart + breakdown (verbatim of the Sleep tab's stageCard display). This is
            // the WHOLE hosted card — the clock-window row + Main/Nap split are deliberately dropped for
            // cross-platform feature parity: the Kotlin `SleepModel` carries no session timestamps/nap
            // blocks, so the Android host card shows the same chart + breakdown and nothing more. The
            // shared/parity data (the stage split) is identical on both platforms.
            StageDetailView(night: model.night, intervals: model.intervals)
        }
    }
}

// MARK: - Shared stage chart (read-only display, lifted from SleepView.stageCard)
//
// The Sleep tab's stage-breakdown chart, window-independent and self-contained so BOTH the read-only
// Today `StagesCard` and (were it ever wired) any other surface render an IDENTICAL chart from the same
// `Night` + `intervals`. It owns its OWN transient UI state — `selectedStage` (tap-highlight) and
// `nightHR` (the sleeping-HR trace) — so tapping a stage in Today never reaches into SleepView. Every
// method below is a VERBATIM lift of the corresponding `SleepView` helper; the `SleepView` originals are
// left in place and unchanged (the Sleep tab keeps full interaction).
struct StageDetailView: View {
    let night: Night
    let intervals: [SleepInterval]
    @EnvironmentObject var repo: Repository
    /// Transient tap-highlight, LOCAL to this instance (never SleepView's `selectedStage`).
    @State private var selectedStage: SleepStage? = nil
    /// Per-night sleeping-HR buckets, loaded by `stageCard`'s `.task(id:)` below.
    @State private var nightHR: [HRBucket] = []

    var body: some View {
        // `stageCard` carries its own `.task(id: night.session.startTs)` HR load; clearing the
        // highlight when the night identity changes mirrors SleepView's nightOffset onChange.
        stageCard(night, intervals: intervals)
            .onChange(of: night.session.startTs) { _ in selectedStage = nil }
    }

    @ViewBuilder
    private func stageCard(_ night: Night, intervals: [SleepInterval]) -> some View {
        let s = night.stages
        let isPersisted = (night.realSegments?.count ?? 0) >= 2
        // An Oura night's stages are the ring's RAW on-device SleepNet classification (decoded off the 0x49
        // phase stream), NOT a NOOP approximation — so it gets its own honest caption instead of the
        // "stages approximate (on-device)" one that describes NOOP's own sparse-motion staging.
        let stageCaption = repo.activeDeviceIsOura
            ? String(localized: "raw on-device stages")
            : String(localized: "stages approximate (on-device)")
        let subtitle = isPersisted
            ? String(localized: "\(durationText(night.timeInBed)) in bed · \(efficiencyText(night)) efficiency · \(stageCaption)")
            : String(localized: "\(durationText(night.timeInBed)) in bed · \(efficiencyText(night)) efficiency")
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            if intervals.count >= 2 {
                // WHOOP sleep-details layout (ryanAtriumAi #988): one full-width timeline ROW per
                // stage — hatched track = the whole night, solid segments = when that stage occurred,
                // header carries the stage %, duration right-aligned. Tap a row to highlight that
                // stage; the others grey out. Replaces the 4-level hypnogram, whose staircase turned
                // fragmented on-device staging into an unreadable comb. No separate footer — the
                // rows ARE the legend.
                stageTimelineCard(s, subtitle: subtitle, intervals: intervals, night: night)
            } else {
                ChartCard(
                    title: "Stage breakdown",
                    subtitle: subtitle,
                    trailing: durationText(s.asleep),
                    height: NoopMetrics.chartHeight,
                    tint: StrandPalette.restColor,
                    chart: { stageBar(s) },
                    footer: { stageBreakdownRows(s) }
                )
            }
            // #407 — subordinate movement/restlessness trace UNDER the hypnogram, on the SAME timeline, for
            // the SAME main-night GROUP blocks the hero resolved (mergeDay's group). Shown only for a real
            // (≥2-segment) hypnogram so the strip aligns with a genuine timeline; the proportional stage-bar
            // fallback has no timeline to anchor to. Placed OUTSIDE the fixed-height ChartCard so it doesn't
            // clip the hypnogram. Honest empty state inside `motionStrip` when no group fragment has motion.
            if intervals.count >= 2 {
                motionStrip(night)
            }
            // H9 — when the engine's Rest confidence flags this night's staging as low-confidence (a
            // high-efficiency night whose deep+REM share is implausibly low → a likely staging miss, not
            // a real night with no restorative sleep), say so honestly under the breakdown rather than
            // presenting the suspect split as fact. Read straight from `ScoreConfidence.rest(...)` — the
            // SAME engine call the daily pass uses — so the badge can never disagree with the score.
            if stageStagingIsLowConfidence(night) {
                stageLowConfidenceNote
            }
            // #345 follow-up: when a night was staged on SPARSE motion coverage it can UNDER-detect — the
            // gravity-only spine fragments and the sub-60-min pieces are dropped, so a real ~8h night can
            // collapse to a fraction ("slept 8h, app shows 1h"). Say so honestly so the short total isn't
            // read as fact. Distinct from the H9 note above (a plausible-duration night with an off split).
            if stageStagingIsSparse(night) {
                stageIncompleteNote
            }
            // For an Oura-provided night, say plainly that this split is the ring's RAW on-device
            // classification — so the larger Awake / smaller Deep+REM here isn't misread as the polished
            // numbers the Oura app shows for the same night (the app post-processes the same stream).
            if repo.activeDeviceIsOura {
                ouraRawStagesNote
            }
        }
        // WHOOP top-chart data (ryanAtriumAi #988): 1-min sleeping-HR buckets for THIS night, reloaded
        // only when the displayed night changes (same `.task(id:)` pattern the other per-night loads use).
        .task(id: night.session.startTs) {
            nightHR = await repo.hrBuckets(from: night.session.startTs,
                                           to: night.session.endTs,
                                           bucketSeconds: 60)
        }
    }

    /// The detailed timeline has a variable-height insight footer, so forcing it into a fixed-height
    /// chart slot left a visibly empty shelf below the hint. This keeps the standard card header and
    /// surface while allowing the timeline to size to the content it actually has.
    private func stageTimelineCard(_ stages: Stages, subtitle: String,
                                   intervals: [SleepInterval], night: Night) -> some View {
        NoopCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                    Text("Stage breakdown").strandOverline()
                    Text(subtitle)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                stageTimeline(stages, intervals: intervals, night: night)
            }
        }
    }

    /// #407 — the per-epoch movement/restlessness strip drawn UNDER the hypnogram, on the SAME timeline.
    /// Reads the already-resolved main-night GROUP's persisted motion off `night.motionEpochs` (laid
    /// fragment-by-fragment in `mergeDay`, NO re-resolution of the night). The left inset (44pt axis + 12pt
    /// spacing) matches the Hypnogram's `HStack` so the strip's plot lines up under the stage bands above.
    /// When the night has no persisted motion (older rows whose `motionJSON` is NULL) it shows an HONEST
    /// empty note rather than a fabricated flat zero trace.
    @ViewBuilder
    private func motionStrip(_ night: Night) -> some View {
        // Label above the trace, plot inset 10pt to line up with the stage-timeline rows' strips
        // (the old 44+12 gutter matched the removed Hypnogram's y-axis column). (ryanAtriumAi #988)
        VStack(alignment: .leading, spacing: 2) {
            Text("Move")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            if night.motionEpochs.count >= 2 {
                MotionTrace(epochs: night.motionEpochs, height: 40, tint: StrandPalette.restColor)
                    .padding(.horizontal, 10)
            } else {
                Text("No movement detail for this night")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .accessibilityLabel(Text("No movement detail recorded for this night"))
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// H9 — true when this night's staging is LOW-CONFIDENCE: a high-efficiency night (lots of measured
    /// sleep) whose restorative (deep+REM) share is implausibly low, which the EEG-free classifier is far
    /// more likely to have mis-staged than a genuine night with no deep or REM. Delegates to the engine's
    /// pure `ScoreConfidence.rest(...)` H9 overload (efficiency in [0,1], seconds for the totals) so the UI
    /// and the persisted Rest confidence agree by construction. Needs staged sleep + a real efficiency
    /// reading; a pooled/no-stage or unknown-efficiency night is never flagged (its base tier already
    /// reads honestly). (#H9)
    private func stageStagingIsLowConfidence(_ night: Night) -> Bool {
        let s = night.stages
        guard let effPct = efficiencyPct(night) else { return false }
        return SleepView.isStagingLowConfidence(
            asleepMin: s.asleep, deepMin: s.deep, remMin: s.rem, efficiency: effPct / 100.0)
    }

    /// True when this night was staged on SPARSE motion coverage — the persisted `stagingSparse` flag the
    /// engine sets from `SleepStager.isGravitySparse` (#345). Such a night can UNDER-detect: the gravity-only
    /// spine fragments and sub-60-min pieces are dropped, so a real night collapses to a fraction. Reads the
    /// day's REAL stored blocks (each carries the day's value), never the synthetic merged `session`; a nil
    /// flag (imported / pre-migration night) is never flagged. Mirror in Kotlin.
    private func stageStagingIsSparse(_ night: Night) -> Bool {
        night.sourceBlocks.contains { $0.stagingSparse == true }
    }

    /// The H9 low-confidence note shown beneath the stage breakdown — a warning-tinted badge plus a
    /// one-line honest explanation. No faked stages, no tanked score; just a clear "treat this split with
    /// care" so a user doesn't read a likely staging miss as a real deep/REM drought. (#H9)
    private var stageLowConfidenceNote: some View {
        HStack(alignment: .top, spacing: 8) {
            SourceBadge("Low confidence", tint: StrandPalette.statusWarning)
            Text("This night scored high efficiency but very little deep or REM, more likely a staging estimate miss than a real restorative shortfall. The totals are kept as-is; read the split with care.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Low confidence staging. This night scored high efficiency but very little deep or REM, more likely an estimate miss than a real restorative shortfall.")
    }

    /// The sparse-coverage caveat: a night staged on thin motion data can under-detect and collapse a real
    /// night to a fraction ("slept 8h, shows 1h"). Honest + actionable — tells the user to make sure the
    /// strap fully synced. Distinct from the H9 note (an off deep/REM split, not a short total). (#345)
    private var stageIncompleteNote: some View {
        HStack(alignment: .top, spacing: 8) {
            SourceBadge("May be incomplete", tint: StrandPalette.statusWarning)
            Text("Your strap recorded little movement overnight (common on WHOOP 4.0), so this night may be under-detected and the sleep total can read short. Make sure the strap fully synced; the numbers are kept as-is.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
        // `.combine` builds the a11y label from the badge + body Text (no separate localized string).
        .accessibilityElement(children: .combine)
    }

    /// Honest caveat for an Oura-provided night: the stage split shown here is the ring's RAW on-device
    /// SleepNet classification, read straight off the BLE phase stream — NOT the adjusted stages the Oura
    /// app displays. The app post-processes the same night, so its Deep/REM run higher and its Awake lower;
    /// cross-checks put our Awake well above the app's. Surfaced so the breakdown isn't taken for the app's.
    private var ouraRawStagesNote: some View {
        HStack(alignment: .top, spacing: 8) {
            SourceBadge("Raw on-device stages", tint: StrandPalette.restColor)
            Text("This split is the ring's raw on-device classification read over Bluetooth, not the adjusted stages the Oura app shows. Expect more Awake and less Deep/REM here than in the Oura app for the same night.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Raw on-device stages. This split is the ring's raw on-device classification read over Bluetooth, not the adjusted stages the Oura app shows. Expect more awake and less deep or REM here than in the Oura app for the same night.")
    }

    /// Full-width proportional stacked stage bar (fallback when no intervals).
    @ViewBuilder
    private func stageBar(_ s: Stages) -> some View {
        let total = max(1, s.total)
        VStack(alignment: .leading, spacing: 10) {
            Spacer(minLength: 0)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    segment(.deep, s.deep, total, geo.size.width)
                    segment(.light, s.light, total, geo.size.width)
                    segment(.rem, s.rem, total, geo.size.width)
                    segment(.awake, s.awake, total, geo.size.width)
                }
            }
            .frame(height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sleep stage breakdown: deep \(stageSharePercent(.deep, s)) percent, light \(stageSharePercent(.light, s)) percent, REM \(stageSharePercent(.rem, s)) percent, awake \(stageSharePercent(.awake, s)) percent")
            HStack(spacing: 16) {
                legend(.deep, String(localized: "Deep"))
                legend(.light, String(localized: "Light"))
                legend(.rem, String(localized: "REM"))
                legend(.awake, String(localized: "Awake"))
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func segment(_ stage: SleepStage, _ minutes: Double, _ total: Double, _ width: CGFloat) -> some View {
        let w = CGFloat(minutes / total) * width
        Rectangle()
            .fill(StrandPalette.sleepStageColor(stage))
            .frame(width: max(0, w))
    }

    @ViewBuilder
    private func legend(_ stage: SleepStage, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(StrandPalette.sleepStageColor(stage))
                .frame(width: 9, height: 9)
            Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    /// The four stage rows that replace the old footer "label · value" grid, read like WHOOP's sleep
    /// detail: a colour swatch, the UPPERCASE stage name, the share-of-night % in the stage colour, a
    /// proportional bar in the stage colour over a faint track, and the right-aligned duration. Same data
    /// as the prior footer (`s.rem` / `s.deep` / `s.light` / `s.awake` over `s.total`) — no new numbers.
    @ViewBuilder
    private func stageBreakdownRows(_ s: Stages) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
            stageBreakdownRow(.rem,   minutes: s.rem,   total: s.total, percent: stageSharePercent(.rem, s))
            stageBreakdownRow(.deep,  minutes: s.deep,  total: s.total, percent: stageSharePercent(.deep, s))
            stageBreakdownRow(.light, minutes: s.light, total: s.total, percent: stageSharePercent(.light, s))
            stageBreakdownRow(.awake, minutes: s.awake, total: s.total, percent: stageSharePercent(.awake, s))
        }
    }

    /// The night's four stages as whole percentages that sum to exactly 100 (largest-remainder), so this
    /// card's breakdown rows, timeline rows and stage-bar read-out print ONE apportionment — and it matches
    /// the SleepView detail for the same night. Bar fills still track the raw `minutes / total` fraction.
    /// Falls back to 0 for a night with no minutes. Same helper as SleepView.stageSharePercent. (tanarchytan)
    private func stageSharePercent(_ stage: SleepStage, _ s: Stages) -> Int {
        guard let p = StagePercentages.wholePercentages([s.awake, s.light, s.deep, s.rem]) else { return 0 }
        switch stage {
        case .awake: return p[0]
        case .light: return p[1]
        case .deep:  return p[2]
        case .rem:   return p[3]
        }
    }

    /// One WHOOP-style stage row. `fraction = minutes / total` sets the bar fill; `percent` is the night's
    /// apportioned share (so the four rows sum to 100). Tappable (WHOOP, ryanAtriumAi #988): selecting a
    /// row highlights that stage and recedes the rest; tapping the selected row again clears the highlight.
    @ViewBuilder
    private func stageBreakdownRow(_ stage: SleepStage, minutes: Double, total: Double, percent: Int) -> some View {
        let color = StrandPalette.sleepStageColor(stage)
        let fraction = total > 0 ? min(1, max(0, minutes / total)) : 0
        let isSelected = selectedStage == stage
        let othersSelected = selectedStage != nil && !isSelected
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            Text(stage.label.uppercased())
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 56, alignment: .leading)
            Text("\(percent)%")
                .font(StrandFont.captionNumber)
                .foregroundStyle(color)
                .frame(width: 38, alignment: .leading)
            // The NOOP signature: a segmented PipBar that counts up to the share-of-night fraction,
            // tinted in the stage colour over the canonical inset track. Flat, crisp, no glow.
            PipBar(value: fraction * 100, segments: 20, tint: color, height: 8)
            Text(durationText(minutes))
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(isSelected ? 0.14 : 0))
        )
        .opacity(othersSelected ? 0.55 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(StrandMotion.fade) {
                selectedStage = isSelected ? nil : stage
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stage.label): \(durationText(minutes)), \(percent) percent of the night")
        .accessibilityHint("Highlights this stage on the sleep chart")
        .accessibilityAddTraits(.isButton)
    }

    /// Clock labels for the timeline axis; "jmm" respects the device 12/24-hour setting.
    private static let stageAxisFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = AppLanguage.activeLocale; f.setLocalizedDateFormatFromTemplate("jmm"); return f
    }()

    /// The WHOOP sleep-stages chart: a stack of four per-stage timeline rows (AWAKE · LIGHT ·
    /// DEEP · REM, WHOOP's order) over a shared onset→wake time axis. Each row is independently
    /// legible no matter how fragmented the on-device staging is — segments in one row can never
    /// tangle with another stage's, which is exactly why WHOOP renders sleep this way.
    @ViewBuilder
    private func stageTimeline(_ s: Stages, intervals: [SleepInterval], night: Night) -> some View {
        // Light display smoothing (90s) keeps WHOOP's fine tick texture while dropping epoch noise;
        // the hypnogram needed 300s because stages shared one staircase — rows tolerate detail.
        let smoothed = Hypnogram.displaySmoothed(intervals.sorted { $0.start < $1.start }, minDuration: 90)
        let origin = smoothed.first?.start ?? 0
        let span = max(1, (smoothed.map(\.end).max() ?? 1) - origin)
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            // WHOOP's hero pair: HOURS OF SLEEP + RESTORATIVE SLEEP (deep + REM), each against
            // its 30-day typical.
            sleepHeadline(s)
            // WHOOP's sleeping heart-rate chart above the rows: thin HR trace across the night.
            // Selecting a stage tints the trace + washes the chart columns during that stage.
            sleepHRChart(intervals: smoothed, origin: origin, span: span, night: night)
                .frame(height: 124)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
            stageTimelineRow(.awake, minutes: s.awake, percent: stageSharePercent(.awake, s), intervals: smoothed, origin: origin, span: span)
            stageTimelineRow(.light, minutes: s.light, percent: stageSharePercent(.light, s), intervals: smoothed, origin: origin, span: span)
            stageTimelineRow(.deep,  minutes: s.deep,  percent: stageSharePercent(.deep, s), intervals: smoothed, origin: origin, span: span)
            stageTimelineRow(.rem,   minutes: s.rem,   percent: stageSharePercent(.rem, s), intervals: smoothed, origin: origin, span: span)
            // onset · midpoint · wake clock labels, aligned with the rows' inner strips.
            HStack {
                Text(Self.stageAxisFormatter.string(from: night.onsetDate))
                Spacer()
                Text(Self.stageAxisFormatter.string(from: night.onsetDate.addingTimeInterval(span / 2)))
                Spacer()
                Text(Self.stageAxisFormatter.string(from: night.onsetDate.addingTimeInterval(span)))
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .padding(.horizontal, 10)
            .accessibilityHidden(true)
            // WHOOP's per-stage insight: with a stage selected, tonight vs the 30-day typical
            // range; otherwise a quiet hint that the rows are tappable. It grows only when a
            // selected-stage comparison needs a second line, avoiding a permanent empty footer.
            stageInsight(s)
                .frame(minHeight: NoopMetrics.compactHintMinHeight, alignment: .topLeading)
                .padding(.horizontal, 2)
        }
    }

    /// WHOOP's hero pair for the night: HOURS OF SLEEP and RESTORATIVE SLEEP (deep + REM), each
    /// with its trailing-30-day typical underneath — the "how does tonight compare" read without
    /// leaving the card.
    @ViewBuilder
    private func sleepHeadline(_ s: Stages) -> some View {
        let restorative = s.deep + s.rem
        HStack(alignment: .top, spacing: NoopMetrics.space6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(durationText(s.asleep))
                    .font(StrandFont.number(26))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("HOURS OF SLEEP")
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
                if let t = stageTypical(nil) {
                    Text("typically \(durationText(t.mean))")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(durationText(restorative))
                    .font(StrandFont.number(26))
                    .foregroundStyle(StrandPalette.sleepREM)
                Text("RESTORATIVE SLEEP")
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
                if let t = restorativeTypical() {
                    Text("typically \(durationText(t))")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    /// The tonight-vs-typical line under the stage rows. Selected: "REM 2h 45m · typically
    /// 1h 50m to 2h 20m, above your usual." Unselected: the tap affordance hint.
    @ViewBuilder
    private func stageInsight(_ s: Stages) -> some View {
        if let sel = selectedStage {
            let minutes = stageMinutes(sel, in: s)
            if let t = stageTypical(sel) {
                let phrase = minutes > t.hi ? String(localized: "above your usual")
                    : (minutes < t.lo ? String(localized: "below your usual")
                                      : String(localized: "about your usual"))
                (Text(sel.label).fontWeight(.semibold).foregroundColor(StrandPalette.sleepStageColor(sel))
                    + Text(" \(durationText(minutes)) · typically \(durationText(t.lo)) to \(durationText(t.hi)), \(phrase)."))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(2)
            } else {
                Text("\(sel.label): \(durationText(minutes)). Not enough history yet for a typical range.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(2)
            }
        } else {
            Text("Tap a stage to compare with your 30-day typical.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    /// Tonight's minutes for one stage out of the decoded totals.
    private func stageMinutes(_ stage: SleepStage, in s: Stages) -> Double {
        switch stage {
        case .awake: return s.awake
        case .light: return s.light
        case .deep:  return s.deep
        case .rem:   return s.rem
        }
    }

    /// Per-stage typical minutes over the trailing 30 scored days: the 25th–75th percentile band
    /// plus the mean — WHOOP's "typical range". Pass nil for total asleep. Returns nil below 5
    /// scored nights (honest cold-start: no fabricated range from a few days).
    private func stageTypical(_ stage: SleepStage?) -> (lo: Double, hi: Double, mean: Double)? {
        let values: [Double] = repo.days.suffix(30).compactMap { d in
            switch stage {
            case nil:     return d.totalSleepMin
            case .light?: return d.lightMin
            case .deep?:  return d.deepMin
            case .rem?:   return d.remMin
            case .awake?:
                // Awake isn't a stored daily column; derive from in-bed minus asleep via efficiency.
                guard let asleep = d.totalSleepMin, asleep > 0, var e = d.efficiency, e > 0 else { return nil }
                if e > 1.5 { e /= 100 }   // efficiency arrives as % on some import paths
                guard e > 0.3, e <= 1 else { return nil }
                return asleep * (1 - e) / e
            }
        }.filter { $0 > 0 }.sorted()
        guard values.count >= 5 else { return nil }
        func pct(_ p: Double) -> Double {
            let idx = p * Double(values.count - 1)
            let l = Int(idx.rounded(.down)), u = Int(idx.rounded(.up))
            let frac = idx - Double(l)
            return values[l] * (1 - frac) + values[u] * frac
        }
        let mean = values.reduce(0, +) / Double(values.count)
        return (pct(0.25), pct(0.75), mean)
    }

    /// 30-day mean restorative minutes (deep + REM per scored night).
    private func restorativeTypical() -> Double? {
        let values: [Double] = repo.days.suffix(30).compactMap { d in
            guard let deep = d.deepMin, let rem = d.remMin else { return nil }
            let v = deep + rem
            return v > 0 ? v : nil
        }
        guard values.count >= 5 else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// One WHOOP stage row: header (STAGE · coloured % · right-aligned duration) above a hatched
    /// night-long track with solid segments where the stage occurred. Tap toggles the highlight:
    /// the selected row keeps its colour + gains a border while every other row's segments grey out.
    @ViewBuilder
    private func stageTimelineRow(_ stage: SleepStage, minutes: Double, percent: Int,
                                  intervals: [SleepInterval], origin: TimeInterval, span: TimeInterval) -> some View {
        let color = StrandPalette.sleepStageColor(stage)
        let isSelected = selectedStage == stage
        let dimmed = selectedStage != nil && !isSelected
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(stage.label.uppercased())
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("\(percent)%")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(dimmed ? StrandPalette.textTertiary : color)
                Spacer()
                Text(durationText(minutes))
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    StageHatchedTrack()
                    ForEach(intervals.filter { $0.stage == stage }) { iv in
                        let x0 = CGFloat((iv.start - origin) / span) * geo.size.width
                        let w = max(2, CGFloat((iv.end - iv.start) / span) * geo.size.width)
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(dimmed ? StrandPalette.textTertiary.opacity(0.55) : color)
                            .frame(width: w, height: geo.size.height)
                            .offset(x: x0)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(height: 20)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(StrandPalette.textPrimary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? StrandPalette.hairlineStrong : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(StrandMotion.fade) { selectedStage = isSelected ? nil : stage }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stage.label): \(durationText(minutes)), \(percent) percent of the night")
        .accessibilityHint("Highlights this stage on the sleep chart")
        .accessibilityAddTraits(.isButton)
    }

    /// WHOOP's sleeping heart-rate chart: a thin HR trace across the night with dashed onset/wake
    /// rules and quiet bpm gridlines. With a stage selected, the trace re-colours inside that
    /// stage's intervals and those time columns get a faint stage-tinted wash — WHOOP's "what did
    /// my heart do during REM" read. Canvas-drawn (~550 one-minute buckets), gaps in the data
    /// break the line honestly rather than interpolating across them.
    @ViewBuilder
    private func sleepHRChart(intervals: [SleepInterval], origin: TimeInterval, span: TimeInterval, night: Night) -> some View {
        let nightStartTs = night.onsetDate.timeIntervalSince1970
        let buckets = nightHR.filter {
            let rel = TimeInterval($0.ts) - nightStartTs
            return rel >= origin - 60 && rel <= origin + span + 60
        }
        if buckets.count >= 2 {
            Canvas { ctx, size in
                let bpms = buckets.map(\.bpm)
                let lo = (bpms.min() ?? 40) - 5
                let hi = (bpms.max() ?? 90) + 5
                func point(_ b: HRBucket) -> CGPoint {
                    let rel = TimeInterval(b.ts) - nightStartTs
                    let x = CGFloat((rel - origin) / span) * size.width
                    let y = size.height * (1 - CGFloat((b.bpm - lo) / max(1, hi - lo)))
                    return CGPoint(x: x, y: y)
                }
                // Selected-stage column washes UNDER everything else.
                if let sel = selectedStage {
                    let wash = StrandPalette.sleepStageColor(sel).opacity(0.13)
                    for iv in intervals where iv.stage == sel {
                        let x0 = CGFloat((iv.start - origin) / span) * size.width
                        let w = max(1, CGFloat((iv.end - iv.start) / span) * size.width)
                        ctx.fill(Path(CGRect(x: x0, y: 0, width: w, height: size.height)), with: .color(wash))
                    }
                }
                // Quiet bpm gridlines + labels at ~3 nice values.
                let step = max(10.0, (((hi - lo) / 3) / 10).rounded() * 10)
                var grid = (lo / step).rounded(.up) * step
                while grid < hi {
                    let y = size.height * (1 - CGFloat((grid - lo) / max(1, hi - lo)))
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(line, with: .color(StrandPalette.hairline.opacity(0.5)), lineWidth: 1)
                    ctx.draw(Text(verbatim: "\(Int(grid))").font(.system(size: 9)).foregroundColor(StrandPalette.textTertiary),
                             at: CGPoint(x: 10, y: y - 7))
                    grid += step
                }
                // Base trace across the whole night; the line BREAKS across >5-min data gaps.
                // Split by signal confidence: clean/measured HR draws solid, weak-optical stretches
                // (PPG conf < 0.3) draw lighter + dashed, so a weak estimate is never presented as a
                // clean measured beat. NOTE: with the default acceptance floor (0.3) no stored PPG
                // sample carries conf < 0.3, so this weak branch is inert unless a future opt-in
                // weak-signal mode (which needs a faithfulness eval first) lowers the floor.
                let baseColor = selectedStage == nil
                    ? StrandPalette.restColor.opacity(0.9)
                    : StrandPalette.textTertiary.opacity(0.45)
                var strong = Path()
                var weakPath = Path()
                var prev: (ts: Int, pt: CGPoint, strong: Bool)? = nil
                for b in buckets {
                    let p = point(b)
                    let isStrong = b.conf >= 0.3
                    if let pr = prev, b.ts - pr.ts <= 300 {
                        // Bridge class transitions from the previous point so the trace stays
                        // continuous — the weak segment owns the bridging stroke.
                        if isStrong {
                            if pr.strong { strong.addLine(to: p) }
                            else { strong.move(to: pr.pt); strong.addLine(to: p) }
                        } else {
                            if !pr.strong { weakPath.addLine(to: p) }
                            else { weakPath.move(to: pr.pt); weakPath.addLine(to: p) }
                        }
                    } else {
                        if isStrong { strong.move(to: p) } else { weakPath.move(to: p) }
                    }
                    prev = (b.ts, p, isStrong)
                }
                ctx.stroke(strong, with: .color(baseColor), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                ctx.stroke(weakPath, with: .color(baseColor.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1, lineJoin: .round, dash: [2, 3]))
                // Selected-stage trace overlay: the HR line re-drawn in the stage colour, only
                // inside that stage's intervals.
                if let sel = selectedStage {
                    let ranges = intervals.filter { $0.stage == sel }.map { ($0.start, $0.end) }
                    var overlay = Path()
                    var lastIn: Int? = nil
                    for b in buckets {
                        let rel = TimeInterval(b.ts) - nightStartTs
                        let inside = ranges.contains { rel >= $0.0 && rel <= $0.1 }
                        if inside {
                            let p = point(b)
                            if let last = lastIn, b.ts - last <= 300 { overlay.addLine(to: p) } else { overlay.move(to: p) }
                            lastIn = b.ts
                        } else {
                            lastIn = nil
                        }
                    }
                    ctx.stroke(overlay, with: .color(StrandPalette.sleepStageColor(sel)),
                               style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                }
                // Dashed onset/wake rules (WHOOP's sleep-window markers).
                for x in [CGFloat(0.75), size.width - 0.75] {
                    var rule = Path()
                    rule.move(to: CGPoint(x: x, y: 0)); rule.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(rule, with: .color(StrandPalette.textTertiary.opacity(0.5)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityLabel(Text("Sleeping heart rate through the night"))
        } else {
            Text("No heart-rate detail for this night")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    /// WHOOP's diagonal-hatched timeline track: subtle 45° stripes over a dark inset well — reads
    /// as "the whole night" behind the solid stage segments, and makes gaps (other stages) obvious
    /// without drawing anything for them.
    private struct StageHatchedTrack: View {
        var body: some View {
            ZStack {
                Rectangle().fill(StrandPalette.surfaceInset.opacity(0.9))
                Canvas { context, size in
                    var path = Path()
                    let step: CGFloat = 5
                    var x: CGFloat = -size.height
                    while x < size.width {
                        path.move(to: CGPoint(x: x, y: size.height))
                        path.addLine(to: CGPoint(x: x + size.height, y: 0))
                        x += step
                    }
                    context.stroke(path, with: .color(StrandPalette.textTertiary.opacity(0.16)), lineWidth: 1)
                }
            }
        }
    }

    private func efficiencyText(_ night: Night) -> String {
        let e = efficiencyPct(night)
        return e.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    /// Efficiency in percent. Prefer the stored session value, else asleep / time-in-bed.
    private func efficiencyPct(_ night: Night) -> Double? {
        if let stored = night.session.efficiency ?? repo.today?.efficiency {
            return stored <= 1.0 ? stored * 100 : stored
        }
        let bed = night.timeInBed
        guard bed > 0 else { return nil }
        return Swift.min(100, night.stages.asleep / bed * 100)
    }

    private func durationText(_ minutes: Double) -> String {
        let m = Swift.max(0, Int(minutes.rounded()))
        if m < 60 { return String(localized: "\(m)m") }
        return String(localized: "\(m / 60)h \(m % 60)m")
    }

}
