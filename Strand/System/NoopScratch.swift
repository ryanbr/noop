import Foundation

/// NOOP's own scratch area inside the process temporary directory, and the sweep that reclaims it.
///
/// Everything NOOP stages in temp lives under one folder it owns, and the sweep removes only what is
/// inside that folder. It used to stage files flat and sweep every sibling whose name began `noop-`,
/// on the stated premise that "the temp dir is NOOP's private sandbox".
///
/// That premise holds on iOS and does not hold on macOS. `Strand.entitlements` does declare
/// `com.apple.security.app-sandbox`, but entitlements only apply to a signed build, and the
/// distributed macOS build is produced with `CODE_SIGNING_ALLOWED=NO` and then ad-hoc re-signed with
/// no entitlements at all (`project.yml` says so beside the entitlement). So the shipped Mac app is
/// unsandboxed, its `temporaryDirectory` is the shared per-user `/var/folders/.../T/`, and the sweep
/// was deleting any process's `noop-*` items more than a minute old, on every launch and on Storage's
/// "Clean up". #2446 hit exactly that: a verification run's own `$TMPDIR/noop-verify` and
/// `noop-measure` folders were removed underneath a live `xcodebuild`.
///
/// Owning a folder removes the guesswork rather than narrowing it: nothing outside it is a candidate,
/// whatever it is called.
enum NoopScratch {

    /// The folder NOOP owns inside the temporary directory, named for the running bundle.
    ///
    /// Not a plain "NOOP". Everything inside this folder is removed by [purge] WITHOUT being matched by
    /// name, on the grounds that NOOP put it there, so the name has to be one nothing else will have
    /// taken. A short one would not be: macOS filesystems are case-insensitive by default, so `NOOP`
    /// and `noop` are the same directory, and the very report behind this change had a process writing
    /// `noop-verify` and `noop-measure` into that shared folder. Adopting a stranger's directory and
    /// then emptying it is the bug this change exists to end, one level down.
    ///
    /// The bundle identifier is per-install and fork-specific, so a collision needs another program
    /// shipping under this app's own identifier. The fallback only applies where there is no bundle id
    /// at all, which in practice is a bare command-line host.
    static var folderName: String { (Bundle.main.bundleIdentifier ?? "com.noopapp.noop") + ".scratch" }

    /// NOOP's scratch folder. Not created; see [directory].
    static func root(in temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> URL {
        temporaryDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    /// NOOP's scratch folder, created if it is not there yet.
    ///
    /// Best-effort: a creation failure returns the URL anyway, so a caller fails on its own write with
    /// its own error rather than on a directory it never asked about.
    @discardableResult
    static func directory(in temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> URL {
        let url = root(in: temporaryDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A URL for `name` inside NOOP's scratch folder, creating the folder first.
    static func file(_ name: String,
                     in temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> URL {
        directory(in: temporaryDirectory).appendingPathComponent(name)
    }

    /// A URL for a subdirectory `name` inside NOOP's scratch folder, creating the parent first.
    static func subdirectory(_ name: String,
                             in temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> URL {
        directory(in: temporaryDirectory).appendingPathComponent(name, isDirectory: true)
    }
    /// Every legacy flat scratch prefix NOOP itself wrote before it owned a folder.
    ///
    /// EXACT prefixes, not the open `noop-` the sweep used to take. These are the names the app
    /// demonstrably writes, so a stranded multi-GB `noop-health-` extraction from an interrupted
    /// import (#590) is still reclaimed, while a sibling this app never created is not a candidate:
    /// the `noop-verify`, `noop-measure` and `noop-canary-a` of #2446 match none of them.
    ///
    /// This list only has to cover builds that predate the owned folder, so it can go once those are
    /// no longer in the field. Nothing new should be added to it.
    static let legacyFlatPrefixes = [
        "noop-settings-", "noop-manifest-", "noop-import-", "noop-health-", "noop-xiaomi-",
        "noop-export-", "noop-recap-", "noop-5mg-raw-", "noop-strap-log-", "noop-raw-sensors-",
        "noop-route-",
    ]

    /// Legacy flat scratch NOOP wrote before it owned a folder, by exact name.
    ///
    /// `noop-last-crash.txt` and `noop-raw-capture-*` are deliberately absent: they are written to the
    /// caches and documents directories, never to temp, so they were never swept and must not start
    /// being. Matching a name is only safe for a directory this app stages into.
    static let legacyFlatNames = ["noop-rhythm.csv"]

    /// Whether `name` is flat scratch an earlier build of THIS app wrote.
    static func isLegacyFlatScratch(_ name: String) -> Bool {
        legacyFlatNames.contains(name) || legacyFlatPrefixes.contains { name.hasPrefix($0) }
    }

    /// Bytes currently held in NOOP's scratch folder, legacy flat scratch included.
    ///
    /// The Storage screen reports this, so it has to count what [purge] would reclaim and nothing
    /// else. Counting a sibling NOOP did not write would attribute another program's disk to NOOP.
    static func sizeBytes(in temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                          measure: (URL) -> Int64) -> Int64 {
        var total = measure(root(in: temporaryDirectory))
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: temporaryDirectory,
                                                   includingPropertiesForKeys: nil, options: []) {
            for item in items where isLegacyFlatScratch(item.lastPathComponent) {
                total += measure(item)
            }
        }
        return total
    }

    /// Remove NOOP's scratch: everything inside the folder it owns, plus legacy flat scratch.
    ///
    /// Keeps the 60 s in-flight guard the flat sweep had, so a running import or export is not pulled
    /// out from under itself.
    static func purge(in temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                      now: Date = Date()) {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-60)

        func removeIfSettled(_ item: URL) {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified > cutoff { return }
            try? fm.removeItem(at: item)
        }

        // Inside the owned folder every entry is ours, so nothing is matched by name.
        if let mine = try? fm.contentsOfDirectory(at: root(in: temporaryDirectory),
                                                  includingPropertiesForKeys: [.contentModificationDateKey],
                                                  options: []) {
            mine.forEach(removeIfSettled)
        }
        // Outside it, only what an earlier build of this app wrote.
        if let siblings = try? fm.contentsOfDirectory(at: temporaryDirectory,
                                                      includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: []) {
            siblings.filter { isLegacyFlatScratch($0.lastPathComponent) }.forEach(removeIfSettled)
        }
    }

}
