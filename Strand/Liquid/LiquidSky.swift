//  LiquidSky.swift
//  NOOP · Liquid design language
//
//  The time-of-day sky: a gradient that flows continuously through the day's
//  keyframes, a quiet starfield, and two subtle sheets of light. No objects,
//  no blur — clean and crisp, the atmosphere of the app's header.

import SwiftUI
import StrandDesign

struct LiquidSkyStop {
    let h: Double
    let top: Color, mid: Color, hor: Color
    let stars: Double, warm: Double
}

private func hx(_ hex: UInt32) -> Color {
    Color(.sRGB,
          red: Double((hex >> 16) & 0xff) / 255,
          green: Double((hex >> 8) & 0xff) / 255,
          blue: Double(hex & 0xff) / 255, opacity: 1)
}

/// The ten keyframes mirror the real app's day-cycle scenes (SceneHeroBackground),
/// as pure gradients rather than painted art.
let liquidSkyKeys: [LiquidSkyStop] = [
    .init(h: 0,    top: hx(0x191A1F), mid: hx(0x1D1E23), hor: hx(0x22242B), stars: 0.20, warm: 0),
    .init(h: 5,    top: hx(0x1A1B20), mid: hx(0x1D1F24), hor: hx(0x23252C), stars: 0.12, warm: 0),
    .init(h: 6.5,  top: hx(0x1B1C21), mid: hx(0x1F2026), hor: hx(0x25272E), stars: 0.06, warm: 0),
    .init(h: 8.5,  top: hx(0x1C1D22), mid: hx(0x202229), hor: hx(0x272A31), stars: 0, warm: 0),
    .init(h: 11,   top: hx(0x1D1E23), mid: hx(0x21232A), hor: hx(0x292C33), stars: 0, warm: 0),
    .init(h: 14,   top: hx(0x1D1E23), mid: hx(0x22242B), hor: hx(0x292C34), stars: 0, warm: 0),
    .init(h: 17.5, top: hx(0x1C1D22), mid: hx(0x202229), hor: hx(0x272930), stars: 0, warm: 0),
    .init(h: 19.5, top: hx(0x1B1C21), mid: hx(0x1F2026), hor: hx(0x24262D), stars: 0.05, warm: 0),
    .init(h: 22,   top: hx(0x191A1F), mid: hx(0x1D1E23), hor: hx(0x22242B), stars: 0.16, warm: 0),
    .init(h: 24,   top: hx(0x191A1F), mid: hx(0x1D1E23), hor: hx(0x22242B), stars: 0.20, warm: 0),
]

/// Light appearance keeps the same time-of-day movement without beginning from the dark-only
/// keyframes above. The restrained blue-gray atmosphere settles naturally into the light canvas.
private let liquidLightSkyKeys: [LiquidSkyStop] = [
    .init(h: 0,    top: hx(0xDCE3ED), mid: hx(0xE5EAF1), hor: hx(0xEEF1F5), stars: 0.08, warm: 0),
    .init(h: 5,    top: hx(0xDDE5EE), mid: hx(0xE7EBF1), hor: hx(0xEFF2F5), stars: 0.05, warm: 0),
    .init(h: 6.5,  top: hx(0xE1E8EF), mid: hx(0xE9EDF2), hor: hx(0xF0F2F5), stars: 0.02, warm: 0),
    .init(h: 8.5,  top: hx(0xE3EBF1), mid: hx(0xEAF0F3), hor: hx(0xF1F3F5), stars: 0, warm: 0),
    .init(h: 11,   top: hx(0xE1EAF0), mid: hx(0xE9EEF2), hor: hx(0xF1F3F5), stars: 0, warm: 0),
    .init(h: 14,   top: hx(0xDFE8EF), mid: hx(0xE8EDF2), hor: hx(0xF0F2F5), stars: 0, warm: 0),
    .init(h: 17.5, top: hx(0xE1E7ED), mid: hx(0xE8ECF1), hor: hx(0xEFF1F4), stars: 0, warm: 0),
    .init(h: 19.5, top: hx(0xDDE4EC), mid: hx(0xE6EAF0), hor: hx(0xEEF1F4), stars: 0.02, warm: 0),
    .init(h: 22,   top: hx(0xDAE2EC), mid: hx(0xE4E9F0), hor: hx(0xEDF0F4), stars: 0.06, warm: 0),
    .init(h: 24,   top: hx(0xDCE3ED), mid: hx(0xE5EAF1), hor: hx(0xEEF1F5), stars: 0.08, warm: 0),
]

private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
private func lerpColor(_ a: Color, _ b: Color, _ t: Double) -> Color {
    let x = a.liquidComponents(), y = b.liquidComponents()
    return Color(.sRGB, red: lerp(x.r, y.r, t), green: lerp(x.g, y.g, t), blue: lerp(x.b, y.b, t), opacity: 1)
}

func liquidSkyAt(_ hour: Double, light: Bool = false) -> (top: Color, mid: Color, hor: Color, stars: Double, warm: Double) {
    let keys = light ? liquidLightSkyKeys : liquidSkyKeys
    var i = 0
    while i < keys.count - 2 && keys[i + 1].h <= hour { i += 1 }
    let a = keys[i], b = keys[i + 1]
    let t = max(0, min(1, (hour - a.h) / (b.h - a.h)))
    return (lerpColor(a.top, b.top, t), lerpColor(a.mid, b.mid, t), lerpColor(a.hor, b.hor, t),
            lerp(a.stars, b.stars, t), lerp(a.warm, b.warm, t))
}

/// A precomputed quiet star field (positions fixed; only the count that render
/// depends on how starry the hour is).
private struct LiquidStar { let x, y, z, ph, sp: Double }
private let liquidStars: [LiquidStar] = (0..<70).map { _ in
    LiquidStar(x: .random(in: 0...1), y: .random(in: 0...0.78), z: .random(in: 0...1),
               ph: .random(in: 0..<7), sp: 0.2 + .random(in: 0..<0.5))
}

struct LiquidSky: View {
    /// Hour of day 0...24. Defaults to live time when nil.
    var hour: Double?
    /// How fully the sky dissolves into the canvas at the bottom (1 = the default seamless fade; <1 holds
    /// the atmosphere so the sky still reads under a full-height "sky behind cards" backdrop).
    var settleStrength: Double = 1
    @Environment(\.colorScheme) private var scheme
    /// The call site already swaps in `LiquidSkyStatic` when motion is unwanted, but this view carried
    /// no gate of its own — a second call site would have been silently ungated. `paused:` makes the
    /// frame loop stand down from inside, so the gate travels with the view.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0,
                                paused: motion.poseStill(reduceMotion))) { tl in
            let now = liquidSeconds(tl.date)
            let h = hour ?? liveHour()
            // The sky must dissolve into the SAME canvas colour the body uses (theme-aware surfaceBase),
            // so there is no hard seam where the sky meets the page — light mode made this glaring.
            let dark = scheme == .dark
            let settle = Color(.sRGB,
                               red: dark ? 29.0 / 255.0 : 242.0 / 255.0,
                               green: dark ? 30.0 / 255.0 : 242.0 / 255.0,
                               blue: dark ? 35.0 / 255.0 : 247.0 / 255.0,
                               opacity: 1)
            Canvas { ctx, size in
                render(ctx, size, hour: h, now: now, settle: settle, light: !dark)
            }
        }
    }

    private func liveHour() -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
    }

    private func render(_ base: GraphicsContext, _ size: CGSize, hour: Double, now: Double,
                        settle: Color, light: Bool) {
        let S = liquidSkyAt(hour, light: light)
        let w = size.width, h = size.height
        var ctx = base
        // the gradient IS the scene
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)),
                 with: .linearGradient(Gradient(stops: [
                    .init(color: S.top, location: 0),
                    .init(color: S.mid, location: 0.5),
                    .init(color: S.hor, location: 0.9)]),
                                       startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: h)))
        // slow breath of light low in the sky
        let breathe = 0.5 + 0.5 * sin(now * 0.22)
        ctx.fill(Path(CGRect(x: 0, y: h * 0.45, width: w, height: h * 0.55)),
                 with: .linearGradient(Gradient(colors: [.white.opacity(0), .white.opacity(0.05 + breathe * 0.03)]),
                                       startPoint: CGPoint(x: 0, y: h * 0.45), endPoint: CGPoint(x: 0, y: h)))
        if S.warm > 0.01 {
            let warm = Color(.sRGB, red: 1, green: 200/255, blue: 120/255, opacity: 1)
            ctx.fill(Path(CGRect(x: 0, y: h * 0.55, width: w, height: h * 0.45)),
                     with: .linearGradient(Gradient(colors: [warm.opacity(0), warm.opacity(S.warm * 0.10)]),
                                           startPoint: CGPoint(x: 0, y: h * 0.55), endPoint: CGPoint(x: 0, y: h)))
        }
        // stars
        if S.stars > 0.01 {
            for s in liquidStars {
                let baseA = 0.04 + s.z * 0.16
                let tw = pow(max(0, sin(s.ph + now * s.sp)), 6)
                let o = S.stars * (baseA + tw * 0.28)
                if o < 0.02 { continue }
                let sz = 0.6 + s.z * 0.8
                ctx.fill(Path(CGRect(x: s.x * w, y: s.y * h, width: sz, height: sz)), with: .color(.white.opacity(o)))
            }
        }
        // Settle into the page: a long fade to the theme's surfaceBase over the lower half so the sky
        // dissolves seamlessly into the body — no hard cut (the light-mode dark→white slam is gone).
        ctx.fill(Path(CGRect(x: 0, y: h * 0.45, width: w, height: h * 0.55)),
                 with: .linearGradient(Gradient(colors: [settle.opacity(0), settle.opacity(settleStrength)]),
                                       startPoint: CGPoint(x: 0, y: h * 0.45), endPoint: CGPoint(x: 0, y: h)))
    }
}

/// A subtle full-bleed time-of-day sky for any `ScreenScaffold.topBackground`, so the liquid
/// atmosphere carries across EVERY tab. Same live sky as Today at a modest header height, so the
/// charts/cards below sit on the dark canvas — the redesign's "the options change, not the page"
/// feel. Non-interactive + accessibility-hidden (pure decoration).
///
/// Honours the SAME two Appearance gates as Today and the metric-detail screens, so every scaffold
/// that passes this reads them for free (Trends / Sleep / More / the hub screens previously ignored
/// both — the sky stayed a fixed band there while Today filled the viewport):
/// - "Day-cycle background" OFF renders nothing, leaving the scaffold's plain `surfaceBase` canvas
///   (the same visual as passing no topBackground at all).
/// - "Sky behind cards" ON fills the scaffold's whole backdrop (the ZStack already spans the scroll
///   view; only this frame capped it) with the held-atmosphere settle, so the Card-transparency
///   setting reveals the sky under every card — the LiquidTodayView treatment.
/// A real View (not a one-shot read) so @AppStorage keeps it reactive: toggling either setting
/// updates every mounted tab in place. Mirrors the Android `LiquidScreenSky(fillHeight:)` +
/// `fullBleedBackground` pairing.
struct LiquidScaffoldSky: View {
    var height: CGFloat = 240
    @AppStorage(SceneBackgroundPrefs.enabledKey) private var showDayCycleBackground = true
    @AppStorage(SkyBehindCardsPrefs.enabledKey) private var skyBehindCards = true

    var body: some View {
        if showDayCycleBackground {
            LiquidSkyStatic(hour: nil, settleStrength: skyBehindCards ? 0.78 : 1)
                .frame(maxWidth: .infinity, maxHeight: skyBehindCards ? .infinity : nil)
                .frame(height: skyBehindCards ? nil : height, alignment: .top)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

func liquidScaffoldSky(height: CGFloat = 240) -> AnyView {
    AnyView(LiquidScaffoldSky(height: height))
}

/// A STATIC time-of-day sky, rendered ONCE (no TimelineView → CoreAnimation caches it as a stable layer,
/// zero per-frame cost) for the scaffold backgrounds on the chart-heavy tabs. An always-animating Canvas
/// behind the charts stole frame headroom and caused stutter (2026-07-02); this is the same look
/// minus the twinkle/breath, matching the classic app's static scene image for scroll perf.
struct LiquidSkyStatic: View {
    var hour: Double?
    /// See `LiquidSky.settleStrength` — 1 = default seamless fade; <1 holds the atmosphere for the
    /// full-height "sky behind cards" backdrop.
    var settleStrength: Double = 1
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let h = hour ?? liveHour()
        let dark = scheme == .dark
        let settle = Color(.sRGB,
                           red: dark ? 29.0 / 255.0 : 242.0 / 255.0,
                           green: dark ? 30.0 / 255.0 : 242.0 / 255.0,
                           blue: dark ? 35.0 / 255.0 : 247.0 / 255.0,
                           opacity: 1)
        Canvas { ctx, size in
            let S = liquidSkyAt(h, light: !dark)
            let w = size.width, hh = size.height
            ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: hh)),
                     with: .linearGradient(Gradient(stops: [
                        .init(color: S.top, location: 0),
                        .init(color: S.mid, location: 0.5),
                        .init(color: S.hor, location: 0.9)]),
                                           startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: hh)))
            if S.stars > 0.01 {
                for s in liquidStars {
                    let o = S.stars * (0.04 + s.z * 0.16)
                    if o < 0.02 { continue }
                    let sz = 0.6 + s.z * 0.8
                    ctx.fill(Path(CGRect(x: s.x * w, y: s.y * hh, width: sz, height: sz)),
                             with: .color(.white.opacity(o)))
                }
            }
            ctx.fill(Path(CGRect(x: 0, y: hh * 0.45, width: w, height: hh * 0.55)),
                     with: .linearGradient(Gradient(colors: [settle.opacity(0), settle.opacity(settleStrength)]),
                                           startPoint: CGPoint(x: 0, y: hh * 0.45), endPoint: CGPoint(x: 0, y: hh)))
        }
    }

    private func liveHour() -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
    }
}
