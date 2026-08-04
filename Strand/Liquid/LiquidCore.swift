//  LiquidCore.swift
//  NOOP · Liquid design language (experimental redesign)
//
//  The physics + motion foundation shared by every liquid element. Ported from the
//  HTML design prototype: a spring-damped surface that stays level with the world
//  as the device tilts, layered travelling waves, suspended metal flake, and splash
//  droplets. Pure value maths in a reference type so a SwiftUI Canvas can step it
//  each frame without writing @State during a view update.
//
//  Locked material: liquid glass carrying metal flake. Translucent colour, flake
//  that drifts and re-catches the light, a reflection that follows the tilt.

import SwiftUI
import StrandDesign   // NoopMotionState / QuietMotionPrefs — the shared quiet-motion gate
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(CoreMotion)
import CoreMotion
#endif

// MARK: - Colour helpers (mirror the mock's rgba / shade / mix)

extension Color {
    /// sRGB components, best-effort. Falls back to opaque white off-UIKit.
    func liquidComponents() -> (r: Double, g: Double, b: Double, a: Double) {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) {
            return (Double(r), Double(g), Double(b), Double(a))
        }
        #elseif canImport(AppKit)
        // macOS has no UIKit; without this the sky keyframes all resolved to the white fallback below,
        // so the whole day-of-sky rendered white on mac. NSColor in sRGB gives the same components UIKit does.
        if let ns = NSColor(self).usingColorSpace(.sRGB) {
            return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
        }
        #endif
        return (1, 1, 1, 1)
    }
    func liquidMix(_ other: Color, _ t: Double) -> Color {
        let a = liquidComponents(), b = other.liquidComponents()
        let f = max(0, min(1, t))
        return Color(.sRGB,
                     red: a.r + (b.r - a.r) * f,
                     green: a.g + (b.g - a.g) * f,
                     blue: a.b + (b.b - a.b) * f,
                     opacity: 1)
    }
    /// Multiply toward black by `t` (the mock's `shade`).
    func liquidDarker(_ t: Double) -> Color {
        let c = liquidComponents()
        let f = max(0, min(1, t))
        return Color(.sRGB, red: c.r * (1 - f), green: c.g * (1 - f), blue: c.b * (1 - f), opacity: 1)
    }
    func liquidLighter(_ t: Double) -> Color { liquidMix(.white, t) }
}

// MARK: - Motion: a single shared tilt source (no per-frame publishing)

/// One accelerometer/attitude source for the whole liquid layer. Reads are plain
/// property reads (NOT @Published) so the per-frame Canvas redraw — driven by
/// TimelineView — is what advances the picture, never a publish storm. Device
/// motion via CMMotionManager needs no permission prompt.
final class LiquidMotion {
    static let shared = LiquidMotion()

    /// Smoothed world tilt in radians, clamped. Mouse fallback is unused on device;
    /// on Mac Catalyst / simulator it simply stays flat, which reads fine.
    private(set) var tilt: Double = 0

    #if os(iOS)   // CMMotionManager is iOS/Catalyst only; CoreMotion imports on macOS but the class is unavailable there
    private let manager = CMMotionManager()
    /// Device-motion callbacks land here, OFF the main thread, so 60Hz sensor updates don't contend with
    /// the scroll + Canvas redraws on main. `tilt` is a single 8-byte Double (atomic read/write on ARM64),
    /// read from the Canvas draw on main — a one-frame-stale value is harmless for a decorative slosh.
    private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.noop.liquid.motion"
        q.qualityOfService = .userInteractive
        q.maxConcurrentOperationCount = 1
        return q
    }()
    #endif
    private var started = false
    private var refCount = 0

    private init() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        // Stop at the app boundary. `onDisappear` is NOT called when the app is backgrounded, and
        // NOOP declares `bluetooth-central` + `location` background modes, so it keeps RUNNING
        // behind the lock screen while a strap is connected — which meant a decorative 60 Hz
        // accelerometer+gyro fusion kept being delivered all day for a picture nobody could see.
        // That is the always-on half of this cost; posing the Canvas still never touched it.
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                       object: nil, queue: .main) { [weak self] _ in self?.stop() }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification,
                       object: nil, queue: .main) { [weak self] _ in self?.startIfWanted() }
        // Live response to all three quiet signals, so flipping Low Power Mode / Reduce Motion /
        // the in-app toggle stops the sensor immediately rather than at the next screen change.
        nc.addObserver(forName: .NSProcessInfoPowerStateDidChange,
                       object: nil, queue: .main) { [weak self] _ in self?.syncToPolicy() }
        nc.addObserver(forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
                       object: nil, queue: .main) { [weak self] _ in self?.syncToPolicy() }
        nc.addObserver(forName: UserDefaults.didChangeNotification,
                       object: UserDefaults.standard, queue: .main) { [weak self] _ in self?.syncToPolicy() }
        #endif
    }

    /// The three signals that mean "no decorative motion", read imperatively. Views read
    /// `NoopMotionState` instead (it publishes, so they invalidate); this is the sensor's own read,
    /// off the same underlying facts, so the two can never disagree.
    static var quietNow: Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        if UserDefaults.standard.bool(forKey: QuietMotionPrefs.enabledKey) { return true }
        #if canImport(UIKit) && !os(watchOS)
        if UIAccessibility.isReduceMotionEnabled { return true }
        #endif
        return false
    }

    /// Ref-counted start/stop so the sensor only runs while a liquid screen is visible.
    ///
    /// The gate is checked HERE and not only at the view branch: a posed vessel renders from the
    /// static path and never calls this, but a future call site that forgets would otherwise
    /// re-arm a 60 Hz sensor the user has explicitly asked to be rid of.
    func acquire() {
        refCount += 1
        startIfWanted()
    }

    private func startIfWanted() {
        guard !started, refCount > 0, !LiquidMotion.quietNow else { return }
        started = true
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard manager.isDeviceMotionAvailable else { started = false; return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            guard let self, let m = motion else { return }
            // roll ≈ side-to-side tilt of the phone held upright
            // #1004: scale the response by uprightness. `m.gravity` is the unit gravity vector in DEVICE
            // coords, so -gravity.y = dot(world-up, screen-up): 1 held upright, ~0 flat on a table or lying
            // down. Near flat, attitude roll is large-but-meaningless (the roll axis approaches the gravity
            // axis), which used to pin the liquid sideways in bed; attenuated, it settles LEVEL instead.
            let upright = LiquidMotion.uprightAttenuation(-m.gravity.y)
            let raw = max(-0.62, min(0.62, m.attitude.roll)) * upright
            self.tilt += (raw - self.tilt) * 0.18   // light smoothing
        }
        #endif
    }

    /// #1004 — pure uprightness → tilt-response attenuation, mirrored bit-for-bit on Android
    /// (LiquidMotion.kt `liquidUprightAttenuation`; golden vectors locked in LiquidUprightTest.kt).
    /// `uprightness` = how aligned screen-up is with world-up, in [-1, 1]: 1 upright portrait, 0 flat /
    /// landscape / lying sideways, -1 upside down. Smoothstep ramp over 0.25→0.65 so a normal handheld
    /// posture (phone reclined toward the face) keeps the full slosh and the response fades smoothly to
    /// level as the device approaches flat — no hard snap at a threshold. (The explicit follow-tilt on/off
    /// toggle stays on the roadmap; this is the always-on physical fix for near-flat use.)
    static func uprightAttenuation(_ uprightness: Double) -> Double {
        let t = max(0, min(1, (uprightness - 0.25) / 0.40))
        return t * t * (3 - 2 * t)
    }

    func release() {
        refCount = max(0, refCount - 1)
        guard refCount == 0 else { return }
        stop()
    }

    /// Stop the sensor but KEEP `refCount` — the screen is still mounted, we simply don't want the
    /// hardware running (backgrounded, or the user asked for quiet). `startIfWanted` resumes it.
    private func stop() {
        guard started else { return }
        started = false
        #if os(iOS) && !targetEnvironment(macCatalyst)
        manager.stopDeviceMotionUpdates()
        #endif
        tilt = 0
    }

    /// Re-evaluate after a Low Power Mode / Reduce Motion / in-app-toggle change.
    private func syncToPolicy() {
        if LiquidMotion.quietNow { stop() } else { startIfWanted() }
    }
}

// MARK: - The liquid simulation

/// Mutable physics for one body of liquid. Stepped once per frame from a Canvas
/// draw closure (mutating a reference type is safe there; mutating @State is not).
final class LiquidSim {
    // fill
    var level: Double = 0
    var target: Double
    // front + back surface springs (the parallax slosh)
    var a = 0.0, av = 0.0
    var ab = 0.0, abv = 0.0
    // wave energy + phases
    var energy: Double
    var p1: Double
    var p2: Double
    // suspended flake, in R-normalised circle coords
    struct Fleck { var x, y, z, ph, sp: Double; var kind: Int }
    var flecks: [Fleck] = []
    // splash droplets, R-normalised
    struct Drop { var x, y, vy, r, w, life: Double }
    var drops: [Drop] = []

    private var nudge: Double
    private var lastTime: Double?
    let reduceMotion: Bool

    init(target: Double, reduceMotion: Bool = false) {
        self.target = max(0, min(1, target))
        self.reduceMotion = reduceMotion
        self.energy = reduceMotion ? 0.1 : 0.5
        self.p1 = Double.random(in: 0..<7)
        self.p2 = Double.random(in: 0..<7)
        self.nudge = 2 + Double.random(in: 0..<5)
        for _ in 0..<28 {   // fewer flecks per vessel: ~40% cheaper per-frame render, imperceptible at gauge size
            let k = Double.random(in: 0..<1) < 0.2 ? 2 : (Double.random(in: 0..<1) < 0.44 ? 1 : 0)
            flecks.append(Fleck(x: .random(in: -1...1), y: .random(in: -1...1),
                                z: 0.35 + Double.random(in: 0..<0.65),
                                ph: .random(in: 0..<7), sp: 0.4 + Double.random(in: 0..<1.4), kind: k))
        }
    }

    // material constants (the locked "liquid glass + flake")
    private let kSpring = 31.0, cSpring = 5.5, kBack = 20.0, cBack = 4.3, phaseMul = 0.85

    /// Advance to absolute time `now` (seconds), chasing `target`, with world tilt.
    func step(now: Double, tilt: Double, target newTarget: Double) {
        target = max(0, min(1, newTarget))
        let dt: Double
        if let last = lastTime { dt = min(0.033, now - last) } else { dt = 0 }
        lastTime = now
        guard dt > 0 else { return }

        let surfTarget = -tilt   // container one way, the surface stays level → the other
        av += (kSpring * (surfTarget - a) - cSpring * av) * dt
        a += av * dt; a = max(-0.6, min(0.6, a))
        abv += (kBack * (surfTarget - ab) - cBack * abv) * dt
        ab += abv * dt; ab = max(-0.66, min(0.66, ab))

        energy = min(1.2, energy + (abs(av) + abs(abv)) * dt * 0.07)
        nudge -= dt
        if nudge <= 0 {
            nudge = 3.5 + Double.random(in: 0..<5)
            if !reduceMotion {
                av += (Bool.random() ? 1 : -1) * (0.05 + Double.random(in: 0..<0.08))
                energy = min(1.2, energy + 0.05)
            }
        }
        let d = target - level
        if abs(d) > 0.0004 {
            level += d * min(1, dt * 2.6)
            energy = min(1.2, energy + abs(d) * dt * 6)
        }
        let speed = (1 + energy * 2.2) * phaseMul
        p1 += dt * 2.1 * speed
        p2 += dt * 3.3 * speed
        energy *= exp(-dt * 1.5)
        if !reduceMotion && energy < 0.025 { energy = 0.025 }

        for i in drops.indices {
            drops[i].y -= drops[i].vy * dt
            drops[i].x += sin(drops[i].y * 7 + drops[i].w) * 0.12 * dt
            drops[i].life -= dt
        }
        drops.removeAll { $0.life <= 0 || $0.y <= 0.03 }

        for i in flecks.indices {
            flecks[i].x += (-av * 0.30 * flecks[i].z + sin(now * 0.35 + flecks[i].ph) * 0.015) * dt
            flecks[i].y += cos(now * 0.28 + flecks[i].ph * 1.3) * 0.012 * dt
            if flecks[i].x > 1.05 { flecks[i].x = -1.05 } else if flecks[i].x < -1.05 { flecks[i].x = 1.05 }
            if flecks[i].y > 1.05 { flecks[i].y = -1.05 } else if flecks[i].y < -1.05 { flecks[i].y = 1.05 }
        }
    }

    func splash(_ n: Int) {
        let count = reduceMotion ? min(n, 4) : n
        let depth = max(0.10, 2 * level * 0.9)
        for _ in 0..<count {
            drops.append(Drop(x: Double.random(in: -1...1) * 0.5,
                              y: depth * (0.45 + Double.random(in: 0..<0.5)),
                              vy: 0.22 + Double.random(in: 0..<0.34),
                              r: 0.012 + Double.random(in: 0..<0.03),
                              w: Double.random(in: 0..<7),
                              life: 1.2 + Double.random(in: 0..<1.4)))
        }
        if drops.count > 40 { drops.removeFirst(drops.count - 40) }
        energy = min(1.2, energy + 0.5)
    }

    /// True once the liquid has effectively stopped moving — lets a paused
    /// TimelineView stand down under reduce-motion.
    var settled: Bool {
        abs(av) < 0.01 && abs(abv) < 0.01 && abs(target - level) < 0.001 && energy < 0.03
    }

    /// A non-animating sim posed at its fill line, surface flat and still — for the small
    /// gauges/tubes that render ONCE (no TimelineView → CoreAnimation caches the layer, zero
    /// per-frame cost). The home screen has ~10 of these; only the hero vessels + HR thread
    /// need to actually slosh. Same static-raster principle as LiquidSkyStatic.
    static func posed(_ target: Double) -> LiquidSim {
        let s = LiquidSim(target: target, reduceMotion: true)
        let t = max(0, min(1, target))
        s.level = t; s.target = t
        s.a = 0; s.av = 0; s.ab = 0; s.abv = 0
        s.energy = 0
        return s
    }
}

// MARK: - Shared wave sampler

/// The surface height at horizontal position `x` (points, centred), including the
/// two travelling sines, the wall-curl (saturated at the chord), and the meniscus.
@inline(__always)
func liquidWave(_ x: Double, amp: Double, R: Double, hw: Double,
                curl: Double, ph1: Double, ph2: Double, ampMul: Double) -> Double {
    let k1 = (Double.pi * 2) / (R * 1.5)
    let k2 = (Double.pi * 2) / (R * 0.95)
    let xs = x > hw ? hw : (x < -hw ? -hw : x)
    var y = amp * ampMul * sin(x * k1 + ph1) + amp * ampMul * 0.6 * sin(x * k2 - ph2)
    y += curl * xs * xs * xs / (hw * hw)
    y += -0.01 * R * pow(abs(xs) / hw, 4)   // menis (wets the wall, just)
    return y
}

@inline(__always) func liquidChordHW(_ R: Double, _ sy: Double) -> Double {
    max(R * 0.3, (R * R - sy * sy > 0 ? (R * R - sy * sy).squareRoot() : R * 0.3))
}
@inline(__always) func liquidCurl(_ av: Double) -> Double { max(-0.18, min(0.18, -av * 0.12)) }

/// A monotonic seconds clock for a TimelineView date.
@inline(__always) func liquidSeconds(_ date: Date) -> Double { date.timeIntervalSinceReferenceDate }
