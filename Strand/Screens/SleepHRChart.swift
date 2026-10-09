import SwiftUI
import StrandDesign
import WhoopStore

/// WHOOP's sleeping heart-rate chart: a thin HR trace across the night with dashed onset/wake
/// rules and quiet bpm gridlines. With a stage selected, the trace re-colours inside that
/// stage's intervals and those time columns get a faint stage-tinted wash — WHOOP's "what did
/// my heart do during REM" read. Canvas-drawn (~550 one-minute buckets), gaps in the data
/// break the line honestly rather than interpolating across them.
///
/// One view for both places the night is drawn: the Sleep tab (`SleepView`) and the Today-hosted stage
/// card (`StageDetailView`). Each previously carried an identical private copy, so a change to one
/// silently missed the other. Pointer hover shows a crosshair and dot on the nearest one-minute bucket
/// with its clock time and bpm, the same readout the Today HR chart gives on the Mac.
struct SleepHRChart: View {
    /// The night's one-minute sleeping-HR buckets (unfiltered; trimmed to the visible window here).
    let nightHR: [HRBucket]
    let intervals: [SleepInterval]
    /// Visible window as seconds after the night's onset.
    let origin: TimeInterval
    let span: TimeInterval
    let night: Night
    let selectedStage: SleepStage?
    /// Clock-time formatter for the hover readout; callers pass their axis formatter so both agree.
    let timeFormatter: DateFormatter

    @State private var hoverX: CGFloat? = nil

    var body: some View {
        let nightStartTs = night.onsetDate.timeIntervalSince1970
        let buckets = nightHR.filter {
            let rel = TimeInterval($0.ts) - nightStartTs
            return rel >= origin - 60 && rel <= origin + span + 60
        }
        if buckets.count >= 2 {
            let bpms = buckets.map(\.bpm)
            let lo = (bpms.min() ?? 40) - 5
            let hi = (bpms.max() ?? 90) + 5
            Canvas { ctx, size in
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
            .overlay {
                hoverLayer(buckets: buckets, nightStartTs: nightStartTs, lo: lo, hi: hi)
            }
            .accessibilityLabel(Text("Sleeping heart rate through the night"))
        } else {
            Text("No heart-rate detail for this night")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    /// Crosshair, dot and time + bpm bubble on the bucket nearest the pointer. Uses the Canvas's own
    /// x/y mapping so the dot sits on the drawn line.
    private func hoverLayer(buckets: [HRBucket], nightStartTs: TimeInterval, lo: Double, hi: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let hx = hoverX {
                    let xs = buckets.map {
                        CGFloat((TimeInterval($0.ts) - nightStartTs - origin) / span) * geo.size.width
                    }
                    if let i = ChartHoverMath.nearestIndex(toX: hx, xs: xs) {
                        let b = buckets[i]
                        let pt = CGPoint(x: xs[i],
                                         y: geo.size.height * (1 - CGFloat((b.bpm - lo) / max(1, hi - lo))))
                        CrosshairRule(x: pt.x, height: geo.size.height)
                        HighlightDot(color: StrandPalette.restColor).position(pt)
                        PositionedTooltip(
                            anchor: pt,
                            container: geo.size,
                            tooltip: ChartTooltip(
                                value: String(localized: "\(Int(b.bpm.rounded())) bpm"),
                                label: timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(b.ts))),
                                accent: StrandPalette.restColor))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                // Non-animating, as in OverviewHRChart: an animated update makes the readout lag the pointer.
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) {
                    switch phase {
                    case .active(let location): hoverX = location.x
                    case .ended: hoverX = nil
                    }
                }
            }
        }
    }
}
