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

    private var hue: Color { StrandPalette.restColor }

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

    private var dial: some View {
        Canvas { ctx, size in
            let side = min(size.width, size.height)
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = side / 2 - 10
            let inner = outer - 16

            // The bare ring, so an empty dial still reads as a clock rather than a broken chart.
            ctx.stroke(Path(ellipseIn: CGRect(x: centre.x - outer, y: centre.y - outer,
                                              width: outer * 2, height: outer * 2)),
                       with: .color(StrandPalette.hairline), lineWidth: 1)

            // Six-hourly ticks: enough to orient the eye, few enough not to compete with the arcs.
            for tick in stride(from: 0.0, to: 24.0, by: 6.0) {
                let a = angle(tick).radians
                var p = Path()
                p.move(to: CGPoint(x: centre.x + cos(a) * (outer - 4), y: centre.y + sin(a) * (outer - 4)))
                p.addLine(to: CGPoint(x: centre.x + cos(a) * outer, y: centre.y + sin(a) * outer))
                ctx.stroke(p, with: .color(StrandPalette.textTertiary.opacity(0.5)), lineWidth: 1)
            }

            func arc(radius: CGFloat, from: Double, to: Double, colour: Color, width: CGFloat) {
                var p = Path()
                p.addArc(center: centre, radius: radius,
                         startAngle: angle(from),
                         endAngle: .degrees(angle(from).degrees + sweep(from, to) / 24 * 360),
                         clockwise: false)
                ctx.stroke(p, with: .color(colour), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }

            if let ideal {
                arc(radius: outer, from: ideal.bedHour, to: ideal.wakeHour,
                    colour: hue.opacity(0.35), width: 8)
            }
            arc(radius: inner, from: actualBedHour, to: actualWakeHour, colour: hue, width: 8)
        }
        .frame(height: 170)
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
