#if os(iOS)
import UIKit
import UniformTypeIdentifiers

/// Async wrappers around `UIDocumentPickerViewController` for importing/exporting the database
/// backup on iOS. Each call presents the system picker from the active window and resumes a
/// continuation with the chosen URL (or `nil` if cancelled).
enum DocumentPicker {

    /// Present the picker to export `url` (saves a copy into Files / iCloud Drive). Returns the
    /// destination URL the user picked, or `nil` if cancelled.
    @MainActor
    static func export(_ url: URL) async -> URL? {
        await present { coordinator in
            let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
            picker.delegate = coordinator
            return picker
        }
    }

    /// Present the picker to import a file of one of `types`. `asCopy` is used so we receive a
    /// readable local copy in our sandbox (no security-scoped bookkeeping needed).
    @MainActor
    static func importFile(_ types: [UTType]) async -> URL? {
        await present { coordinator in
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
            picker.delegate = coordinator
            picker.allowsMultipleSelection = false
            return picker
        }
    }

    /// Present a folder picker (Backup & Sync). Returns the chosen folder, or nil.
    ///
    /// To let the user actually SELECT a directory (not just dive into it), the picker must be built for
    /// OPENING the `.folder` content type with `asCopy: false`. The bare `forOpeningContentTypes:` form
    /// historically left Files' "Open"/"Select" greyed out for folders on some iOS builds (#859), because
    /// without the explicit `asCopy: false` the picker can resolve to a copy-in (import) presentation that
    /// only enables the button for files. Passing `asCopy: false` puts it in true open-in-place mode, where
    /// the directory itself is selectable and the button enables on a folder. The returned URL is
    /// security-scoped; the caller bookmarks it (see `FolderBackup.saveFolder`, which brackets the scoped
    /// access while minting the bookmark) so the chosen folder survives relaunch.
    ///
    /// `startingAt` (#1000a): an explicit starting directory — the caller's last-used folder when there
    /// is one, else our own Documents. Some iOS builds reportedly keep the Open/Select button disabled
    /// when the picker opens on its default "Recents"-style root; giving it a concrete `directoryURL`
    /// lands it on a real, selectable directory. HONESTY NOTE: we could not reproduce the dead button
    /// in-house and Apple documents `directoryURL` only as a hint, so on the affected iOS build this
    /// may or may not be the whole fix — which is why `BackupSyncView` now also surfaces a visible
    /// message when the picker comes back empty instead of failing silently.
    @MainActor
    static func pickFolder(startingAt root: URL? = nil) async -> URL? {
        await present { coordinator in
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            picker.delegate = coordinator
            picker.allowsMultipleSelection = false
            picker.directoryURL = root
                ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            return picker
        }
    }

    // MARK: - Presentation plumbing

    @MainActor
    private static func present(_ make: (Coordinator) -> UIDocumentPickerViewController) async -> URL? {
        guard let root = topViewController() else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            let coordinator = Coordinator(continuation: continuation)
            let picker = make(coordinator)
            // Keep the coordinator alive for the lifetime of the picker.
            objc_setAssociatedObject(picker, &Coordinator.assocKey, coordinator, .OBJC_ASSOCIATION_RETAIN)
            // The continuation is resumed ONLY by a delegate callback. UIKit can decline a presentation
            // SILENTLY — no throw, no delegate — when the target is already presenting or mid-transition
            // (`topViewController`'s walk down the presentedViewController chain is momentarily inconsistent
            // during an animation). The caller would then await a value that never arrives, hanging forever
            // and leaving `BackupSyncView.busy` stuck true — every control there is `.disabled(busy)`, so a
            // pick that never appeared wedged the entire screen with no message. In the presentation
            // completion, detect a picker that never reached a window and resume with nil. `finish` is
            // resume-once, so a picker that DID open cannot be double-resumed.
            root.present(picker, animated: true) {
                if picker.view.window == nil && picker.presentingViewController == nil {
                    DocumentPicker.recordEvent("not-presented", url: nil)
                    coordinator.finish(nil)
                }
            }
        }
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
            ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    private final class Coordinator: NSObject, UIDocumentPickerDelegate {
        static var assocKey = 0
        private let continuation: CheckedContinuation<URL?, Never>
        private var resumed = false
        /// When the sheet went up, so a dismissal can report how long it was open.
        private let presentedAt = Date()

        init(continuation: CheckedContinuation<URL?, Never>) {
            self.continuation = continuation
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            DocumentPicker.recordEvent(urls.isEmpty ? "picked-empty" : "picked", url: urls.first,
                                       openSeconds: Date().timeIntervalSince(presentedAt),
                                       startedIn: BackupPickerStart.category(controller.directoryURL))
            finish(urls.first)
        }

        /// UIKit calls this both when the user taps Cancel AND, as #2356 showed, when the user picks a
        /// folder and taps Open but iOS declines to grant it. Nothing in the API distinguishes them, so
        /// this must NOT report "cancelled": that asserts an intent we did not observe, and it sent the
        /// last investigation after a disabled Open button that was never the problem.
        ///
        /// What we DO know is that the sheet closed and handed back no URL. That is what it says, plus the
        /// two facts that let a reader tell the cases apart: how long the picker was open (a tap on Cancel
        /// is a couple of seconds; navigating into iCloud Drive and choosing a folder is far longer) and
        /// which directory it opened on.
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            DocumentPicker.recordEvent("closed without a folder", url: nil,
                                       openSeconds: Date().timeIntervalSince(presentedAt),
                                       startedIn: BackupPickerStart.category(controller.directoryURL))
            finish(nil)
        }

        /// Resume the awaiting caller exactly once. Not private: `present` calls it when UIKit declined
        /// to show the picker at all — the one outcome no delegate callback covers.
        func finish(_ url: URL?) {
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: url)
        }
    }

    /// #52 instrumentation: persist the last picker delegate outcome so a debug export can distinguish
    /// "the picker never called back / user cancelled" (its Open button never fired — an iOS picker
    /// issue the internal-folder fallback sidesteps) from "it returned a URL we then failed to bookmark"
    /// (our bug, see `FolderBackup.saveFolder`'s scoped/bookmark flags). Shared by all three pickers, so
    /// the export labels it "last picker event"; the folder pick is the one under investigation.
    /// `startedIn` is a CATEGORY, never a path or a folder name.
    ///
    /// This string is printed into the debug export, which people attach to public issues, and that export
    /// is not passed through a redactor. A folder someone chose can carry a person's name as easily as a
    /// strap can (#2337), so the name never leaves the device: note which KIND of folder the picker opened
    /// on, which is the whole diagnostic value, and drop the rest. The picked folder's own name has always
    /// been stored and never printed, for the same reason.
    static func recordEvent(_ kind: String, url: URL?, openSeconds: Double? = nil, startedIn: String? = nil) {
        let d = UserDefaults.standard
        d.set(kind, forKey: "backupPicker.lastEvent")
        d.set(Date().timeIntervalSince1970, forKey: "backupPicker.lastEventAt")
        d.set(url?.lastPathComponent ?? "", forKey: "backupPicker.lastName")
        // Written UNCONDITIONALLY, including the nil case. Writing only when present would leave the
        // duration and start folder from an earlier pick sitting beside a newer event, so the export
        // would show two facts about two different sessions as though they described one.
        d.set(openSeconds ?? 0, forKey: "backupPicker.lastOpenSeconds")
        d.set(startedIn ?? "", forKey: "backupPicker.lastStart")
    }
}

#endif

import Foundation

/// Which KIND of directory the backup folder picker opened on, with no name attached.
///
/// #1000a made the starting directory a variable (the last-used folder when there is one, else our own
/// Documents), so which of those it landed on is worth knowing when a pick fails. The NAME is not, and
/// must not travel: this string is printed into the debug export people attach to public issues, and a
/// folder someone chose carries a person's name as easily as a strap does (#2337).
///
/// Deliberately OUTSIDE the `#if os(iOS)` above, even though only the iOS picker calls it. It is pure
/// (a URL and `FileManager`, no UIKit), and behind the platform gate the macOS test bundle could only
/// match its call site as text and never actually run it. Out here the behaviour itself is testable,
/// which is the difference between pinning that a line exists and pinning that it is right.
enum BackupPickerStart {
    static func category(_ directory: URL?) -> String {
        guard let directory else { return "the picker default" }
        let ourDocuments = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return directory.standardizedFileURL == ourDocuments?.standardizedFileURL
            ? "NOOP's own folder" : "a folder you chose"
    }
}
