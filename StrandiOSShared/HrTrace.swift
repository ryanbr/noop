import Foundation

/// One point on the widget's heart-rate trace: when it was taken, and the bpm.
///
/// `Sendable` because a SwiftUI `Shape` holding these is itself Sendable, and the compiler warns that
/// carrying a non-Sendable stored property there is an error in a future language mode. Two immutable
/// value fields, so it is Sendable by inspection rather than by assertion.
public struct HrPoint: Codable, Equatable, Sendable {
    public let ts: Int64
    public let bpm: Int
    public init(ts: Int64, bpm: Int) {
        self.ts = ts
        self.bpm = bpm
    }
}

/// The pure half of the heart-rate widget: what the trace CONTAINS and where its ink goes.
///
/// Swift twin of the Kotlin `HrTrace`. The retention rule, the tick choices and the normalisation are
/// the same decisions on both platforms and must not be made twice — a trace that kept a different
/// window, or picked different labels, would be a different reading of the same heart.
///
/// What deliberately does NOT port is the bitmap sizing: `fitBox`, the byte budget and the 565 pixel
/// depth exist because Glance compiles to RemoteViews, cannot draw, and carries its payload over a
/// Binder transaction with a hard ceiling. WidgetKit is SwiftUI and strokes the trace as a vector, so
/// there is no bitmap to budget for and nothing here needs a pixel format.
///
/// `encode`/`decode` do not port either. Android packs the series into a SharedPreferences string
/// because that is what it has; the snapshot here is already Codable and carries `[HrPoint]` directly,
/// so a hand-rolled format would be a second encoding to keep correct for no gain.
public enum HrTrace {

    /// How much history the trace shows. Three hours matches what fits legibly at widget width.
    public static let windowSec: Int64 = 3 * 60 * 60

    /// One point per minute. The strap streams ~1/s; keeping every sample would put 10 800 points
    /// behind a trace a few hundred points wide, which costs space and buys nothing the eye resolves.
    public static let bucketSec: Int64 = 60

    /// What counts as a GAP. Deliberately NOT the Today chart's "more than one bucket": that chart reads
    /// a fixed DB grid, where a missing bucket really is missing data, while this series only gains a
    /// point when the app PUBLISHES one, and background scheduling routinely skips a minute. At a
    /// one-bucket threshold that ordinary jitter would shatter a healthy trace into dots, which is a
    /// worse lie than the joined line being fixed.
    ///
    /// Set to `HrDisplay.staleCap` rather than to a number picked here, so the line breaks exactly where
    /// the widget would already have dropped the headline reading for being too old to represent HR at
    /// all. `testTheGapThresholdMatchesTheStaleCap` pins the two together.
    public static let gapSec: Int64 = 15 * bucketSec

    /// Hard cap, so a clock jump backwards cannot grow the series without bound.
    public static let maxPoints = 200

    /// Fold a fresh reading into the series: one point per minute bucket, newest wins within a bucket.
    ///
    /// Newest-wins rather than an average because the widget's headline number is the LATEST bpm, and a
    /// trace whose last point disagreed with the number printed above it would read as a bug.
    public static func append(_ series: [HrPoint], ts: Int64, bpm: Int, nowSec: Int64? = nil) -> [HrPoint] {
        let now = nowSec ?? ts
        guard bpm > 0 else { return prune(series, nowSec: now) }
        let bucket = ts / bucketSec * bucketSec
        var out = series.filter { $0.ts != bucket }
        out.append(HrPoint(ts: bucket, bpm: bpm))
        // No sort here: `prune` sorts on the way out and has to anyway, since it is also the entry point
        // for a decoded series. Appending at the end is already in order for anything but a backwards
        // clock, and prune's sort is what makes even that correct.
        return prune(out, nowSec: now)
    }

    /// Drop anything older than the window, then anything beyond the cap (oldest first).
    public static func prune(_ series: [HrPoint], nowSec: Int64) -> [HrPoint] {
        let floor = nowSec - windowSec
        let kept = series.filter { $0.ts >= floor }.sorted { $0.ts < $1.ts }
        guard kept.count > maxPoints else { return kept }
        return Array(kept.suffix(maxPoints))
    }

    /// The three numbers the header shows. Nil when there is nothing to describe.
    public struct Stats: Equatable {
        public let min: Int
        public let max: Int
        public let latest: Int
    }

    public static func stats(_ series: [HrPoint]) -> Stats? {
        guard let first = series.first, let last = series.last else { return nil }
        var lo = first.bpm
        var hi = first.bpm
        for p in series {
            if p.bpm < lo { lo = p.bpm }
            if p.bpm > hi { hi = p.bpm }
        }
        return Stats(min: lo, max: hi, latest: last.bpm)
    }

    /// A point in the trace's drawing box, origin top-left.
    ///
    /// `startsRun` means LIFT THE PEN before this point: nothing was recorded for `gapSec` before it.
    /// The trace joined every point unconditionally, and because x is mapped by TIME rather than by
    /// index, a 90-minute disconnect inside the 3-hour window drew as one confident diagonal across
    /// half the widget. The gap was already the right width; it was the line across it that was never
    /// measured: the same defect #2082 describes on the Today sparkline, on a second surface.
    public struct Pt: Equatable {
        public let x: CGFloat
        public let y: CGFloat
        public let startsRun: Bool

        public init(x: CGFloat, y: CGFloat, startsRun: Bool = false) {
            self.x = x
            self.y = y
            self.startsRun = startsRun
        }
    }

    /// The trace split into runs of consecutive readings: each range is a stretch the strap recorded
    /// without a break, and the pen lifts between one run and the next. A series with no gaps is one
    /// run, which is the common case and draws exactly as it always did.
    public static func runs(_ points: [Pt]) -> [ClosedRange<Int>] {
        guard !points.isEmpty else { return [] }
        var out: [ClosedRange<Int>] = []
        var start = 0
        for i in 1..<points.count where points[i].startsRun {
            out.append(start...(i - 1))
            start = i
        }
        out.append(start...(points.count - 1))
        return out
    }

    /// The trace as coordinates inside a `width` x `height` box.
    ///
    /// Two degenerate shapes decide most of this, and both are ordinary rather than exotic — a widget
    /// placed mid-afternoon has one point, and a resting arm holds one bpm for minutes at a time:
    ///
    ///  - ONE point, or every point at the same instant: there is no time axis to spread across, so it
    ///    sits at the left edge rather than at x = NaN.
    ///  - every bpm equal: there is no range to scale into, so the line runs along the VERTICAL MIDDLE.
    ///    Pinning it to the top or bottom would read as a maxed-out or flatlined heart.
    ///
    /// Y is flipped on the way out: bpm rises upward, screen coordinates rise downward.
    public static func points(_ series: [HrPoint], width: CGFloat, height: CGFloat) -> [Pt] {
        guard !series.isEmpty, width > 0, height > 0,
              let t0 = series.first?.ts, let t1 = series.last?.ts else { return [] }
        let span = CGFloat(t1 - t0)
        var lo = series[0].bpm
        var hi = series[0].bpm
        for p in series {
            if p.bpm < lo { lo = p.bpm }
            if p.bpm > hi { hi = p.bpm }
        }
        let range = CGFloat(hi - lo)
        return series.enumerated().map { i, p in
            let x = span <= 0 ? 0 : CGFloat(p.ts - t0) / span * width
            let y = range <= 0 ? height / 2 : height - CGFloat(p.bpm - lo) / range * height
            return Pt(x: x, y: y, startsRun: i > 0 && p.ts - series[i - 1].ts > gapSec)
        }
    }

    /// The three bpm labels down the right edge: max, midpoint, min, stacked as they appear.
    ///
    /// A flat series returns the same number three times rather than an invented spread — the honest
    /// reading of a steady heart is one number. The VIEW declines to draw a scale in that case; the
    /// rule stays here so both platforms agree on what the labels would be.
    public static func bpmTicks(_ stats: Stats) -> [Int] {
        [stats.max, (stats.min + stats.max + 1) / 2, stats.min]
    }

    /// The three timestamps along the bottom: first, middle, last of the DATA, not of the window.
    ///
    /// Anchored to the data because a widget holding forty minutes of history would otherwise label its
    /// axis with two hours that were never sampled. Fewer than three distinct instants returns what
    /// there is, so the view draws one label rather than three copies of it.
    public static func timeTicks(_ series: [HrPoint]) -> [Int64] {
        guard let first = series.first?.ts, let last = series.last?.ts else { return [] }
        if first == last { return [first] }
        let mid = first + (last - first) / 2
        if mid == first || mid == last { return [first, last] }
        return [first, mid, last]
    }
}

/// What heart rate the widget should SHOW, given how long ago it was actually measured.
///
/// Twin of the Kotlin `HrDisplay`, and the reason it exists is the same on both platforms: a snapshot
/// carries the last reading indefinitely, so without an age rule a widget renders an hours-old number as
/// though it were current.
///
/// Anchored to the newest TRACE POINT rather than to the snapshot's `updated`, which is the closer twin
/// of Android reading its own `hrAt`. A publish happens for battery or score changes too, so `updated`
/// refreshes without a new reading and would make a stale heart look fresh.
public enum HrDisplay {
    /// Past this without a newer reading the number is DIMMED: still shown, no longer claimed as live.
    public static let liveWindow: TimeInterval = 2 * 60

    /// Past this it is dropped entirely — too old to stand for the wearer at all.
    public static let staleCap: TimeInterval = 15 * 60

    /// - Returns: the bpm to show (nil to show nothing) and whether it is a carried-over reading.
    public static func resolve(bpm: Int?, newestPointTs: Int64?, now: Date) -> (bpm: Int?, stale: Bool) {
        guard let bpm, bpm > 0 else { return (nil, false) }
        // No trace yet is the FIRST reading, not an old one: a widget added this minute has a bpm and an
        // empty series, and dropping the number there would blank a widget that just started working.
        guard let newestPointTs else { return (bpm, false) }
        let age = now.timeIntervalSince1970 - TimeInterval(newestPointTs)
        if age > staleCap { return (nil, false) }
        return (bpm, age > liveWindow)
    }
}
