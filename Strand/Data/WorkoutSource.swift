import Foundation
import WhoopStore
import StrandAnalytics   // WorkoutsTrace: the dedup-decision line formatter for the Workouts test mode

/// Origin of a workout row, classified from its stored `source` column. The macOS read model
/// (`WorkoutRow`) carries no `deviceId`, so the row's origin has to be recovered from `source`.
/// Stored values today:
///   - "whoop"        — WhoopImporter (imported WHOOP session)
///   - "apple_health" / "apple-health" — AppleHealthImport
///   - "manual"       — AppModel.endWorkout (v1.67 live session) AND the retro add/edit sheet
///   - "my-whoop-noop"— IntelligenceEngine detected bouts (source == the computed deviceId, i.e.
///                       it ends in "-noop"). These are re-derived every analyzeRecent run.
///
/// Classification order matters: "-noop" is checked BEFORE "whoop" because the computed id
/// "my-whoop-noop" also contains the substring "whoop".
enum WorkoutSource: Equatable {
    case whoop, apple, detected, manual, lifting, activityFile

    /// Canonical Apple Health source id written by new imports. The early rows used the underscore
    /// spelling, so reads must accept both — see `isAppleHealth`.
    static let appleHealthSource = "apple-health"
    private static let legacyAppleHealthSource = "apple_health"

    static func classify(_ source: String) -> WorkoutSource {
        let s = source.lowercased()
        if s.hasSuffix("-noop") { return .detected }   // BEFORE whoop: "my-whoop-noop" contains "whoop"
        if s == "manual" { return .manual }
        if s == "lifting" { return .lifting }          // imported Hevy / Liftosaur strength session
        if s == "activity-file" { return .activityFile } // imported GPX / TCX / FIT activity file
        if isAppleHealth(s) { return .apple }          // both spellings → Apple Health
        if s.contains("whoop") { return .whoop }
        return .apple
    }

    /// True for an Apple Health workout row regardless of which spelling it was stored under —
    /// the canonical `apple-health` or the legacy `apple_health`. Case-insensitive. Counts that
    /// filter Apple-logged workouts (Today, the Apple Health page) MUST go through this so existing
    /// underscore rows still tally.
    static func isAppleHealth(_ source: String) -> Bool {
        let s = source.lowercased()
        return s == appleHealthSource || s == legacyAppleHealthSource
    }

    /// Sport-cell text. The detector stores the machine token "detected"; show it as a neutral
    /// "Activity" (we don't claim a sport we didn't actually classify). WHOOP sport names arrive as
    /// concatenated camelCase (e.g. "TraditionalStrengthTraining"), which reads as one long
    /// unbreakable word and truncates badly — split it into words on the lower→Upper boundary so it
    /// renders "Traditional Strength Training". Already-spaced labels (manual/edited) pass through. (#175)
    static func displaySport(_ sport: String) -> String {
        if sport == "detected" { return String(localized: "Activity") }
        return splitCamelCase(sport)
    }

    /// The camelCase splitter shared by the display and KEY paths. Deliberately NOT localized: the
    /// key path below must be locale-stable.
    private static func splitCamelCase(_ sport: String) -> String {
        if sport.isEmpty || sport.contains(" ") { return sport }
        var out = ""
        var prev: Character?
        for ch in sport {
            if let p = prev, ch.isUppercase, !p.isUppercase { out.append(" ") }
            out.append(ch)
            prev = ch
        }
        return out
    }

    /// The locale-stable editable form: what an edit field should SEED so a save round-trips a stable
    /// token ("Activity", never a translated word that would split cross-source dedup per language).
    static func editableSport(_ sport: String) -> String {
        sport == "detected" ? "Activity" : splitCamelCase(sport)
    }

    // MARK: - Dismissed detected bouts (durable across re-detection)
    //
    // The engine wipes + re-derives "detected" rows every run, so deleting a detected row from the
    // table would only hide it until the next analyzeRecent recreates the same (startTs, sport) PK.
    // The durable "this isn't a workout" record is a list of dismissed time spans persisted in
    // UserDefaults (the macOS WorkoutRow lives in the WhoopStore Journal file, which this layer must
    // not extend with a new column). A detected row overlapping any dismissed span stays hidden.
    // (#107)

    /// UserDefaults key holding the dismissed spans as "startTs:endTs" strings.
    static let dismissedDefaultsKey = "workouts.dismissedDetected"

    /// Parse "startTs:endTs" spans (UserDefaults string array). Malformed / non-positive-width
    /// entries are dropped so a corrupt value can never hide everything.
    static func parseDismissedSpans(_ raw: [String]) -> [(start: Int, end: Int)] {
        raw.compactMap { s in
            let parts = s.split(separator: ":")
            guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), b > a else { return nil }
            return (a, b)
        }
    }

    /// The "startTs:endTs" token persisted for a dismissed row (caller appends it to the defaults list).
    static func dismissedToken(for row: WorkoutRow) -> String { "\(row.startTs):\(row.endTs)" }

    /// Read-time filter: a DETECTED row overlapping any dismissed span is hidden. Imported / manual
    /// rows are never auto-hidden (the user deletes those outright), so dismissal only applies to the
    /// re-derived detected source. Half-open overlap test: `row.start < span.end && span.start < row.end`.
    static func isDismissed(_ row: WorkoutRow, spans: [(start: Int, end: Int)]) -> Bool {
        classify(row.source) == .detected
            && spans.contains { row.startTs < $0.end && $0.start < row.endTs }
    }

    // MARK: - Cross-source dedup (#687)
    //
    // The SAME activity can land twice: once live, Bluetooth-tracked under the strap (rich — real HR
    // trace, strain, zones, route), and once imported from Health Connect / Apple Health for the same
    // window (thin — usually just duration + calories). They sit under different deviceIds/sources, so
    // the workout list shows both as separate sessions. Collapse a pair that is clearly the same bout
    // (overlapping time window + same sport) to a single richer entry.
    //
    // Pure + deterministic so both platforms and the unit test share one rule. Run AFTER the dismissed
    // filter, BEFORE the final sort, on the combined multi-source list.

    /// Normalised sport key for cross-source matching. Folds the WHOOP camelCase token and a
    /// human-readable import label to the same key ("TraditionalStrengthTraining" and
    /// "Traditional Strength Training" → "traditionalstrengthtraining"), case- and space-insensitive,
    /// so the same activity matches across sources. "detected"/"Activity" both fold to "activity".
    /// LOCALE-STABLE by construction: computed from the raw token, never the localized display (a
    /// localized word here would vary the dedup key and the trace allowlist per user language).
    static func sportKey(_ sport: String) -> String {
        editableSport(sport).lowercased().filter { !$0.isWhitespace }
    }

    /// The set of `sportKey`s for the named catalogue (Running, Cycling, … Padel, Other), computed once.
    /// Used ONLY by the TRACE path to decide whether a key is a known, non-PII catalogue sport.
    private static let catalogSportKeys: Set<String> =
        Set(WorkoutCatalog.all.map { sportKey($0.name) })

    /// PRIVACY (TRACE PATH ONLY): a redaction-safe sport key for the Workouts test-mode trace. `sportKey`
    /// returns a free-typed name verbatim (folded), so a user-named sport like "Johns Birthday 5k" would
    /// otherwise surface as `sport=johnsbirthday5k` in the export, which `redactPii` cannot catch. Here we
    /// emit the key ONLY when it matches the known named catalogue; any off-catalogue / free-text sport
    /// folds to the generic "custom" so genuine user text can never enter a shared bundle. The user-facing
    /// `displaySport` is unchanged - this is purely the diagnostic-line token. "detected"/"Activity" fold to
    /// "activity" via `sportKey` and that IS a catalogue-independent known token, so it is allowed through.
    static func traceSportKey(_ sport: String) -> String {
        let key = sportKey(sport)
        if key == "activity" { return key }   // the detector's neutral token, never user text
        return catalogSportKeys.contains(key) ? key : "custom"
    }

    /// How many "rich" captured signals a row carries — the tiebreak for which duplicate to keep.
    /// A live-tracked strap session scores high (HR trace, peak, strain, zones, distance); a thin
    /// import scores low. Energy is the most commonly-present import field so it is weighted lowest.
    static func richness(_ row: WorkoutRow) -> Int {
        var n = 0
        if row.avgHr != nil { n += 1 }
        if row.maxHr != nil { n += 1 }
        if row.strain != nil { n += 1 }
        if let z = row.zonesJSON, !z.isEmpty { n += 1 }
        if let d = row.distanceM, d > 0 { n += 1 }
        if let k = row.energyKcal, k > 0 { n += 1 }
        return n
    }

    /// True when two rows are the SAME activity from different sources: same normalised sport AND their
    /// time windows overlap by more than half of the shorter session. The >50%-of-shorter test (not bare
    /// touching) keeps two genuinely back-to-back same-sport sessions distinct while still catching the
    /// small start/end drift between a live capture and its import.
    static func sameActivity(_ a: WorkoutRow, _ b: WorkoutRow) -> Bool {
        sportKey(a.sport) == sportKey(b.sport) && overlapsInTime(a, b)
    }

    /// The time-overlap half of `sameActivity`: the two windows overlap by more than half of the shorter
    /// session. Sport equality is checked separately — `collapseCrossSource` buckets rows by sport, so within
    /// a bucket only this (allocation-free) half remains, which is what makes the collapse walk near-linear.
    private static func overlapsInTime(_ a: WorkoutRow, _ b: WorkoutRow) -> Bool {
        let overlap = min(a.endTs, b.endTs) - max(a.startTs, b.startTs)
        guard overlap > 0 else { return false }
        let shorter = max(1, min(a.endTs - a.startTs, b.endTs - b.startTs))
        return Double(overlap) > 0.5 * Double(shorter)
    }

    /// Of two same-activity rows, the one to KEEP. Prefer the richer (more captured signals); on a tie
    /// prefer the strap-native source (live/manual/detected/whoop carry the real trace) over a thin
    /// import (Apple Health / Health Connect); final tie → the longer session, then `a` (stable).
    static func preferred(_ a: WorkoutRow, _ b: WorkoutRow) -> WorkoutRow {
        let ra = richness(a), rb = richness(b)
        if ra != rb { return ra > rb ? a : b }
        let ia = classify(a.source) == .apple, ib = classify(b.source) == .apple
        if ia != ib { return ia ? b : a }   // keep the non-import on a richness tie
        let da = a.endTs - a.startTs, db = b.endTs - b.startTs
        if da != db { return da > db ? a : b }
        return a
    }

    // MARK: - Detected-vs-real overlap collapse (#975)
    //
    // The engine derives a "detected" bout from raw HR and DROPS it when it overlaps a real logged session
    // (IntelligenceEngine: bare time overlap, ANY source), but only on the next analyze pass. Between a live
    // /manual session ending and that pass, BOTH the manual row AND the detected shadow of the same bout show
    // in the list, and the detected shadow (a WIDER, sport-agnostic HR window) reads an implausibly high
    // interpolated Effort/HR next to the real one. `sameActivity` cannot collapse them because their SPORTS
    // differ ("detected" vs the user's sport). This read-time guard mirrors the engine's own rule so the list
    // never shows the transient duplicate: a DETECTED row is dropped when its time window overlaps a REAL
    // (non-detected) session by more than half of the shorter of the two. The >50%-of-shorter test (not bare
    // touching) keeps a genuinely separate back-to-back session distinct, matching `sameActivity`'s overlap
    // rule. Runs BEFORE the same-sport cross-source dedup, so the detected shadow is gone before that walk.

    /// True when `detected` (a detected bout) is a redundant shadow of `real` (a logged session of any source
    /// other than detected): their windows overlap by more than half of the shorter session. Order matters ,
    /// `detected` must be the detected row and `real` a non-detected row; the caller enforces that.
    static func detectedShadowsReal(_ detected: WorkoutRow, _ real: WorkoutRow) -> Bool {
        let overlap = min(detected.endTs, real.endTs) - max(detected.startTs, real.startTs)
        guard overlap > 0 else { return false }
        let shorter = max(1, min(detected.endTs - detected.startTs, real.endTs - real.startTs))
        return Double(overlap) > 0.5 * Double(shorter)
    }

    /// Drop every DETECTED row whose window shadows a REAL (non-detected) session in the same list (#975), so
    /// the live/manual session and its detected twin never both show. Order-stable; a list with no detected
    /// row, or no real row, passes through unchanged. Runs before `dedupCrossSource`.
    static func dropDetectedShadows(_ rows: [WorkoutRow]) -> [WorkoutRow] {
        let reals = rows.filter { classify($0.source) != .detected }
        guard !reals.isEmpty else { return rows }
        return rows.filter { row in
            guard classify(row.source) == .detected else { return true }
            return !reals.contains { detectedShadowsReal(row, $0) }
        }
    }

    /// Collapse cross-source duplicates of the same activity, keeping the richer row of each pair.
    /// Order-stable: walks the input once, and a row that duplicates one already kept is dropped (with
    /// the kept row swapped for the richer of the two). Single-source lists pass through unchanged.
    /// #975: a DETECTED bout that shadows a real logged session is dropped FIRST so the transient
    /// live+detected duplicate never shows and can't pollute the Effort/HR read-out.
    static func dedupCrossSource(_ rows: [WorkoutRow]) -> [WorkoutRow] {
        collapseCrossSource(dropDetectedShadows(rows))
    }

    /// The shared cross-source collapse walk behind `dedupCrossSource` and `dedupCrossSourceTrace`. Byte-
    /// identical to the naive "compare every kept row" walk — same first match (kept insertion order), same
    /// `preferred` winner, same resulting list — but near-linear instead of O(n²): `sportKey` is computed
    /// ONCE per row (not twice per comparison), rows are bucketed by it, and a candidate only ever compares
    /// against kept rows of the SAME sport (a cross-sport pair can never be `sameActivity`). That removes the
    /// per-comparison string-normalisation that made a large imported history freeze the workout screens.
    /// `onMerge` is invoked with (winner, loser) for each collapsed pair so the trace path can record it.
    private static func collapseCrossSource(
        _ input: [WorkoutRow],
        onMerge: ((_ winner: WorkoutRow, _ loser: WorkoutRow) -> Void)? = nil
    ) -> [WorkoutRow] {
        var kept: [WorkoutRow] = []
        kept.reserveCapacity(input.count)
        // sportKey -> indices into `kept` for that sport, in insertion order (preserves first-match semantics).
        var bySport: [String: [Int]] = [:]
        for row in input {
            let key = sportKey(row.sport)
            var merged = false
            for idx in bySport[key, default: []] where overlapsInTime(kept[idx], row) {
                let winner = preferred(kept[idx], row)
                if let onMerge {
                    // Identify the loser by the REAL keep decision (== against the winner). When the two rows
                    // are byte-identical the label is interchangeable, so == is correct in every case.
                    onMerge(winner, winner == kept[idx] ? row : kept[idx])
                }
                kept[idx] = winner
                merged = true
                break
            }
            if !merged {
                bySport[key, default: []].append(kept.count)
                kept.append(row)
            }
        }
        return kept
    }

    /// A short, source-only descriptor of a row for the Workouts test-mode dedup trace ("strap" / "apple" /
    /// "detected" / "manual" / "lifting" / "activityFile"). No timestamps or free text.
    static func sourceLabel(_ row: WorkoutRow) -> String {
        switch classify(row.source) {
        case .whoop:        return "strap"
        case .apple:        return "apple"
        case .detected:     return "detected"
        case .manual:       return "manual"
        case .lifting:      return "lifting"
        case .activityFile: return "activityFile"
        }
    }

    /// Diagnostic twin of `dedupCrossSource(...)` for the Workouts & GPS test mode: returns the BYTE-IDENTICAL
    /// kept list (the SAME walk, the SAME `preferred` choice) plus a trace line per collapsed pair naming the
    /// kept vs dropped source and their richness. The kept output equals `dedupCrossSource(...)` exactly, so
    /// the trace can never diverge from the list the screen shows. Only called when the mode is on.
    /// #975: it FIRST drops any detected shadow of a real session (the SAME `dropDetectedShadows` step the
    /// plain path runs) and emits one `detectedBout verdict=droppedShadow` line per drop, so the export shows
    /// exactly which detected twin was suppressed to keep the live/manual session single.
    static func dedupCrossSourceTrace(_ rows: [WorkoutRow]) -> (kept: [WorkoutRow], trace: [String]) {
        var lines: [String] = []
        // Detected-shadow drop first (byte-identical to dedupCrossSource's `dropDetectedShadows`), tracing each.
        let reals = rows.filter { classify($0.source) != .detected }
        var input: [WorkoutRow] = []
        input.reserveCapacity(rows.count)
        for row in rows {
            if classify(row.source) == .detected,
               let hit = reals.first(where: { detectedShadowsReal(row, $0) }) {
                let durMin = max(0, (row.endTs - row.startTs) / 60)
                lines.append(WorkoutsTrace.detectedBoutLine(
                    verdict: "droppedShadow", durMin: durMin, avgBpm: row.avgHr ?? 0,
                    overlapSource: sourceLabel(hit)))
                continue
            }
            input.append(row)
        }
        // Same bucketed collapse as the plain path, so the kept list can never diverge from what the screen
        // shows; the callback records one dedup line per collapsed pair. traceSportKey reads the winner's
        // sport — same sportKey as the loser (they matched), so the emitted token is stable either way.
        let kept = collapseCrossSource(input) { winner, loser in
            lines.append(WorkoutsTrace.dedupLine(
                sportKey: traceSportKey(winner.sport),   // PRIVACY: catalogue key or "custom", never free text
                keptSource: sourceLabel(winner), droppedSource: sourceLabel(loser),
                keptRichness: richness(winner), droppedRichness: richness(loser)))
        }
        return (kept, lines)
    }

    // MARK: - Building / preserving rows

    /// Carry the captured fields the add/edit sheet does NOT expose (maxHr, strain, zonesJSON, notes,
    /// steps) over from the row being edited. A v1.67 live-tracked session has real captured
    /// strain/maxHr; rebuilding the row from the sheet's inputs alone would silently wipe them on an
    /// edit. No-op for a fresh add (`old == nil`). `distanceM` is NOW a sheet field (#1195), so it comes
    /// from the freshly built `row` (the sheet pre-fills it from the edited row, so an untouched field
    /// preserves the captured GPS distance and a cleared one clears it) rather than being force-carried
    /// from `old`. `steps` (#1058) has no sheet field at all, so it is carried like the others (#1444).
    static func preservingCaptured(_ row: WorkoutRow, from old: WorkoutRow?) -> WorkoutRow {
        guard let old else { return row }
        return WorkoutRow(startTs: row.startTs, endTs: row.endTs, sport: row.sport,
                          source: row.source, durationS: row.durationS,
                          energyKcal: row.energyKcal, avgHr: row.avgHr,
                          maxHr: old.maxHr, strain: old.strain, distanceM: row.distanceM,
                          zonesJSON: old.zonesJSON, notes: old.notes, steps: old.steps)
    }

    /// Build a retroactive manual workout (source "manual", persisted under the strap deviceId by the
    /// caller — where v1.67's live sessions live). Returns nil when the input can't make an honest row.
    /// strain/zones stay nil: with no captured HR window an APPROXIMATE strain is never fabricated.
    static func buildManualRow(start: Date, durationMin: Int, sport: String,
                               avgHr: Int?, energyKcal: Double?, distanceM: Double? = nil,
                               now: Date = Date()) -> WorkoutRow? {
        guard durationMin > 0, durationMin <= 24 * 60 else { return nil }
        let trimmed = sport.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, start <= now else { return nil }
        if let hr = avgHr, !(25...250).contains(hr) { return nil }
        if let k = energyKcal, k < 0 || k > 20_000 { return nil }
        // Distance 0–1000 km (#1195): rejects a negative or absurd manual entry. 1000 km comfortably
        // covers any single session (an Ironman bike is 180 km, an ultra 160 km).
        if let d = distanceM, d < 0 || d > 1_000_000 { return nil }
        let s = Int(start.timeIntervalSince1970)
        guard s > 0 else { return nil }
        // Reject a row whose END lands in the future: `start <= now` alone still lets `start + duration`
        // overshoot (a start 10 min ago + a 45 min duration ends 35 min ahead). Overflow-safe, and a row
        // ending exactly at `now` stays valid. Twin of Android `WorkoutEditing` (#1067).
        let durationSeconds = durationMin * 60
        guard durationSeconds <= Int.max - s else { return nil }
        let end = s + durationSeconds
        guard end <= Int(now.timeIntervalSince1970) else { return nil }
        return WorkoutRow(startTs: s, endTs: end, sport: trimmed, source: "manual",
                          durationS: Double(durationSeconds), energyKcal: energyKcal,
                          avgHr: avgHr, maxHr: nil, strain: nil, distanceM: distanceM,
                          zonesJSON: nil, notes: nil, steps: nil)
    }
}

// MARK: - Filter predicate (#64)
//
// The Workouts list filters beyond the time range: a SPORT filter (a specific displayed sport, or all)
// and a SOURCE filter (Whoop / Apple / Detected / Manual / Lifting / File, or all), plus a free-text
// SEARCH over the displayed sport name. All three are pure and compose with the time-range window the
// screen already computes, so the whole screen (hero, tiles, breakdown, zones, list) reads one filtered
// set. Kept alongside `WorkoutSource` so both platforms share one rule and the unit test pins it.

/// One workout-list filter state. `sport` is a displayed-sport key (`WorkoutSource.displaySport`), nil =
/// all sports. `sourceClass` is the origin class, nil = all sources. `search` is a free-text query over
/// the displayed sport name (trimmed, case-insensitive; empty = no search).
struct WorkoutFilter: Equatable {
    var sport: String?
    var sourceClass: WorkoutSource?
    var search: String

    init(sport: String? = nil, sourceClass: WorkoutSource? = nil, search: String = "") {
        self.sport = sport
        self.sourceClass = sourceClass
        self.search = search
    }

    /// True when no facet is active — the caller can skip the walk and keep the input verbatim.
    var isActive: Bool {
        sport != nil || sourceClass != nil
            || !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Does one row pass every active facet? Sport matches on the DISPLAYED name (so "detected" folds to
    /// "Activity", camelCase splits) exactly as the picker lists it; source matches on `classify`; search
    /// is a case-insensitive substring of the displayed sport.
    func matches(_ row: WorkoutRow) -> Bool {
        if let sport, WorkoutSource.displaySport(row.sport) != sport { return false }
        if let sourceClass, WorkoutSource.classify(row.source) != sourceClass { return false }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty,
           WorkoutSource.displaySport(row.sport).range(of: q, options: .caseInsensitive) == nil {
            return false
        }
        return true
    }

    /// Apply the filter to a windowed list, preserving order. A no-op when nothing is active.
    func apply(_ rows: [WorkoutRow]) -> [WorkoutRow] {
        guard isActive else { return rows }
        return rows.filter(matches)
    }
}

// MARK: - Merge (#64)
//
// Merge two or more overlapping / adjacent MANUAL or DETECTED sessions into one, keeping the richer
// captured signals. Imported history (whoop / apple / lifting / activityFile) is read-only and is NEVER
// merged — the eligibility gate below enforces it, and the persistence path (Repository.mergeWorkouts)
// only ever writes through the manual-row path. Pure + deterministic so both platforms and the unit test
// share one rule; the persistence sequence lives in the repository.

enum WorkoutMerge {

    /// Only MANUAL and DETECTED rows can be merged (imported history stays read-only). A merge needs at
    /// least two eligible rows.
    static func isMergeable(_ row: WorkoutRow) -> Bool {
        switch WorkoutSource.classify(row.source) {
        case .manual, .detected: return true
        case .whoop, .apple, .lifting, .activityFile: return false
        }
    }

    /// True when a set of selected rows can be merged: two or more, and every one is mergeable.
    static func canMerge(_ rows: [WorkoutRow]) -> Bool {
        rows.count >= 2 && rows.allSatisfy(isMergeable)
    }

    /// The sport the merge should carry: the most-frequent non-"detected" sport across the inputs (ties
    /// broken by first appearance), or nil when every input is a bare detected bout — then the caller
    /// asks the user to pick one. "detected"/"Activity" never wins so a merge with any real label keeps it.
    static func resolvedSport(_ rows: [WorkoutRow]) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for r in rows where r.sport != "detected" {
            let s = r.sport
            if counts[s] == nil { order.append(s) }
            counts[s, default: 0] += 1
        }
        guard !order.isEmpty else { return nil }
        // Stable: highest count, ties resolved by first appearance (order index).
        return order.max(by: { (counts[$0] ?? 0, order.firstIndex(of: $1) ?? 0)
                                < (counts[$1] ?? 0, order.firstIndex(of: $0) ?? 0) })
    }

    /// Merge the given rows into one manual row. `sport` overrides the resolved sport (used when the
    /// inputs are all detected and the user picked one); when nil the resolved sport is used, falling back
    /// to "Activity" only if there is genuinely no label. Returns nil for fewer than two rows.
    ///
    /// Math (per the #64 brief): startTs = min, endTs = max (the honest span); durationS = SUM of the
    /// per-session durations (honest active time, NOT the span); energyKcal = SUM; avgHr = duration-
    /// weighted mean of the sessions that carry one; maxHr = max; distanceM = SUM; strain = nil (the repo
    /// rescores it from the strap HR via analyzeRecent, the #598 pattern); zonesJSON = nil; notes = joined.
    static func merge(_ rows: [WorkoutRow], sport: String? = nil) -> WorkoutRow? {
        guard rows.count >= 2 else { return nil }
        let start = rows.map(\.startTs).min() ?? rows[0].startTs
        let end = rows.map(\.endTs).max() ?? rows[0].endTs

        // Duration = sum of each session's active duration (fall back to its own span when nil).
        let durationS = rows.reduce(0.0) { $0 + ($1.durationS ?? Double(max(0, $1.endTs - $1.startTs))) }

        // Energy + distance + steps sum only the present values; nil when NOTHING carried one (never a
        // fake 0). #1444: steps is cumulative per session exactly like distance, so a merge sums it too —
        // it was silently dropped here until making the field explicit forced the question.
        let kcals = rows.compactMap(\.energyKcal)
        let energyKcal = kcals.isEmpty ? nil : kcals.reduce(0, +)
        let dists = rows.compactMap(\.distanceM)
        let distanceM = dists.isEmpty ? nil : dists.reduce(0, +)
        let stepCounts = rows.compactMap(\.steps)
        let mergedSteps = stepCounts.isEmpty ? nil : stepCounts.reduce(0, +)

        // Avg HR = duration-weighted mean over the rows that HAVE an avg; weight = that row's duration
        // (fall back to its span). maxHr = the max present peak. Both nil when no row carried the field.
        var hrWeight = 0.0, hrSum = 0.0
        for r in rows {
            guard let hr = r.avgHr else { continue }
            let w = r.durationS ?? Double(max(1, r.endTs - r.startTs))
            hrWeight += w
            hrSum += Double(hr) * w
        }
        let avgHr = hrWeight > 0 ? Int((hrSum / hrWeight).rounded()) : nil
        let maxHrs = rows.compactMap(\.maxHr)
        let maxHr = maxHrs.max()

        // Notes = the non-empty notes joined (order-stable), nil when none.
        let notes = rows.compactMap { $0.notes?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let mergedNotes = notes.isEmpty ? nil : notes.joined(separator: " · ")

        let mergedSport = sport ?? resolvedSport(rows) ?? "Activity"

        return WorkoutRow(startTs: start, endTs: end, sport: mergedSport, source: "manual",
                          durationS: durationS, energyKcal: energyKcal, avgHr: avgHr, maxHr: maxHr,
                          strain: nil, distanceM: distanceM, zonesJSON: nil, notes: mergedNotes,
                          steps: mergedSteps)
    }
}
