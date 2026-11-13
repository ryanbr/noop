import Foundation

/// Top-level entry points for Strand's data import. Takes a `URL` (a folder,
/// `export.zip`, `export.xml`, or a Whoop CSV `.zip`) and returns the normalized
/// model arrays plus an `ImportSummary` (record count + date range).
///
/// This layer is **parsing only** — it does not touch the database. Persistence
/// is wired in a later integration step; keeping the coordinator pure makes the
/// whole package unit-testable.
public struct ImportCoordinator {

    private let appleHealth: AppleHealthImporter
    private let whoop: WhoopExportImporter
    private let xiaomi: XiaomiBandImporter
    private let wearable: WearableExportImporter

    public init(
        appleHealth: AppleHealthImporter = AppleHealthImporter(),
        whoop: WhoopExportImporter = WhoopExportImporter(),
        xiaomi: XiaomiBandImporter = XiaomiBandImporter(),
        wearable: WearableExportImporter = WearableExportImporter()
    ) {
        self.appleHealth = appleHealth
        self.whoop = whoop
        self.xiaomi = xiaomi
        self.wearable = wearable
    }

    // MARK: - Explicit-kind entry points

    /// Parse an Apple Health export (`export.zip`, `export.xml`, or a folder).
    ///
    /// `retainRawSamples` defaults to `true` so existing call sites and tests get
    /// the raw `samples` array. The app's import path passes `false` so a
    /// multi-year export is folded into per-day aggregates incrementally and the
    /// raw samples are dropped, keeping peak memory bounded (issue #355).
    public func importAppleHealth(
        from url: URL,
        retainRawSamples: Bool = true
    ) throws -> AppleHealthImportResult {
        // Reuse the injected importer when its flag already matches (keeps any
        // custom importer the caller supplied); otherwise build one with the
        // requested retention so callers can opt into bounded memory per-call.
        if retainRawSamples == appleHealth.retainRawSamples {
            return try appleHealth.import(from: url)
        }
        return try AppleHealthImporter(retainRawSamples: retainRawSamples).import(from: url)
    }

    /// Parse a Whoop CSV export (`.zip` or folder).
    public func importWhoopExport(from url: URL) throws -> WhoopImportResult {
        try whoop.import(from: url)
    }

    /// Parse a Xiaomi / Mi Band export (the Mi Fitness sandbox folder, a `.zip` of it,
    /// or the bare `<user_id>.db`).
    public func importXiaomiBand(from url: URL) throws -> XiaomiImportResult {
        try xiaomi.import(from: url)
    }

    /// Parse a user's own Oura / Fitbit / Garmin data export (a `.json`, a folder, or a `.zip`).
    /// The brand is auto-detected by content.
    public func importWearableExport(from url: URL) throws -> WearableImportResult {
        try wearable.import(from: url)
    }

    // MARK: - Auto-detecting entry point

    /// The detected kind plus exactly one of the two result payloads.
    public enum DetectedImport: Sendable, Equatable {
        case appleHealth(AppleHealthImportResult)
        case whoopExport(WhoopImportResult)
        case xiaomiBand(XiaomiImportResult)
        case wearable(WearableImportResult)

        public var kind: DataSourceKind {
            switch self {
            case .appleHealth: return .appleHealth
            case .whoopExport: return .whoopExport
            case .xiaomiBand: return .xiaomiBand
            case .wearable(let r): return r.brand.dataSourceKind
            }
        }

        public var summary: ImportSummary {
            switch self {
            case .appleHealth(let r): return r.summary
            case .whoopExport(let r): return r.summary
            case .xiaomiBand(let r): return r.summary
            case .wearable(let r): return r.summary
            }
        }
    }

    /// Inspect the input and route to the correct importer.
    ///
    /// Detection heuristics:
    /// - A path/entry named `export.xml` → Apple Health.
    /// - A folder/zip containing `physiological_cycles.csv` (or any of the Whoop
    ///   CSVs) → Whoop export.
    /// - A folder/zip containing `export.xml` → Apple Health.
    public func detectAndImport(from url: URL) throws -> DetectedImport {
        // The three first-party exports have distinctive structural markers; try them first.
        let kind: DataSourceKind
        do {
            kind = try detectKind(of: url)
        } catch ImportError.notAZipOrFolder {
            // A readable file with no first-party marker: hand it to the Oura/Fitbit/Garmin wearable
            // export importer, which sniffs the brand by content. ONLY this case falls through. A
            // genuinely missing file (fileNotFound) or any other structural error is re-thrown so the
            // user sees the real problem instead of a misleading "not an Oura/Fitbit/Garmin export".
            return .wearable(try wearable.import(from: url))
        }
        switch kind {
        case .appleHealth:
            return .appleHealth(try appleHealth.import(from: url))
        case .whoopExport:
            return .whoopExport(try whoop.import(from: url))
        case .xiaomiBand:
            return .xiaomiBand(try xiaomi.import(from: url))
        // detectKind never returns the wearable-import kinds (it has no marker for them) — the wearable
        // importer owns brand detection. Unreachable but kept exhaustive.
        case .ouraImport, .fitbitImport, .garminImport:
            return .wearable(try wearable.import(from: url))
        }
    }

    /// Determine which kind of export a URL points at without parsing it fully.
    public func detectKind(of url: URL) throws -> DataSourceKind {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ImportError.fileNotFound(url.path)
        }

        let ext = url.pathExtension.lowercased()
        if ext == "xml" { return .appleHealth }
        // A bare Mi Fitness SQLite file.
        if ext == "db" { return .xiaomiBand }

        let names = try entryFilenames(of: url, isDirectory: isDir.boolValue)
        if names.contains("export.xml") { return .appleHealth }
        // A localised Apple Health export (`apple_health_export/导出.xml`) carries no `export.xml`.
        // A folder is matched by full path, so picking `apple_health_export/` itself still sees
        // the folder name as the file's parent.
        if isDir.boolValue {
            if let e = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for case let u as URL in e where AppleHealthExportLocator.isMainExportEntry(u.path) {
                    return .appleHealth
                }
            }
        } else if let paths = try? ZipPeek.paths(in: url),
                  paths.contains(where: AppleHealthExportLocator.isMainExportEntry) {
            return .appleHealth
        }
        let whoopNames: Set<String> = [
            "physiological_cycles.csv", "sleeps.csv", "workouts.csv", "journal_entries.csv",
        ]
        if !names.isDisjoint(with: whoopNames) { return .whoopExport }

        // Mi Fitness sandbox: a `DataBase/<user_id>/de/<user_id>.db` somewhere inside.
        if try containsMiFitnessDB(of: url, isDirectory: isDir.boolValue) { return .xiaomiBand }

        throw ImportError.notAZipOrFolder(url.path)
    }

    /// True if a folder or zip holds a Mi Fitness health DB (`.../de/<…>.db`).
    private func containsMiFitnessDB(of url: URL, isDirectory: Bool) throws -> Bool {
        func isHealthDBPath(_ p: String) -> Bool {
            let lower = p.lowercased()
            return lower.hasSuffix(".db") && lower.contains("/de/")
        }

        if isDirectory {
            let fm = FileManager.default
            guard let e = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                return false
            }
            for case let u as URL in e where isHealthDBPath(u.path) { return true }
            return false
        }

        guard let paths = try? ZipPeek.paths(in: url) else { return false }
        return paths.contains(where: isHealthDBPath)
    }

    // MARK: - Helpers

    /// Lowercased base filenames present in a folder or zip (shallow scan of all
    /// entries; cheap because we only read the zip's central directory or list
    /// the folder).
    private func entryFilenames(of url: URL, isDirectory: Bool) throws -> Set<String> {
        let fm = FileManager.default
        var names: Set<String> = []

        if isDirectory {
            if let e = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for case let u as URL in e {
                    names.insert(u.lastPathComponent.lowercased())
                }
            }
            return names
        }

        // A file: peek into it as a zip via the importer-agnostic helper.
        if let zipNames = try? ZipPeek.filenames(in: url) {
            return zipNames
        }
        // Not a zip — just record the single filename.
        names.insert(url.lastPathComponent.lowercased())
        return names
    }
}

// MARK: - Lightweight zip listing

import ZIPFoundation

/// Reads only the zip central directory to list base filenames — no extraction.
enum ZipPeek {
    static func filenames(in zipURL: URL) throws -> Set<String> {
        let archive = try Archive(url: zipURL, accessMode: .read)
        var names: Set<String> = []
        for entry in archive where entry.type == .file {
            names.insert((entry.path as NSString).lastPathComponent.lowercased())
        }
        return names
    }

    /// Full relative entry paths (lowercased) — for structure-aware detection where a
    /// base filename isn't enough (e.g. spotting `DataBase/<id>/de/<id>.db`).
    static func paths(in zipURL: URL) throws -> [String] {
        let archive = try Archive(url: zipURL, accessMode: .read)
        return archive.compactMap { $0.type == .file ? $0.path.lowercased() : nil }
    }
}
