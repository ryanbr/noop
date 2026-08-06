//  LiveSessionView.swift
//  NOOP · Live Sessions (silent guardian) — the in-session screen + summary sheet.
//
//  Deliberately near-empty: one breathing ring, one line of intent, one honest Charge
//  sentence that fades, an End button. The ring is the whole language — lit teal and
//  breathing in band, dimmed below, hot above, grey when the stream is stale (coaching
//  paused, nothing claimed). NO live HR number by default; a long-press on the ring
//  reveals the engine's smoothed bpm. A thin outer arc fills with time held in band,
//  toward an hour. Every value on screen is the engine's `Output`, verbatim — this
//  file renders, it never decides.
//
//  Design contract: docs/superpowers/specs/2026-07-04-live-sessions-design.md.

import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

struct LiveSessionView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Low Power Mode / the in-app quiet-motion toggle. The guardian breath is a `repeatForever`
    /// animation that never settles, so it belongs behind the same gate as the liquid surfaces.
    /// The Android twin gated `LiveSessionScreen`'s breath under battery saver in #911.
    @ObservedObject private var motion = NoopMotionState.shared

    /// "Card transparency" (0–100, default 100): fades the live-session cards in lockstep with the frosted
    /// cards; content stays readable. Mirrors Kotlin `NoopPrefs.cardOpacityPercent`.
    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent
    private var cardOpacity: Double { max(0, min(1, Double(cardOpacityPercent) / 100)) }

    /// One runner per presentation — created here, started on appear, never restarted.
    @StateObject private var runner = LiveSessionRunner()
    let onClose: () -> Void

    /// Long-press reveal for the live (smoothed) bpm — off by default, per the contract.
    @State private var showBpm = false
    /// The one Charge sentence: shown for 6 s, then fades and stays gone.
    @State private var chargeLineVisible = true
    /// Caller-owned draw for BevelGauge: eases to each new smoothed position. HOLDS the last position
    /// while stale — the grey tint says "no reading"; snapping to zero would invent a collapse.
    @State private var ringFraction: Double = 0
    /// The thin outer "time held in band" arc, filling toward an hour.
    @State private var heldFraction: Double = 0
    /// The slow in-band breathing scale (the only motion on screen).
    @State private var breathe = false
    @State private var showSummary = false
    /// "N sessions guarded" for the summary streak line, read from the store when the session ends.
    @State private var guardedCount: Int?

    private let ringDiameter: CGFloat = 250

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, NoopMetrics.space6)
            Spacer()
            ring
            Text(guardianLine)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, NoopMetrics.space6)
                .padding(.horizontal, NoopMetrics.space6)
            chargeSentence
                .padding(.top, NoopMetrics.space3)
                .padding(.horizontal, NoopMetrics.space6)
            Spacer()
            NoopButton("End session", systemImage: "stop.fill", kind: .destructive, fullWidth: true) {
                endSession()
            }
        }
        .screenPadding()
        .padding(.vertical, NoopMetrics.space6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 640)
        #endif
        .onAppear {
            runner.start(model: model, repo: repo, ble: model.ble, profile: profile)
        }
        // Left without ending (a dismissed sheet on macOS, a shell teardown): end cleanly so the
        // realtime-HR arm is balanced and the row's totals are banked. Guarded — a normal End already set
        // finalRow, so this only catches the escape paths.
        .onDisappear {
            if runner.finalRow == nil { runner.end() }
        }
        // Both end paths (the End tap and the 10-min stale auto-end) land here: load the streak count,
        // then raise the summary.
        .onChangeCompat(of: runner.finalRow) { row in
            guard row != nil else { return }
            loadGuardedCount()
            showSummary = true
        }
        .onChangeCompat(of: runner.output) { out in advance(to: out) }
        .task { await fadeChargeSentenceLater() }
        .sheet(isPresented: $showSummary, onDismiss: { onClose() }) {
            if let row = runner.finalRow {
                LiveSessionSummarySheet(row: row, guardedCount: guardedCount) {
                    showSummary = false   // onDismiss closes the whole session screen
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SILENT GUARDIAN")
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.metricCyan)
            HStack(spacing: NoopMetrics.space2) {
                Text("Live Session")
                    .font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)
                betaPill
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var betaPill: some View {
        Text("BETA")
            .font(StrandFont.overlineScaled(8.5)).tracking(1.2)
            .foregroundStyle(StrandPalette.textSecondary)
            .padding(.horizontal, 8).padding(.vertical, 2.5)
            .background(Capsule().fill(StrandPalette.surfaceInset)
                .overlay(Capsule().strokeBorder(StrandPalette.hairline, lineWidth: 1)))
            .accessibilityLabel("Beta feature")
    }

    // MARK: - Ring

    /// The whole instrument: BevelGauge showing the smoothed position across [floor−20, ceiling+20],
    /// a thin outer arc of time held in band, tinted by the engine's position, breathing only while
    /// in band and active. Long-press toggles the bpm read-out.
    private var ring: some View {
        ZStack {
            // Thin outer arc: time held in band this session, filling toward 60 min. Same 240° open
            // geometry as the gauge (start 150°, span 240°) so the two read as one instrument.
            Circle()
                .trim(from: 0, to: heldFraction * (240.0 / 360.0))
                .rotation(.degrees(150))
                .stroke(StrandPalette.metricCyan.opacity(0.55),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: ringDiameter + 26, height: ringDiameter + 26)
            BevelGauge(
                fraction: ringFraction,
                stops: [Gradient.Stop(color: ringTint.opacity(0.7), location: 0),
                        Gradient.Stop(color: ringTint, location: 1)],
                tipColor: ringTint,
                numberText: bpmText,
                captionText: showBpm ? "bpm" : nil,
                stateText: nil,
                diameter: ringDiameter,
                showsLabel: showBpm,
                animatedFraction: ringFraction,
                bloomActive: false
            )
        }
        .scaleEffect(breathe ? 1.03 : 1.0)
        .contentShape(Circle())
        .onLongPressGesture { showBpm.toggle() }
        .onChangeCompat(of: isBreathing) { on in setBreathing(on) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(ringAccessibilityLabel))
        .accessibilityHint(Text("Long press to show or hide your heart rate."))
    }

    /// Breathing is the "on track" signal: only in band, only once active, never when anything is
    /// asking for quiet (Reduce Motion, Low Power Mode, or "Reduce motion in NOOP").
    private var isBreathing: Bool {
        !motion.poseStill(reduceMotion)
            && runner.output?.status == .active
            && runner.output?.position == .inBand
    }

    private func setBreathing(_ on: Bool) {
        if on {
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { breathe = true }
        } else {
            withAnimation(.easeOut(duration: 0.5)) { breathe = false }
        }
    }

    /// The engine's smoothed bpm, only when revealed and only when it exists — a stale stream shows a
    /// dash, never a held or guessed number.
    private var bpmText: String {
        guard let s = runner.output?.smoothedBpm else { return "—" }
        return "\(Int(s.rounded()))"
    }

    private var ringTint: Color {
        guard let out = runner.output, out.smoothedBpm != nil else {
            return StrandPalette.textTertiary   // stale / no reading yet: grey, no coaching claims
        }
        switch out.position {
        case .inBand: return StrandPalette.metricCyan               // lit: on track
        case .below:  return StrandPalette.metricCyan.opacity(0.3)  // dim: too easy for today
        case .above:  return StrandPalette.statusCritical           // hot: today can't pay for this
        }
    }

    private var ringAccessibilityLabel: String {
        guard let out = runner.output, out.smoothedBpm != nil else {
            return String(localized: "No live reading. Coaching is paused.")
        }
        switch out.position {
        case .inBand: return String(localized: "In your band. On track.")
        case .below:  return String(localized: "Below your band.")
        case .above:  return String(localized: "Above your band.")
        }
    }

    /// Ease the arc to each new smoothed position across [floor−20, ceiling+20]; hold while stale.
    private func advance(to out: LiveSessionEngine.Output?) {
        guard let out else { return }
        if let s = out.smoothedBpm {
            let lo = out.band.floorBpm - 20
            let hi = out.band.ceilingBpm + 20
            if hi > lo {
                let f = min(max((s - lo) / (hi - lo), 0), 1)
                withAnimation(.easeOut(duration: 0.9)) { ringFraction = f }
            }
        }
        withAnimation(.linear(duration: 1.0)) {
            heldFraction = min(out.inBandSeconds / 3600, 1)
        }
    }

    // MARK: - Lines

    /// The screen's one line of intent, honest per engine status — a stale stream never claims guarding.
    private var guardianLine: String {
        switch runner.output?.status {
        case .stale, .none:
            return String(localized: "No live reading. Coaching is paused until the strap comes back.")
        case .warmup:
            return String(localized: "Warming up. Cues stay quiet for the first minute.")
        case .active:
            return String(localized: "Guarding your session. Silence means you're on track.")
        }
    }

    /// The one honest Charge sentence — what the band is and why — shown for 6 s, then gone.
    private var chargeSentence: some View {
        Text(chargeLineText)
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .multilineTextAlignment(.center)
            .opacity(chargeLineVisible ? 1 : 0)
            .accessibilityHidden(!chargeLineVisible)
    }

    private var chargeLineText: String {
        guard let band = runner.baseBand else { return "" }
        let floor = Int(band.floorBpm.rounded()), ceiling = Int(band.ceilingBpm.rounded())
        if let charge = runner.chargeAtStart {
            return String(localized: "Charge \(Int(charge.rounded())) today, so your band is \(floor)–\(ceiling) bpm.")
        }
        return String(localized: "No Charge banked today, so your band takes a careful middle course: \(floor)–\(ceiling) bpm.")
    }

    /// 6 s on screen, then a slow fade — the sentence said its piece; the ring carries it from here.
    /// Runs inside `.task`, so a torn-down screen cancels the sleep and skips the (now moot) fade.
    private func fadeChargeSentenceLater() async {
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 1.2)) { chargeLineVisible = false }
    }

    // MARK: - End

    private func endSession() {
        runner.end()   // finalRow lands via onChangeCompat → summary sheet
    }

    /// "N sessions guarded" — completed sessions in the recent look-back, this one included (its final
    /// row is upserted before `finalRow` publishes).
    private func loadGuardedCount() {
        let deviceId = repo.deviceId
        Task {
            guard let store = await repo.storeHandle() else { return }
            let rows = (try? await store.recentLiveSessions(deviceId: deviceId, limit: 50)) ?? []
            guardedCount = rows.filter { $0.endTs != nil }.count
        }
    }
}

// MARK: - Summary sheet

/// The end-of-session read-out: time in / below / above the band, the cues sent, a plain verdict, and
/// the streak line. Everything comes off the banked `LiveSessionRow` — the same record the look-back
/// reads, so this sheet and history can never disagree.
struct LiveSessionSummarySheet: View {
    let row: LiveSessionRow
    let guardedCount: Int?
    let onDone: () -> Void
    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent
    private var cardOpacity: Double { max(0, min(1, Double(cardOpacityPercent) / 100)) }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text("LIVE SESSION")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.metricCyan)
                Text("Session summary")
                    .font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)
            }
            .padding(.top, NoopMetrics.space6)

            Text(Self.verdict(row: row))
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            summaryCard {
                bandRow(String(localized: "In band"), seconds: row.inBandSec, tint: StrandPalette.metricCyan)
                bandRow(String(localized: "Below band"), seconds: row.belowSec, tint: StrandPalette.textTertiary)
                bandRow(String(localized: "Above band"), seconds: row.aboveSec, tint: StrandPalette.statusCritical)
            }

            summaryCard {
                HStack {
                    Text("Cues sent").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Text(cueLine).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                }
                HStack {
                    Text("Band").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Text("\(Int(row.floorBpm.rounded()))–\(Int(row.ceilingBpm.rounded())) bpm")
                        .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                }
            }

            if let n = guardedCount, n > 0 {
                Text(n == 1 ? String(localized: "1 session guarded")
                            : String(localized: "\(n) sessions guarded"))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            Spacer(minLength: NoopMetrics.space3)
            NoopButton("Done", kind: .primary, fullWidth: true) { onDone() }
        }
        .screenPadding()
        .padding(.vertical, NoopMetrics.space6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }

    // MARK: Rows

    private func bandRow(_ label: String, seconds: Double, tint: Color) -> some View {
        HStack(spacing: NoopMetrics.rowSpacing) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(Self.clock(seconds))
                .font(StrandFont.number(17)).monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private func summaryCard<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NoopPanelSurface(cornerRadius: 22, surfaceOpacity: cardOpacity))
    }

    private var cueLine: String {
        if row.pushCount == 0 && row.easeCount == 0 {
            return String(localized: "None — silence, start to finish")
        }
        var parts: [String] = []
        if row.pushCount > 0 { parts.append(String(localized: "\(row.pushCount) push")) }
        if row.easeCount > 0 { parts.append(String(localized: "\(row.easeCount) ease-off")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Verdict (pure + honest — fractions of the banked totals, no editorialising beyond them)

    static func verdict(row: LiveSessionRow) -> String {
        let total = row.inBandSec + row.belowSec + row.aboveSec
        guard total >= 300 else {
            return String(localized: "Too short to judge — the band needs a few minutes to mean anything.")
        }
        let inFrac = row.inBandSec / total
        if inFrac >= 0.7 {
            return String(localized: "You held the band. Right where today wanted you.")
        }
        if inFrac >= 0.4 {
            return String(localized: "In and out, but the band won more than it lost.")
        }
        return row.belowSec >= row.aboveSec
            ? String(localized: "Mostly under the band — there was more in the tank today.")
            : String(localized: "Mostly over the band — harder than today's Charge could pay for.")
    }

    /// m:ss off the banked seconds (sessions are an hour-scale affair; no hour arithmetic needed).
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
