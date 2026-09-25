import Foundation
#if canImport(FoundationXML)
// corelibs Foundation moved the event-driven XML parser into its own module; Darwin keeps it in
// Foundation. Conditional so one import serves both, with no #if at the use sites.
import FoundationXML
#endif
import ZIPFoundation

/// Parses an Apple Health export (`export.xml`, possibly inside `export.zip`)
/// into normalized Swift models using a **streaming SAX parser**
/// (`XMLParser`/`XMLParserDelegate`) — never a DOM, because the file can exceed
/// 1 GB.
///
/// Behaviour (per Strand design spec §3.1 / §7.1):
/// - Maintains an element stack to track nesting (`Correlation`, `Workout`,
///   `MetadataEntry`, etc.).
/// - Filters to the relevant `Record` types only.
/// - `OxygenSaturation` is a 0–1 fraction → multiplied by 100.
/// - `SleepAnalysis` category values mapped to `SleepStage`.
/// - **Dedupe:** records nested inside a `<Correlation>` also appear at top
///   level → only top-level records are ingested, and a final dedupe pass on
///   `type+start+end+source+value` removes any residual duplicates.
/// - Dates `yyyy-MM-dd HH:mm:ss Z` parsed with `Locale(en_US_POSIX)`.
public struct AppleHealthImporter {

    /// When `true` (the default) the parsed `[HealthSample]` array is retained on
    /// the result — what every existing test and call site expects. The app's
    /// real import path passes `false` so a multi-year export is folded into
    /// per-day aggregates incrementally and the raw samples are dropped, keeping
    /// peak memory bounded (issue #355). The per-day `sampleDailies` are always
    /// produced regardless of this flag.
    public let retainRawSamples: Bool

    public init(retainRawSamples: Bool = true) {
        self.retainRawSamples = retainRawSamples
    }

    /// Health types Strand cares about (prefix already stripped).
    public static let relevantTypes: Set<String> = [
        "HeartRate",
        "RestingHeartRate",
        "HeartRateVariabilitySDNN",
        "WalkingHeartRateAverage",
        "OxygenSaturation",
        "BodyTemperature",
        "AppleSleepingWristTemperature",
        "RespiratoryRate",
        "ActiveEnergyBurned",
        "BasalEnergyBurned",
        "VO2Max",
        "StepCount",
        "SleepAnalysis",
        // Body composition
        "BodyMass",
        "BodyFatPercentage",
        "LeanBodyMass",
        "BodyMassIndex",
    ]

    // MARK: - Public entry points

    /// Import from `export.zip` or a path to `export.xml` (or a folder
    /// containing it).
    public func `import`(from url: URL) throws -> AppleHealthImportResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ImportError.fileNotFound(url.path)
        }

        if isDir.boolValue {
            guard let xmlURL = findExportXML(inFolder: url) else {
                throw ImportError.missingEntry("export.xml")
            }
            return try importXML(at: xmlURL)
        }

        let ext = url.pathExtension.lowercased()
        if ext == "xml" {
            return try importXML(at: url)
        }
        if ext == "zip" {
            return try importZip(at: url)
        }
        // Unknown extension: try zip first, then raw XML.
        if let z = try? importZip(at: url) { return z }
        return try importXML(at: url)
    }

    /// Stream-parse a raw `export.xml` file.
    public func importXML(at xmlURL: URL) throws -> AppleHealthImportResult {
        // Stream from disk via an InputStream rather than XMLParser(contentsOf:), which would load
        // the entire (multi-hundred-MB) file into memory before parsing.
        guard let raw = InputStream(url: xmlURL) else {
            throw ImportError.fileNotFound(xmlURL.path)
        }
        // Wrap the disk stream in a sanitizer so XML-1.0-illegal bytes (stray control chars, broken
        // UTF-8 from a decade-old export) are scrubbed in fixed-size chunks BEFORE libxml2 sees them.
        // Without this a single bad byte mid-file (libxml2 error 65 / SpaceRequired etc.) aborts the
        // whole multi-year import. The sanitizer is itself an InputStream, so streaming/memory bounds
        // are preserved — nothing is buffered to RAM or disk.
        let sanitizer = SanitizingInputStream(source: raw)
        return try runParser(XMLParser(stream: sanitizer), sanitizer: sanitizer)
    }

    /// Parse a `Data` blob of XML (used for the zip-streaming path and tests).
    public func importXML(data: Data) throws -> AppleHealthImportResult {
        // Route the in-memory path through the same sanitizing stream so tests and the (rare) data
        // path get identical tolerance to illegal bytes / broken UTF-8 as the disk path.
        let sanitizer = SanitizingInputStream(source: InputStream(data: data))
        return try runParser(XMLParser(stream: sanitizer), sanitizer: sanitizer)
    }

    // MARK: - Zip handling

    private func importZip(at zipURL: URL) throws -> AppleHealthImportResult {
        let archive: Archive
        do {
            archive = try Archive(url: zipURL, accessMode: .read)
        } catch {
            throw ImportError.notAZipOrFolder(zipURL.path)
        }

        // Locate the export.xml entry by filename anywhere in the archive
        // (Apple nests it under apple_health_export/).
        var target: Entry?
        for entry in archive where entry.type == .file {
            if (entry.path as NSString).lastPathComponent.lowercased() == "export.xml" {
                target = entry
                break
            }
        }
        guard let entry = target else { throw ImportError.missingEntry("export.xml") }

        // Decompress export.xml to a temp file (chunks go straight to disk, so RAM stays bounded),
        // then stream-parse it from disk. This replaces a pipe-fed background parser that could
        // deadlock or crash with a broken-pipe exception on a malformed/malicious export.
        // Inside the app's own bundle-named scratch folder, not flat beside it. On the unsandboxed Mac build
        // the temporary directory is shared with every other process of the user, so the launch sweep
        // that reclaims an interrupted import (#590) used to match siblings by a `noop-` prefix and
        // deleted files it did not write (#2446). The folder name is spelled here rather than shared
        // from the app target, which this package cannot see; `NoopScratch` in Strand/System owns it.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent((Bundle.main.bundleIdentifier ?? "com.noopapp.noop") + ".scratch",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let tmp = scratch.appendingPathComponent("health-\(UUID().uuidString).xml")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: tmp) else {
            throw ImportError.xmlParseFailed("could not open a temp file for import")
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        var written = 0
        let cap = 8 << 30   // 8 GB decompressed ceiling (real exports are < 2 GB) — zip-bomb guard
        do {
            _ = try archive.extract(entry, bufferSize: 1 << 20) { chunk in
                written += chunk.count
                if written > cap { throw ImportError.xmlParseFailed("export.xml too large") }
                try handle.write(contentsOf: chunk)
            }
        } catch {
            try? handle.close()
            throw ImportError.xmlParseFailed("could not read export.xml from zip: \(error.localizedDescription)")
        }
        try? handle.close()

        return try importXML(at: tmp)
    }

    // MARK: - Core parse

    private func runParser(
        _ parser: XMLParser,
        sanitizer: SanitizingInputStream? = nil
    ) throws -> AppleHealthImportResult {
        let delegate = HealthXMLDelegate(retainRawSamples: retainRawSamples)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        let ok = parser.parse()

        // How many illegal-byte runs the sanitizer scrubbed before the parser ran. Always surfaced.
        let scrubbedRuns = sanitizer?.scrubbedRunCount ?? 0

        if !ok || delegate.parseError != nil {
            // TOLERANT PARSE: a hard XML error can still slip past the sanitizer (e.g. a structurally
            // broken tag, not just a bad byte). If we already parsed at least one record, keep the
            // partial result rather than discarding a whole 15-year import over the tail. The dropped
            // span is COUNTED and surfaced, never hidden.
            if delegate.hasAnyRecord {
                return delegate.makeResult(extraSkippedSpans: scrubbedRuns + 1)
            }
            let msg = delegate.parseError?.localizedDescription
                ?? parser.parserError?.localizedDescription
                ?? "unknown error"
            throw ImportError.xmlParseFailed(msg)
        }
        return delegate.makeResult(extraSkippedSpans: scrubbedRuns)
    }

    private func findExportXML(inFolder folder: URL) -> URL? {
        let fm = FileManager.default
        // Common location first.
        let direct = folder.appendingPathComponent("export.xml")
        if fm.fileExists(atPath: direct.path) { return direct }
        let nested = folder.appendingPathComponent("apple_health_export/export.xml")
        if fm.fileExists(atPath: nested.path) { return nested }
        // Otherwise search for an "export.xml" by name (any depth, case-insensitive).
        if let e = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let u as URL in e where u.lastPathComponent.lowercased() == "export.xml" {
                return u
            }
        }
        // LOCALISED export: a non-English Health app names the root file in the
        // device locale (e.g. `экспорт.xml`, `エクスポート.xml`), not `export.xml`.
        // As a last resort accept a single `.xml` file at the folder root (or in
        // `apple_health_export/`). Only act when there is EXACTLY one candidate so
        // we never guess wrong amid several XML files.
        let exportSub = folder.appendingPathComponent("apple_health_export")
        for dir in [folder, exportSub] {
            if let only = soleXMLFile(directlyIn: dir) { return only }
        }
        return nil
    }

    /// The single `*.xml` file directly inside `dir` (non-recursive), or `nil` if
    /// `dir` doesn't exist, has no `.xml` files, or has more than one.
    private func soleXMLFile(directlyIn dir: URL) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let xmls = entries.filter { $0.pathExtension.lowercased() == "xml" }
        return xmls.count == 1 ? xmls[0] : nil
    }
}

// MARK: - SAX delegate

final class HealthXMLDelegate: NSObject, XMLParserDelegate {

    /// When `false`, parsed samples are folded into `dailyAcc` and then dropped
    /// rather than retained in `samples`, so a multi-year export stays within a
    /// bounded memory budget (issue #355). `true` keeps the raw array for
    /// callers/tests that need it.
    let retainRawSamples: Bool

    init(retainRawSamples: Bool = true) {
        self.retainRawSamples = retainRawSamples
        super.init()
    }

    // Outputs
    private(set) var samples: [HealthSample] = []
    private(set) var workouts: [HealthWorkout] = []
    private(set) var sleepIntervals: [SleepStageInterval] = []
    private(set) var countsByType: [String: Int] = [:]
    private(set) var parseError: Error?

    /// Running per-day fold of every (deduped) sample. Always maintained — it is
    /// the bounded-memory aggregate the app consumes and is also produced when
    /// raw samples are retained, so the two paths share one reduction.
    private var dailyAcc = AppleDailySampleAccumulator()

    /// True once at least one usable record/workout/sleep row was seen. Tracked
    /// independently of `samples` because `samples` may be empty when
    /// `retainRawSamples` is false (issue #355).
    private var anyRecordSeen = false

    // Incrementally-tracked summary inputs, so makeResult doesn't need the raw
    // `samples` array (which may be empty).
    private var earliestDate: Date?
    private var latestDate: Date?
    /// Count of distinct (post-dedupe) samples folded in — the `samples.count`
    /// equivalent for the summary's recordCount when raw samples were dropped.
    private var sampleCount = 0

    // Element nesting stack (just the element names).
    private var stack: [String] = []
    // Depth of the current Correlation, if inside one. Records nested inside a
    // Correlation are skipped (they also appear top-level).
    private var correlationDepth = 0
    // The <Workout> currently being assembled. Built at the `<Workout>` start tag from its legacy
    // attributes, filled by any nested `<WorkoutStatistics>` children (iOS 16+), and appended to
    // `workouts` at the `</Workout>` end tag. nil when not inside a workout. Workouts never nest and
    // never appear inside a Correlation, so a single slot (not a stack) is sufficient.
    private var pendingWorkout: HealthWorkout?

    // Dedupe set over HealthSample dedupeKeys — stored as the key's 64-bit HASH, not the full String
    // (#183). A large Apple Health export has tens of millions of unique samples; retaining a ~50-100 B
    // String each was ~1-2 GB of RAM, enough to push an import into sustained memory pressure and hang.
    // A 64-bit hash is 8 B/entry (~10x less); a collision across even 20M samples is ~1e-5, and a rare
    // one just drops a look-alike duplicate — the same effect dedup intends. Within one import run the
    // hash is stable, so identical keys always dedupe.
    private var seenSampleKeys: Set<Int> = []

    /// 64-bit FNV-1a over `s`'s UTF-16 code units — byte-identical to the Android `hash64` (both iterate
    /// UTF-16 units with the same offset basis + prime, wrapping at 64 bits), so the two platforms produce
    /// the same dedupe hashes and drop the exact same look-alike duplicates (#183).
    static func hash64(_ s: String) -> Int {
        var h: UInt64 = 0xcbf29ce484222325   // FNV-1a 64-bit offset basis
        for u in s.utf16 {
            h = (h ^ UInt64(u)) &* 0x100000001b3   // xor code unit, ×= FNV prime (wraps, intended)
        }
        return Int(bitPattern: UInt(h))
    }

    /// True once at least one usable record/workout/sleep row was parsed. Drives the tolerant-parse
    /// decision: a hard error AFTER real data was seen keeps the partial result instead of failing.
    /// Uses `anyRecordSeen` (not `samples`) so it still fires when raw samples are dropped.
    var hasAnyRecord: Bool {
        anyRecordSeen || !workouts.isEmpty || !sleepIntervals.isEmpty
    }

    private let dateParser = HealthDateParser()

    // MARK: XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let parentIsCorrelation = (stack.last == "Correlation")
        stack.append(elementName)

        // Drain per-element: a multi-year export.xml has tens of millions of elements, each
        // bridging an attribute dictionary + temporaries (date parsing). Without a pool these
        // accumulate until parse() returns, inflating peak memory. Pool drains every element.
        autoreleasepool {
            switch elementName {
            case "Correlation":
                correlationDepth += 1

            case "Record":
                // Skip records nested inside a Correlation (deduped to top-level).
                if parentIsCorrelation || correlationDepth > 0 {
                    return
                }
                handleRecord(attributeDict)

            case "Workout":
                handleWorkout(attributeDict)

            case "WorkoutStatistics":
                // iOS 16+ nests per-workout energy/distance/HR here (was <Workout> attributes on iOS <=15).
                handleWorkoutStatistics(attributeDict)

            default:
                break
            }
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "Correlation", correlationDepth > 0 {
            correlationDepth -= 1
        }
        if elementName == "Workout" {
            // The whole <Workout> sub-tree (including any <WorkoutStatistics>) has now been seen; commit it.
            finishWorkout()
        }
        if stack.last == elementName {
            stack.removeLast()
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        // Ignore benign "no data" / EOF style errors that can occur when the
        // streaming pipe closes; only record genuine malformed-XML errors.
        let ns = parseError as NSError
        if ns.domain == XMLParser.errorDomain {
            // Code 5 == NSXMLParserPrematureDocumentEndError can happen on empty
            // streams; treat truly empty as non-fatal only if we parsed nothing.
            if ns.code == XMLParser.ErrorCode.prematureDocumentEndError.rawValue,
               !anyRecordSeen, workouts.isEmpty, sleepIntervals.isEmpty {
                self.parseError = parseError
                return
            }
        }
        self.parseError = parseError
    }

    // MARK: Record handling

    private func handleRecord(_ attrs: [String: String]) {
        guard let rawType = attrs["type"] else { return }
        let type = Self.stripPrefix(rawType)
        guard AppleHealthImporter.relevantTypes.contains(type) else { return }

        guard
            let startStr = attrs["startDate"],
            let endStr = attrs["endDate"],
            let (start, _) = dateParser.parse(startStr),
            let (end, endOffset) = dateParser.parse(endStr)
        else { return }

        let source = attrs["sourceName"]
        let unit = attrs["unit"]
        let rawValue = attrs["value"]

        if type == "SleepAnalysis" {
            // Sleep is a category record; its value is a stage enum string.
            let stage = SleepStage.from(rawValue: rawValue ?? "")
            let interval = SleepStageInterval(
                stage: stage,
                start: start,
                end: end,
                tzOffsetMin: endOffset,
                sourceName: source
            )
            sleepIntervals.append(interval)
            countsByType[type, default: 0] += 1
            anyRecordSeen = true
            // Mirror the old summary, which spanned EVERY sleep interval's start
            // (intervals are never deduped). Tracked here so a deduped sleep
            // sample still contributes its start to the date span.
            if earliestDate == nil || start < earliestDate! { earliestDate = start }
            if latestDate == nil || start > latestDate! { latestDate = start }

            // Also record a generic sample so the row survives in the sink with
            // its raw value string (dedupe-protected).
            appendSample(
                type: type,
                value: nil,
                valueString: rawValue,
                unit: unit,
                start: start,
                end: end,
                tzOffsetMin: endOffset,
                sourceName: source
            )
            return
        }

        var numeric = rawValue.flatMap { Double($0) }
        // OxygenSaturation is a 0–1 fraction → percent.
        if type == "OxygenSaturation", let v = numeric {
            numeric = v * 100.0
        }

        appendSample(
            type: type,
            value: numeric,
            valueString: rawValue,
            unit: unit,
            start: start,
            end: end,
            tzOffsetMin: endOffset,
            sourceName: source
        )
        countsByType[type, default: 0] += 1
    }

    private func appendSample(
        type: String,
        value: Double?,
        valueString: String?,
        unit: String?,
        start: Date,
        end: Date,
        tzOffsetMin: Int,
        sourceName: String?
    ) {
        let sample = HealthSample(
            type: type,
            value: value,
            valueString: valueString,
            unit: unit,
            start: start,
            end: end,
            tzOffsetMin: tzOffsetMin,
            sourceName: sourceName
        )
        // Dedupe on type+start+end+source+value (correctness-critical). Retain only the key's 64-bit
        // hash, not the String, so the set stays ~10x smaller on a huge export (#183). Uses the SAME
        // FNV-1a as Android (NOT Swift's per-run-randomized hashValue) so both platforms dedupe identically.
        if seenSampleKeys.insert(Self.hash64(sample.dedupeKey)).inserted {
            // Always fold into the bounded per-day accumulator.
            dailyAcc.add(sample)
            anyRecordSeen = true
            sampleCount += 1
            // Track the date span incrementally so makeResult never needs the
            // (possibly empty) raw `samples` array. Matches the prior summary,
            // which spanned sample/workout/sleep `start` dates.
            if earliestDate == nil || start < earliestDate! { earliestDate = start }
            if latestDate == nil || start > latestDate! { latestDate = start }
            // Only retain the raw struct when the caller asked for it.
            if retainRawSamples {
                samples.append(sample)
            }
        }
    }

    // MARK: Workout handling

    private func handleWorkout(_ attrs: [String: String]) {
        guard
            let startStr = attrs["startDate"],
            let endStr = attrs["endDate"],
            let (start, _) = dateParser.parse(startStr),
            let (end, endOffset) = dateParser.parse(endStr)
        else { return }

        let rawActivity = attrs["workoutActivityType"] ?? "Unknown"
        let activity = Self.stripPrefix(rawActivity)

        var durationS: Double?
        if let dStr = attrs["duration"], let d = Double(dStr) {
            // durationUnit is typically "min"; default to minutes per Apple's export.
            let unit = (attrs["durationUnit"] ?? "min").lowercased()
            switch unit {
            case "min": durationS = d * 60.0
            case "sec", "s": durationS = d
            case "hr", "h": durationS = d * 3600.0
            default: durationS = d * 60.0
            }
        }

        // iOS <=15 put per-workout totals on <Workout> as `totalDistance`/`totalEnergyBurned`; iOS 16+
        // moved them into nested <WorkoutStatistics> children (folded in by `handleWorkoutStatistics`).
        // Seed the pending workout from the legacy attributes; the children FILL any still absent — a
        // modern export carries no legacy attributes, so nothing a legacy value set is clobbered.
        let distanceM = attrs["totalDistance"].flatMap { Double($0) }
            .map { Self.distanceMeters($0, unit: attrs["totalDistanceUnit"]) }
        let energyKcal = attrs["totalEnergyBurned"].flatMap { Double($0) }
        // Apple exports energy in kcal by default (totalEnergyBurnedUnit "kcal").

        // Defer the append / counts to `finishWorkout()` at `</Workout>`, once any statistics children
        // have folded in. A truncated workout with no end tag is simply dropped (its tail is counted a
        // skipped span upstream), never counted as a complete row.
        pendingWorkout = HealthWorkout(
            activityType: activity,
            durationS: durationS,
            distanceM: distanceM,
            energyKcal: energyKcal,
            start: start,
            end: end,
            tzOffsetMin: endOffset,
            sourceName: attrs["sourceName"]
        )
    }

    /// Fold one `<WorkoutStatistics>` child into the workout currently being assembled. iOS 16+ emits
    /// per-metric totals here: energy/distance as `sum`, heart rate as `average`/`maximum`. Fills only a
    /// field still absent, so a legacy attribute value already set is never overwritten.
    private func handleWorkoutStatistics(_ attrs: [String: String]) {
        guard var workout = pendingWorkout, let rawType = attrs["type"] else { return }
        let type = Self.stripPrefix(rawType)
        switch type {
        case "ActiveEnergyBurned":
            if workout.energyKcal == nil { workout.energyKcal = attrs["sum"].flatMap { Double($0) } }
        case "HeartRate":
            if workout.avgHr == nil { workout.avgHr = attrs["average"].flatMap { Double($0) } }
            if workout.maxHr == nil { workout.maxHr = attrs["maximum"].flatMap { Double($0) } }
        default:
            if type.hasPrefix("Distance"), workout.distanceM == nil {
                workout.distanceM = attrs["sum"].flatMap { Double($0) }
                    .map { Self.distanceMeters($0, unit: attrs["unit"]) }
            }
        }
        pendingWorkout = workout
    }

    /// Commit the assembled workout at `</Workout>`: append it and fold its start into the summary's
    /// counts + date span (deferred here so any statistics children are already in). No-op when not in a
    /// workout (a stray end tag) or when the start tag was rejected for bad dates.
    private func finishWorkout() {
        guard let workout = pendingWorkout else { return }
        pendingWorkout = nil
        workouts.append(workout)
        countsByType["Workout", default: 0] += 1
        anyRecordSeen = true
        // Workouts don't go through appendSample, so track their start in the
        // incremental date span too (matches the prior summary).
        if earliestDate == nil || workout.start < earliestDate! { earliestDate = workout.start }
        if latestDate == nil || workout.start > latestDate! { latestDate = workout.start }
    }

    /// Convert a distance value in `km` / `mi` / `m` to metres (defaulting to km, Apple's usual unit).
    static func distanceMeters(_ value: Double, unit: String?) -> Double {
        switch (unit ?? "km").lowercased() {
        case "km": return value * 1000.0
        case "mi": return value * 1609.344
        case "m":  return value
        default:   return value * 1000.0
        }
    }

    // MARK: Result

    /// Build the normalized result. `extraSkippedSpans` carries the number of dropped XML spans
    /// (sanitizer-scrubbed illegal-byte runs, plus 1 if a hard parse error truncated the tail) so the
    /// summary reports a partial import honestly instead of looking complete.
    func makeResult(extraSkippedSpans: Int = 0) -> AppleHealthImportResult {
        // Build the summary from incrementally-tracked values, NOT from `samples`
        // (which is empty when raw samples were dropped — issue #355).
        // `sampleCount` is the post-dedupe sample count, matching the old
        // `samples.count`; earliest/latest span sample + workout + sleep starts.
        let summary = ImportSummary(
            sourceKind: .appleHealth,
            recordCount: sampleCount + workouts.count,
            earliest: earliestDate,
            latest: latestDate,
            countsByCategory: countsByType,
            skippedSpans: extraSkippedSpans
        )
        return AppleHealthImportResult(
            samples: samples,
            workouts: workouts,
            sleepIntervals: sleepIntervals,
            summary: summary,
            sampleDailies: dailyAcc.finish()
        )
    }

    // MARK: Helpers

    /// Strip the HealthKit identifier prefix from a type string.
    /// `HKQuantityTypeIdentifierHeartRate` → `HeartRate`,
    /// `HKCategoryTypeIdentifierSleepAnalysis` → `SleepAnalysis`,
    /// `HKWorkoutActivityTypeRunning` → `Running`.
    static func stripPrefix(_ raw: String) -> String {
        let prefixes = [
            "HKQuantityTypeIdentifier",
            "HKCategoryTypeIdentifier",
            "HKDataTypeIdentifier",
            "HKWorkoutActivityType",
        ]
        for p in prefixes where raw.hasPrefix(p) {
            return String(raw.dropFirst(p.count))
        }
        return raw
    }
}

// MARK: - Date parsing for Apple Health

/// Parses Apple Health dates `yyyy-MM-dd HH:mm:ss Z` (space before a colon-less
/// offset) with `en_US_POSIX`, returning a UTC `Date` plus the original offset
/// in minutes.
final class HealthDateParser {
    private let formatter: DateFormatter

    init() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        self.formatter = f
    }

    /// Returns (utcDate, offsetMinutes).
    func parse(_ raw: String) -> (Date, Int)? {
        guard let date = formatter.date(from: raw) else {
            // Fallback: try a few alternative shapes (ISO-8601, no seconds).
            return parseFallback(raw)
        }
        return (date, Self.offsetMinutes(from: raw))
    }

    private func parseFallback(_ raw: String) -> (Date, Int)? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) {
            return (d, Self.offsetMinutes(from: raw))
        }
        return nil
    }

    /// Extract the trailing numeric UTC offset (`+0100`, `-0500`, `+01:00`, `Z`)
    /// from a date string, in minutes.
    static func offsetMinutes(from raw: String) -> Int {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("Z") || trimmed.hasSuffix("z") { return 0 }
        // Offset is the last token; look for the sign within the last ~6 chars.
        let tail = String(trimmed.suffix(6))
        guard let signRange = tail.range(of: "[+-]", options: .regularExpression) else {
            return 0
        }
        let offStr = String(tail[signRange.lowerBound...])
        let sign = offStr.hasPrefix("-") ? -1 : 1
        let digits = offStr.dropFirst().filter { $0.isNumber }
        guard digits.count >= 2 else { return 0 }
        let s = String(digits)
        var hours = 0, minutes = 0
        if s.count >= 4 {
            hours = Int(s.prefix(2)) ?? 0
            minutes = Int(s.dropFirst(2).prefix(2)) ?? 0
        } else {
            hours = Int(s.prefix(2)) ?? 0
        }
        return sign * (hours * 60 + minutes)
    }
}

// MARK: - Chunked sanitizing input stream

/// An `InputStream` that wraps a source stream and scrubs every byte XML 1.0 forbids — and every
/// invalid UTF-8 sequence — *as it streams*, in fixed-size chunks, before the bytes reach
/// `XMLParser`/libxml2.
///
/// WHY this exists: a single malformed byte in a multi-year Apple Health `export.xml` (a stray
/// control char, or mojibake / truncated UTF-8 from a decade-old phone) makes libxml2 abort with a
/// hard error (e.g. error 65 "SpaceRequired"), discarding everything parsed up to that point. By
/// repairing the byte stream up front the parse runs to EOF and the import survives.
///
/// It is itself a streaming `InputStream`, so memory stays bounded: it never holds more than one
/// source chunk plus, at most, the 1–3 trailing bytes of a UTF-8 sequence that straddles a chunk
/// boundary. We do NOT inflate the file to RAM or disk.
///
/// Sanitization rules (UTF-8 only — Apple Health exports declare UTF-8):
///  - Bytes `< 0x20` that are not TAB (0x09), LF (0x0A) or CR (0x0D) → dropped (XML-1.0 illegal).
///  - 0x7F and any byte sequence that is not valid UTF-8 → replaced with U+FFFD (`EF BF BD`).
///  - Valid multi-byte UTF-8 sequences are passed through byte-for-byte, including ones split across
///    a chunk boundary (the incomplete tail is carried into the next read).
///
/// `scrubbedRunCount` tracks how many *contiguous runs* of dropped/replaced bytes were scrubbed, so
/// the import summary can report "N spans skipped" honestly rather than hiding the damage.
final class SanitizingInputStream: InputStream {

    private let source: InputStream
    /// Bytes lifted from `source` but not yet sanitized — only a partial UTF-8 sequence sitting at a
    /// chunk boundary ever lives here (≤ 3 bytes), plus transiently a full read chunk during scrub.
    private var carry: [UInt8] = []
    /// Sanitized bytes ready to hand to the parser but not yet consumed by `read`.
    private var outBuffer: [UInt8] = []
    private var outOffset = 0
    private var sourceEOF = false
    private var sourceError: Error?

    /// Number of contiguous illegal-byte runs scrubbed (one increment per run, not per byte), so the
    /// summary reports a sensible "spans skipped" figure even on a heavily-corrupted export.
    private(set) var scrubbedRunCount = 0
    /// Tracks whether the previous emitted byte was itself a scrub, so a run of N consecutive bad
    /// bytes counts as ONE span, not N.
    private var inScrubRun = false

    private let chunkSize: Int

    init(source: InputStream, chunkSize: Int = 1 << 16) {
        self.source = source
        self.chunkSize = max(chunkSize, 8)
        // InputStream's designated init; the data is ignored because we override read().
        super.init(data: Data())
    }

    // MARK: InputStream lifecycle

    override func open() { source.open() }
    override func close() { source.close() }

    override var streamError: Error? { sourceError }
    override var streamStatus: Stream.Status {
        if sourceError != nil { return .error }
        if sourceEOF && outOffset >= outBuffer.count { return .atEnd }
        return source.streamStatus
    }

    override var hasBytesAvailable: Bool {
        outOffset < outBuffer.count || !sourceEOF
    }

    /// Fill `buffer` with up to `len` sanitized bytes. Returns the count, 0 at EOF, or -1 on a
    /// source read error (the parser then surfaces it; the tolerant-parse layer decides whether to
    /// keep what was parsed so far).
    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard len > 0 else { return 0 }
        // Top up the sanitized output buffer until we have something to give or the source is drained.
        while outOffset >= outBuffer.count {
            if sourceEOF {
                // Drain any remaining carry: at true EOF a leftover partial UTF-8 sequence is itself
                // invalid and becomes a single U+FFFD.
                if !carry.isEmpty {
                    flushCarryAtEOF()
                    if outOffset < outBuffer.count { break }
                }
                return 0
            }
            if let err = sourceError { _ = err; return -1 }
            refill()
        }
        let available = outBuffer.count - outOffset
        let n = min(len, available)
        outBuffer.withUnsafeBufferPointer { src in
            buffer.update(from: src.baseAddress! + outOffset, count: n)
        }
        outOffset += n
        if outOffset >= outBuffer.count {
            outBuffer.removeAll(keepingCapacity: true)
            outOffset = 0
        }
        return n
    }

    override func getBuffer(
        _ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
        length len: UnsafeMutablePointer<Int>
    ) -> Bool {
        // No zero-copy buffer; force callers (XMLParser) onto read(_:maxLength:).
        return false
    }

    // MARK: Sanitizing core

    /// Read one chunk from the source, append it to `carry`, scrub the carry up to the last complete
    /// UTF-8 boundary, and stage the result in `outBuffer`.
    private func refill() {
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        let n = chunk.withUnsafeMutableBufferPointer { ptr -> Int in
            source.read(ptr.baseAddress!, maxLength: chunkSize)
        }
        if n < 0 {
            sourceError = source.streamError
                ?? NSError(domain: "SanitizingInputStream", code: -1)
            return
        }
        if n == 0 {
            sourceEOF = true
            return
        }
        carry.append(contentsOf: chunk[0..<n])
        // Scrub everything except a possible incomplete trailing UTF-8 sequence, which we hold back
        // so a sequence split across chunk reads isn't misclassified as invalid.
        scrub(holdIncompleteTail: true)
    }

    /// At EOF, anything left in `carry` is final: a dangling partial sequence is genuinely invalid.
    private func flushCarryAtEOF() {
        scrub(holdIncompleteTail: false)
    }

    /// Consume `carry`, emit sanitized bytes into `outBuffer`. When `holdIncompleteTail` is true the
    /// trailing bytes of a not-yet-complete (but so-far-valid) UTF-8 sequence are left in `carry` for
    /// the next chunk.
    private func scrub(holdIncompleteTail: Bool) {
        var i = 0
        let bytes = carry
        let count = bytes.count
        outBuffer.reserveCapacity(outBuffer.count + count)

        while i < count {
            let b = bytes[i]

            // 1) ASCII fast path.
            if b < 0x80 {
                if b >= 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                    // 0x20–0x7F (incl. DEL 0x7F, which XML 1.0 permits) pass through unchanged.
                    outBuffer.append(b)
                    inScrubRun = false
                } else {
                    // XML-1.0-illegal C0 control char (< 0x20, not TAB/LF/CR) → drop.
                    noteScrub()
                }
                i += 1
                continue
            }

            // 2) Multi-byte UTF-8. Determine the expected sequence length from the lead byte.
            let seqLen: Int
            if b & 0xE0 == 0xC0 { seqLen = 2 }
            else if b & 0xF0 == 0xE0 { seqLen = 3 }
            else if b & 0xF8 == 0xF0 { seqLen = 4 }
            else { seqLen = 0 } // 0x80–0xBF continuation as a lead, or 0xF8–0xFF: invalid.

            if seqLen == 0 {
                emitReplacement()
                i += 1
                continue
            }

            // Not enough bytes yet for the full sequence?
            if i + seqLen > count {
                if holdIncompleteTail {
                    // Could still be a valid sequence finishing in the next chunk — carry it over.
                    break
                } else {
                    // EOF with a truncated sequence: invalid.
                    emitReplacement()
                    i += 1
                    continue
                }
            }

            // Validate the continuation bytes AND reject overlong / surrogate / out-of-range
            // encodings (the cases libxml2 rejects). Mirrors the well-formed-UTF-8 ranges.
            if isValidUTF8Sequence(bytes, start: i, length: seqLen) {
                for k in 0..<seqLen { outBuffer.append(bytes[i + k]) }
                inScrubRun = false
                i += seqLen
            } else {
                // Only the lead byte is consumed; the (invalid) continuation bytes are re-examined.
                emitReplacement()
                i += 1
            }
        }

        // Anything from `i` onward is the held-back incomplete tail (or nothing).
        if i >= count {
            carry.removeAll(keepingCapacity: true)
        } else {
            carry = Array(bytes[i..<count])
        }
    }

    /// Emit a U+FFFD replacement and account for the scrub run.
    private func emitReplacement() {
        outBuffer.append(contentsOf: [0xEF, 0xBF, 0xBD]) // U+FFFD in UTF-8
        // The replacement is also part of a scrub run; count it.
        noteScrub()
    }

    /// Account for one scrubbed byte, collapsing consecutive bad bytes into a single counted span.
    private func noteScrub() {
        if !inScrubRun {
            scrubbedRunCount += 1
            inScrubRun = true
        }
    }

    /// Validate a UTF-8 sequence of `length` bytes starting at `start`, including the overlong /
    /// surrogate / range constraints (RFC 3629), so we only pass through encodings libxml2 accepts.
    private func isValidUTF8Sequence(_ bytes: [UInt8], start: Int, length: Int) -> Bool {
        let b0 = bytes[start]
        switch length {
        case 2:
            // Valid 2-byte lead is C2..DF. C0/C1 also match `b & 0xE0 == 0xC0` (so seqLen==2) but are
            // overlong encodings of ASCII — reject them here.
            guard b0 >= 0xC2 else { return false }
            return isCont(bytes[start + 1])
        case 3:
            let b1 = bytes[start + 1]
            guard isCont(bytes[start + 2]) else { return false }
            switch b0 {
            case 0xE0: return b1 >= 0xA0 && b1 <= 0xBF            // exclude overlong
            case 0xED: return b1 >= 0x80 && b1 <= 0x9F            // exclude UTF-16 surrogates
            default:   return isCont(b1)
            }
        case 4:
            let b1 = bytes[start + 1]
            guard isCont(bytes[start + 2]), isCont(bytes[start + 3]) else { return false }
            switch b0 {
            case 0xF0: return b1 >= 0x90 && b1 <= 0xBF            // exclude overlong
            case 0xF4: return b1 >= 0x80 && b1 <= 0x8F            // exclude > U+10FFFF
            case 0xF1...0xF3: return isCont(b1)
            default: return false
            }
        default:
            return false
        }
    }

    @inline(__always)
    private func isCont(_ b: UInt8) -> Bool { b & 0xC0 == 0x80 }
}
