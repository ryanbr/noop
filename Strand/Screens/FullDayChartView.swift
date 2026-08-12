import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Deep Timeline (full-day, full-resolution metric viewer) — #575
//
// The headline tap-through from Explore: a whole-day line for one metric that the user can ZOOM and PAN
// down to the raw per-second signal. The hard problem — never drawing ~86k points for a worn 24h — is
// solved in the read layer (`Repository.timelineSeries` picks coarse SQL buckets at day scale and raw
// seconds when zoomed in), so this screen only ever receives ~targetPoints points regardless of zoom.
//
// Reuses the existing `OverviewHRChart` (its `.chartXScale(domain:)` already pins the axis); the chart's
// zoom binding drives the visible window, and re-reads at the new resolution as the window changes. macOS
// adds scroll-to-zoom (no pinch); both platforms drag-to-pan. Serves #574 (owned-source filter / honest
// "Other sources" disclosure) and is the detail surface behind #582.
//
// #979 spin-offs: (1) annotation parity with the classic Today whole-day chart — the main night's sleep
// band + a sport glyph at each workout, fed through the SAME OverviewHRChart layers Today uses (this
// screen previously drew a bare line, despite being sold as "the whole-day trend with bands"); (2) an
// iPhone touch-and-hold scrub (`touchScrub: true`) so the crosshair readout the Mac pointer hover gets
// is reachable on touch too.

struct FullDayChartView: View {
    @EnvironmentObject var repo: Repository

    /// The day this timeline is showing (its real calendar midnight). Defaults to the logical day so an
    /// after-midnight open still lands on the night the user is living, not an empty new calendar day (#144).
    /// Mutable so the user can step back through previous days (#597 — was today-only with no way back).
    @State private var dayStart: Date
    /// True once we've done the one-shot "open on the most recent day with data" jump (or the caller pinned
    /// an explicit day, in which case we never override it). Stops the jump from fighting manual navigation.
    @State private var didLandOnLatest: Bool

    init(dayStart: Date? = nil) {
        _dayStart = State(initialValue: dayStart ?? Repository.logicalDayStart(Date()))
        _didLandOnLatest = State(initialValue: dayStart != nil)
    }

    @State private var metric: Repository.TimelineMetric = .hr
    // Imperial/Metric temperature preference (#101) — mirrors MetricExplorerView so skin temp here
    // respects the same °C/°F override instead of always showing Celsius.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    private var temperatureUnit: TemperatureUnit {
        let system = UnitSystem(rawValue: unitSystemRaw) ?? .metric
        return UnitPrefs.resolveTemperature(system: system, override: temperatureRaw)
    }
    /// "Owned only" hides empty non-strap rows; "All sources" surfaces the disclosure (#574). The strap is
    /// always the owned source, so this currently scopes the empty-state copy rather than swapping reads.
    @State private var ownedOnly = true
    /// #623: true when the current SpO2/respiration metric is genuinely unsupported on the active strap —
    /// a 5.0-family strap that has NEVER produced it (4.0-only wire signals) — vs merely an empty window.
    @State private var metricUnsupported = false

    @State private var series: Repository.TimelineSeries = .empty
    // #979 spin-off — day annotations, mirroring the classic Today's Overview HR markers: the main
    // night's band (labelled with its duration) and each workout's sport glyph. Day-scoped facts, so
    // they're loaded per shown day (NOT per zoom window — the chart clamps them into the visible
    // window itself), keeping the zoom/pan re-read path untouched.
    @State private var sleepSpan: OverviewHRChart.SleepSpan? = nil
    @State private var workoutSpans: [OverviewHRChart.WorkoutSpan] = []
    /// The visible window the chart's gestures mutate. nil → full day (the chart falls back to `dayBounds`).
    @State private var zoomDomain: ClosedRange<Date>? = nil
    @State private var loading = true
    /// Bumped on every settled zoom/metric change so the re-read task re-runs at the new resolution.
    @State private var reloadTick = 0

    /// The full clamp the zoom window can never escape — the selected calendar day.
    private var dayBounds: ClosedRange<Date> {
        dayStart...dayStart.addingTimeInterval(86_400)
    }

    /// #986: a continuous left-drag can scroll back to the shown day plus the two before it (a rolling
    /// 3-day window), so older HR is reachable by dragging, not only the day-stepper. Deliberately bounded
    /// so one drag can't fling through weeks. The default view is still exactly one day (xRange: dayBounds);
    /// this only widens the pan clamp, and the data reload keys on the visible window so panned-to days load.
    private var panBounds: ClosedRange<Date> {
        dayStart.addingTimeInterval(-2 * 86_400)...dayBounds.upperBound
    }

    /// The currently-visible window (zoomed or the whole day).
    private var visibleWindow: ClosedRange<Date> { zoomDomain ?? dayBounds }

    var body: some View {
        ScreenScaffold(title: "Deep Timeline", subtitle: "Every second of your day, zoomable.") {
            metricPills
            dayNav
            sourcePill
            chartCard
            zoomHint
        }
        .task(id: taskKey) { await reload() }
        .task(id: annotationKey) { await reloadAnnotations() }
        .task { await landOnLatestDayIfNeeded() }
        .task(id: metric) { await resolveMetricUnsupported() }   // #623
    }

    /// #623: a SpO2/respiration track is "unsupported on this strap" only when it's a 5.0-family strap that
    /// has never produced the metric — not merely an empty window (a 4.0-v24 banks SpO2, and the legacy
    /// bare-"WHOOP" model resolves to the 5.0 family). Re-resolves when the metric changes.
    ///
    /// The family test must be a positive "is it a 5/MG" (#1086), never a coalesced one: the respiration
    /// copy tells the reader their estimate is on the Health screen, which is true for a WHOOP 5 (the R-R
    /// RSA estimate runs) and false for a non-WHOOP device whose banked stream that estimate refuses.
    private func resolveMetricUnsupported() async {
        guard repo.activeStrapIsWhoop5(), metric == .spo2 || metric == .respiration else {
            metricUnsupported = false
            return
        }
        metricUnsupported = !(await repo.strapHasEverProduced(metric))
    }

    /// Annotations re-read only when the shown day changes or fresh strap data lands — deliberately NOT
    /// on zoom (see `sleepSpan` above), so scrubbing/pinching never re-queries sleeps/workouts.
    private var annotationKey: String {
        "\(Int(dayStart.timeIntervalSince1970))|\(repo.refreshSeq)"
    }

    /// Re-read whenever the metric, the day, the source scope, the settled zoom window, or fresh strap
    /// data changes. The window is bucketed to whole seconds so micro-jitter during a drag doesn't thrash
    /// the DB — the chart redraws smoothly from the in-hand domain while the data settles.
    private var taskKey: String {
        let lo = Int(visibleWindow.lowerBound.timeIntervalSince1970)
        let hi = Int(visibleWindow.upperBound.timeIntervalSince1970)
        return "\(metric.rawValue)|\(Int(dayStart.timeIntervalSince1970))|\(ownedOnly)|\(lo)|\(hi)|\(repo.refreshSeq)"
    }

    // MARK: Controls

    private var metricPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            SegmentedPillControl(Repository.TimelineMetric.allCases, selection: $metric) { $0.title }
                .padding(.vertical, NoopMetrics.space1 / 2)
        }
    }

    @ViewBuilder private var sourcePill: some View {
        HStack(spacing: NoopMetrics.rowSpacing) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(StrandFont.footnote.weight(.medium))
                .foregroundStyle(StrandPalette.textTertiary)
            Text("My WHOOP")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            // #574 — owned-source scope. The strap is the owned source; "All sources" reveals the honest
            // disclosure that other sources' raw per-second streams aren't offloaded on-device.
            SegmentedPillControl([true, false], selection: $ownedOnly) { $0 ? String(localized: "Owned") : String(localized: "All") }
                .fixedSize()
        }
        .padding(.horizontal, NoopMetrics.space1)
    }

    /// Day stepper — move the whole timeline back/forward a day so a user can reach the days that actually
    /// hold their data, not just today (#597). Forward is clamped at today (no future days).
    private var dayNav: some View {
        HStack(spacing: NoopMetrics.cardInnerSpacing) {
            Button { stepDay(-1) } label: {
                Image(systemName: "chevron.left").font(StrandFont.headline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(StrandPalette.accent)
            .accessibilityLabel("Previous day")

            Spacer()
            Text(dayLabel)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
            Spacer()

            Button { stepDay(1) } label: {
                Image(systemName: "chevron.right").font(StrandFont.headline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(isOnLatestDay ? StrandPalette.textTertiary : StrandPalette.accent)
            .disabled(isOnLatestDay)
            .accessibilityLabel("Next day")
        }
        .padding(.horizontal, NoopMetrics.space1)
    }

    private var isOnLatestDay: Bool { dayStart >= Repository.logicalDayStart(Date()) }

    /// Step the shown day by `delta` days, clamped so you can never go past today, and drop any zoom so the
    /// new day opens at full-day scale.
    private func stepDay(_ delta: Int) {
        let next = dayStart.addingTimeInterval(Double(delta) * 86_400)
        if delta > 0 && next > Repository.logicalDayStart(Date()) { return }
        withAnimation(StrandMotion.interactive) {
            dayStart = next
            zoomDomain = nil
        }
    }

    private var dayLabel: String {
        let today = Repository.logicalDayStart(Date())
        if Calendar.current.isDate(dayStart, inSameDayAs: today) { return String(localized: "Today") }
        if Calendar.current.isDate(dayStart, inSameDayAs: today.addingTimeInterval(-86_400)) { return String(localized: "Yesterday") }
        return Self.dayFmt.string(from: dayStart)
    }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    // MARK: Chart

    @ViewBuilder private var chartCard: some View {
        ChartCard(
            title: LocalizedStringKey(metric.title),
            subtitle: resolutionSubtitle,
            trailing: latestReadout,
            height: 280,
            tint: StrandPalette.metricRose
        ) {
            if loading && series.points.isEmpty {
                loadingState
            } else if series.points.isEmpty {
                emptyState
            } else {
                chart
            }
        } footer: {
            if !series.points.isEmpty { statsFooter }
        }
    }

    /// `series.points` in the DISPLAYED unit (#101) — for every metric but skin temp this is just the raw
    /// points; skin temp is stored/read in °C, so when the user has °F selected the chart's line, y-axis
    /// domain AND gridlines (which plot the raw value, not `format`'s output) need the converted number,
    /// not just the readout label. The timeline series is the ABSOLUTE skin temp (`skinTempCelsius`), so
    /// the absolute °C→°F conversion (×9/5 + 32) is the right one here — not a deviation rescale.
    private var displayPoints: [TrendPoint] {
        guard metric == .skinTemp, temperatureUnit == .fahrenheit else { return series.points }
        return series.points.map {
            TrendPoint(date: $0.date, value: UnitFormatter.celsiusToFahrenheit($0.value))
        }
    }

    private var chart: some View {
        OverviewHRChart(
            points: displayPoints,
            // #979 spin-off — the same sleep-band + workout-glyph layers the classic Today feeds. Passed
            // on EVERY metric track (they're time annotations, so "when was I asleep / training" reads
            // against skin temp or HRV just as it does against HR); the glyph anchors at the shown
            // metric's peak inside the workout window, and the chart clamps both into the zoom window.
            sleep: sleepSpan,
            workouts: workoutSpans,
            gradient: gradientFor(metric),
            valueRange: valueRange(displayPoints),
            xRange: dayBounds,
            height: 280,
            // #979 spin-off — iPhone touch scrub: hold to pin the crosshair, drag to read values under
            // the finger (the Mac pointer hover's readout, made reachable on touch). Opt-in here only.
            touchScrub: true,
            zoomDomain: $zoomDomain,
            zoomBounds: panBounds,   // #986: pan/scroll clamp is the rolling 3-day window, not one day
            valueFormat: { format($0) },
            dateFormat: { Self.timeFmt.string(from: $0) }
        )
        #if os(macOS)
        // macOS has no pinch here, so wheel/trackpad scroll zooms about the cursor-agnostic centre.
        // (DeepTimeline owns the scroll handler; the chart's own gesture covers drag-pan.)
        .modifier(ScrollToZoomModifier(
            current: { visibleWindow },
            bounds: panBounds,   // #986: match the widened pan clamp
            apply: { zoomDomain = $0 }
        ))
        #endif
    }

    // MARK: States

    private var loadingState: some View {
        VStack(spacing: NoopMetrics.rowSpacing) {
            ProgressView().controlSize(.large)
            Text("Loading the day…")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Honest empty/dash state — a window the strap offloaded nothing for (a not-yet-synced stretch, an
    /// off-wrist gap, or a metric this device doesn't record). Never a fabricated flat line.
    private var emptyState: some View {
        VStack(spacing: NoopMetrics.space2) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(StrandPalette.textTertiary)
            Text("No \(metric.title.lowercased()) here")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
            Text(emptyReason)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, NoopMetrics.space6)
    }

    /// #623: on a 5.0/MG the SpO2 + raw respiration tracks are PERMANENTLY empty (4.0-only wire signals),
    /// so say that instead of a generic "nothing offloaded" that reads as broken, and point respiration at
    /// the Health screen where the R-R/RSA estimate surfaces. Strap view only (ownedOnly). Twin of Android
    /// FullDayChartScreen.EmptyTimelineState.
    private var emptyReason: String {
        if ownedOnly, metricUnsupported, metric == .spo2 {
            return String(localized: "This strap doesn’t send SpO₂ over Bluetooth. Import a WHOOP export or Health Connect to see it.")
        }
        if ownedOnly, metricUnsupported, metric == .respiration {
            return String(localized: "This strap sends no raw respiration stream. Your estimated respiratory rate appears on the Health screen.")
        }
        return ownedOnly
            ? String(localized: "Nothing offloaded for this window yet.")
            : String(localized: "Other sources don’t offload raw per-second data on-device.")
    }

    @ViewBuilder private var zoomHint: some View {
        HStack(spacing: NoopMetrics.space2) {
            Image(systemName: zoomDomain == nil ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                .font(StrandFont.footnote.weight(.semibold))
            #if os(macOS)
            Text(zoomDomain == nil ? "Scroll to zoom · drag to pan" : "Zoomed in. Drag to pan")
            #else
            // #979 spin-off: name the hold-to-scrub affordance — a hidden gesture nobody tries is a
            // feature that doesn't exist. (On the Mac the pointer hover is self-discovering.)
            Text(zoomDomain == nil ? "Pinch to zoom · drag to pan · hold to read" : "Zoomed in. Drag to pan · hold to read")
            #endif
            Spacer()
            if zoomDomain != nil {
                Button("Reset") { withAnimation(StrandMotion.interactive) { zoomDomain = nil } }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.accent)
                    .buttonStyle(.plain)
            }
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textTertiary)
        .padding(.horizontal, NoopMetrics.space1)
        .padding(.top, NoopMetrics.space1 / 2)
    }

    private var statsFooter: some View {
        let v = displayPoints.map(\.value)
        return ChartFooter([
            ("Min", format(v.min() ?? 0)),
            ("Avg", format(v.reduce(0, +) / Double(max(1, v.count)))),
            ("Max", format(v.max() ?? 0)),
        ])
    }

    // MARK: Read

    /// One-shot on first open: if today has no data but an earlier day does (the classic just-synced-history
    /// case, #597), land the timeline on that most-recent day so the user sees their data instead of an empty
    /// today. Skipped when the caller pinned an explicit day, and never fights manual navigation afterwards.
    private func landOnLatestDayIfNeeded() async {
        guard !didLandOnLatest else { return }
        didLandOnLatest = true
        if let latest = await repo.latestDataDayStart(), latest < dayStart {
            withAnimation(StrandMotion.interactive) { dayStart = latest }
        }
    }

    private func reload() async {
        loading = true
        let window = visibleWindow
        let result = await repo.timelineSeries(
            metric: metric,
            from: Int(window.lowerBound.timeIntervalSince1970),
            to: Int(window.upperBound.timeIntervalSince1970),
            targetPoints: 600
        )
        // Guard against a stale task landing after the user moved on.
        guard !Task.isCancelled else { return }
        series = result
        loading = false
    }

    /// #979 spin-off — load the shown day's sleep + workouts and scope them EXACTLY like the classic
    /// Today's Overview HR markers: `allSleepSessions` (imported AND on-device computed sources — a
    /// Bluetooth-only user's sleep lives under the computed source), longest overlapping block = the main
    /// night, never a nap; `workoutRows` (already dedup/dismiss-filtered) kept where they overlap the day.
    /// The band + duration use the EFFECTIVE onset so a hand-corrected bedtime shows the same band here as
    /// on the Sleep tab (#318). Both repo reads are today-relative, so `days:` walks back far enough from
    /// now to cover the shown day; the +2 pad mirrors TodayView's sleep read (the night straddles midnight).
    private func reloadAnnotations() async {
        let daysBack = max(0, Int(Date().timeIntervalSince(dayStart) / 86_400)) + 2

        let sleepCandidates: [OverviewHRChart.SleepSpan] = await repo.allSleepSessions(days: daysBack)
            .map { s in
                .init(start: Date(timeIntervalSince1970: TimeInterval(s.effectiveStartTs)),
                      end: Date(timeIntervalSince1970: TimeInterval(s.endTs)),
                      label: Self.hoursMinutes(s.endTs - s.effectiveStartTs))
            }
        let workoutCandidates: [OverviewHRChart.WorkoutSpan] = await repo.workoutRows(days: daysBack)
            .map { w in
                .init(start: Date(timeIntervalSince1970: TimeInterval(w.startTs)),
                      end: Date(timeIntervalSince1970: TimeInterval(w.endTs)),
                      symbol: sportSymbol(w.sport))
            }
        guard !Task.isCancelled else { return }
        // The pure, headless-tested selection (StrandDesignTests) — window = the shown DAY, not the zoom.
        sleepSpan = OverviewHRChart.mainSleep(sleepCandidates, overlapping: dayBounds)
        workoutSpans = OverviewHRChart.workouts(workoutCandidates, overlapping: dayBounds)
    }

    /// "H:MM" for a duration in seconds (e.g. a 6h06m night → "6:06") — mirrors TodayView.hoursMinutes
    /// so the band label reads identically on both whole-day charts.
    private static func hoursMinutes(_ seconds: Int) -> String {
        let h = max(0, seconds) / 3600, m = (max(0, seconds) % 3600) / 60
        return "\(h):\(String(format: "%02d", m))"
    }

    // MARK: Presentation helpers

    private var resolutionSubtitle: String {
        guard !series.points.isEmpty else { return "—" }
        if series.isRaw { return String(localized: "Raw · per second") }
        let m = series.bucketSeconds / 60
        return m >= 1 ? String(localized: "\(m)-minute average")
                      : String(localized: "\(series.bucketSeconds)-second average")
    }

    private var latestReadout: String? {
        displayPoints.last.map { "\(format($0.value))\(unitSuffix)" }
    }

    private var unitSuffix: String {
        switch metric {
        case .hr: return " bpm"
        case .skinTemp: return UnitFormatter.temperatureUnit(temperatureUnit)   // #101: °C / °F per preference
        case .respiration: return ""
        case .hrv: return " ms"
        // Gravity-vector magnitude (#102): tag it "g" so the readout doesn't read as a bare, unexplained
        // number — spo2/bandSleepState stay unitless (unitless ratio / a named state, not a magnitude).
        case .motion: return " g"
        // Seconds of movement per ~30 s window (the ring's OWN 0x47 activity), so tag it "s".
        case .ouraMovement: return " s"
        case .spo2, .bandSleepState: return ""
        }
    }

    private func format(_ v: Double) -> String {
        switch metric {
        case .hr, .respiration, .hrv, .ouraMovement: return String(Int(v.rounded()))
        // `v` already arrives in the displayed unit — callers read from `displayPoints`, which converts
        // skin temp to °F upfront so the chart's own axis (plotted from the same points) agrees. (#101)
        case .skinTemp: return String(format: "%.1f", v)
        case .spo2, .motion: return String(format: "%.2f", v)
        // #175: name the band's own state at the nearest code so the readout reads "asleep", not "2.0".
        case .bandSleepState: return Self.bandStateLabel(v)
        }
    }

    /// #175: map the band's 0-3 sleep_state code to its word. A bucket-averaged fractional value (when
    /// zoomed out) is rounded to the nearest code — honest for a readout label; the track itself plots the
    /// numeric code. This names the BAND's own reported state, never a stage NOOP derives.
    static func bandStateLabel(_ v: Double) -> String {
        switch Int(v.rounded()) {
        case 0: return String(localized: "wake")
        case 1: return String(localized: "still")
        case 2: return String(localized: "asleep")
        case 3: return String(localized: "up")
        default: return String(Int(v.rounded()))
        }
    }

    /// Padded value range so the line never sits flush against an edge (mirrors MetricExplorer/TodayView).
    private func valueRange(_ pts: [TrendPoint]) -> ClosedRange<Double> {
        let vals = pts.map(\.value)
        guard let lo = vals.min(), let hi = vals.max() else {
            return metric == .hr ? 40...120 : 0...1
        }
        if hi <= lo { return (lo - 1)...(hi + 1) }
        let pad = (hi - lo) * 0.12
        return (lo - pad)...(hi + pad)
    }

    private func gradientFor(_ m: Repository.TimelineMetric) -> Gradient {
        switch m {
        case .hr:
            return Gradient(colors: [StrandPalette.metricRose.opacity(0.55), StrandPalette.metricRose])
        case .skinTemp:
            return Gradient(colors: [StrandPalette.strain033.opacity(0.55), StrandPalette.strain033])
        case .hrv, .spo2:
            return Gradient(colors: [StrandPalette.sleepLight.opacity(0.55), StrandPalette.sleepLight])
        case .respiration, .motion, .ouraMovement:
            return Gradient(colors: [StrandPalette.textSecondary.opacity(0.5), StrandPalette.textSecondary])
        // #175: the band-state track uses the deep-sleep hue so it reads as a distinct sleep track.
        case .bandSleepState:
            return Gradient(colors: [StrandPalette.sleepDeep.opacity(0.55), StrandPalette.sleepDeep])
        }
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
}

#if os(macOS)
import AppKit
// MARK: - macOS scroll-to-zoom
//
// Scroll up (or trackpad pinch on macOS, which arrives as a magnify event the chart already handles) zooms
// in about the window centre; scroll down zooms out toward the day. Kept as a modifier so the platform
// split stays out of the screen body.
private struct ScrollToZoomModifier: ViewModifier {
    let current: () -> ClosedRange<Date>
    let bounds: ClosedRange<Date>
    let apply: (ClosedRange<Date>) -> Void

    func body(content: Content) -> some View {
        content.background(ScrollCatcher { deltaY in
            // Each notch scales by ~1.15; up (positive) zooms in, down zooms out.
            let scale = deltaY > 0 ? 1.15 : (1.0 / 1.15)
            let zoomed = OverviewHRChart.zoomed(current(), scale: scale, anchorFraction: 0.5, bounds: bounds)
            apply(zoomed.upperBound > zoomed.lowerBound ? zoomed : current())
        })
    }
}

/// A transparent NSView that reports scroll-wheel deltaY up the closure. AppKit-only.
private struct ScrollCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void
    func makeNSView(context: Context) -> NSView { CatcherView(onScroll: onScroll) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onScroll = onScroll
    }
    final class CatcherView: NSView {
        var onScroll: (CGFloat) -> Void
        init(onScroll: @escaping (CGFloat) -> Void) {
            self.onScroll = onScroll
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func scrollWheel(with event: NSEvent) {
            if abs(event.scrollingDeltaY) > 0.5 { onScroll(event.scrollingDeltaY) }
        }
    }
}
#endif
