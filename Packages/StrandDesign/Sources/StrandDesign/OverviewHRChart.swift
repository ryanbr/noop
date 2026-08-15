#if !os(watchOS)
// OverviewHRChart is a Swift Charts view with .onContinuousHover / MagnificationGesture pan-zoom
// (none available on watchOS); the watch never shows it, so the whole file is excluded there.
import SwiftUI
import Charts

// MARK: - Overview HR Chart (§ Today — day-in-review)
//
// The Today screen's 24h heart-rate line, annotated like WHOOP's "Overview HR":
// the warm HR curve overlaid with a sleep band, a recovery marker at wake, a
// strain marker at "now", and a sport glyph at each workout's HR peak. The line +
// hover affordance mirror `TrendChart`; this view adds the marker layers and pins
// the x-axis to the HR window so markers never stretch the timeline.
//
// Colours stay in NOOP's Titanium & Gold language (burnt-orange HR line, gold
// recovery, amber strain, blue sleep) rather than copying WHOOP's blue. Tokens
// only — never hardcode hex.

public struct OverviewHRChart: View {

    /// The sleep period to shade as a band, with an optional corner label (e.g. duration "6:06").
    public struct SleepSpan: Sendable {
        public var start: Date
        public var end: Date
        public var label: String?
        public init(start: Date, end: Date, label: String? = nil) {
            self.start = start; self.end = end; self.label = label
        }
    }

    /// A workout window; the sport glyph is placed at the HR peak inside [start, end].
    public struct WorkoutSpan: Identifiable, Sendable {
        public let id = UUID()
        public var start: Date
        public var end: Date
        public var symbol: String          // SF Symbol (see `sportSymbol`)
        public init(start: Date, end: Date, symbol: String) {
            self.start = start; self.end = end; self.symbol = symbol
        }
    }

    /// A labelled vertical marker pinned to a moment in the day (recovery at wake, strain at now).
    public struct EdgeMarker: Sendable {
        public var date: Date
        public var label: String
        public var color: Color
        public var alignment: HorizontalAlignment
        public init(date: Date, label: String, color: Color, alignment: HorizontalAlignment = .leading) {
            self.date = date; self.label = label; self.color = color; self.alignment = alignment
        }
    }

    public var points: [TrendPoint]
    public var sleep: SleepSpan?
    public var workouts: [WorkoutSpan]
    public var recovery: EdgeMarker?
    public var effort: EdgeMarker?
    public var gradient: Gradient
    public var valueRange: ClosedRange<Double>
    /// Explicit x-axis window. When set, the axis spans exactly this range (so missing data shows as
    /// empty space); when nil, the axis is derived from the data extent.
    public var xRange: ClosedRange<Date>?
    public var height: CGFloat
    public var showsHover: Bool
    /// iPhone touch scrub (#979 spin-off): when true, touch-and-hold pins the hover crosshair under the
    /// finger and dragging scrubs it — driving the SAME readout layer the Mac pointer hover uses. Off by
    /// default so every existing call site keeps its exact touch behaviour; the Deep Timeline opts in.
    public var touchScrub: Bool
    public var valueFormat: (Double) -> String
    public var dateFormat: (Date) -> String

    /// Deep-Timeline zoom/pan window. When bound (Deep Timeline only), it OVERRIDES `xRange`/data extent
    /// as the visible x-domain, and pinch-magnify (iOS) / scroll-to-zoom (macOS) + drag-pan mutate it.
    /// `bounds` is the full clamp the window can never escape (the day's full extent). nil on every other
    /// call site, so the existing static chart is byte-for-byte unchanged.
    @Binding public var zoomDomain: ClosedRange<Date>?
    public var zoomBounds: ClosedRange<Date>?

    /// Tint for the workout glyph badges (NOOP's warm strain accent by default).
    public var workoutTint: Color

    private let averageValue: Double

    public init(
        points: [TrendPoint],
        sleep: SleepSpan? = nil,
        workouts: [WorkoutSpan] = [],
        recovery: EdgeMarker? = nil,
        effort: EdgeMarker? = nil,
        gradient: Gradient = Gradient(colors: [StrandPalette.metricRose.opacity(0.55), StrandPalette.metricRose]),
        valueRange: ClosedRange<Double> = 40...120,
        xRange: ClosedRange<Date>? = nil,
        height: CGFloat = 220,
        showsHover: Bool = true,
        touchScrub: Bool = false,
        workoutTint: Color = StrandPalette.strain033,
        zoomDomain: Binding<ClosedRange<Date>?> = .constant(nil),
        zoomBounds: ClosedRange<Date>? = nil,
        valueFormat: @escaping (Double) -> String = { String(Int($0.rounded())) },
        dateFormat: @escaping (Date) -> String = { TrendChart.defaultDateString($0) }
    ) {
        let sorted = points.sorted { $0.date < $1.date }
        self.points = sorted
        self.sleep = sleep
        self.workouts = workouts
        self.recovery = recovery
        self.effort = effort
        self.gradient = gradient
        self.valueRange = valueRange
        self.xRange = xRange
        self.height = height
        self.showsHover = showsHover
        self.touchScrub = touchScrub
        self.workoutTint = workoutTint
        self._zoomDomain = zoomDomain
        self.zoomBounds = zoomBounds
        self.valueFormat = valueFormat
        self.dateFormat = dateFormat
        self.averageValue = sorted.isEmpty
            ? valueRange.lowerBound
            : sorted.map(\.value).reduce(0, +) / Double(sorted.count)
        // Deep Timeline (the only caller that supplies `zoomBounds`) keeps full resolution so pinch-zoom
        // into sub-windows stays crisp. The default-binding case here is `zoomBounds == nil`, so the
        // static Today chart downsamples. `zoomBounds` is the stable discriminator (set once, never
        // toggles) — unlike the live `zoomDomain`, which is nil until the user first zooms.
        self.displayPoints = (zoomBounds != nil)
            ? sorted
            : ChartDownsample.minMaxBucketed(sorted, threshold: ChartDownsample.markThreshold,
                                             targetCount: ChartDownsample.targetVertices)
    }

    @State private var hoverX: CGFloat? = nil
    /// The zoom window captured at the start of a magnify/drag gesture, so the gesture is applied
    /// against a stable anchor instead of compounding each frame.
    @State private var gestureAnchorDomain: ClosedRange<Date>? = nil
    #if os(iOS)
    /// True while a touch scrub is engaged (the hold completed). Only used to fire the engage haptic
    /// exactly once per scrub — the sequenced gesture can report `.second(true, nil)` more than once.
    @State private var scrubEngaged = false
    #endif

    /// PERF: the 24h HR line can carry hundreds of samples — more than the ~360pt plot has pixels, so most
    /// are sub-pixel pure draw cost. This is the point set actually handed to the line/area marks:
    /// full resolution in the Deep Timeline (where the user pinches into sub-windows), else
    /// min/max-per-bucket down to ~the plot pixel width. Min/max bucketing keeps every visible spike, so
    /// the static Today chart is pixel-identical. Computed ONCE in `init` (not per body/hover eval) so
    /// it's memoized on `points`; hover / markers / accessibility stay on the full `points`.
    private let displayPoints: [TrendPoint]

    /// Smallest zoom window we allow (1 minute) — past this the line is just two points and pinch jitters.
    public static let minZoomSpan: TimeInterval = 60

    // MARK: Zoom / pan math (pure, testable in isolation)

    /// The visible domain after scaling `base` about `anchorFraction` (0…1 across the window) by
    /// `scale` (>1 zooms in), clamped into `bounds` and floored at `minZoomSpan`. Pure.
    public static func zoomed(_ base: ClosedRange<Date>, scale: Double, anchorFraction: Double,
                              bounds: ClosedRange<Date>, minSpan: TimeInterval = minZoomSpan) -> ClosedRange<Date> {
        let lo = base.lowerBound.timeIntervalSince1970
        let hi = base.upperBound.timeIntervalSince1970
        let span = hi - lo
        guard span > 0, scale > 0 else { return base }
        let pivot = lo + span * min(max(anchorFraction, 0), 1)
        let boundsSpan = bounds.upperBound.timeIntervalSince1970 - bounds.lowerBound.timeIntervalSince1970
        let newSpan = min(max(span / scale, minSpan), max(boundsSpan, minSpan))
        var newLo = pivot - (pivot - lo) * (newSpan / span)
        var newHi = newLo + newSpan
        // Clamp inside bounds, preserving span.
        if newLo < bounds.lowerBound.timeIntervalSince1970 {
            newLo = bounds.lowerBound.timeIntervalSince1970; newHi = newLo + newSpan
        }
        if newHi > bounds.upperBound.timeIntervalSince1970 {
            newHi = bounds.upperBound.timeIntervalSince1970; newLo = newHi - newSpan
        }
        newLo = max(newLo, bounds.lowerBound.timeIntervalSince1970)
        return Date(timeIntervalSince1970: newLo)...Date(timeIntervalSince1970: max(newLo + 1, newHi))
    }

    // MARK: Annotation scoping (pure, testable in isolation)

    /// The single sleep to band for a visible window: the LONGEST candidate overlapping it — the main
    /// night, never an afternoon nap — the same pick the classic Today makes for its whole-day HR chart.
    /// Extracted pure so the Deep Timeline's annotation parity (#979 spin-off) is headless-testable.
    /// Overlap is half-open-ish like Today's filter: a sleep ending exactly at the window start (or
    /// starting exactly at its end) does NOT count — it contributes zero visible band.
    public static func mainSleep(_ candidates: [SleepSpan], overlapping window: ClosedRange<Date>) -> SleepSpan? {
        candidates
            .filter { $0.end > window.lowerBound && $0.start < window.upperBound }
            .max(by: { $0.end.timeIntervalSince($0.start) < $1.end.timeIntervalSince($1.start) })
    }

    /// The workout spans overlapping a visible window (a glyph for an out-of-window workout would be
    /// clamp-dragged to the plot edge and lie about its time). Edge-touching spans are kept — mirrors
    /// the classic Today's inclusive workout filter. Order preserved. Pure.
    public static func workouts(_ candidates: [WorkoutSpan], overlapping window: ClosedRange<Date>) -> [WorkoutSpan] {
        candidates.filter { $0.end >= window.lowerBound && $0.start <= window.upperBound }
    }

    /// The visible domain after panning `base` by `deltaSeconds`, clamped into `bounds` (span preserved). Pure.
    public static func panned(_ base: ClosedRange<Date>, deltaSeconds: Double,
                              bounds: ClosedRange<Date>) -> ClosedRange<Date> {
        let lo = base.lowerBound.timeIntervalSince1970
        let hi = base.upperBound.timeIntervalSince1970
        let span = hi - lo
        var newLo = lo + deltaSeconds
        newLo = min(max(newLo, bounds.lowerBound.timeIntervalSince1970),
                    bounds.upperBound.timeIntervalSince1970 - span)
        newLo = max(newLo, bounds.lowerBound.timeIntervalSince1970)
        return Date(timeIntervalSince1970: newLo)...Date(timeIntervalSince1970: newLo + span)
    }

    // MARK: Geometry helpers

    /// The x-axis window. When the caller supplies `xRange` (e.g. a full calendar day for a past
    /// date), that wins — so a stretch with no samples reads as visible empty space rather than the
    /// axis silently collapsing to the data extent. Otherwise it's pinned to the HR data so markers
    /// (sleep onset the night before, etc.) can't stretch the timeline. Safe even for sparse input.
    private var xDomain: ClosedRange<Date> {
        // Deep Timeline: the bound zoom window wins over everything (it's what gestures drive).
        if let zoomDomain, zoomDomain.upperBound > zoomDomain.lowerBound { return zoomDomain }
        if let xRange, xRange.upperBound > xRange.lowerBound { return xRange }
        let lo = points.first?.date ?? Date(timeIntervalSince1970: 0)
        let hi = points.last?.date ?? lo.addingTimeInterval(3600)
        return hi > lo ? lo...hi : lo...lo.addingTimeInterval(3600)
    }

    /// The hard clamp a zoom/pan window may never escape: the caller-supplied bounds, else the data extent.
    private var zoomClampBounds: ClosedRange<Date> {
        if let zoomBounds, zoomBounds.upperBound > zoomBounds.lowerBound { return zoomBounds }
        if let xRange, xRange.upperBound > xRange.lowerBound { return xRange }
        let lo = points.first?.date ?? Date(timeIntervalSince1970: 0)
        let hi = points.last?.date ?? lo.addingTimeInterval(3600)
        return hi > lo ? lo...hi : lo...lo.addingTimeInterval(3600)
    }

    private func clampX(_ d: Date) -> Date {
        min(max(d, xDomain.lowerBound), xDomain.upperBound)
    }

    /// Map a value onto 0...1 over the value range, for the gradient stops.
    private func unit(_ value: Double) -> Double {
        let lo = valueRange.lowerBound, hi = valueRange.upperBound
        guard hi > lo else { return 0 }
        return min(max((value - lo) / (hi - lo), 0), 1)
    }

    private var valueGradient: LinearGradient {
        LinearGradient(gradient: gradient, startPoint: .bottom, endPoint: .top)
    }

    /// The peak HR sample inside a workout window, where its glyph is anchored.
    private func peak(in w: WorkoutSpan) -> TrendPoint? {
        points
            .filter { $0.date >= w.start && $0.date <= w.end }
            .max(by: { $0.value < $1.value })
    }

    private func nearestPoint(toX x: CGFloat, proxy: ChartProxy, plot: CGRect) -> TrendPoint? {
        guard !points.isEmpty else { return nil }
        let relX = x - plot.minX
        guard let date: Date = proxy.value(atX: relX) else { return nil }
        return points.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        })
    }

    // MARK: Mark layers
    //
    // Only lines/bands live as Chart marks. All text labels + workout glyphs are drawn in the
    // overlay (below) via the proxy — Swift Charts' `.annotation` overflow-clamping needs macOS 14
    // and gets clipped by the card's fixed height on 13, so we position labels ourselves.

    @ChartContentBuilder private var marks: some ChartContent {
        // Sleep band — shaded region behind the curve (drawn first so the HR line/area sit on top).
        if let sleep, sleep.end > xDomain.lowerBound {
            RectangleMark(
                xStart: .value("Sleep start", clampX(sleep.start)),
                xEnd: .value("Sleep end", clampX(sleep.end))
            )
            .foregroundStyle(StrandPalette.sleepDeep.opacity(0.32))
        }

        ForEach(displayPoints) { p in
            AreaMark(x: .value("Time", p.date), y: .value("BPM", p.value))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            StrandPalette.sample(stops: gradient.toStops(), at: unit(averageValue)).opacity(0.28),
                            Color.clear
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
        }
        ForEach(displayPoints) { p in
            LineMark(x: .value("Time", p.date), y: .value("BPM", p.value))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .foregroundStyle(valueGradient)
        }

        // Wake divider — the sleep→day boundary. Always shown with a sleep band so the band reads
        // even before recovery calibrates (when the gold recovery rule is absent).
        if let sleep, sleep.end > xDomain.lowerBound, sleep.end < xDomain.upperBound {
            RuleMark(x: .value("Wake", clampX(sleep.end)))
                .foregroundStyle(StrandPalette.sleepLight.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        if let recovery {
            RuleMark(x: .value("Recovery", clampX(recovery.date)))
                .foregroundStyle(recovery.color.opacity(0.85))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
        if let effort {
            RuleMark(x: .value("Effort", clampX(effort.date)))
                .foregroundStyle(effort.color.opacity(0.85))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
    }

    // MARK: Overlay helpers

    /// Screen x for a date (plot-relative position offset into container coords). nil if off-scale.
    private func xPos(_ date: Date, _ proxy: ChartProxy, _ plot: CGRect) -> CGFloat? {
        proxy.position(forX: date).map { $0 + plot.minX }
    }

    /// Rough label width for edge-clamping (footnote ≈ 6.5pt/char + padding/glyph).
    private func estWidth(_ s: String, extra: CGFloat = 18) -> CGFloat { CGFloat(s.count) * 6.5 + extra }

    /// Place a label centred on `x`, clamped so it never spills past the plot edges.
    @ViewBuilder
    private func placed<V: View>(_ view: V, atX x: CGFloat, topY: CGFloat, width: CGFloat, plot: CGRect) -> some View {
        let half = width / 2
        let cx = min(max(x, plot.minX + half + 4), plot.maxX - half - 4)
        view.position(x: cx, y: topY)
    }

    @ViewBuilder
    private func markerLabels(proxy: ChartProxy, plot: CGRect) -> some View {
        let topY = plot.minY + 12
        if let sleep, let label = sleep.label, sleep.end > xDomain.lowerBound {
            placed(SleepBandLabel(text: label),
                   atX: xPos(clampX(sleep.start), proxy, plot) ?? plot.minX,
                   topY: topY, width: estWidth(label, extra: 34), plot: plot)
        }
        if let recovery, let rx = xPos(clampX(recovery.date), proxy, plot) {
            placed(MarkerLabel(text: recovery.label, color: recovery.color),
                   atX: rx, topY: topY, width: estWidth(recovery.label), plot: plot)
        }
        if let effort, let sx = xPos(clampX(effort.date), proxy, plot) {
            placed(MarkerLabel(text: effort.label, color: effort.color),
                   atX: sx, topY: topY, width: estWidth(effort.label), plot: plot)
        }
        ForEach(workouts) { w in
            if let pk = peak(in: w),
               let px = xPos(pk.date, proxy, plot),
               let pyRel = proxy.position(forY: pk.value) {
                let cx = min(max(px, plot.minX + 14), plot.maxX - 14)
                WorkoutBadge(symbol: w.symbol, tint: workoutTint)
                    .position(x: cx, y: max(topY + 26, pyRel + plot.minY - 20))
            }
        }
    }

    @ViewBuilder
    private func hoverLayer(proxy: ChartProxy, plot: CGRect, container: CGSize) -> some View {
        if showsHover, let hx = hoverX,
           let p = nearestPoint(toX: hx, proxy: proxy, plot: plot),
           let pxRel = proxy.position(forX: p.date),
           let pyRel = proxy.position(forY: p.value) {
            let cx = pxRel + plot.minX
            let cy = pyRel + plot.minY
            let color = StrandPalette.sample(stops: gradient.toStops(), at: unit(p.value))
            CrosshairRule(x: cx, height: container.height)
            HighlightDot(color: color).position(x: cx, y: cy)
            PositionedTooltip(
                anchor: CGPoint(x: cx, y: cy),
                container: container,
                tooltip: ChartTooltip(value: valueFormat(p.value), label: dateFormat(p.date), accent: color)
            )
        }
    }

    #if os(iOS)
    /// Touch-and-hold-then-drag scrub (#979 spin-off). The stationary hold (0.25 s within 8 pt) is the
    /// gate that separates scrubbing from the pan drag (min 6 pt) and pinch that own immediate movement.
    /// LongPressGesture reports no location, so the crosshair appears from the drag phase's coordinates —
    /// in practice the first micro-movement of a held finger, which is immediate; the engage haptic marks
    /// the mode switch the instant the hold lands. Drives the SAME `hoverX` the Mac pointer hover drives,
    /// so the readout (crosshair + dot + tooltip) is byte-identical across input methods.
    private var touchScrubGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.25, maximumDistance: 8)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if !scrubEngaged {
                    scrubEngaged = true
                    StrandHaptic.selection.play()
                }
                if let drag {
                    // Non-animating transaction, same reason as hover (TrendChart #104 flicker).
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) { hoverX = drag.location.x }
                }
            }
            .onEnded { _ in
                scrubEngaged = false
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) { hoverX = nil }
            }
    }
    #endif

    // MARK: Body

    public var body: some View {
        Chart { marks }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: valueRange)
        // catmullRom overshoots past the data on sharp turns and the area gradient draws
        // unclipped — clip the plot so a spiky HR curve doesn't bleed past the chart (see TrendChart).
        .chartPlotStyle { plotArea in plotArea.clipped() }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
                    .font(StrandFont.footnote)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
                    .font(StrandFont.footnote)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotRectCompat(in: geo)
                ZStack(alignment: .topLeading) {
                    markerLabels(proxy: proxy, plot: plot)
                    hoverLayer(proxy: proxy, plot: plot, container: geo.size)
                }
                .animation(StrandMotion.fade, value: hoverX)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    guard showsHover else { return }
                    // Non-animating transaction: otherwise crossing the plot edge re-runs the
                    // line's draw-on animation and flickers the curve (mirrors TrendChart #104).
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) {
                        switch phase {
                        case .active(let location): hoverX = location.x
                        case .ended: hoverX = nil
                        }
                    }
                }
                #if os(iOS)
                // #979 spin-off — touch scrub. onContinuousHover above is pointer-only, so on iPhone the
                // crosshair readout was unreachable (the collapsed a11y summary was the only datum
                // affordance; cf. CompareView's touch-scrub note). Touch-and-hold claims the touch for
                // scrubbing, then dragging moves the crosshair; lift clears it. Gating behind the hold is
                // what keeps zoom/pan untouched: an immediate drag exceeds the hold's max distance and
                // still pans (ZoomPanModifier), pinch still zooms, double-tap still resets. `.subviews`
                // masks the gesture entirely on the call sites that don't opt in.
                .gesture(touchScrubGesture, including: (touchScrub && showsHover) ? .all : .subviews)
                #endif
            }
        }
        .frame(height: height)
        // Zoom/pan: active whenever a zoom binding is supplied (the Deep Timeline and the Today HR chart).
        // Every other call site passes the default `.constant(nil)`, so those static charts keep their exact
        // gestures. The modifier itself reads Reduce Motion, so the double-tap reset snaps when it's on.
        // #829 follow-up: keyed on `zoomBounds` (the stable "a zoom binding was supplied" discriminator the
        // init comment names, set once by the two zooming call sites, nil everywhere else), NOT on the live
        // `zoomDomain`, which is nil until the user first zooms, so keying on it left the gestures unmounted
        // in exactly the state where the first pinch has to land. `apply` below normalises a window that
        // covers the full clamp bounds back to nil, so an un-zoomed drag (a pan of the whole day into
        // itself) never flips the hint/Reset row into its "Zoomed in" state.
        .modifier(ZoomPanModifier(
            isActive: zoomBounds != nil,
            scrubActive: {
                #if os(iOS)
                scrubEngaged
                #else
                false
                #endif
            },
            isZoomed: { zoomDomain != nil },
            current: { xDomain },
            bounds: zoomClampBounds,
            anchor: $gestureAnchorDomain,
            apply: { newDomain in
                zoomDomain = (newDomain.lowerBound <= zoomClampBounds.lowerBound
                              && newDomain.upperBound >= zoomClampBounds.upperBound) ? nil : newDomain
            },
            reset: { zoomDomain = nil },
            zoom: { base, scale, frac, bounds in Self.zoomed(base, scale: scale, anchorFraction: frac, bounds: bounds) },
            pan: { base, dx, plotWidth, bounds in
                // Map a horizontal drag (points) to seconds across the current visible span.
                let span = base.upperBound.timeIntervalSince1970 - base.lowerBound.timeIntervalSince1970
                let secPerPoint = plotWidth > 0 ? span / Double(plotWidth) : 0
                return Self.panned(base, deltaSeconds: -dx * secPerPoint, bounds: bounds)
            }
        ))
        // Collapse the Charts marks into ONE meaningful VoiceOver element with a summary, instead of
        // letting VoiceOver walk every line/area/rule/rect mark as a separate, contextless axis value
        // (matches the sibling TrendChart). The only datum affordance otherwise is hover, which is
        // dead on touch — so on iPhone this chart spoke no heart rate at all.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Heart rate, 24 hours"))
        .accessibilityValue(Text(accessibilitySummary))
    }

    /// One-line VoiceOver summary: the day's HR (count, mean, range) plus the band/marker context the
    /// chart shows visually, so the collapsed element still conveys the whole picture (cf. the Android
    /// OverviewHRChart semantics).
    private var accessibilitySummary: String {
        guard !points.isEmpty else { return String(localized: "No heart-rate data", bundle: .module) }
        let values = points.map(\.value)
        let lo = values.min() ?? valueRange.lowerBound
        let hi = values.max() ?? valueRange.upperBound
        var parts = [String(localized: "\(points.count) readings", bundle: .module),
                     String(localized: "average \(valueFormat(averageValue)) bpm", bundle: .module),
                     String(localized: "range \(valueFormat(lo)) to \(valueFormat(hi))", bundle: .module)]
        if let sleep {
            parts.append(String(localized: "asleep \(Self.hoursMinutes(sleep.end.timeIntervalSince(sleep.start)))", bundle: .module))
        }
        if let recovery { parts.append(recovery.label) }
        if let effort { parts.append(effort.label) }
        if !workouts.isEmpty {
            parts.append(workouts.count == 1 ? String(localized: "1 workout", bundle: .module) : String(localized: "\(workouts.count) workouts", bundle: .module))
        }
        return parts.joined(separator: ", ")
    }

    private static func hoursMinutes(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let h = total / 3_600, m = (total % 3_600) / 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        return h > 0 ? "\(h)h" : "\(m)m"
    }
}

// MARK: - Marker chrome

/// Sport glyph in a tinted badge, anchored above a workout's HR peak.
private struct WorkoutBadge: View {
    let symbol: String
    let tint: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(StrandPalette.textPrimary)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint)
            )
            .shadow(color: tint.opacity(0.5), radius: 4, y: 1)
            .allowsHitTesting(false)
    }
}

/// Small caps read-out for the recovery / strain edge markers (e.g. "67% Recovery").
private struct MarkerLabel: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(StrandFont.footnote)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(NoopPanelSurface(cornerRadius: 6, elevated: true, surfaceOpacity: 0.92))
            .fixedSize()
            .allowsHitTesting(false)
    }
}

/// Moon glyph + sleep duration, shown at the leading corner of the sleep band.
private struct SleepBandLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "moon.fill").font(.system(size: 9))
            Text(text).font(StrandFont.footnote).fontWeight(.semibold)
        }
        .foregroundStyle(StrandPalette.sleepLight)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(NoopPanelSurface(cornerRadius: 6, elevated: true, surfaceOpacity: 0.92))
        .fixedSize()
        .allowsHitTesting(false)
    }
}

// MARK: - Zoom / pan gesture host
//
// Kept as a standalone modifier so the chart body stays readable and so the platform split (pinch on
// iOS, scroll-to-zoom on macOS; drag-pan on both) lives in one place. No-op when `isActive` is false.

private struct ZoomPanModifier: ViewModifier {
    let isActive: Bool
    /// #1342: true while a touch scrub is engaged, so the pan drag is masked off (`.subviews`) and can't
    /// ALSO slide the window sideways out from under the crosshair. Always false on macOS (no touch scrub).
    let scrubActive: () -> Bool
    /// True while the window is zoomed in (a reset is meaningful). Read at double-tap time so a tap on the
    /// already-full-day chart does nothing rather than re-triggering a no-op animation.
    let isZoomed: () -> Bool
    let current: () -> ClosedRange<Date>
    let bounds: ClosedRange<Date>
    @Binding var anchor: ClosedRange<Date>?
    let apply: (ClosedRange<Date>) -> Void
    /// Drop the zoom window back to the full extent (sets the bound `zoomDomain` to nil).
    let reset: () -> Void
    let zoom: (ClosedRange<Date>, Double, Double, ClosedRange<Date>) -> ClosedRange<Date>
    let pan: (ClosedRange<Date>, CGFloat, CGFloat, ClosedRange<Date>) -> ClosedRange<Date>

    @State private var plotWidth: CGFloat = 1
    // Reduce Motion: the reset snaps instantly when on, otherwise it eases out (the gesture frames
    // themselves are never animated, per the per-frame apply below, so only the reset honours this).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Reset the window, snapping when Reduce Motion is on and easing otherwise.
    private func resetZoom() {
        guard isZoomed() else { return }
        withAnimation(NoopMotion.gated(StrandMotion.interactive, reduced: reduceMotion)) { reset() }
    }

    func body(content: Content) -> some View {
        guard isActive else { return AnyView(content) }
        // #1342: 10 pt (not 6) so the pan can't start inside the scrub long-press's 8 pt hold window —
        // the 6–8 pt overlap band is what let a held-then-dragged finger begin panning during a scrub.
        let drag = DragGesture(minimumDistance: 10)
            .onChanged { value in
                let base = anchor ?? current()
                if anchor == nil { anchor = base }
                apply(pan(base, value.translation.width, plotWidth, bounds))
            }
            .onEnded { _ in anchor = nil }

        let magnify = MagnificationGesture()
            .onChanged { scale in
                let base = anchor ?? current()
                if anchor == nil { anchor = base }
                // Pinch zooms about the window centre (we don't get a focal point from MagnificationGesture).
                apply(zoom(base, Double(scale), 0.5, bounds))
            }
            .onEnded { _ in anchor = nil }

        // Double-tap anywhere on the plot resets to the full window: the discoverable "back out" affordance
        // both platforms share (alongside the explicit Reset button the host shows). It does NOT add an
        // accessibility action: the chart collapses to one labelled VoiceOver element with a static value, so
        // a hidden tap gesture here is invisible to VoiceOver and never steals its double-tap-to-activate.
        let doubleTapReset = TapGesture(count: 2).onEnded { resetZoom() }

        let measured = content.background(
            GeometryReader { geo in
                Color.clear.onAppear { plotWidth = geo.size.width }
                    .onChangeCompat(of: geo.size.width) { plotWidth = $0 }
            }
        )

        #if os(macOS)
        // macOS has no pinch in this context; drag pans. Scroll-to-zoom is handled by the Deep Timeline
        // host's scroll modifier (it owns the NSEvent monitor); here we wire pan + the double-tap reset.
        return AnyView(measured.gesture(drag).simultaneousGesture(doubleTapReset))
        #else
        // #1342: mask the pan off while a scrub is engaged so a horizontal scrub no longer ALSO slides
        // the window (the pan is `.simultaneous`, so it otherwise co-recognises alongside the scrub).
        return AnyView(measured.gesture(magnify)
            .simultaneousGesture(drag, including: scrubActive() ? .subviews : .all)
            .simultaneousGesture(doubleTapReset))
        #endif
    }
}

#if DEBUG
#Preview("OverviewHRChart") {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let pts: [TrendPoint] = (0..<288).map { i in
        let t = now.addingTimeInterval(Double(i) * 300 - 288 * 300)
        let base = 58.0 + 18 * abs(sin(Double(i) / 30.0))
        let spike = (i > 200 && i < 215) ? 75.0 : 0
        return TrendPoint(date: t, value: base + spike)
    }
    return VStack(alignment: .leading, spacing: 12) {
        Text("Overview HR").strandOverline()
        OverviewHRChart(
            points: pts,
            sleep: .init(start: pts.first!.date, end: pts.first!.date.addingTimeInterval(6 * 3600 + 6 * 60), label: "6:06"),
            workouts: [.init(start: pts[200].date, end: pts[215].date, symbol: "figure.run")],
            recovery: .init(date: pts.first!.date.addingTimeInterval(6 * 3600), label: "67% Recovery", color: StrandPalette.recoveryColor(67)),
            effort: .init(date: pts.last!.date, label: "12.5 Effort", color: StrandPalette.strainColor(12.5), alignment: .trailing),
            valueRange: 45...140
        )
    }
    .padding(28)
    .frame(width: 760, height: 360)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
#endif
