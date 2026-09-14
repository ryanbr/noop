import Foundation
import WhoopProtocol

// AutoWorkoutDetector+Trace.swift - the Workouts & GPS test-mode auto-detect trace + line formatters.
//
// detectTrace(...) is the side-effect-free twin of AutoWorkoutDetector.detect(...): it returns the SAME
// [DetectedWorkout] detect would (it reuses detect verbatim), plus a trace that names the detector's inputs
// (HR sample count, resting floor), the thresholds it applied (elevated margin, sustained minutes, dip /
// merge / motion-confirm constants), and WHY each candidate window was offered or dropped (too short,
// motion-not-confirmed, overlaps a saved session). So a "my workout went missing / auto-detect didn't fire"
// report shows exactly which gate kept or dropped each window.
//
// WorkoutsTrace adds the line formatters the app-target emitters use for the session lifecycle, the GPS-fix
// count and the cross-source dedup decisions (the app layer owns the live state, this owns the line shape so
// the two platforms read identically and a fixture pins them). Everything here is pure, no clock, no I/O, no
// PII (counts / bpm / seconds / sport keys only). The Workouts test mode gates each call behind
// TestCentre.active(.workouts) at the call site; when the mode is off it is never called, so there is zero
// cost. No em-dashes. The Kotlin twin is AutoWorkoutDetectorTrace / WorkoutsTrace.

extension AutoWorkoutDetector {

    private struct ShadowPair {
        let candidateIndex: Int
        let savedIndex: Int
        let overlapS: Int
    }

    /// Side-effect-free diagnostic twin of `detect(...)`: returns the SAME `[DetectedWorkout]` detect would,
    /// plus the trace. The returned windows ARE `detect(...)`'s verbatim, so the trace can never disagree
    /// with what the Today card actually suggests. The trace logs the inputs + the thresholds, then walks the
    /// detector's own gates (sustained-minutes, motion-confirm, saved-overlap) to name why each merged window
    /// survived or dropped, mirroring the algorithm exactly. The Kotlin twin is
    /// `AutoWorkoutDetectorTrace.detectTrace`.
    ///
    /// - Parameters mirror `detect(...)` exactly. `minimumSustainedMinutes` defaults to the published
    ///   12-minute policy; explicit 10/15-minute values are for local shadow diagnostics only. `path` tags
    ///   the call ("autoDetect" / "manualReview") so a report shows which entry point produced it.
    public static func detectTrace(hr: [(ts: Int, bpm: Int)],
                                   restingBpm: Int?,
                                   motion: [MotionPoint]? = nil,
                                   savedSpans: [SavedWorkoutSpan] = [],
                                   minimumSustainedMinutes: Double = minSustainedMin,
                                   path: String = "autoDetect")
        -> (results: [DetectedWorkout], trace: [String]) {

        // The result the Today card reads, verbatim, so the trace cannot diverge from it.
        let results = detect(hr: hr, restingBpm: restingBpm, motion: motion,
                             savedSpans: savedSpans,
                             minimumSustainedMinutes: minimumSustainedMinutes)

        var lines: [String] = []
        let floor = (restingBpm ?? defaultRestingHR) + elevatedMarginBPM
        let hasMotion = !(motion?.isEmpty ?? true)

        // Inputs the detector saw.
        lines.append("autoDetect path=\(path) hrSamples=\(hr.count) "
            + "restingBpm=\(restingBpm.map(String.init) ?? "default(\(defaultRestingHR))") "
            + "elevatedFloor=\(floor)bpm motion=\(hasMotion ? "supplied" : "hrOnly") savedSpans=\(savedSpans.count)")

        // Thresholds applied (the autoDetectThresholds capture). Stated once so a report carries the
        // calibration the windows were judged against.
        lines.append("autoDetect thresholds elevatedMargin=\(elevatedMarginBPM)bpm "
            + "minSustainedMin=\(minimumSustainedMinutes) maxDipS=\(maxDipS) mergeGapS=\(mergeGapS) "
            + "motionConfirmMean=\(motionConfirmMean)")

        // Rebuild the SAME merged windows the detector forms (sustained spans tolerating dips, then merge),
        // so we can name why each survived or dropped WITHOUT changing the returned `results`. This mirrors
        // detect(...)'s steps 1-4 exactly; the per-window verdict below mirrors steps 5-6.
        let seg = hr.sorted { $0.ts < $1.ts }
        if seg.isEmpty {
            lines.append("autoDetect result windows=0 (no HR samples)")
            return (results, lines)
        }

        var spans: [(start: Int, end: Int)] = []
        var spanStart: Int? = nil
        var spanEnd = 0
        var dipStart: Int? = nil
        func closeSpan() {
            if let s = spanStart, Double(spanEnd - s) >= minimumSustainedMinutes * 60.0 {
                spans.append((s, spanEnd))
            }
            spanStart = nil
            dipStart = nil
        }
        for sample in seg {
            if sample.bpm >= floor {
                if spanStart == nil { spanStart = sample.ts }
                spanEnd = sample.ts
                dipStart = nil
            } else if spanStart != nil {
                if dipStart == nil { dipStart = sample.ts }
                if let d = dipStart, sample.ts - d > maxDipS { closeSpan() }
            }
        }
        closeSpan()

        if spans.isEmpty {
            lines.append("autoDetect why=noSustainedSpan "
                + "(no contiguous run held >=\(minimumSustainedMinutes)min above \(floor)bpm)")
            lines.append("autoDetect result windows=0")
            return (results, lines)
        }

        // Merge spans whose gap is strictly < mergeGapS (same as detect step 4).
        var merged: [(start: Int, end: Int)] = []
        var curStart = spans[0].start
        var curEnd = spans[0].end
        for k in 1..<spans.count {
            let next = spans[k]
            if next.start - curEnd < mergeGapS {
                curEnd = max(curEnd, next.end)
            } else {
                merged.append((curStart, curEnd))
                curStart = next.start
                curEnd = next.end
            }
        }
        merged.append((curStart, curEnd))

        // Per-window verdict (the autoDetectWhy capture), mirroring detect steps 5-6.
        let motionSeries = hasMotion ? motion : nil
        for (start, end) in merged {
            let durMin = (end - start) / 60
            if savedSpans.contains(where: { overlaps(start, end, $0.startSec, $0.endSec) }) {
                lines.append("autoDetect window durMin=\(durMin) verdict=dropped why=overlapsSavedWorkout")
                continue
            }
            if let motionSeries {
                let inWin = motionSeries.filter { $0.ts >= start && $0.ts <= end }.map { $0.intensity }
                let meanMotion = inWin.isEmpty ? 0.0 : inWin.reduce(0.0, +) / Double(inWin.count)
                if meanMotion < motionConfirmMean {
                    lines.append("autoDetect window durMin=\(durMin) verdict=dropped why=motionNotConfirmed "
                        + "(mean=\((meanMotion * 1000).rounded() / 1000) < \(motionConfirmMean))")
                    continue
                }
            }
            lines.append("autoDetect window durMin=\(durMin) verdict=offered")
        }
        lines.append("autoDetect result windows=\(results.count) "
            + "(offered the most recent that is not saved or dismissed)")
        return (results, lines)
    }

    /// Compare shadow candidates with manually/imported labelled workouts, without suppressing overlaps.
    /// Candidates and labels are canonical-sorted, then paired one-to-one with a deterministic weighted
    /// assignment. The assignment maximises cardinality first and total overlap second, so a broad label cannot
    /// strand a candidate with no alternative and an equally large matching cannot retain a lower-overlap set.
    /// Results therefore do not depend on database/union iteration order. A match requires strictly positive
    /// overlap; endpoint-only contact is not evidence that the detector found the labelled workout.
    ///
    /// When `hrForObservability` is supplied, a label is observable only when its longest recorded HR run
    /// (no sample gap above the detector's 90-second dip tolerance) spans the shorter of the label duration
    /// and this policy's qualification duration. This retains genuinely short labelled workouts as evidence,
    /// but two isolated points cannot manufacture a policy miss. Unobservable labels are reported separately
    /// and never counted as misses. `matched` counts pairs, `unmatched` candidates left over, and `missed`
    /// observable labelled spans left over. Median onset/end errors are absolute seconds for matched pairs,
    /// or `n/a` when nothing matched.
    ///
    /// The caller must exclude legacy automatically detected rows from `savedSpans`: shadow mode measures
    /// against user-confirmed/imported labels, not against the detector's own prior output. This formatter is
    /// pure and returns only aggregate counts; it cannot save, dismiss, classify, or score a workout.
    public static func shadowComparisonLine(policyMinutes: Double,
                                            candidates: [DetectedWorkout],
                                            savedSpans: [SavedWorkoutSpan],
                                            hrForObservability: [(ts: Int, bpm: Int)]? = nil) -> String {
        let orderedCandidates = candidates.sorted {
            if $0.startSec != $1.startSec { return $0.startSec < $1.startSec }
            if $0.endSec != $1.endSec { return $0.endSec < $1.endSec }
            if $0.avgBpm != $1.avgBpm { return $0.avgBpm < $1.avgBpm }
            if $0.peakBpm != $1.peakBpm { return $0.peakBpm < $1.peakBpm }
            return $0.durationMin < $1.durationMin
        }
        let labelPartition = shadowLabelPartition(
            savedSpans: savedSpans,
            hr: hrForObservability,
            policyMinutes: policyMinutes)
        let orderedSaved = labelPartition.observable.sorted {
            if $0.startSec != $1.startSec { return $0.startSec < $1.startSec }
            return $0.endSec < $1.endSec
        }
        var possibleByCandidate = Array(repeating: [ShadowPair](), count: orderedCandidates.count)
        for (candidateIndex, candidate) in orderedCandidates.enumerated() {
            for (savedIndex, saved) in orderedSaved.enumerated() {
                let overlapS = min(candidate.endSec, saved.endSec)
                    - max(candidate.startSec, saved.startSec)
                guard overlapS > 0 else { continue }
                possibleByCandidate[candidateIndex].append(ShadowPair(
                    candidateIndex: candidateIndex,
                    savedIndex: savedIndex,
                    overlapS: overlapS))
            }
        }
        let matchedPairs = maximumCardinalityOverlapPairs(
            possibleByCandidate: possibleByCandidate,
            savedCount: orderedSaved.count)

        let onsetErrors = matchedPairs.map {
            abs(orderedCandidates[$0.candidateIndex].startSec - orderedSaved[$0.savedIndex].startSec)
        }
        let endErrors = matchedPairs.map {
            abs(orderedCandidates[$0.candidateIndex].endSec - orderedSaved[$0.savedIndex].endSec)
        }
        let matched = matchedPairs.count
        let missed = orderedSaved.count - matched
        let unmatched = candidates.count - matched
        return "workout shadow policy=\(shadowMinuteLabel(policyMinutes))min candidates=\(candidates.count) "
            + "matched=\(matched) missed=\(missed) unobservable=\(labelPartition.unobservableCount) "
            + "unmatched=\(unmatched) "
            + "medianOnsetErrorS=\(medianErrorLabel(onsetErrors)) "
            + "medianEndErrorS=\(medianErrorLabel(endErrors))"
    }

    /// Run the published policy plus the supported 10/15-minute alternatives for local shadow diagnostics
    /// and return aggregate trace lines only. Label spans are deliberately NOT passed into `detect`: doing
    /// so would suppress every true overlap before it could be measured. No result from this function is a
    /// published suggestion.
    public static func shadowComparisonLines(hr: [(ts: Int, bpm: Int)],
                                             restingBpm: Int?,
                                             motion: [MotionPoint]? = nil,
                                             savedSpans: [SavedWorkoutSpan],
                                             policies: [Double] = ([minSustainedMin]
                                                 + shadowSustainedMinutes).sorted()) -> [String] {
        policies.map { policy in
            let candidates = detect(hr: hr, restingBpm: restingBpm, motion: motion,
                                    minimumSustainedMinutes: policy)
            return shadowComparisonLine(policyMinutes: policy, candidates: candidates,
                                        savedSpans: savedSpans, hrForObservability: hr)
        }
    }

    /// Split labels by whether the detector input has enough contiguous-in-time HR to evaluate this policy.
    private static func shadowLabelPartition(savedSpans: [SavedWorkoutSpan],
                                             hr: [(ts: Int, bpm: Int)]?,
                                             policyMinutes: Double)
        -> (observable: [SavedWorkoutSpan], unobservableCount: Int) {
        guard let hr else { return (savedSpans, 0) }
        let timestamps = Array(Set(hr.map(\.ts))).sorted()
        var observable: [SavedWorkoutSpan] = []
        observable.reserveCapacity(savedSpans.count)
        for span in savedSpans {
            let labelDuration = max(0, span.endSec - span.startSec)
            let requiredCoverage = min(Double(labelDuration), max(0, policyMinutes * 60.0))
            var runStart: Int?
            var previousTimestamp: Int?
            var longestRun = 0
            for timestamp in timestamps {
                if timestamp < span.startSec { continue }
                if timestamp > span.endSec { break }
                if let previousTimestamp, timestamp - previousTimestamp > maxDipS {
                    runStart = timestamp
                } else if runStart == nil {
                    runStart = timestamp
                }
                if let runStart { longestRun = max(longestRun, timestamp - runStart) }
                previousTimestamp = timestamp
            }
            if longestRun > 0, Double(longestRun) >= requiredCoverage { observable.append(span) }
        }
        return (observable, savedSpans.count - observable.count)
    }

    /// Hungarian assignment over candidate rows and saved-label + dummy columns. Every positive-overlap
    /// edge receives a cardinality bonus larger than the maximum possible total overlap, making the scalar
    /// objective exactly lexicographic: match count first, summed overlap second. Canonical input order and
    /// lowest-column tie breaks keep equal optima deterministic across Swift and Kotlin.
    private static func maximumCardinalityOverlapPairs(possibleByCandidate: [[ShadowPair]],
                                                       savedCount: Int) -> [ShadowPair] {
        let candidateCount = possibleByCandidate.count
        guard candidateCount > 0, savedCount > 0,
              let maxOverlap = possibleByCandidate.flatMap({ $0 }).map(\.overlapS).max()
        else { return [] }

        let maximumMatches = min(candidateCount, savedCount)
        let cardinalityBonus = Int64(maxOverlap) * Int64(maximumMatches) + 1
        let columnCount = savedCount + candidateCount
        var weights = Array(
            repeating: Array(repeating: Int64(0), count: columnCount),
            count: candidateCount)
        for options in possibleByCandidate {
            for option in options {
                weights[option.candidateIndex][option.savedIndex] =
                    cardinalityBonus + Int64(option.overlapS)
            }
        }

        // Minimum-cost Hungarian algorithm over negated weights. `p[column]` is its assigned 1-based row.
        var rowPotential = Array(repeating: Int64(0), count: candidateCount + 1)
        var columnPotential = Array(repeating: Int64(0), count: columnCount + 1)
        var assignedRow = Array(repeating: 0, count: columnCount + 1)
        var previousColumn = Array(repeating: 0, count: columnCount + 1)
        let infinity = Int64.max / 4

        for row in 1...candidateCount {
            assignedRow[0] = row
            var currentColumn = 0
            var minimumReducedCost = Array(repeating: infinity, count: columnCount + 1)
            var usedColumn = Array(repeating: false, count: columnCount + 1)
            repeat {
                usedColumn[currentColumn] = true
                let currentRow = assignedRow[currentColumn]
                var delta = infinity
                var nextColumn = 0
                for column in 1...columnCount where !usedColumn[column] {
                    let cost = -weights[currentRow - 1][column - 1]
                    let reducedCost = cost - rowPotential[currentRow] - columnPotential[column]
                    if reducedCost < minimumReducedCost[column] {
                        minimumReducedCost[column] = reducedCost
                        previousColumn[column] = currentColumn
                    }
                    if minimumReducedCost[column] < delta {
                        delta = minimumReducedCost[column]
                        nextColumn = column
                    }
                }
                for column in 0...columnCount {
                    if usedColumn[column] {
                        rowPotential[assignedRow[column]] += delta
                        columnPotential[column] -= delta
                    } else {
                        minimumReducedCost[column] -= delta
                    }
                }
                currentColumn = nextColumn
            } while assignedRow[currentColumn] != 0

            repeat {
                let prior = previousColumn[currentColumn]
                assignedRow[currentColumn] = assignedRow[prior]
                currentColumn = prior
            } while currentColumn != 0
        }

        var matches: [ShadowPair] = []
        for savedColumn in 1...savedCount {
            let candidateRow = assignedRow[savedColumn]
            guard candidateRow > 0,
                  let pair = possibleByCandidate[candidateRow - 1]
                    .first(where: { $0.savedIndex == savedColumn - 1 })
            else { continue }
            matches.append(pair)
        }
        return matches.sorted {
            if $0.candidateIndex != $1.candidateIndex { return $0.candidateIndex < $1.candidateIndex }
            return $0.savedIndex < $1.savedIndex
        }
    }

    /// Locale-independent policy label for byte-identical Swift/Kotlin shadow lines.
    private static func shadowMinuteLabel(_ value: Double) -> String {
        if value.isFinite, abs(value) < 1e15, value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }

    private static func medianErrorLabel(_ values: [Int]) -> String {
        guard !values.isEmpty else { return "n/a" }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if !sorted.count.isMultiple(of: 2) { return String(sorted[middle]) }
        return shadowMinuteLabel((Double(sorted[middle - 1]) + Double(sorted[middle])) / 2.0)
    }
}

/// Pure line formatters + the live-readout parser for the Workouts & GPS test mode. The app-target emitters
/// (AppModel session lifecycle, GpsWorkoutRecorder fixes, Repository cross-source dedup) own the live state;
/// these own the line SHAPE so both platforms read identically and a fixture pins them. WorkoutsReadout
/// parses the `.workouts`-tagged log tail back into the `lastSessionSummary` id the panel binds. No state,
/// no side effects, no PII (counts / seconds / sport keys only). No em-dashes. The Kotlin twin is WorkoutsTrace.
public enum WorkoutsTrace {

    /// A session-lifecycle line. `event` is "start" / "end" / "discarded"; the counts are the captured HR
    /// window size and (for an end) the duration + whether a GPS route landed, so the lifecycle of a missing
    /// workout is visible end to end. Sport is the normalised key, never free text.
    public static func sessionLine(event: String,
                                   sportKey: String,
                                   hrSamples: Int,
                                   durationSec: Int? = nil,
                                   gpsPoints: Int? = nil) -> String {
        var line = "session event=\(event) sport=\(sportKey) hrSamples=\(hrSamples)"
        if let durationSec { line += " durationSec=\(durationSec)" }
        if let gpsPoints { line += " gpsPoints=\(gpsPoints)" }
        return line
    }

    /// A GPS-fix-progress line: the raw fixes seen, how many the accuracy / speed filter accepted, and the
    /// running distance. So a route that under-records (a weak signal, a denied permission) is visible.
    ///
    /// `rawFixes` is OPTIONAL: macOS sees the pre-filter raw stream and passes a real count, so the line can
    /// show a true accept rate. Android's LocationTracker pre-filters upstream, so the raw count is NOT
    /// available at the GpsSession seam (every fix here is already accepted); it passes nil and the line
    /// renders `rawFixes=n/a` rather than implying an accept rate the platform cannot actually measure.
    public static func gpsLine(rawFixes: Int?, acceptedPoints: Int, distanceM: Double) -> String {
        "gps rawFixes=\(rawFixes.map(String.init) ?? "n/a") accepted=\(acceptedPoints) "
            + "distanceM=\(Int(distanceM.rounded())) (filter: accuracy+speed gate)"
    }

    /// An analytics detected-bout decision line. IntelligenceEngine derives a bout from raw HR/motion for
    /// scoring and enrichment, but never creates or reconciles a visible generic workout from it. A bout
    /// with no real overlap is `analyticsOnly`; one overlapping a manual/imported row is either
    /// `droppedOverlapBackfilled` when it supplied missing metrics, or `droppedOverlap` when that row was
    /// already complete. On an overlap, `overlapSource` names the real row. `durMin` is the whole-minute bout
    /// length. No PII (a source label + minutes + bpm only). Mirrors Kotlin `WorkoutsTrace.detectedBoutLine`.
    public static func detectedBoutLine(verdict: String,
                                        durMin: Int,
                                        avgBpm: Int,
                                        overlapSource: String? = nil) -> String {
        var line = "detectedBout verdict=\(verdict) durMin=\(durMin) avgBpm=\(avgBpm)"
        if let overlapSource { line += " overlapSource=\(overlapSource)" }
        return line
    }

    /// A cross-source dedup decision line: two same-activity rows from different sources were collapsed to
    /// the richer one. Reports the sources, the kept richness, and the overlap, so a "my workout shows twice"
    /// or "the richer one disappeared" report shows exactly which pair merged and which won.
    public static func dedupLine(sportKey: String,
                                 keptSource: String,
                                 droppedSource: String,
                                 keptRichness: Int,
                                 droppedRichness: Int) -> String {
        "dedup sport=\(sportKey) kept=\(keptSource)(richness=\(keptRichness)) "
            + "dropped=\(droppedSource)(richness=\(droppedRichness)) (same activity, richer kept)"
    }
}

/// Pure values for the Workouts & GPS live-readout panel. Parses the `.workouts`-tagged log tail the
/// emitters write, so the panel reflects exactly the last session without the app layer exposing new
/// published properties. No state, no side effects, no em-dashes. The Kotlin twin is the WorkoutsReadout object.
public enum WorkoutsReadout {

    /// The last session summary for the `lastSessionSummary` id: the most recent session-lifecycle line's
    /// fragment (event + sport + counts), or nil when none is present. So the panel reads the same outcome
    /// the lifecycle emitter wrote.
    public static func lastSessionSummary(taggedTail: [String]) -> String? {
        for line in taggedTail.reversed() {
            if let r = line.range(of: "session ") {
                let frag = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !frag.isEmpty { return frag }
            }
        }
        return nil
    }
}
