//  LiquidPrimitives.swift
//  NOOP · Liquid design language
//
//  The Canvas renderers + SwiftUI view wrappers for the signature elements:
//  the circular vessel gauge, the horizontal tube, and the live heart-rate thread.
//  Each view owns a LiquidSim, steps it from a TimelineView clock, and reads the
//  one shared tilt source. Colours come from StrandDesign tokens at the call site.

import SwiftUI
import StrandDesign   // NoopMotionState — the shared quiet-motion gate

// MARK: - Renderers (pure GraphicsContext drawing)

enum LiquidRender {

    /// A softly sculpted circular progress ring. The simulation still drives the value and tap response,
    /// but the visual treatment follows the reference's calm, recessed score dials instead of a filled orb.
    static func vessel(_ base: GraphicsContext, _ size: CGSize, _ sim: LiquidSim, now: Double, tint: Color) {
        let diameter = max(2, min(size.width, size.height) - 3)
        let rect = CGRect(x: (size.width - diameter) / 2, y: (size.height - diameter) / 2,
                          width: diameter, height: diameter)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = diameter * 0.39
        let lineWidth = max(5, diameter * 0.105)
        var ctx = base

        ctx.fill(Path(ellipseIn: rect), with: .linearGradient(
            Gradient(colors: [Color.white.opacity(0.08), Color.black.opacity(0.11)]),
            startPoint: CGPoint(x: rect.midX, y: rect.minY),
            endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        let inset = rect.insetBy(dx: diameter * 0.13, dy: diameter * 0.13)
        ctx.fill(Path(ellipseIn: inset), with: .color(Color(.sRGB, red: 43/255, green: 45/255, blue: 54/255, opacity: 1)))

        var track = Path()
        track.addArc(center: center, radius: radius, startAngle: .degrees(-90),
                     endAngle: .degrees(270), clockwise: false)
        ctx.stroke(track, with: .color(Color.white.opacity(0.10)),
                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

        let level = max(0, min(1, sim.level))
        if level > 0.004 {
            var progress = Path()
            progress.addArc(center: center, radius: radius, startAngle: .degrees(-90),
                            endAngle: .degrees(-90 + 360 * level), clockwise: false)
            ctx.stroke(progress,
                       with: .linearGradient(Gradient(colors: [tint.opacity(0.72), tint]),
                                             startPoint: CGPoint(x: rect.minX, y: rect.maxY),
                                             endPoint: CGPoint(x: rect.maxX, y: rect.minY)),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }

        ctx.stroke(Path(ellipseIn: rect.insetBy(dx: 0.5, dy: 0.5)),
                   with: .color(Color.white.opacity(0.09)), lineWidth: 1)
    }

    /// A horizontal capsule tube filled to `frac`; tilt pushes the liquid along it.
    static func tube(_ base: GraphicsContext, _ size: CGSize, _ sim: LiquidSim, now: Double, frac: Double, tint: Color) {
        let w = size.width, h = size.height, r = h / 2
        let outline = Path(roundedRect: CGRect(x: 0.5, y: 0.5, width: w - 1, height: h - 1), cornerRadius: r)
        var ctx = base
        ctx.fill(outline, with: .color(Color(.sRGB, red: 14/255, green: 14/255, blue: 18/255, opacity: 1)))
        ctx.stroke(outline, with: .color(.white.opacity(0.07)), lineWidth: 1)

        var clip = ctx
        clip.clip(to: outline)
        let shift = -sim.a * h * 1.3
        let edge = max(r * 0.8, min(w - 2, frac * (w - 4) + shift))
        let bulge = r * 0.6 + sin(sim.p1 * 2) * sim.energy * h * 0.3 - 0.01 * h * 6
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: edge - r * 0.3, y: 0))
        p.addQuadCurve(to: CGPoint(x: edge - r * 0.3, y: h), control: CGPoint(x: edge + bulge, y: h / 2))
        p.addLine(to: CGPoint(x: 0, y: h))
        p.closeSubpath()
        clip.fill(p, with: .linearGradient(Gradient(colors: [tint.opacity(0.84), tint.liquidDarker(0.28).opacity(0.86)]),
                                           startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: h)))
        clip.fill(Path(CGRect(x: 2, y: 1.2, width: max(0, edge - r * 0.6), height: 1)), with: .color(.white.opacity(0.12)))
        for i in 0..<min(8, sim.flecks.count) {
            let f = sim.flecks[i]
            let spark = pow(max(0, sin(f.ph + sim.a * 5 + now * f.sp)), 10)
            if spark < 0.08 { continue }
            let fx = 3 + (f.x + 1.05) / 2.1 * max(1, edge - 8)
            clip.fill(Path(CGRect(x: fx, y: h * 0.15 + f.z * h * 0.7, width: 1 + spark, height: 1 + spark)), with: .color(.white.opacity(spark * 0.6)))
        }
    }

    /// The live heart-rate curve as a glowing liquid thread with a travelling glint.
    static func thread(_ base: GraphicsContext, _ size: CGSize, values: [Double], now: Double, tint: Color) {
        guard values.count >= 2 else { return }
        let w = size.width, h = size.height, pad: Double = 10
        var mn = Double.greatestFiniteMagnitude, mx = -Double.greatestFiniteMagnitude
        for v in values { mn = min(mn, v); mx = max(mx, v) }
        let span = max(10, mx - mn)
        let n = values.count
        func px(_ i: Int) -> Double { pad + Double(i) * (w - 2 * pad) / Double(n - 1) }
        func py(_ v: Double) -> Double { h - pad - (v - mn) / span * (h - 2 * pad) }
        func curve() -> Path {
            var p = Path()
            p.move(to: CGPoint(x: px(0), y: py(values[0])))
            for i in 1..<(n - 1) {
                let xc = (px(i) + px(i + 1)) / 2, yc = (py(values[i]) + py(values[i + 1])) / 2
                p.addQuadCurve(to: CGPoint(x: xc, y: yc), control: CGPoint(x: px(i), y: py(values[i])))
            }
            p.addLine(to: CGPoint(x: px(n - 1), y: py(values[n - 1])))
            return p
        }
        var ctx = base
        ctx.stroke(curve(), with: .color(tint.opacity(0.9)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
        // travelling glint
        let phase = -(now * 55).truncatingRemainder(dividingBy: 414)
        ctx.stroke(curve(), with: .color(.white.opacity(0.55)),
                   style: StrokeStyle(lineWidth: 1.1, lineCap: .round, dash: [14, 400], dashPhase: phase))
        // endpoint pulse
        let ex = px(n - 1), ey = py(values[n - 1])
        let pr = 3 + sin(now * 6) * 1.1
        ctx.fill(Path(ellipseIn: CGRect(x: ex - pr - 4, y: ey - pr - 4, width: (pr + 4) * 2, height: (pr + 4) * 2)), with: .color(tint.opacity(0.15)))
        ctx.fill(Path(ellipseIn: CGRect(x: ex - pr, y: ey - pr, width: pr * 2, height: pr * 2)), with: .color(tint))
    }
}

// MARK: - Views

/// A circular liquid gauge. `value` is 0...1 (nil = empty/no-data). Tap → splash.
///
/// `animated: false` renders a single static frame (no TimelineView, no CoreMotion) — the small
/// gauges in card rows / vitals slosh imperceptibly at 26–30pt but each cost a live 30fps Canvas,
/// so they pose still and CoreAnimation caches them. The big hero gauges stay animated.
struct LiquidVessel: View {
    let value: Double?
    let tint: Color
    var animated: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared
    @State private var sim: LiquidSim
    @State private var splashes = 0

    init(value: Double?, tint: Color, animated: Bool = true) {
        self.value = value
        self.tint = tint
        self.animated = animated
        _sim = State(initialValue: LiquidSim(target: value ?? 0))
    }

    var body: some View {
        if animated && !motion.poseStill(reduceMotion) { gauge } else { staticGauge }
    }

    private var gauge: some View {
        // 60fps: on the 120Hz ProMotion panel a 30fps cap updated the fluid only every 4th refresh,
        // which read as juddery slosh. Only the 3 hero gauges + HR thread run live now (the small ones
        // are static), so the higher rate is affordable and the liquid actually flows.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { tl in
            let now = liquidSeconds(tl.date)
            Canvas { context, size in
                sim.step(now: now, tilt: LiquidMotion.shared.tilt, target: value ?? 0)
                LiquidRender.vessel(context, size, sim, now: now, tint: tint)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Circle())
        .onTapGesture { sim.splash(12); splashes &+= 1 }
        .liquidTapHaptic(trigger: splashes)   // light tap feedback (guarded so the primitives compile on macOS 13)
        .onAppear { LiquidMotion.shared.acquire() }
        .onDisappear { LiquidMotion.shared.release() }
    }

    /// One-shot, cached render — posed at the fill line, no clock, no motion acquire.
    private var staticGauge: some View {
        Canvas { context, size in
            LiquidRender.vessel(context, size, LiquidSim.posed(value ?? 0), now: 0, tint: tint)
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Circle())
    }
}

/// A horizontal liquid tube filled to `frac` (0...1).
///
/// `animated: false` poses it still and lets CoreAnimation cache the layer — the 8pt grid tubes
/// and 12pt workout bar don't need a live 30fps Canvas each. Hero-adjacent tubes can stay live.
struct LiquidTube: View {
    let frac: Double
    let tint: Color
    var height: CGFloat = 14
    var animated: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared
    @State private var sim = LiquidSim(target: 0)

    var body: some View {
        if animated && !motion.poseStill(reduceMotion) { liveTube } else { staticTube }
    }

    private var liveTube: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            let now = liquidSeconds(tl.date)
            Canvas { context, size in
                sim.step(now: now, tilt: LiquidMotion.shared.tilt, target: frac)
                LiquidRender.tube(context, size, sim, now: now, frac: max(0, min(1, frac)), tint: tint)
            }
        }
        .frame(height: height)
        .onAppear { LiquidMotion.shared.acquire() }
        .onDisappear { LiquidMotion.shared.release() }
    }

    private var staticTube: some View {
        Canvas { context, size in
            LiquidRender.tube(context, size, LiquidSim.posed(frac), now: 0,
                              frac: max(0, min(1, frac)), tint: tint)
        }
        .frame(height: height)
    }
}

/// The live heart-rate thread. `bpm` is the recent series (any length ≥ 2).
struct LiquidThread: View {
    let bpm: [Double]
    var tint: Color = Color(.sRGB, red: 1, green: 107/255, blue: 129/255, opacity: 1)
    var height: CGFloat = 96
    var animated: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared

    var body: some View {
        if animated && !motion.poseStill(reduceMotion) { liveThread } else { staticThread }
    }

    private var liveThread: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { tl in   // 60fps to flow smoothly on ProMotion
            let now = liquidSeconds(tl.date)
            Canvas { context, size in
                LiquidRender.thread(context, size, values: bpm, now: now, tint: tint)
            }
        }
        .frame(height: height)
    }

    /// One-shot render (no travelling glint / pulse) — used until first data load settles.
    private var staticThread: some View {
        Canvas { context, size in
            LiquidRender.thread(context, size, values: bpm, now: 0, tint: tint)
        }
        .frame(height: height)
    }
}

// MARK: - Shared liquid components (cross-platform: used by Today AND the other liquid screens on iOS + mac)

extension View {
    /// A light selection/impact haptic, available only where `sensoryFeedback` is (iOS 17 / macOS 14);
    /// a no-op below that so the liquid primitives still compile on the macOS 13 deployment target.
    @ViewBuilder func liquidTapHaptic(trigger: some Equatable) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.sensoryFeedback(.impact(weight: .light), trigger: trigger)
        } else {
            self
        }
    }

    /// A selection tick (e.g. the WHOOP-style day change), guarded so it compiles on macOS 13.
    @ViewBuilder func liquidSelectionHaptic(trigger: some Equatable) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.sensoryFeedback(.selection, trigger: trigger)
        } else {
            self
        }
    }

    /// A firmer medium impact (e.g. the pull-to-refresh release), guarded for the macOS 13 target.
    @ViewBuilder func liquidMediumHaptic(trigger: some Equatable) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.sensoryFeedback(.impact(weight: .medium), trigger: trigger)
        } else {
            self
        }
    }
}

/// The "this card was pressed" response for any tappable liquid card — a small settle inward plus a
/// touch of dimming. Cheap (a transform), so it's free on static cards and makes every tap feel physical.
struct LiquidPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// A number that animates to its value: SwiftUI interpolates `animatableData`, so the shown integer rolls
/// smoothly frame-by-frame whenever `value` changes inside a `withAnimation` block.
struct CountUpNumber: View, Animatable {
    var value: Double
    var font: Font
    /// Decimal places to render. 0 (default) keeps the whole-number scores (Charge/Rest/100-scale Effort)
    /// byte-identical; the WHOOP 0–21 Effort scale passes 1 so the hero matches the app-wide one-decimal
    /// `effortDisplay` convention instead of rounding 12.6 → "13" (#45).
    var decimals: Int = 0
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View {
        Text(decimals > 0 ? String(format: "%.\(decimals)f", value) : "\(Int(value.rounded()))")
            .font(font).monospacedDigit()
    }
}
