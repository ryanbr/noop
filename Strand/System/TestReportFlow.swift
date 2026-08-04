import Foundation
import StrandAnalytics

#if canImport(UIKit)
import UIKit
import SafariServices
#elseif canImport(AppKit)
import AppKit
#endif

/// Drives the in-app "Report" action (spec section 5.2): build plus save the redacted .zip, open the
/// prefilled GitHub issue, then toast the user to attach the file. The decision logic lives in `Plan`
/// (pure, unit-tested); `run` performs the side effects over the shipped share path. The bundle is
/// already redacted by TestBundleAssembler (meta.redaction="v2"); this flow never re-scrubs.
///
/// Group B owns the assembler primitives (redactEntries, capEntries) and FileExport.exportBundle;
/// Group C owns the deep-link and this flow. The caller assembles the already-redacted, already-capped
/// entries (the Group D orchestrator composes redactEntries + capEntries + meta.json) and hands them
/// here, so this file depends only on the Group A/B/C contracts and stays compilable on its own.
enum TestReportFlow {

    /// Pure decisions, no side effects, so they are testable on any actor.
    enum Plan {
        /// noop-<profile>-<platform>-v<version>-<yyMMdd-HHmm>.zip (spec section 5.1). Delegates the
        /// stamp to FileExport.bundleName so the filename matches the export layer exactly.
        static func bundleName(profile: TestDomain, platform: String, version: String,
                               date: Date = Date()) -> String {
            FileExport.bundleName(profile: profile.id, platform: platform, version: version, date: date)
        }

        /// The toast shown after the issue page opens, naming the exact saved file to attach.
        static func attachToast(savedName: String) -> String {
            "Saved as \(savedName). On the next screen tap the paperclip and pick it."
        }

        /// GitHub's mobile composer can't reliably attach a .zip, so iOS also offers "Copy report.txt".
        /// macOS Finder drag-drop works, so the fallback is mobile-only.
        static func offersCopyFallback(platform: String) -> Bool {
            platform.lowercased() == "ios"
        }
    }

    /// The review gate is mandatory and not skippable (spec section 12): the flow only proceeds once
    /// the user has explicitly confirmed the review.
    static func shouldProceed(gate: ReportReviewGate) -> Bool { gate.isCleared }

    /// Save/share the already-redacted bundle, open the prefilled issue, and toast. `entries` is the
    /// redacted, capped bundle the caller assembled (the Group D orchestrator builds it from
    /// TestBundleAssembler.redactEntries + capEntries + meta.json). `showToast` and `copyToPasteboard`
    /// are injected so the call site supplies the platform presenters. Review-before-share is mandatory:
    /// nothing is shared, no URL opened and no toast shown until the gate is cleared (spec section 12).
    ///
    /// Async (#646/#651): `FileExport.exportBundle` now stages its zip off the main actor, so this awaits
    /// it before continuing to the toast/pasteboard steps below (same ordering as before, just non-blocking).
    @MainActor
    static func run(profile: TestDomain, title: String,
                    version: String, platform: String, osVersion: String,
                    gate: ReportReviewGate,
                    entries: [FileExport.BundleEntry],
                    showToast: @escaping (String) -> Void,
                    copyToPasteboard: @escaping (String) -> Void,
                    // CAPTURE-A (#812): the questionnaire-derived one-liner seeding the form's what_happens
                    // box. nil leaves that required field for the user. The report.txt tail is read from
                    // `entries` below, so a report submitted without the .zip still carries the trace.
                    whatHappensSeed: String? = nil) async {
        // Review-before-share is mandatory: do nothing until the user has confirmed.
        guard shouldProceed(gate: gate) else { return }
        let name = Plan.bundleName(profile: profile, platform: platform, version: version)
        // The redacted report.txt (already scrubbed by TestBundleAssembler) prefills the issue's log block
        // so a forgotten attachment doesn't yield an empty report (#812).
        let reportText = entries.first(where: { $0.name == "report.txt" })
            .flatMap { String(data: $0.data, encoding: .utf8) }
        let issueURL = TestReportLink.reportURL(profile: profile, title: title,
                                                version: version, platform: platform, osVersion: osVersion,
                                                reportText: reportText, whatHappensSeed: whatHappensSeed)
        // Save/share the .zip first, THEN open the prefilled issue. M1 (#812): on iOS the issue MUST open
        // in an in-app SFSafariViewController, never UIApplication.open, a bare github.com universal link
        // is handed to the installed GitHub app, which ignores the web prefill and just foregrounds itself
        // ("opens GitHub and nothing happens"). Opening it in the share sheet's completion (after the sheet
        // is dismissed) keeps the SafariVC from racing the share sheet and lets the user attach the .zip
        // they just saved. macOS opens in the default browser via NSWorkspace (no hijack there).
        #if canImport(UIKit)
        _ = await FileExport.exportBundle(entries: entries, suggestedName: name, completion: {
            if let issueURL { presentInSafari(issueURL) }
        })
        #elseif canImport(AppKit)
        _ = await FileExport.exportBundle(entries: entries, suggestedName: name)
        if let issueURL { NSWorkspace.shared.open(issueURL) }
        #endif
        showToast(Plan.attachToast(savedName: name))
        if Plan.offersCopyFallback(platform: platform),
           let report = entries.first(where: { $0.name == "report.txt" }),
           let text = String(data: report.data, encoding: .utf8) {
            // Offer the copy fallback by priming the pasteboard closure; the UI exposes a "Copy report.txt"
            // button bound to this same text so a mobile user who can't attach can paste a <details> block.
            copyToPasteboard(text)
        }
    }

    #if canImport(UIKit)
    /// M1 (#812): present the prefilled new-issue URL in an in-app Safari view so the installed GitHub app
    /// cannot hijack the github.com universal link (which it does for a bare UIApplication.open, ignoring
    /// the web prefill). Climbs to the top-most view controller, the same presenter pattern FileExport uses.
    @MainActor
    private static func presentInSafari(_ url: URL) {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
                ?? scene.windows.first?.rootViewController else {
            UIApplication.shared.open(url)   // last-resort fallback if no window is reachable
            return
        }
        var presenter = root
        while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
        presenter.present(SFSafariViewController(url: url), animated: true)
    }
    #endif
}
