import Foundation

/// Mirror mode (macOS): this Mac shows a read-only copy of the iPhone's NOOP data instead of talking to
/// the strap itself.
///
/// Why: a WHOOP holds an encrypted bond with one device at a time, and the strap forgets history once a
/// device has offloaded it. A Mac that also connects steals the bond from the phone (no buzz, alarm or
/// sync there) and splits the history between two stores that never merge. Mirror mode keeps the phone
/// as the only device on the strap and gives the Mac the phone's data through Backup & Sync:
///
///   1. The iPhone backs up to a folder (iCloud Drive), daily or on "Back up now".
///   2. On every launch, BEFORE the store opens, this Mac restores the newest backup in that folder if it
///      hasn't loaded it yet (`restoreNewestOnLaunch`, called from `StrandApp.init`).
///   3. Every Bluetooth scan / connect path refuses while it is on (`BLEManager`, `SourceCoordinator`),
///      and this Mac never writes its own backups into the folder (it would then mirror itself).
///
/// Anything changed on the Mac is replaced by the next restore. iOS is always the source: `isEnabled` is
/// false there whatever the stored value.
enum MirrorMode {
    static let enabledKey = "mirror.enabled"
    private static let lastNameKey = "mirror.lastSnapshotName"
    private static let lastTimeKey = "mirror.lastSnapshotTimeMs"
    private static let statusKey = "mirror.lastStatus"
    private static let checkedAtKey = "mirror.lastCheckedAt"

    static var isEnabled: Bool {
        #if os(macOS)
        return UserDefaults.standard.bool(forKey: enabledKey)
        #else
        return false
        #endif
    }

    /// What the last launch did, for the Backup & Sync screen ("Loaded the iPhone backup from …").
    static var lastStatus: String? { UserDefaults.standard.string(forKey: statusKey) }
    /// When the last launch check ran (epoch seconds), 0 if never.
    static var lastCheckedAt: Double { UserDefaults.standard.double(forKey: checkedAtKey) }
    /// Whether this launch ran the mirror restore, so a toggle switched on mid-session can say a relaunch
    /// is needed instead of showing an older launch's status.
    private(set) static var ranThisLaunch = false

    /// Load the newest backup from the Backup & Sync folder if it is new. Must run before anything opens
    /// the store: the restore swaps the SQLite file underneath. Synchronous on purpose (it is launch-time,
    /// and the app can't show data until it's done); an iCloud file that isn't downloaded yet is NOT
    /// waited for: its download is started and the next launch picks it up.
    static func restoreNewestOnLaunch() {
        #if os(macOS)
        guard isEnabled else { return }
        ranThisLaunch = true
        let d = UserDefaults.standard
        let last = d.string(forKey: lastNameKey).map { (name: $0, timeMs: d.integer(forKey: lastTimeKey)) }
        let status: String
        switch FolderBackup.mirrorRestoreNewest(skipping: last) {
        case .restored(let name, let timeMs):
            d.set(name, forKey: lastNameKey)
            d.set(timeMs, forKey: lastTimeKey)
            status = String(localized: "Loaded the iPhone backup from \(stamp(timeMs)).")
        case .upToDate(let timeMs):
            status = String(localized: "Up to date with the iPhone backup from \(stamp(timeMs)).")
        case .downloading:
            status = String(localized: "A newer iPhone backup is downloading from iCloud. Reopen NOOP in a minute to load it.")
        case .noFolder:
            status = String(localized: "Choose the same backup folder the iPhone uses to start mirroring.")
        case .noBackups:
            status = String(localized: "No backups in the folder yet. On the iPhone, open Backup & Sync and tap Back up now.")
        case .failed(let message):
            status = String(localized: "Couldn't load the newest backup: \(message)")
        }
        d.set(status, forKey: statusKey)
        d.set(Date().timeIntervalSince1970, forKey: checkedAtKey)
        #endif
    }

    private static func stamp(_ timeMs: Int) -> String {
        guard timeMs > 0 else { return String(localized: "an unknown time") }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: Double(timeMs) / 1000))
    }
}
