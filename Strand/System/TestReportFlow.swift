import Foundation
import StrandAnalytics

/// Drives the in-app "Share" action (spec section 5.2): build plus save the redacted .zip and hand it to
/// the share sheet. The decision logic lives in `Plan` (pure, unit-tested); `run` performs the side
/// effects over the shipped share path. The bundle is already redacted by TestBundleAssembler
/// (meta.redaction="v2"); this flow never re-scrubs.
///
/// It used to open a prefilled GitHub issue after sharing, which is why the button said "Report". That
/// step is gone: the app takes nothing off the device and names no destination, and this button now does
/// what the strap-log Share button beside it does. Filing an issue, and attaching the saved file to it,
/// is the reporter's own step.
///
/// Group B owns the assembler primitives (redactEntries, capEntries) and FileExport.exportBundle;
/// Group C owns this flow. The caller assembles the already-redacted, already-capped
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

        /// The toast shown after the share sheet, naming the exact saved file.
        ///
        /// It used to read "On the next screen tap the paperclip and pick it", which described the GitHub
        /// issue composer this flow opened. Nothing opens a composer now, so the line says where the file
        /// went and stops there rather than instructing the user through a screen they will not see.
        static func attachToast(savedName: String) -> String {
            "Saved as \(savedName). Attach it to your bug report."
        }

        /// Mobile share sheets make a .zip awkward to paste into a web form, so iOS also offers
        /// "Copy report.txt" for a reporter writing an issue by hand. macOS Finder drag-drop works, so the
        /// fallback stays mobile-only.
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
                    copyToPasteboard: @escaping (String) -> Void) async {
        // Review-before-share is mandatory: do nothing until the user has confirmed.
        guard shouldProceed(gate: gate) else { return }
        let name = Plan.bundleName(profile: profile, platform: platform, version: version)
        // Share the .zip and stop. Nothing is opened, navigated to, or sent: the destination is whatever
        // the user picks in the sheet, and the app never names one.
        _ = await FileExport.exportBundle(entries: entries, suggestedName: name)
        showToast(Plan.attachToast(savedName: name))
        if Plan.offersCopyFallback(platform: platform),
           let report = entries.first(where: { $0.name == "report.txt" }),
           let text = String(data: report.data, encoding: .utf8) {
            // Offer the copy fallback by priming the pasteboard closure; the UI exposes a "Copy report.txt"
            // button bound to this same text, so a reporter writing an issue by hand can paste a
            // <details> block instead of wrestling a .zip into a web form on a phone.
            copyToPasteboard(text)
        }
    }
}
