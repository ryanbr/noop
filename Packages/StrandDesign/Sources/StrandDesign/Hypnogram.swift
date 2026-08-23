#if !os(watchOS)
// The watch never draws the hypnogram (uses .onContinuousHover + ChartHover helpers, unavailable
// on watchOS); excluded there, iOS/macOS unchanged.
import SwiftUI

// MARK: - Hypnogram (§9.4 Sleep)
//
// (WHOOP-style hypnogram visuals adopted from ryanAtriumAi #988.)
// A sleep-stage horizontal banded timeline, WHOOP-style. Four faint stage lanes
// (awake top → deep bottom) anchor height → stage so the chart reads even across
// gaps; each interval is a flat, square-ended bar whose WIDTH tracks its duration
// (brief stages stay slim ticks, never fat dots) coloured per §9.1 with the sleep
// tokens — awake pale grey, light periwinkle (#A7A4F4), deep orchid (#FD96FD), REM
// purple (#AE5BEF). Transitions are quiet, round-capped vertical risers, so the
// whole night reads as one continuous, legible "staircase".

/// A single stage interval. `start`/`end` are seconds from the start of the night.
public struct SleepInterval: Identifiable, Sendable {
    public var stage: SleepStage
    public var start: TimeInterval
    public var end: TimeInterval

    /// Stable, CONTENT-derived identity (stage + start + end) rather than a random `UUID()`.
    /// A fresh UUID per value defeated SwiftUI's `ForEach` diffing — every body eval re-identified
    /// all bands as brand-new, so the whole hypnogram rebuilt on each hover/diff. Intervals are
    /// non-overlapping with distinct starts within a night, so this composite is unique and stable.
    public var id: String { "\(stage.rawValue)|\(start)|\(end)" }

    public init(stage: SleepStage, start: TimeInterval, end: TimeInterval) {
        self.stage = stage
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { max(0, end - start) }
}

public struct Hypnogram: View {

    public var intervals: [SleepInterval]
    /// Height of the plotting band.
    public var height: CGFloat
    /// Whether to draw the stage labels down the left edge.
    public var showsStageAxis: Bool
    /// Whether hovering a stage band highlights it and shows a tooltip
    /// (stage name, clock start–end, duration). Defaults on.
    public var showsHover: Bool
    /// Optional wall-clock time the night began. When set, the tooltip shows
    /// real clock times (e.g. "23:42–00:04"); otherwise it shows elapsed time
    /// from the start of the night (e.g. "0:06–0:28").
    public var nightStart: Date?
    /// Whether to anchor the timeline with an x time axis (onset · midpoint · wake
    /// hairlines + clock labels). Needs `nightStart`. Defaults off so existing
    /// callers are unchanged.
    public var showsTimeAxis: Bool
    /// WHOOP's tap-a-stage interaction: when set, this stage's segments (and its lane)
    /// render at full strength while every other stage recedes. Nil = everything full.
    public var highlightedStage: SleepStage?
    /// When true, each stage band extends from its lane DOWN to the baseline (the FILLED stepped-area
    /// look) instead of the slim ribbon band. The stage → lane mapping, risers and axis are identical;
    /// only the band height changes. Mirrors the Android `FilledHypnogram(filled:)`.
    public var filled: Bool
    /// The stage-colour ramp: NOOP tokens (default, and every non-sleep caller), Oura's (Ribbon), or
    /// Garmin's (Garmin Fill). Only the Sleep-tab stepped chart passes a non-default ramp.
    public var stagePalette: SleepStagePalette

    public init(
        intervals: [SleepInterval],
        height: CGFloat = 180,
        showsStageAxis: Bool = true,
        showsHover: Bool = true,
        nightStart: Date? = nil,
        showsTimeAxis: Bool = false,
        smoothingSeconds: TimeInterval = 300,
        highlightedStage: SleepStage? = nil,
        filled: Bool = false,
        stagePalette: SleepStagePalette = .noop
    ) {
        let sorted = intervals.sorted { $0.start < $1.start }
        self.intervals = smoothingSeconds > 0
            ? Hypnogram.displaySmoothed(sorted, minDuration: smoothingSeconds)
            : sorted
        self.height = height
        self.showsStageAxis = showsStageAxis
        self.showsHover = showsHover
        self.nightStart = nightStart
        self.showsTimeAxis = showsTimeAxis
        self.highlightedStage = highlightedStage
        self.filled = filled
        self.stagePalette = stagePalette
    }

    // MARK: Display smoothing (WHOOP-style)
    //
    // The on-device stager emits 30s-epoch runs, so a real night arrives as 60–100 fragments —
    // sub-minute stage flickers each dragging a full-height riser, which renders as an unreadable
    // "comb" (the original complaint). WHOOP's chart reads cleanly because brief fragments are
    // absorbed into their surroundings AT DISPLAY TIME. This is render-only: totals, percentages
    // and stored data are computed from the raw segments elsewhere and are untouched.
    //
    // Pass `smoothingSeconds: 0` to render the raw timeline. Public so other stage-timeline
    // renderings (e.g. the WHOOP-style per-stage rows in SleepView) reuse the same smoothing.
    public static func displaySmoothed(_ sorted: [SleepInterval], minDuration: TimeInterval) -> [SleepInterval] {
        guard sorted.count > 2 else { return sorted }

        // Coalesce adjacent same-stage runs (also bridges the zero-length seams between epochs).
        func coalesce(_ ivs: [SleepInterval]) -> [SleepInterval] {
            var out: [SleepInterval] = []
            for iv in ivs {
                if let last = out.last, last.stage == iv.stage, iv.start - last.end < 1 {
                    out[out.count - 1] = SleepInterval(stage: last.stage, start: last.start, end: iv.end)
                } else {
                    out.append(iv)
                }
            }
            return out
        }

        var ivs = coalesce(sorted)
        // Repeatedly absorb the shortest sub-threshold fragment into its longer neighbour,
        // re-coalescing after each pass, until every remaining block clears the threshold.
        while ivs.count > 1 {
            guard let idx = ivs.indices
                .filter({ ivs[$0].duration < minDuration })
                .min(by: { ivs[$0].duration < ivs[$1].duration }) else { break }
            let victim = ivs[idx]
            let prev = idx > 0 ? ivs[idx - 1] : nil
            let next = idx < ivs.count - 1 ? ivs[idx + 1] : nil
            if let p = prev, let n = next {
                // Absorb into the longer neighbour so the dominant surrounding stage wins.
                if p.duration >= n.duration {
                    ivs[idx - 1] = SleepInterval(stage: p.stage, start: p.start, end: victim.end)
                } else {
                    ivs[idx + 1] = SleepInterval(stage: n.stage, start: victim.start, end: n.end)
                }
            } else if let p = prev {
                ivs[idx - 1] = SleepInterval(stage: p.stage, start: p.start, end: victim.end)
            } else if let n = next {
                ivs[idx + 1] = SleepInterval(stage: n.stage, start: victim.start, end: n.end)
            } else {
                break
            }
            ivs.remove(at: idx)
            ivs = coalesce(ivs)
        }
        return ivs
    }

    /// Index of the hovered interval, or nil.
    @State private var hoverIndex: Int? = nil

    private static let clockFormatter: DateFormatter = {
        // "jmm" respects the device's 12-/24-hour setting (#337) rather than forcing 24-hour.
        let f = DateFormatter(); f.locale = Locale.current; f.setLocalizedDateFormatFromTemplate("jmm"); return f
    }()

    /// Format a seconds-from-origin offset either as wall-clock (if nightStart
    /// is set) or as elapsed H:MM from the start of the night.
    private func timeLabel(_ secondsFromOrigin: TimeInterval) -> String {
        if let nightStart {
            let d = nightStart.addingTimeInterval(secondsFromOrigin - origin)
            return Hypnogram.clockFormatter.string(from: d)
        }
        let total = Int((secondsFromOrigin - origin).rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        return String(format: "%d:%02d", h, m)
    }

    private var span: TimeInterval {
        guard let first = intervals.first, let last = intervals.max(by: { $0.end < $1.end }) else { return 1 }
        return max(1, last.end - first.start)
    }
    private var origin: TimeInterval { intervals.first?.start ?? 0 }

    /// ONE spoken summary of the whole night for VoiceOver: total time in each stage. Replaces the old
    /// per-band accessibility layer (which emitted one element PER interval — O(intervals), a heavy
    /// semantics subtree the Compose/AppKit accessibility walk re-copied on every scroll, a contributor
    /// to the #707 OOM). Collapsing to one node keeps a clear screen-reader read-out at O(1) node cost.
    /// e.g. "Sleep stages, 2 hours deep, 1 hour 30 minutes REM, 3 hours light, 20 minutes awake".
    private var axSummary: String {
        guard !intervals.isEmpty else { return String(localized: "Sleep stages, no data", bundle: .module) }
        // Sum duration per stage in the natural read order (deep · REM · light · awake), naming only the
        // stages that actually occur so a night with no awake time doesn't read "0 minutes awake".
        var parts: [String] = []
        for stage in [SleepStage.deep, .rem, .light, .awake] {
            let total = intervals.filter { $0.stage == stage }.reduce(0.0) { $0 + $1.duration }
            if total > 0 { parts.append("\(Hypnogram.durationPhrase(total)) \(stage.label.lowercased())") }
        }
        return parts.isEmpty ? String(localized: "Sleep stages, no data", bundle: .module)
                             : String(localized: "Sleep stages, \(parts.joined(separator: ", "))", bundle: .module)
    }

    /// A spoken duration phrase ("2 hours 5 minutes", "45 minutes", "1 hour") for a seconds interval.
    private static func durationPhrase(_ seconds: TimeInterval) -> String {
        let total = Int((seconds / 60).rounded())   // whole minutes
        let h = total / 60
        let m = total % 60
        // Whole-phrase per unit (no "s"-suffix stitching) so each key can carry its own plural rule.
        func hours(_ n: Int) -> String { n == 1 ? String(localized: "1 hour", bundle: .module) : String(localized: "\(n) hours", bundle: .module) }
        func minutes(_ n: Int) -> String { n == 1 ? String(localized: "1 minute", bundle: .module) : String(localized: "\(n) minutes", bundle: .module) }
        if h > 0 && m > 0 { return "\(hours(h)) \(minutes(m))" }
        if h > 0 { return hours(h) }
        return minutes(max(m, 1))
    }

    // 4 stage rows; awake = rank 0 (top), deep = rank 3 (bottom).
    private let rowCount = 4

    /// The band/lane colour for a stage: the brand ramp (Garmin filled / Oura ribbon) when opted in, else
    /// the NOOP sleep tokens.
    private func stageColor(_ stage: SleepStage) -> Color {
        StrandPalette.sleepStageColor(stage, palette: stagePalette)
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if showsStageAxis { axis }
            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack {
                        // STATIC LAYER: baselines + time-axis hairlines + risers + the stage bands.
                        // These rebuild only when intervals/size/hover change, so flatten them into ONE
                        // cached GPU raster via .drawingGroup() — the bands are flat solid pills (no
                        // blur), so the raster is pixel-identical. The hover crosshair/ring/tooltip stay
                        // OUTSIDE this group (below). drawingGroup() strips child accessibility elements,
                        // and VoiceOver is served by ONE collapsed element on the plot (see `axSummary`
                        // applied below) — so the bands raster cheaply AND the accessibility walk never
                        // copies a per-band subtree (the old O(intervals) layer was a #707 contributor).
                        ZStack {
                            // Faint per-stage lanes (WHOOP): a subtle full-width band tinted with each
                            // stage's colour, so the eye maps height → stage even across gaps — the missing
                            // "context" the flat blob chart never gave. Replaces the old centre hairlines.
                            ForEach(0..<rowCount, id: \.self) { rank in
                                let stage = stagesTopToBottom[rank]
                                let rowStep = geo.size.height / CGFloat(rowCount)
                                // The highlighted stage's lane brightens (WHOOP's selected-stage wash).
                                let lane = highlightedStage == stage ? 0.16 : 0.07
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(stageColor(stage).opacity(lane))
                                    .frame(width: geo.size.width, height: rowStep * 0.74)
                                    .position(x: geo.size.width / 2, y: rowY(rank, in: geo.size.height))
                            }

                            // time-axis vertical hairlines: onset · midpoint · wake
                            if showsTimeAxis, nightStart != nil {
                                ForEach([0.0, 0.5, 1.0], id: \.self) { frac in
                                    let x = geo.size.width * frac
                                    Path { p in
                                        p.move(to: CGPoint(x: x, y: 0))
                                        p.addLine(to: CGPoint(x: x, y: geo.size.height))
                                    }
                                    .stroke(StrandPalette.hairline.opacity(0.4), lineWidth: 1)
                                }
                            }

                            // connecting risers
                            risers(in: geo.size)

                            // stage bands (visual only — a11y is the single collapsed plot summary below)
                            ForEach(Array(intervals.enumerated()), id: \.element.id) { idx, interval in
                                let band = bandRect(for: interval, in: geo.size)
                                // FILLED: extend the band from its lane centre down to the baseline so the
                                // night reads as a continuous stepped-area staircase. RIBBON: the slim band.
                                let rect = filled
                                    ? CGRect(x: band.minX, y: band.midY, width: band.width,
                                             height: max(0, geo.size.height - band.midY))
                                    : band
                                let color = stageColor(interval.stage)
                                let hoverDimmed = hoverIndex != nil && hoverIndex != idx
                                let stageDimmed = highlightedStage != nil && interval.stage != highlightedStage
                                // WHOOP hypnogram: squared segments — the night reads as one continuous
                                // step line (ribbon) or filled staircase. No pill caps: a brief stage draws
                                // at its true duration as a thin tick, never inflated into a dot. When a
                                // stage is highlighted (tap its legend row), everything else recedes.
                                RoundedRectangle(cornerRadius: filled ? 0 : 2.5, style: .continuous)
                                    .fill(color)
                                    .frame(width: rect.width, height: rect.height)
                                    .opacity(stageDimmed ? 0.22 : (hoverDimmed ? 0.45 : 1.0))
                                    .position(x: rect.midX, y: rect.midY)
                            }
                        }
                        // NO .drawingGroup() — flat solid pills are cheap to draw inline; the per-instance
                        // offscreen flatten was part of the v7.0.2 lag regression. The #707 accessibility
                        // collapse is served by `.accessibilityHidden(true)` below + the single plot summary.
                        .accessibilityHidden(true)

                        // Hover affordance: crosshair, band highlight ring, tooltip.
                        if showsHover, let idx = hoverIndex, idx < intervals.count {
                            let interval = intervals[idx]
                            let rect = bandRect(for: interval, in: geo.size)
                            let color = stageColor(interval.stage)
                            // vertical crosshair across the full height at band centre
                            CrosshairRule(x: rect.midX, height: geo.size.height)
                            // ring around the hovered band
                            RoundedRectangle(cornerRadius: (rect.height + 6) / 2)
                                .stroke(StrandPalette.hairlineStrong, lineWidth: 1.5)
                                .frame(width: rect.width + 6, height: rect.height + 6)
                                .position(x: rect.midX, y: rect.midY)
                            PositionedTooltip(
                                anchor: CGPoint(x: rect.midX, y: rect.midY),
                                container: geo.size,
                                tooltip: ChartTooltip(
                                    value: interval.stage.label,
                                    label: "\(timeLabel(interval.start))-\(timeLabel(interval.end)) · \(Int((interval.duration / 60).rounded()))m",
                                    accent: color
                                )
                            )
                        }
                    }
                    .animation(StrandMotion.fade, value: hoverIndex)
                    .animation(StrandMotion.fade, value: highlightedStage)
                    .contentShape(Rectangle())
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        guard showsHover else { return }
                        switch phase {
                        case .active(let location):
                            hoverIndex = intervalIndex(atX: location.x, in: geo.size)
                        case .ended:
                            hoverIndex = nil
                        }
                    }
                    // ONE collapsed VoiceOver element for the whole hypnogram (per-stage totals), instead
                    // of the old O(intervals) per-band layer the accessibility walk re-copied each scroll
                    // frame (#707). The visual bands already live in a `.drawingGroup()` marked
                    // `accessibilityHidden`, so this single summary is the only node the chart contributes.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(axSummary))
                }
                .frame(height: height)

                // x time axis: onset · midpoint · wake clock labels under the plot
                if showsTimeAxis, nightStart != nil {
                    HStack(spacing: 0) {
                        Text(timeLabel(origin)).frame(maxWidth: .infinity, alignment: .leading)
                        Text(timeLabel(origin + span / 2)).frame(maxWidth: .infinity, alignment: .center)
                        Text(timeLabel(origin + span)).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                }
            }
        }
    }

    /// The interval whose horizontal span contains a local x, or the nearest.
    private func intervalIndex(atX x: CGFloat, in size: CGSize) -> Int? {
        guard !intervals.isEmpty, size.width > 0 else { return nil }
        let t = origin + Double(x / size.width) * span
        // First try an exact containment hit.
        for (i, iv) in intervals.enumerated() where t >= iv.start && t <= iv.end {
            return i
        }
        // Otherwise snap to the nearest interval by centre time.
        return intervals.enumerated().min(by: { a, b in
            abs(midTime(a.element) - t) < abs(midTime(b.element) - t)
        })?.offset
    }

    private func midTime(_ iv: SleepInterval) -> TimeInterval { (iv.start + iv.end) / 2 }

    // MARK: Axis

    private var axis: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(stagesTopToBottom, id: \.self) { stage in
                Text(stage.label)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(width: 44, height: height)
    }

    private var stagesTopToBottom: [SleepStage] {
        [.awake, .rem, .light, .deep]
    }

    // MARK: Geometry

    private func rowY(_ rank: Int, in totalHeight: CGFloat) -> CGFloat {
        let usable = totalHeight
        let step = usable / CGFloat(rowCount)
        return step * (CGFloat(rank) + 0.5)
    }

    private func bandRect(for interval: SleepInterval, in size: CGSize) -> CGRect {
        let x0 = CGFloat((interval.start - origin) / span) * size.width
        let x1 = CGFloat((interval.end - origin) / span) * size.width
        // WHOOP ribbon: a slim, UNIFORM thickness — the night reads as one stepped line, not slabs.
        // (Fat rowStep-proportional slabs were the earlier blob regression; with display smoothing
        // capping the block count, a fixed slim ribbon is the WHOOP look.)
        let thickness: CGFloat = 12
        // Width is the TRUE duration, floored only at a hairline so a brief stage stays a visible
        // tick. Never floored to the thickness — that inflated short stages into dots.
        let width = max(2, x1 - x0)
        let mid = (x0 + x1) / 2
        let y = rowY(interval.stage.bandRank, in: size.height)
        return CGRect(x: mid - width / 2, y: y - thickness / 2, width: width, height: thickness)
    }

    // WHOOP-style transition connectors: thin, quiet vertical hairlines between consecutive stage
    // levels — present enough to trace the staircase, never competing with the ribbon segments.
    // They recede further while a stage is highlighted so the selected stage owns the chart.
    private func risers(in size: CGSize) -> some View {
        Path { p in
            for i in 0..<(intervals.count - (intervals.isEmpty ? 0 : 1)) {
                let a = intervals[i]
                let b = intervals[i + 1]
                let x = CGFloat((b.start - origin) / span) * size.width
                let ya = rowY(a.stage.bandRank, in: size.height)
                let yb = rowY(b.stage.bandRank, in: size.height)
                p.move(to: CGPoint(x: x, y: ya))
                p.addLine(to: CGPoint(x: x, y: yb))
            }
        }
        .stroke(StrandPalette.textTertiary.opacity(highlightedStage == nil ? 0.35 : 0.15),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }
}

/// A compact colour-coded key for a stepped hypnogram: one dot + label per stage in the chart's ramp, so a
/// reader can decode the bands — which is what makes the Garmin ramp's two pinks (Awake vs REM) legible.
/// (#sleep-chart-style)
///
/// NOTHING RENDERS THIS (#1536). Its only call sites put it above `stageBreakdownRows`, whose rows carry
/// their own labels — so it named stages already named, in a different order than the rows list them, and
/// in the chart ramp's colours while those rows use fixed `StrandPalette` tokens, which made its dots
/// disagree with the swatches directly beneath them on any non-NOOP ramp. Kept rather than deleted: it is
/// the only code that knows how to build this key, and a genuinely unlabelled hypnogram is what it is for.
/// Wire it to one of those, not to a labelled table.
public struct SleepStageLegend: View {
    public var palette: SleepStagePalette
    public init(palette: SleepStagePalette) { self.palette = palette }

    // Awake · REM · Light · Deep — the order Oura/Garmin list them.
    private let order: [SleepStage] = [.awake, .rem, .light, .deep]

    public var body: some View {
        HStack(spacing: 14) {
            ForEach(order, id: \.rawValue) { stage in
                HStack(spacing: 5) {
                    Circle()
                        .fill(StrandPalette.sleepStageColor(stage, palette: palette))
                        .frame(width: 8, height: 8)
                    Text(stage.label)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Decorative colour key — the breakdown rows below carry the same stages for VoiceOver.
        .accessibilityHidden(true)
    }
}

#if DEBUG
private func sampleNight() -> [SleepInterval] {
    // ~7.5h night, seconds.
    var t: TimeInterval = 0
    func add(_ stage: SleepStage, _ minutes: Double) -> SleepInterval {
        let s = SleepInterval(stage: stage, start: t, end: t + minutes * 60)
        t += minutes * 60
        return s
    }
    return [
        add(.awake, 6),
        add(.light, 22),
        add(.deep, 38),
        add(.light, 18),
        add(.rem, 24),
        add(.light, 14),
        add(.deep, 30),
        add(.rem, 28),
        add(.light, 20),
        add(.awake, 4),
        add(.rem, 32),
        add(.light, 26),
        add(.awake, 8),
    ]
}

#Preview("Hypnogram") {
    let start = Calendar.current.date(bySettingHour: 23, minute: 18, second: 0, of: Date())
    return VStack(alignment: .leading, spacing: 12) {
        Text("Last night").strandOverline()
        Text("Hover a band: stage name, clock start–end and duration.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        Hypnogram(intervals: sampleNight(), height: 200, nightStart: start)
    }
    .padding(28)
    .frame(width: 720, height: 340)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
#endif
