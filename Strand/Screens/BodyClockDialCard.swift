import SwiftUI
import StrandAnalytics
import StrandDesign

/// A 24 h dial comparing the night actually slept against the chronotype-ideal window (#1680).
///
/// Two concentric arcs on one ring: the outer is where the body clock wanted the night, the inner is
/// where it happened. Overlap is the whole message — the card exists so "was last night's timing right"
/// is answerable at a glance, which the existing text-only `BodyClockCard` on Health cannot do.
///
/// VOCABULARY. The caption measures `sleepWindowOffsetHours` — the distance between the two ARCS DRAWN —
/// and NOT `offsetVsScheduleMinutes`, which compares the clock to the wearer's habitual schedule and is
/// what the Health card already reports. The two disagree exactly when someone keeps a consistent
/// schedule that does not suit their clock, and that is the case this dial exists to show, so captioning
/// it with the other number would contradict the picture.
///
/// Nothing here computes a metric: the window, the offset and the chronotype all come from
/// `CircadianEngine`, byte-identical with the Kotlin twin. Only the drawing is per-platform.
struct BodyClockDialCard: View {
    let estimate: CircadianEngine.PhaseEstimate
    /// The night's own bed/wake clock hours (0..<24, fractional), from the scored session.
    let actualBedHour: Double
    let actualWakeHour: Double

    // One hue for both arcs, told apart by dash and weight rather than by a second colour. Two blues
    // competed with the background image; a single legible one plus a dashed, lighter reference does not.
    private var hue: Color { StrandPalette.restLine }

    /// The night's length, taken the long way round the clock when it crosses midnight.
    private var durationHours: Double {
        let d = (actualWakeHour - actualBedHour).truncatingRemainder(dividingBy: 24)
        return d <= 0 ? d + 24 : d
    }

    private var ideal: (bedHour: Double, wakeHour: Double)? {
        CircadianEngine.idealSleepWindow(tempMinHour: estimate.tempMinHour, durationHours: durationHours)
    }

    private var offsetHours: Double {
        CircadianEngine.sleepWindowOffsetHours(tempMinHour: estimate.tempMinHour,
                                               actualWakeHour: actualWakeHour)
    }

    var body: some View {
        // `ideal` is nil exactly when the night's length is non-positive or a full day — the same input
        // that makes `sweep` wrap to 24 h and draw the actual arc as a complete ring. Rendering a full
        // circle with no ideal arc beside it would state something false about the night, so the card
        // stands down instead. Twin of the Kotlin guard.
        if ideal != nil {
            NoopCard(tint: hue) {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    header
                    dial
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        // Label only. The verdict is the caption Text below, a separate element, so giving
                        // the dial the same string as its VALUE made VoiceOver announce it twice.
                        .accessibilityLabel(Text("Body clock dial"))
                    legend
                    Text(alignmentText)
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let chronotype = CircadianEngine.chronotype(estimate) {
                        Text(chronotypeText(chronotype))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Body clock").strandOverline()
                Text("Last night against your clock")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
        }
    }

    /// Midnight at the top, clocking round to the right — the orientation every 24 h dial uses, so the
    /// ring reads without a legend. SwiftUI's zero angle is at 3 o'clock, hence the −90.
    private func angle(_ hour: Double) -> Angle { .degrees(hour / 24 * 360 - 90) }

    /// Sweep from `from` to `to` going clockwise, always positive so an arc crossing midnight still draws.
    private func sweep(_ from: Double, _ to: Double) -> Double {
        let d = (to - from).truncatingRemainder(dividingBy: 24)
        return d <= 0 ? d + 24 : d
    }

    /// The ring geometry, resolved once. Explicitly typed and hoisted out of the drawing closure: an
    /// 84-line `Canvas` body of inferred `CGFloat` arithmetic exceeded the Swift type-checker's budget
    /// and failed the macOS build outright ("unable to type-check this expression in reasonable time"),
    /// which only app-build compiles — the same trap `DevicesView`'s gates hit.
    ///
    /// The radii are NAMED BANDS rather than two numbers because the previous pair collided: the
    /// reference arc was stroked at `outer`, the same radius the six-hour ticks occupy, so on a window
    /// spanning midnight the dashes ran straight into the ticks (#2350). Each band now owns a radius and
    /// a width, and `BodyClockDialLayoutTests` asserts they cannot overlap, which is the part of "does
    /// this look right" that arithmetic can actually settle.
    private struct DialGeometry {
        let centre: CGPoint
        let outer: CGFloat
        let labelRadius: CGFloat
        let reference: CGFloat
        let night: CGFloat
        let glyphRadius: CGFloat

        /// Tick lengths, the numeral band, and the two arc widths. Shared with the Kotlin twin verbatim.
        /// The rim the band offsets were tuned against: a 200 pt card, so `side / 2 - 10`.
        static let tunedRim: CGFloat = 90
        static let midnightTick: CGFloat = 6
        static let regularTick: CGFloat = 4
        static let referenceWidth: CGFloat = 7
        static let nightWidth: CGFloat = 9
        static let glyph: CGFloat = 12

        /// The band offsets are a FRACTION of the available radius, not fixed subtractions.
        ///
        /// Fixed offsets make the nesting depth constant at 58 pt whatever the canvas is, so a narrow
        /// card drives the inner bands through the centre and then negative: below about 136 pt the bed
        /// lands on the centre, and below 110 the night arc radius is negative, which is undefined for
        /// `addArc` and draws nothing in the Kotlin twin. `side` is `min(width, height)` and the height
        /// is pinned, so width alone decides it. Scaling keeps the tuned proportions at the shipping
        /// size (the factor is exactly 1 at rim 90) and every band stays positive for any rim, since the
        /// deepest is 58/90 of it.
        init(size: CGSize) {
            let side: CGFloat = min(size.width, size.height)
            centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let rim: CGFloat = side / 2 - 10
            let scale: CGFloat = rim / DialGeometry.tunedRim
            outer = rim
            labelRadius = rim - 15 * scale
            reference = rim - 31 * scale
            night = rim - 45 * scale
            glyphRadius = rim - 58 * scale
        }
    }

    private var dial: some View {
        Canvas { ctx, size in
            let g = DialGeometry(size: size)
            drawTrack(ctx, g)
            drawTicks(ctx, g)
            drawHourLabels(ctx, g)
            drawArcs(ctx, g)
            drawOnset(ctx, g)
        }
        .frame(height: 200)
    }

    /// A full-circle TRACK under the night arc, the same idiom `RecoveryRing` uses: a faint
    /// `surfaceInset` band with the live arc drawn on top. A one-point hairline left the dial reading as
    /// a thin wireframe against a busy background; a real track gives the ring presence and makes the
    /// highlighted segment obvious as a portion of a whole day. The rim hairline is the circle the TICKS
    /// belong to; it no longer doubles as the reference arc's circle, because that arc moved inward to
    /// its own band (#2350) and sharing a radius with the ticks was the collision being removed.
    private func drawTrack(_ ctx: GraphicsContext, _ g: DialGeometry) {
        let trackRect = CGRect(x: g.centre.x - g.night, y: g.centre.y - g.night,
                               width: g.night * 2, height: g.night * 2)
        ctx.stroke(Path(ellipseIn: trackRect), with: .color(StrandPalette.surfaceInset),
                   style: StrokeStyle(lineWidth: 9, lineCap: .round))
        let rimRect = CGRect(x: g.centre.x - g.outer, y: g.centre.y - g.outer,
                             width: g.outer * 2, height: g.outer * 2)
        ctx.stroke(Path(ellipseIn: rimRect), with: .color(StrandPalette.hairline), lineWidth: 1)
    }

    /// Six-hourly ticks, with MIDNIGHT drawn longer and brighter. Four identical marks at 90 degrees
    /// orient nothing — the ring is symmetric under rotation as far as they are concerned, so a reader
    /// cannot tell midnight from noon and the arcs become unplaceable. One distinguished mark anchors the
    /// whole dial, and does it without text, keeping the card clear of a 12-versus-24-hour format question.
    private func drawTicks(_ ctx: GraphicsContext, _ g: DialGeometry) {
        for tick in stride(from: 0.0, to: 24.0, by: 6.0) {
            let isMidnight: Bool = tick == 0
            let a: Double = angle(tick).radians
            let len: CGFloat = isMidnight ? DialGeometry.midnightTick : DialGeometry.regularTick
            let cosA: CGFloat = cos(a)
            let sinA: CGFloat = sin(a)
            var p = Path()
            p.move(to: CGPoint(x: g.centre.x + cosA * (g.outer - len),
                               y: g.centre.y + sinA * (g.outer - len)))
            p.addLine(to: CGPoint(x: g.centre.x + cosA * g.outer, y: g.centre.y + sinA * g.outer))
            let tint: Color = isMidnight ? StrandPalette.textSecondary
                                         : StrandPalette.textTertiary.opacity(0.5)
            ctx.stroke(p, with: .color(tint), lineWidth: isMidnight ? 1.5 : 1)
        }
    }

    /// Hour numerals at 00, 06, 12 and 18.
    ///
    /// The dial previously carried one longer midnight tick and nothing else, on the reasoning that a
    /// single distinguished mark orients the ring without raising a 12-versus-24-hour question. It does
    /// orient it, but it leaves no time READABLE: the card's own caption claims a night is "2.6 h later
    /// than your body clock" and there was no way to check that against the picture (#2350). Numerals
    /// settle the format question by answering it, in the 24-hour form the rest of this card uses.
    private func drawHourLabels(_ ctx: GraphicsContext, _ g: DialGeometry) {
        for hour in stride(from: 0.0, to: 24.0, by: 6.0) {
            let a: Double = angle(hour).radians
            let x: CGFloat = g.centre.x + cos(a) * g.labelRadius
            let y: CGFloat = g.centre.y + sin(a) * g.labelRadius
            // A FIXED point size, not `StrandFont.caption`. That is a text STYLE, so it scales with
            // Dynamic Type, and these numerals sit in a fixed-radius canvas with 3.5 pt of clearance to
            // the ticks: at an accessibility text size they would grow straight into them, recreating
            // the collision this change exists to remove. The dial is a diagram, and its geometry does
            // not scale, so neither may its labels.
            // Colour via the RESOLVED text's shading, the same way `drawOnset` tints the bed, NOT via
            // `.foregroundStyle` on the `Text`. That overload returns `Text` only from macOS 14, and this
            // target is macOS 13, so there the expression is a `View` and `resolve` has no matching
            // overload. The iOS leg compiled it happily on its iOS 17 floor, which is why only the macOS
            // leg caught it, and why `swiftc -parse` could not: it never resolves a symbol.
            var numeral = ctx.resolve(
                Text(String(format: "%02d", Int(hour))).font(.system(size: 10, design: .rounded)))
            numeral.shading = .color(StrandPalette.textTertiary)
            ctx.draw(numeral, at: CGPoint(x: x, y: y), anchor: .center)
        }
    }

    /// The two arcs differ by PATTERN as well as weight. Opacity alone was the first cut and it does not
    /// survive the card being translucent over a custom background image — the reference arc washed out
    /// to near-invisible on a real device, losing the comparison the card exists for. BUTT caps on the
    /// dashed stroke: a round cap adds lineWidth/2 at EACH end of EVERY dash, so at a 7 pt stroke a
    /// [2, 7] dash renders as 9 pt of ink with a 0 pt gap — a line that looks solid while claiming to be
    /// dashed, the one outcome this must not produce.
    private func drawArcs(_ ctx: GraphicsContext, _ g: DialGeometry) {
        if let ideal {
            strokeArc(ctx, g, radius: g.reference, from: ideal.bedHour, to: ideal.wakeHour,
                      colour: hue.opacity(0.55), width: DialGeometry.referenceWidth, dashed: true)
        }
        strokeArc(ctx, g, radius: g.night, from: actualBedHour, to: actualWakeHour,
                  colour: hue, width: DialGeometry.nightWidth, dashed: false)
    }

    private func strokeArc(_ ctx: GraphicsContext, _ g: DialGeometry, radius: CGFloat,
                           from: Double, to: Double, colour: Color, width: CGFloat, dashed: Bool) {
        let startAngle: Angle = angle(from)
        let sweepDegrees: Double = sweep(from, to) / 24 * 360
        var p = Path()
        p.addArc(center: g.centre, radius: radius, startAngle: startAngle,
                 endAngle: .degrees(startAngle.degrees + sweepDegrees), clockwise: false)
        // Each dash must be LONGER than the stroke is wide, or it renders as a radial hash mark rather
        // than a dashed line, which is what a [3, 5] dash under a 7 pt stroke produced (#2350). The
        // remedy is the DASH, not the weight: the note above records that opacity alone left this arc
        // washed out to near-invisible over a custom background on a real device, so the 7 pt stroke is
        // legibility someone bought with hardware. Thinning it to satisfy the rule would have paid for
        // one fix with another's evidence.
        let dash: [CGFloat] = dashed ? [10, 8] : []
        ctx.stroke(p, with: .color(colour),
                   style: StrokeStyle(lineWidth: width, lineCap: dashed ? .butt : .round, dash: dash))
    }

    /// A bed at sleep ONSET. Without it the night arc has two indistinguishable ends and the reader must
    /// work out which way round the day runs before the picture means anything — the marker turns
    /// "somewhere in this band" into "it started here". Drawn INTO A RECT, not at a point: `draw(_:at:)`
    /// renders an SF Symbol at its intrinsic size, which follows the environment font and would not match
    /// the Kotlin twin's fixed 14 dp glyph.
    private func drawOnset(_ ctx: GraphicsContext, _ g: DialGeometry) {
        var bed = ctx.resolve(Image(systemName: "bed.double.fill"))
        bed.shading = .color(hue)
        let onset: Double = angle(actualBedHour).radians
        // INSIDE the night arc, not on it. Centred on the arc itself the bed covered the very onset it
        // exists to mark (#2350); set in one band it still points at the start without hiding it.
        let glyph: CGFloat = DialGeometry.glyph
        let x: CGFloat = g.centre.x + cos(onset) * g.glyphRadius - glyph / 2
        let y: CGFloat = g.centre.y + sin(onset) * g.glyphRadius - glyph / 2
        ctx.draw(bed, in: CGRect(x: x, y: y, width: glyph, height: glyph))
    }

    /// Which arc is which. Without this the card shows two bands and no way to tell them apart —
    /// "outer means ideal" is an arbitrary choice, not something a reader can infer. The swatches are
    /// drawn with the SAME stroke style as the arcs so the mapping cannot drift apart from the drawing.
    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(colour: hue, dashed: false, label: String(localized: "Last night"))
            legendItem(colour: hue.opacity(0.55), dashed: true,
                       label: String(localized: "Your clock"))
            Spacer()
        }
        .accessibilityHidden(true)   // the caption below already states the comparison in words
    }

    private func legendItem(colour: Color, dashed: Bool, label: String) -> some View {
        HStack(spacing: 5) {
            Canvas { ctx, size in
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height / 2))
                p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                ctx.stroke(p, with: .color(colour),
                           style: StrokeStyle(lineWidth: 3, lineCap: dashed ? .butt : .round,
                                              dash: dashed ? [2, 3] : []))
            }
            .frame(width: 18, height: 4)
            Text(label)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    /// Rounded to five minutes: the underlying phase is an activity fit, so a to-the-minute caption would
    /// imply a precision the estimate does not carry.
    private var alignmentText: String {
        let minutes = Int((offsetHours * 60 / 5).rounded()) * 5
        if abs(minutes) < 30 { return String(localized: "In sync with your body clock") }
        let hours = abs(Double(minutes)) / 60
        // Locale-formatted, NOT String(format:). That is C-locale, so it prints "1.5 h" for a German
        // reader while the Android twin's String.format prints "1,5 h" from the default locale — the two
        // platforms disagreeing on a decimal separator in the same sentence.
        let amount = hours >= 1
            ? "\(hours.formatted(.number.precision(.fractionLength(1)))) h"
            : "\(abs(minutes)) min"
        return minutes > 0
            ? String(localized: "\(amount) later than your body clock")
            : String(localized: "\(amount) earlier than your body clock")
    }

    private func chronotypeText(_ c: CircadianEngine.Chronotype) -> String {
        switch c {
        case .morning:      return String(localized: "Morning type")
        case .intermediate: return String(localized: "Intermediate type")
        case .evening:      return String(localized: "Evening type")
        }
    }
}
