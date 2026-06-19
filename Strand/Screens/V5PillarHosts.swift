import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore
import WhoopProtocol

// V5PillarHosts.swift — the thin Wave-3 host wrappers that feed the two PURE v5 pillar screens
// (FusedRecordView + RhythmView) the engine results they take by init. The views own only
// presentation and previews from a fixture; these hosts do the I/O — they load the rows the store
// already holds, run the pure engine, and hand the result down. Self-contained: each takes the
// Repository / AppModel via the environment, exactly like every other screen.
//
// Mounted as reachable nav destinations by RootView (macOS sidebar) + RootTabView (iOS More list)
// and reachable via NavRouter deep-links from the Health / Devices&Sources hubs.

// MARK: - Fused record host ("Your Data, Fused")

/// Loads today's fused record via `AppModel.buildTodayFusedRecord()` (the additive multi-device
/// adapter) and feeds `FusedRecordView`. Re-loads when fresh data lands (`repo.refreshSeq`).
struct FusedRecordHost: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var repo: Repository

    @State private var record = FusedRecord(rows: [], dayOwner: nil, contributingSourceCount: 0)
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded {
                FusedRecordView(record: record)
            } else {
                ScreenScaffold(title: "Your Data, Fused",
                               subtitle: "Building your best-sourced record…") {
                    ComingSoon(what: "Reading your sources…", symbol: "square.stack.3d.up")
                }
            }
        }
        .task(id: repo.refreshSeq) {
            record = await model.buildTodayFusedRecord()
            loaded = true
        }
    }
}

// MARK: - Rhythm host (experimental beat-to-beat visualization)

/// Loads the most recent banked night's R-R windows, runs the pure `RhythmScreener` over each
/// still, resting window, and feeds `RhythmView` (which self-gates on its own consent before it
/// shows anything). All math is on-device; nothing is computed until the user passes the gate.
struct RhythmHost: View {
    @EnvironmentObject private var repo: Repository
    /// Optional dismissal hook when presented as a sheet (iOS / drill-in).
    var onClose: (() -> Void)? = nil

    @AppStorage(RhythmConsent.acceptedVersionKey) private var acceptedVersion = ""
    @AppStorage(RhythmConsent.enabledKey) private var enabled = false

    @State private var night: RhythmScreener.NightRhythmSummary?
    @State private var windows: [RhythmScreener.WindowResult] = []
    @State private var loaded = false

    private var consentGiven: Bool { enabled && RhythmConsent.isAccepted(acceptedVersion) }

    var body: some View {
        RhythmView(night: night, windows: windows, onClose: onClose)
            // Only compute once consent is given (the view shows the gate otherwise) AND on fresh data.
            .task(id: "\(consentGiven)|\(repo.refreshSeq)") {
                guard consentGiven, !loaded else { return }
                await load()
                loaded = true
            }
    }

    /// Read the most recent banked sleep session, pull its R-R + gravity, split into ~5-minute windows,
    /// gate each on stillness + resting rate, and screen it. Descriptive stats only — never a verdict.
    private func load() async {
        guard let store = await repo.storeHandle(),
              let lastSleep = (await repo.allSleepSessions(days: 14)).last else { return }
        let lo = lastSleep.effectiveStartTs
        let hi = lastSleep.endTs
        guard hi > lo else { return }
        let rr = (try? await store.rrIntervals(deviceId: repo.deviceId, from: lo, to: hi, limit: 200_000)) ?? []
        // BLE-only users have their night under the computed source; fall back to it when the imported
        // device yields nothing.
        let rrRows = rr.isEmpty
            ? ((try? await store.rrIntervals(deviceId: repo.deviceId + "-noop", from: lo, to: hi, limit: 200_000)) ?? [])
            : rr
        guard !rrRows.isEmpty else { return }
        let grav = (try? await store.gravitySamples(deviceId: repo.deviceId, from: lo, to: hi, limit: 200_000)) ?? []

        // Window the night into 5-minute slices; a slice is "still" when its gravity variance is small.
        let windowSec = 5 * 60
        var results: [RhythmScreener.WindowResult] = []
        var t = lo
        while t < hi {
            let wEnd = min(t + windowSec, hi)
            let wRR = rrRows.filter { $0.ts >= t && $0.ts < wEnd }
            if wRR.count >= RhythmScreener.windowMinBeats {
                let wGrav = grav.filter { $0.ts >= t && $0.ts < wEnd }
                let still = Self.isStill(wGrav)
                let input = RhythmScreener.WindowInput(rr: wRR, motionStill: still)
                results.append(RhythmScreener.screenWindow(input))
            }
            t = wEnd
        }
        windows = results
        night = RhythmScreener.summarizeNight(results)
    }

    /// A window is "still" when its accelerometer magnitude varies little (a resting wrist). A coarse,
    /// conservative gate — movement is the single biggest false signal for a regularity read, so we err
    /// toward NOT reading a window rather than describing a moving one.
    private static func isStill(_ grav: [GravitySample]) -> Bool {
        guard grav.count >= 4 else { return false }
        let mags = grav.map { ($0.x * $0.x + $0.y * $0.y + $0.z * $0.z).squareRoot() }
        let mean = mags.reduce(0, +) / Double(mags.count)
        guard mean > 0 else { return false }
        let variance = mags.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(mags.count)
        // Normalised standard deviation below ~3% of the mean magnitude reads as a still wrist.
        return (variance.squareRoot() / mean) < 0.03
    }
}
