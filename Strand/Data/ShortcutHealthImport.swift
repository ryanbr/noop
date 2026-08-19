import Foundation
import WhoopStore

/// PR #581 — HealthKit-free Apple Health **import** for sideloaded iOS installs. The mirror of the
/// #155 export (`ShortcutHealthExport`): a free (7-day) signing identity can't carry the HealthKit
/// entitlement, so the in-app `AppleHealthImport` (which reads an `export.zip` via HealthKit-shaped
/// XML) is the user's only path — and that still works. This adds a SECOND, lighter path for the
/// data Apple Health can hand a Shortcut directly: the reporter builds a Siri Shortcut that reads
/// their daily Health totals + workouts and opens
///
///   noop://import-health?v=1&payload=<base64(text)>
///
/// where the decoded text is line-oriented, en_US_POSIX, NO header, one record per line. Two record
/// kinds, discriminated by the first field:
///
///   D,yyyy-MM-dd,steps,activeKcal,restingHr,hrvMs,avgHr,asleepMin,vo2max,weightKg
///   W,startUnix,endUnix,sport,durationS,energyKcal,distanceM
///
/// Empty fields keep their commas (fixed column positions); a missing optional is empty, not 0.
///
/// LOOP-FREEDOM (the #581 review's central risk). Everything this ingests lands under the
/// `apple-health` source id — the SAME source the `export.zip` importer writes and NEVER the strap
/// (`my-whoop`) source. The complementary export (#155) reads the strap source ONLY and writes into
/// Apple Health. So the round-trip is one-way at each hop:
///
///   strap (`my-whoop`)  --[#155 export Shortcut]-->  Apple Health  --[this import]-->  `apple-health`
///
/// A value this import writes can never be picked up by the export (the export ignores `apple-health`)
/// and so can never be re-logged into Apple Health and re-imported. `targetSource` is asserted equal to
/// `WorkoutSource.appleHealthSource` and is REJECTED if it is ever the strap source — a belt-and-braces
/// guard so a future caller can't accidentally point the ingest at the strap and create the loop.
/// `ShortcutHealthImportTests.testRejectsStrapTarget` pins this.
///
/// Platform-neutral (no UIKit) so it compiles into the macOS target too, mirroring `ShortcutHealthExport`;
/// the iOS-only `.onOpenURL` wiring lives in StrandiOS/ (see crossLaneNotes / Lane E) and calls
/// `AppModel.handleHealthImportURL(_:)`.
enum ShortcutHealthImport {

    /// The only source id this import is ever allowed to write to. Equal to the `export.zip` importer's
    /// source so the two Apple paths merge into one timeline. NEVER a strap device id.
    static let targetSource = WorkoutSource.appleHealthSource   // "apple-health"

    /// The strap source ids the import must never write to — writing here is what would close the
    /// export→import loop. Used only by the guard + its test.
    static let forbiddenSources: Set<String> = ["my-whoop", "my-whoop-noop"]

    static let scheme = "noop"
    static let host = "import-health"
    static let payloadParam = "payload"
    static let versionParam = "v"
    static let supportedVersion = 1
    static let maxPayloadBytes = 1 << 20

    enum Outcome: Error, Equatable {
        case imported(days: Int, workouts: Int)
        case nothingToImport
        case rejected(String)
    }

    /// A parsed daily-totals line. All metrics optional; a day with no metric is dropped.
    struct ParsedDay: Equatable {
        let day: String                 // yyyy-MM-dd
        var steps: Int? = nil
        var activeKcal: Double? = nil
        var restingHr: Int? = nil
        var hrvMs: Double? = nil
        var avgHr: Int? = nil
        var asleepMin: Double? = nil
        var vo2max: Double? = nil
        var weightKg: Double? = nil

        var hasAnyMetric: Bool {
            steps != nil || activeKcal != nil || restingHr != nil || hrvMs != nil
                || avgHr != nil || asleepMin != nil || vo2max != nil || weightKg != nil
        }
    }

    /// A parsed workout line.
    struct ParsedWorkout: Equatable {
        let startTs: Int
        let endTs: Int
        let sport: String
        var durationS: Double? = nil
        var energyKcal: Double? = nil
        var distanceM: Double? = nil
    }

    struct Parsed: Equatable {
        var days: [ParsedDay] = []
        var workouts: [ParsedWorkout] = []
        var isEmpty: Bool { days.isEmpty && workouts.isEmpty }
    }

    struct PendingImport: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let parsed: Parsed

        var daysCount: Int { parsed.days.count }
        var workoutsCount: Int { parsed.workouts.count }
    }

    // MARK: - URL → outcome

    /// Validate + decode the `noop://import-health` URL into the raw text payload. Returns nil with a
    /// `.rejected` reason on any malformed/foreign URL so a stray deep link can't reach the store.
    static func decodePayload(from url: URL) -> Result<String, Outcome> {
        guard url.scheme?.lowercased() == scheme else {
            return .failure(.rejected("Not a noop:// link."))
        }
        guard url.host?.lowercased() == host else {
            return .failure(.rejected("Unsupported noop:// action."))
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let params = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        if let v = params[versionParam], let n = Int(v), n != supportedVersion {
            return .failure(.rejected("Unsupported import version \(n)."))
        }
        guard let b64 = params[payloadParam], !b64.isEmpty else {
            return .failure(.rejected("No import payload."))
        }
        let maxBase64Length = ((maxPayloadBytes + 2) / 3) * 4 + 4
        guard b64.utf8.count <= maxBase64Length else {
            return .failure(.rejected("Import payload is too large."))
        }
        // Tolerate URL-safe base64 (Shortcuts' "Base64 Encode" can emit either) + missing padding.
        guard let data = decodeBase64(b64), data.count <= maxPayloadBytes,
              let text = String(data: data, encoding: .utf8) else {
            return .failure(.rejected("Couldn't decode the import payload."))
        }
        return .success(text)
    }

    /// Accept both standard and URL-safe base64, with or without `=` padding.
    static func decodeBase64(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = t.count % 4
        if pad != 0 { t += String(repeating: "=", count: 4 - pad) }
        return Data(base64Encoded: t)
    }

    // MARK: - Pure parse

    /// Parse the decoded payload text into days + workouts. Unknown record kinds and unparseable lines
    /// are skipped (forward-compatible). Days with no metric are dropped.
    static func parse(_ text: String) -> Parsed {
        var out = Parsed()
        // Split on ANY newline via `Character.isNewline`. Critically, a CRLF (`\r\n`) is a SINGLE Swift
        // Character (extended grapheme cluster), so an `$0 == "\n" || $0 == "\r"` predicate would NOT
        // match it — a Windows/Shortcuts CRLF-terminated payload would then glue the line ending onto the
        // next record's kind field ("\r\nW" ≠ "W") and silently DROP that valid record. `isNewline`
        // matches CR, LF and the CRLF grapheme. Trim newlines too (not just spaces) as belt-and-braces.
        for raw in text.split(whereSeparator: { $0.isNewline }) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let f = line.components(separatedBy: ",")
            guard let kind = f.first?.uppercased() else { continue }
            switch kind {
            case "D":
                if let d = parseDay(f) { out.days.append(d) }
            case "W":
                if let w = parseWorkout(f) { out.workouts.append(w) }
            default:
                continue   // forward-compatible: ignore record kinds this build doesn't know
            }
        }
        return out
    }

    private static func field(_ f: [String], _ i: Int) -> String? {
        guard i < f.count else { return nil }
        let v = f[i].trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    private static func parseDay(_ f: [String]) -> ParsedDay? {
        // D,day,steps,activeKcal,restingHr,hrvMs,avgHr,asleepMin,vo2max,weightKg
        guard let day = field(f, 1), isValidDay(day) else { return nil }
        var d = ParsedDay(day: day)
        d.steps      = field(f, 2).flatMap { Int($0) }
        d.activeKcal = field(f, 3).flatMap { Double($0) }
        d.restingHr  = field(f, 4).flatMap { Int($0) }
        d.hrvMs      = field(f, 5).flatMap { Double($0) }
        d.avgHr      = field(f, 6).flatMap { Int($0) }
        d.asleepMin  = field(f, 7).flatMap { Double($0) }
        d.vo2max     = field(f, 8).flatMap { Double($0) }
        d.weightKg   = field(f, 9).flatMap { Double($0) }
        return d.hasAnyMetric ? d : nil
    }

    private static func parseWorkout(_ f: [String]) -> ParsedWorkout? {
        // W,startUnix,endUnix,sport,durationS,energyKcal,distanceM
        guard let startS = field(f, 1), let start = Int(startS),
              let endS = field(f, 2), let end = Int(endS),
              let sport = field(f, 3), end >= start else { return nil }
        var w = ParsedWorkout(startTs: start, endTs: end, sport: sport)
        w.durationS  = field(f, 4).flatMap { Double($0) } ?? Double(end - start)
        w.energyKcal = field(f, 5).flatMap { Double($0) }
        w.distanceM  = field(f, 6).flatMap { Double($0) }
        return w
    }

    /// A strict `yyyy-MM-dd` shape check (the store keys on the day string; a garbage key would
    /// scatter rows). Calendar-validity is not enforced — the importer never date-maths the key.
    static func isValidDay(_ s: String) -> Bool {
        let parts = s.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return false }
        return true
    }

    // MARK: - Parsed → store rows

    /// Map the parsed days into the same three store shapes the `export.zip` importer writes
    /// (`AppleDaily`, `DailyMetric`, generic `MetricPoint`), all under `targetSource`.
    static func appleDailyRows(_ days: [ParsedDay]) -> [AppleDaily] {
        days.map { d in
            AppleDaily(day: d.day, steps: d.steps, activeKcal: d.activeKcal, basalKcal: nil,
                       vo2max: d.vo2max, avgHr: d.avgHr, maxHr: nil, walkingHr: nil,
                       weightKg: d.weightKg)
        }
    }

    static func dailyMetricRows(_ days: [ParsedDay]) -> [DailyMetric] {
        days.map { d in
            DailyMetric(day: d.day,
                        totalSleepMin: d.asleepMin, efficiency: nil,
                        deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                        restingHr: d.restingHr, avgHrv: d.hrvMs,
                        recovery: nil, strain: nil, exerciseCount: nil,
                        spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil)
        }
    }

    static func metricPointRows(_ days: [ParsedDay]) -> [MetricPoint] {
        var out: [MetricPoint] = []
        for d in days {
            func add(_ key: String, _ v: Double?) { if let v { out.append(MetricPoint(day: d.day, key: key, value: v)) } }
            add("steps", d.steps.map(Double.init))
            add("active_kcal", d.activeKcal)
            add("resting_hr", d.restingHr.map(Double.init))
            add("hrv", d.hrvMs)
            add("avg_hr", d.avgHr.map(Double.init))
            add("asleep_min", d.asleepMin)
            add("vo2max", d.vo2max)
            add("weight", d.weightKg)
        }
        return out
    }

    static func workoutRows(_ workouts: [ParsedWorkout]) -> [WorkoutRow] {
        workouts.map { w in
            WorkoutRow(startTs: w.startTs, endTs: w.endTs, sport: w.sport,
                       source: WorkoutSource.appleHealthSource,
                       durationS: w.durationS, energyKcal: w.energyKcal,
                       avgHr: nil, maxHr: nil, strain: nil,
                       distanceM: w.distanceM, zonesJSON: nil, notes: nil, steps: nil)
        }
    }

    // MARK: - Ingest

    /// Decode + parse a Shortcut payload without writing anything. The app uses this to show a
    /// confirmation sheet before accepting data from the custom URL scheme.
    static func prepare(url: URL) -> Result<PendingImport, Outcome> {
        let text: String
        switch decodePayload(from: url) {
        case .success(let t): text = t
        case .failure(let outcome): return .failure(outcome)
        }
        let parsed = parse(text)
        guard !parsed.isEmpty else { return .failure(.nothingToImport) }
        return .success(PendingImport(text: text, parsed: parsed))
    }

    /// Decode → parse → upsert into `store` under `targetSource`. Returns a typed outcome. Rejects any
    /// caller-supplied source that targets the strap (loop guard). Does NOT refresh the dashboard — the
    /// caller (AppModel) does, matching the file-import path.
    @discardableResult
    static func ingest(url: URL, into store: WhoopStore,
                       targetSource source: String = ShortcutHealthImport.targetSource) async -> Outcome {
        // Loop guard: never write to the strap source, or the export would re-emit imported rows.
        guard !forbiddenSources.contains(source), source == targetSource else {
            return .rejected("Import target must be the Apple Health source, not the strap.")
        }
        let pending: PendingImport
        switch prepare(url: url) {
        case .success(let p): pending = p
        case .failure(let outcome): return outcome
        }
        return await ingest(prepared: pending, into: store, targetSource: source)
    }

    @discardableResult
    static func ingest(prepared pending: PendingImport, into store: WhoopStore,
                       targetSource source: String = ShortcutHealthImport.targetSource) async -> Outcome {
        guard !forbiddenSources.contains(source), source == targetSource else {
            return .rejected("Import target must be the Apple Health source, not the strap.")
        }
        let parsed = pending.parsed
        do {
            if !parsed.days.isEmpty {
                try await store.upsertAppleDaily(appleDailyRows(parsed.days), deviceId: source)
                try await store.upsertDailyMetrics(dailyMetricRows(parsed.days), deviceId: source)
                try await store.upsertMetricSeries(metricPointRows(parsed.days), deviceId: source)
            }
            if !parsed.workouts.isEmpty {
                try await store.upsertWorkouts(workoutRows(parsed.workouts), deviceId: source)
            }
            try? await store.checkpointWAL()   // a Shortcut import can still be sizeable (#590)
            return .imported(days: parsed.days.count, workouts: parsed.workouts.count)
        } catch {
            return .rejected("Import failed: \(error.localizedDescription)")
        }
    }
}
