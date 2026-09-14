import Foundation

/// One hour on the widget's stress trace.
///
/// `level` is the shared 0-3 proxy, nil when the hour was not scored. `moving` separates the two
/// reasons it can be nil: the motion gate masked an AMBULATORY hour (exertion raises heart rate on its
/// own, so it is deliberately not scored as stress), or there was not enough signal. Both break the
/// line; only the first earns a mark along the base.
///
/// `Sendable` for the same reason `HrPoint` is: a SwiftUI `Shape` holding these is itself Sendable, and
/// carrying a non-Sendable stored property there is an error in a future language mode. Three immutable
/// value fields, so it is Sendable by inspection rather than by assertion.
public struct StressPoint: Codable, Equatable, Sendable {
    public let ts: Int64
    public let level: Double?
    public let moving: Bool
    public init(ts: Int64, level: Double?, moving: Bool = false) {
        self.ts = ts
        self.level = level
        self.moving = moving
    }
}

/// The pure half of the stress widget: what the curve CONTAINS and where its ink goes.
///
/// Swift twin of the Kotlin `StressTrace`. The domain, the gap rule, the band threshold and the tick
/// choices are the same decisions on both platforms and must not be made twice: a widget that scaled
/// differently, or drew through a hole, would be a different reading of the same day.
///
/// TWO THINGS DIFFER FROM `HrTrace`, and both are deliberate.
///
/// The domain is FIXED at `domainMax`, not normalised to the day's own range. Heart rate has no
/// absolute meaning at widget size, so its trace spreads whatever range it has across the full box. A
/// stress score does have one: the bands are what the number means. Normalising here would redraw a
/// flat calm day as a dramatic one, which is precisely the lie the fixed domain prevents.
///
/// And the series is REPLACED rather than appended to. The HR trace folds a live push into a rolling
/// window; today's stress is a whole scored day that arrives complete each time it is scored, so there
/// is no retention rule, no clock-jump guard and no cap. Yesterday is overwritten, not merged.
///
/// What deliberately does NOT port is Android's `encode`/`decode`: it packs the series into a
/// SharedPreferences string because that is what it has, while the snapshot here is already `Codable`
/// and carries `[StressPoint]` directly. Nor does the bitmap sizing, for the reason `HrTrace` gives:
/// WidgetKit strokes a vector and has no payload budget to fit inside.
public enum StressTrace {

    /// Top of the scored range, the same 0-3 scale the gauge and the screen use.
    public static let domainMax: Double = 3.0

    /// Floor of the HIGH band, the level at which an hour earns a dot.
    ///
    /// This is `StrandAnalytics.DaytimeStress.highBandFloor`, RESTATED rather than referenced, because
    /// the widget extension links no packages: everything it draws with has to live in shared sources
    /// that import Foundation and nothing else. Android has no such wall and reads the analytics
    /// constant directly, so this is the one place the two platforms express the same threshold
    /// differently. `StressTraceTests` asserts the two are equal from the app target, which can see
    /// both, so the copy cannot drift silently.
    public static let highBandFloor: Double = 2.0

    /// A point in the curve's box, origin top-left.
    public struct Pt: Equatable, Sendable {
        public let x: CGFloat
        public let y: CGFloat
        public init(x: CGFloat, y: CGFloat) {
            self.x = x
            self.y = y
        }
    }

    /// The numbers the header shows. Nil when no hour was scored.
    public struct Stats: Equatable, Sendable {
        /// Mean across SCORED hours, the figure the screen prints as the day's average.
        public let mean: Double
        /// Highest scored hour.
        public let peak: StressPoint
        /// How many hours carry a score.
        public let scoredHours: Int
        /// How many were masked as movement rather than scored.
        public let movingHours: Int
    }

    public static func stats(_ series: [StressPoint]) -> Stats? {
        let scored = series.filter { $0.level != nil }
        guard let first = scored.first else { return nil }
        var peak = first
        var sum = 0.0
        for p in scored {
            sum += p.level ?? 0
            if (p.level ?? 0) > (peak.level ?? 0) { peak = p }
        }
        return Stats(mean: sum / Double(scored.count),
                     peak: peak,
                     scoredHours: scored.count,
                     movingHours: series.filter(\.moving).count)
    }

    /// The one placement rule, shared so a dot and its vertex cannot land apart.
    private static func place(ts: Int64, level: Double, t0: Int64, span: CGFloat,
                              width: CGFloat, height: CGFloat) -> Pt {
        let x = span <= 0 ? 0 : CGFloat(ts - t0) / span * width
        let fraction = min(max(CGFloat(level / domainMax), 0), 1)
        return Pt(x: x, y: height - fraction * height)
    }

    /// The curve as CONTIGUOUS RUNS of scored hours, each already in the box's coordinates.
    ///
    /// Runs rather than one list because an unscored hour is a hole in the day, and a line drawn
    /// straight across it would invent a reading for an hour that has none. The screen's own caption
    /// promises bare gaps, so the widget owes the same.
    ///
    /// X is placed on the hour's position in the day's SPAN, so an afternoon hole leaves a hole of the
    /// right width rather than closing up. A single scored hour, or a day whose hours share one
    /// timestamp, has no span to spread across and sits at the left edge.
    ///
    /// Y comes off the FIXED domain, so a calm day draws along the bottom where it belongs, and is
    /// flipped on the way out: stress rises upward, points rise downward.
    public static func segments(_ series: [StressPoint], width: CGFloat, height: CGFloat) -> [[Pt]] {
        guard let firstPoint = series.first, let lastPoint = series.last,
              width > 0, height > 0 else { return [] }
        let t0 = firstPoint.ts
        let span = CGFloat(lastPoint.ts - t0)
        var out: [[Pt]] = []
        var run: [Pt] = []
        for p in series {
            guard let level = p.level else {
                if !run.isEmpty { out.append(run); run = [] }
                continue
            }
            run.append(place(ts: p.ts, level: level, t0: t0, span: span, width: width, height: height))
        }
        if !run.isEmpty { out.append(run) }
        return out
    }

    /// The scored hours sitting in the HIGH band, for the dots the screen puts above the line.
    ///
    /// Mapped through the same placement as `segments`, so a dot lands exactly on its own vertex.
    public static func highPoints(_ series: [StressPoint], width: CGFloat, height: CGFloat) -> [Pt] {
        guard let firstPoint = series.first, let lastPoint = series.last,
              width > 0, height > 0 else { return [] }
        let t0 = firstPoint.ts
        let span = CGFloat(lastPoint.ts - t0)
        return series.compactMap { p in
            guard let level = p.level, level >= highBandFloor else { return nil }
            return place(ts: p.ts, level: level, t0: t0, span: span, width: width, height: height)
        }
    }

    /// The hours masked as movement, grouped into CONTIGUOUS x ranges, for the marks along the base.
    ///
    /// A run rather than a mark per hour, because a run says which STRETCH of the day was masked, and
    /// that is what a reader needs when they are looking at a hole in the trace and trying to work out
    /// what put it there. The reason it matters was reported rather than theorised: a wearer saw the
    /// gaps, read the evenly spaced marks along the zero line as axis ticks, concluded the data itself
    /// was missing, and asked whether continuous HRV tracking would fill them in. One bar under the
    /// stretch it explains cannot be mistaken for a scale, because a scale does not start and stop with
    /// the data.
    ///
    /// Adjacency is by POSITION in the series, not by timestamp arithmetic: the series is already the
    /// hour grid the chart draws, so two neighbouring entries are two neighbouring hours by construction.
    ///
    /// A span runs edge to edge of the hours it covers, NOT centre to centre. An hour is a stretch of the
    /// day, not an instant, and the difference is the whole case for the shape: centre to centre gives a
    /// lone masked hour a width of zero, which is exactly the hour that most needs to be legible, since
    /// there are no neighbours to make it obvious. Edges are the MIDPOINT to each neighbour rather than a
    /// fixed slot, so an irregular series (a DST-long day, an hour missing from the list entirely) still
    /// gets honest extents. At the ends of the series the territory stops at the point itself: the day's
    /// extent is what was sampled, nothing is invented past it, and every span stays inside the box
    /// without a clamp.
    ///
    /// The upper edge is floored to the lower one. On a sorted series it never binds, but the two
    /// platforms disagree about what an inverted range means, Kotlin yielding an empty one where Swift
    /// traps, and a twin that crashes on one side and shrugs on the other is not a twin.
    public static func movingSpans(_ series: [StressPoint], width: CGFloat) -> [ClosedRange<CGFloat>] {
        guard let firstPoint = series.first, let lastPoint = series.last, width > 0 else { return [] }
        let t0 = firstPoint.ts
        let span = CGFloat(lastPoint.ts - t0)
        let xs = series.map { span <= 0 ? CGFloat(0) : CGFloat($0.ts - t0) / span * width }
        let last = series.count - 1
        func leftEdge(_ i: Int) -> CGFloat { i == 0 ? xs[0] : (xs[i - 1] + xs[i]) / 2 }
        func rightEdge(_ i: Int) -> CGFloat { i == last ? xs[last] : (xs[i] + xs[i + 1]) / 2 }
        var out: [ClosedRange<CGFloat>] = []
        var runStart: Int?
        for i in series.indices {
            let moving = series[i].moving
            if moving, runStart == nil { runStart = i }
            // A run closes at the first hour that is NOT moving, and also at the end of the series, or
            // a day whose last hours were all masked would be dropped for want of a terminator.
            if let from = runStart, !moving || i == last {
                let lo = leftEdge(from)
                out.append(lo...max(rightEdge(moving ? i : i - 1), lo))
                runStart = nil
            }
        }
        return out
    }

    /// The labels up the left edge, top-down: the top of the domain down to zero.
    ///
    /// Fixed, not derived, for the same reason the domain is: these are the scale, and an axis that
    /// moved with the day would make two days impossible to compare at a glance.
    public static func levelTicks() -> [Int] { [3, 2, 1, 0] }

    /// The three timestamps along the bottom: first, middle and last of the SERIES.
    ///
    /// The series, not the scored hours, because these label the AXIS, and the axis IS the series: every
    /// placement in this file maps x across `first.ts ... last.ts`, and every renderer spreads these
    /// three labels evenly across that same width. Anchoring them to the scored subset instead put the
    /// last SCORED instant at the right-hand edge, so a day whose closing hours were all masked as
    /// movement announced that it ended when scoring stopped rather than when the day did.
    ///
    /// That is the second half of #2106, and it was read exactly as it was drawn: a chart running to
    /// 22:00 labelled "18:30" at its right edge, reported as the app having stopped updating. The
    /// trailing hours were there the whole time, masked as exertion. Only the axis disagreed.
    ///
    /// The rationale this replaces was that an evening-only wearer would otherwise be labelled with a
    /// morning that was never sampled. The buckets are built FROM the samples, so the series carries no
    /// unsampled hours to begin with, and the curve was already spread across the series either way.
    /// The labels were the only part that ever disagreed with the geometry.
    ///
    /// Fewer than three distinct instants returns what there is, so the caller draws one label rather
    /// than three copies of it.
    public static func timeTicks(_ series: [StressPoint]) -> [Int64] {
        guard let first = series.first?.ts, let last = series.last?.ts else { return [] }
        if first == last { return [first] }
        let mid = first + (last - first) / 2
        return (mid == first || mid == last) ? [first, last] : [first, mid, last]
    }
}
