import StrandDesign
import SwiftUI
import WidgetKit

/// Home-screen widget: today's stress as the intraday curve the Stress screen draws (#2040).
///
/// Swift twin of the Android `StressGlanceWidget`, but the drawing is NOT a port. Glance compiles to
/// RemoteViews and cannot draw, so Android renders the curve to a Bitmap under a payload budget and a
/// reduced pixel depth, and has to composite every translucent colour by hand because 565 carries no
/// alpha. WidgetKit is SwiftUI: stroked `Path`s, resolution-independent, with real opacity. What IS
/// shared is `StressTrace` — the fixed domain, the gap rule, the band threshold and the tick choices —
/// because those are the same reading of the same day.
///
/// Honest-blank throughout, matching the twin: an unscored hour is a GAP rather than an interpolation,
/// an hour the motion gate masked gets a faint mark along the base instead of a score, and a day with
/// nothing scored shows no chart at all rather than a flat line at zero.
struct StressEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot?
}

struct StressProvider: TimelineProvider {
    func placeholder(in context: Context) -> StressEntry {
        StressEntry(date: Date(), snap: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (StressEntry) -> Void) {
        completion(StressEntry(date: Date(), snap: WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StressEntry>) -> Void) {
        let entry = StressEntry(date: Date(), snap: WidgetSnapshot.load())
        // Half an hour, where the heart-rate widget takes fifteen minutes. This curve gains at most one
        // point an hour, so a tighter net would spend budget on entries identical to the one before it.
        // The app reloads timelines when it scores an hour, so this is only the safety net for when it
        // is not running — and it also carries the card across midnight, when the day number changes and
        // yesterday's curve stops being drawn.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date())
            ?? Date().addingTimeInterval(1_800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

/// The curve: every contiguous run of scored hours as its own subpath.
///
/// Runs rather than one path because an unscored hour is a hole, and a line drawn across it would
/// invent a reading. When `filled` each run is closed to the baseline SEPARATELY, so the area cannot
/// spread under hours that were never scored, which would undo the gap the broken line exists to draw.
private struct StressCurveShape: Shape {
    let series: [StressPoint]
    let filled: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for run in StressTrace.segments(series, width: rect.width, height: rect.height) {
            guard let first = run.first else { continue }
            if run.count == 1 {
                // A run of one hour is not a line. A dot says "one scored hour"; an empty box says
                // "no data", and those are different things.
                guard !filled else { continue }
                let r: CGFloat = 2.5
                path.addEllipse(in: CGRect(x: max(first.x, r) - r, y: first.y - r,
                                           width: r * 2, height: r * 2))
                continue
            }
            path.move(to: CGPoint(x: first.x, y: first.y))
            for p in run.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
            if filled {
                path.addLine(to: CGPoint(x: run[run.count - 1].x, y: rect.maxY))
                path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
                path.closeSubpath()
            }
        }
        return path
    }
}

/// The hours sitting in the HIGH band, dotted above the line as the screen marks them.
private struct StressHighDotsShape: Shape {
    let series: [StressPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r: CGFloat = 2
        for p in StressTrace.highPoints(series, width: rect.width, height: rect.height) {
            // Lifted clear of the stroke so a dot is never half-hidden under the line it marks.
            let y = max(p.y - 5, r)
            path.addEllipse(in: CGRect(x: min(max(p.x, r), rect.maxX - r) - r, y: y - r,
                                       width: r * 2, height: r * 2))
        }
        return path
    }
}

/// The stretches the motion gate masked, marked along the base rather than scored.
private struct StressMovingMarksShape: Shape {
    let series: [StressPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let half: CGFloat = 3
        for x in StressTrace.movingMarks(series, width: rect.width) {
            path.addRoundedRect(
                in: CGRect(x: max(x - half, 0), y: rect.minY,
                           width: min(half * 2, rect.width), height: rect.height),
                cornerSize: CGSize(width: half, height: half),
            )
        }
        return path
    }
}

struct StressWidgetView: View {
    let entry: StressEntry

    /// Resolved on read, so a curve scored for a day that is over is dropped rather than drawn. Measured
    /// from `entry.date` rather than `Date()` because WidgetKit renders an entry at ITS date, which is
    /// the same reasoning the heart-rate widget's prune follows.
    private var series: [StressPoint] {
        entry.snap?.stressCurve(now: entry.date) ?? []
    }
    private var stats: StressTrace.Stats? { StressTrace.stats(series) }
    private var latest: Double? { series.last(where: { $0.level != nil })?.level }

    // The ramp's band anchors, taken from the palette tokens the Stress screen's own ramp is built from,
    // rather than the local hexes the Glance twin has to carry. Blue calm, green steady, amber tense.
    private var calm: Color { StrandPalette.accent }
    private var steady: Color { StrandPalette.statusPositive }
    private var tense: Color { StrandPalette.statusWarning }

    /// Vertical, because `StressTrace.segments` maps the score onto Y off a FIXED domain: height already
    /// encodes level, so one top-to-bottom gradient paints every run the colour its own score deserves.
    /// The screen's ramp read upward.
    private var rampGradient: LinearGradient {
        LinearGradient(colors: [tense, steady, calm], startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stress")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(StrandPalette.textPrimary)

            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(latest.map { String(format: "%.1f", $0) } ?? "—")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(StrandPalette.textPrimary)
                if latest != nil {
                    Text("of 3")
                        .font(.system(size: 12))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                if let stats, let peak = stats.peak.level {
                    // "Peak" is a catalog key the app already carries in every locale; the value and the
                    // time are DATA, so they are formatted into a plain String and shown verbatim. That
                    // keeps a translator's job to the word that has one, and adds no catalog entry for a
                    // string that is otherwise punctuation.
                    let peakTime = Date(timeIntervalSince1970: TimeInterval(stats.peak.ts))
                        .formatted(date: .omitted, time: .shortened)
                    HStack(spacing: 4) {
                        Text("Peak")
                        Text(verbatim: String(format: "%.1f", peak) + " · " + peakTime)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(tense.opacity(0.18), in: Capsule())
                    .padding(.leading, 6)
                }
            }

            if stats != nil {
                HStack(alignment: .top, spacing: 6) {
                    // The scale sits on the LEFT, where the Stress screen puts it. (The heart-rate
                    // widget puts its scale on the right, which is right for a trace whose numbers are
                    // read off the end.) Fixed rather than derived, because that is what the domain is:
                    // an axis that moved with the day would make two days impossible to compare.
                    let ticks = StressTrace.levelTicks()
                    VStack(alignment: .trailing) {
                        ForEach(Array(ticks.enumerated()), id: \.offset) { index, tick in
                            Text("\(tick)")
                                .font(.system(size: 10))
                                .foregroundStyle(StrandPalette.textSecondary)
                            if index < ticks.count - 1 { Spacer(minLength: 0) }
                        }
                    }
                    StressCurveChart(series: series, ramp: rampGradient,
                                     fillTint: steady, dotTint: tense)
                }
                StressTimeAxis(series: series)
            }

            Spacer(minLength: 0)
            if let updated = entry.snap?.updated, updated != .distantPast {
                HStack {
                    Spacer()
                    // Both halves are catalog keys the app already carries, `avg %@` and `Updated %@`,
                    // joined by a separator with nothing in it to translate. One composite key would have
                    // needed a new entry in ten locales to say what these two already say.
                    if let stats {
                        HStack(spacing: 0) {
                            Text("avg \(String(format: "%.1f", stats.mean))")
                            Text(verbatim: " · ")
                            Text("Updated \(updated, format: .dateTime.hour().minute())")
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(StrandPalette.textSecondary)
                    } else {
                        Text("Updated \(updated, format: .dateTime.hour().minute())")
                            .font(.system(size: 10))
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer()
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// One spoken sentence rather than a run of loose numbers, the same choice the heart-rate widget
    /// makes. `String(localized:)` rather than bare literals: the audit matches a literal sitting
    /// immediately after `.accessibilityLabel(`, and this is a computed property, so hardcoded English
    /// here would ship to every locale with the gate green.
    private var accessibilityText: String {
        guard let latest else { return String(localized: "Stress, no reading today") }
        let now = String(format: "%.1f", latest)
        guard let stats, let peak = stats.peak.level else {
            return String(localized: "Stress \(now) of 3")
        }
        let peakText = String(format: "%.1f", peak)
        let meanText = String(format: "%.1f", stats.mean)
        return String(localized: "Stress \(now) of 3, average \(meanText), peak \(peakText)")
    }
}

/// The chart: fill, stroke, high-band dots, and the movement strip beneath them.
///
/// The marks get their OWN row rather than a reserved band inside the chart's coordinate space. The
/// Glance twin has to carve the band out of one bitmap and normalise around it, which is exactly where
/// that side went wrong once; here a `VStack` gives each part its own rect and the arithmetic
/// disappears.
private struct StressCurveChart: View {
    let series: [StressPoint]
    let ramp: LinearGradient
    let fillTint: Color
    let dotTint: Color

    private var hasMarks: Bool { series.contains(where: \.moving) }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                StressCurveShape(series: series, filled: true)
                    .fill(LinearGradient(
                        colors: [fillTint.opacity(0.3), fillTint.opacity(0)],
                        startPoint: .top, endPoint: .bottom,
                    ))
                StressCurveShape(series: series, filled: false)
                    .stroke(ramp, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                StressHighDotsShape(series: series)
                    .fill(dotTint)
            }
            if hasMarks {
                StressMovingMarksShape(series: series)
                    .fill(StrandPalette.textSecondary.opacity(0.45))
                    .frame(height: 3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StressTimeAxis: View {
    let series: [StressPoint]

    var body: some View {
        let ticks = StressTrace.timeTicks(series)
        // One instant pinned to the left edge reads as a stray rather than an axis, so it waits for a
        // span to label, matching the twin.
        if ticks.count >= 2 {
            HStack {
                ForEach(Array(ticks.enumerated()), id: \.offset) { i, ts in
                    Text(Date(timeIntervalSince1970: TimeInterval(ts)),
                         format: .dateTime.hour().minute())
                        .font(.system(size: 9))
                        .foregroundStyle(StrandPalette.textSecondary)
                    if i < ticks.count - 1 { Spacer(minLength: 0) }
                }
            }
        }
    }
}

struct StressWidget: Widget {
    static let kind = "StressWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: StressProvider()) { entry in
            if #available(iOS 17.0, *) {
                StressWidgetView(entry: entry)
                    .containerBackground(StrandPalette.surfaceBase, for: .widget)
            } else {
                StressWidgetView(entry: entry)
                    .padding()
                    .background(StrandPalette.surfaceBase)
            }
        }
        .configurationDisplayName("Stress")
        .description("Today's stress as an hour-by-hour curve.")
        .supportedFamilies([.systemMedium])
    }
}
