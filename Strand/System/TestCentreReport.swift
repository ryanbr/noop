import Foundation
import SwiftUI
import StrandAnalytics

/// The Report action behind every Test Centre Report button (spec section 5.2 flow). It assembles the
/// redacted, capped bundle for the active profile, presents the MANDATORY review-before-share sheet
/// (spec section 12) bound to the exact report.txt the user is about to share, and only on an explicit
/// confirm hands the bundle to TestReportFlow.run (which saves/shares it, opens the prefilled GitHub
/// issue, and toasts). No network of our own, no cloud.
///
/// This is the thin orchestrator that ties Group D's UI to the Group B/C contracts (TestBundleAssembler,
/// FileExport.exportBundle, ReportReviewGate, TestReportLink, TestReportFlow). It is an ObservableObject
/// so the screen can present the review sheet off `pendingReview`.
@MainActor
final class TestCentreReport: ObservableObject {

    /// A report pending the user's review. The screen presents a sheet bound to `gate.previewText` while
    /// this is non-nil; confirming calls `confirm()`, cancelling calls `cancel()`.
    struct Pending: Identifiable {
        let id = UUID()
        let profile: TestDomain
        let title: String
        var gate: ReportReviewGate
        /// #1002: true when the selected profile's test mode is NOT on at report time (never activated,
        /// or turned off) - so the bundle carries no capture for the very thing being reported. The
        /// review sheet shows a plain warning off this; the #812 capture_check can't cover it because it
        /// only grades ACTIVE domains. Always false for the master profile (it has no wear-and-capture
        /// mode of its own).
        var modeInactive: Bool = false
    }

    /// Non-nil while a report is awaiting review. Drive a `.sheet(item:)` off this.
    @Published var pending: Pending?

    /// A one-line status banner the screen can show after a share fires (the app has no global toast).
    @Published var lastStatus: String?

    /// M3 (#812): the redacted report.txt for the iOS "Copy report.txt" fallback. Set after a confirmed
    /// share on the mobile path (TestReportFlow.Plan.offersCopyFallback); the screen surfaces a button
    /// bound to it so a user who cannot attach the .zip can paste the <details> block straight into the
    /// issue. nil on macOS / when there is nothing to copy, so the button stays hidden.
    @Published var copyableReport: String?

    /// Build the redacted bundle for `mode` and stage it for review. Nothing leaves the device yet.
    /// Async under the hood (#1002): the storage probe reads the store actor, so the bundle is staged a
    /// beat after the tap; the sheet presents off `pending` exactly as before. `repo` is the live
    /// Repository for the row-count probe - nil (tests/previews) skips the store read and the meta keeps
    /// the honest zeroed block.
    func start(mode: TestMode, live: LiveState, repo: Repository? = nil) {
        Task { @MainActor [weak self] in
            let storage = await TestCentreReport.storageProbe(repo: repo, live: live)
            // #1002: the connected model. BLEManager persists the DETECTED family to this key on every
            // connect, so it reflects the strap that actually linked - nil before any strap ever did.
            // Read, never guessed.
            let model = UserDefaults.standard.string(forKey: "selectedWhoopModel")
            let entries = TestBundleAssembler.assemble(profile: mode.domain, live: live,
                                                       storage: storage, strapModel: model)
            self?.pending = Pending(profile: mode.domain, title: mode.title,
                                    gate: ReportReviewGate(entries: entries),
                                    modeInactive: mode.domain != .master && !TestCentre.active(mode.domain))
        }
    }

    /// #1002: the REAL storage probe behind meta.json's storage block, replacing the Phase-1 zeros.
    /// - db_bytes: the store's on-disk footprint (whoop.sqlite + its -wal/-shm sidecars), read off the
    ///   filesystem so it is the byte count a maintainer can reason about.
    /// - rows: per-table row counts read via the store (the same COUNTs the store's stats surface runs).
    /// - raw_capture_bytes: the banked rawBatch bytes in the store PLUS the on-disk raw-capture .jsonl
    ///   when the frame recorder is on - the full raw-capture footprint (#590).
    /// Returns nil when nothing was readable (store unopenable AND no file), so the caller's zeroed
    /// fallback stays an honest "unreadable", never a fabricated figure.
    static func storageProbe(repo: Repository?, live: LiveState) async -> TestBundleMeta.Storage? {
        let fm = FileManager.default
        var dbBytes = 0
        if let path = try? StorePaths.defaultDatabasePath() {
            for suffix in ["", "-wal", "-shm"] {
                dbBytes += (try? fm.attributesOfItem(atPath: path + suffix))?[.size] as? Int ?? 0
            }
        }
        var rows: [String: Int] = [:]
        var rawBytes = 0
        if let store = await repo?.storeHandle() {
            if let c = try? await store.storageStats_rowCountsForTest() {
                rows = ["hr": c.hr, "rr": c.rr, "events": c.events, "battery": c.battery,
                        "spo2": c.spo2, "skinTemp": c.skinTemp, "resp": c.resp, "gravity": c.gravity]
            }
            if let steps = try? await store.stepCountForTest() { rows["steps"] = steps }
            rawBytes = (try? await store.storageStats().rawBytes) ?? 0
        }
        if let url = live.puffinCaptureURL {
            rawBytes += (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        }
        guard dbBytes > 0 || !rows.isEmpty || rawBytes > 0 else { return nil }
        return TestBundleMeta.Storage(dbBytes: dbBytes, rows: rows, rawCaptureBytes: rawBytes)
    }

    /// The user read the report and confirmed: clear the gate and run the shipped share + deep-link flow.
    func confirm() {
        guard var p = pending else { return }
        p.gate.confirm()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        #if os(iOS)
        let platform = "iOS"
        #else
        let platform = "macOS"
        #endif
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        // CAPTURE-A (#812): seed the issue's what_happens box from the tester's own questionnaire answers so
        // a report submitted without the .zip still opens with their words. The log tail is prefilled inside
        // TestReportFlow from the redacted report.txt entry.
        let seed = TestModeRegistry.mode(p.profile).flatMap {
            TestReportLink.whatHappensSeed(questionnaire: $0.questionnaire, answers: TestCentre.answers(p.profile))
        }
        // Launched (#646/#651): TestReportFlow.run is now async since it awaits FileExport.exportBundle's
        // off-main zip build.
        Task {
            await TestReportFlow.run(
                profile: p.profile, title: p.title,
                version: version, platform: platform, osVersion: osVersion,
                gate: p.gate,
                entries: p.gate.entries,
                showToast: { [weak self] msg in self?.lastStatus = msg },
                // M3: prime the clipboard AND surface the report for a visible "Copy report.txt" button so
                // the documented mobile fallback is reachable, not just silently on the pasteboard.
                copyToPasteboard: { [weak self] text in PlatformPasteboard.copy(text); self?.copyableReport = text },
                whatHappensSeed: seed)
        }
        pending = nil
    }

    /// The user cancelled the review: nothing is shared.
    func cancel() { pending = nil }
}
