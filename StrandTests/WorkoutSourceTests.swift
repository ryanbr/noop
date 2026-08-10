import XCTest
import WhoopStore
@testable import Strand

/// Pins the pure workout-editing logic: source classification (the macOS read model has no
/// deviceId, so origin is recovered from `source`), the durable dismissed-span filter that keeps a
/// re-detected bout hidden (#107), manual-row validation, and field preservation on edit.
/// Mirrors the Android WorkoutEditingTest case-for-case.
final class WorkoutSourceTests: XCTestCase {

    private func row(start: Int, end: Int, sport: String, source: String,
                     avgHr: Int? = nil, maxHr: Int? = nil, strain: Double? = nil) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: end, sport: sport, source: source,
                   durationS: Double(end - start), energyKcal: nil, avgHr: avgHr, maxHr: maxHr,
                   strain: strain, distanceM: nil, zonesJSON: nil, notes: nil)
    }

    // MARK: - classify

    func testClassifyOrdersNoopBeforeWhoop() {
        // "my-whoop-noop" contains "whoop" — the -noop suffix MUST win, else a detected bout
        // would be classified as an imported WHOOP row and become un-dismissable.
        XCTAssertEqual(WorkoutSource.classify("my-whoop-noop"), .detected)
        XCTAssertEqual(WorkoutSource.classify("whoop"), .whoop)
        XCTAssertEqual(WorkoutSource.classify("manual"), .manual)
        XCTAssertEqual(WorkoutSource.classify("lifting"), .lifting)
        XCTAssertEqual(WorkoutSource.classify("activity-file"), .activityFile)
        XCTAssertEqual(WorkoutSource.classify("apple_health"), .apple)
        XCTAssertEqual(WorkoutSource.classify("apple-health"), .apple)
    }

    func testAppleHealthSourceAcceptsCanonicalAndLegacySpellings() {
        XCTAssertTrue(WorkoutSource.isAppleHealth("apple-health"))
        XCTAssertTrue(WorkoutSource.isAppleHealth("apple_health"))
        XCTAssertTrue(WorkoutSource.isAppleHealth("APPLE_HEALTH"))
        XCTAssertFalse(WorkoutSource.isAppleHealth("whoop"))
    }

    func testDisplaySportRenamesDetectedToken() {
        XCTAssertEqual(WorkoutSource.displaySport("detected"), "Activity")
        XCTAssertEqual(WorkoutSource.displaySport("Running"), "Running")
    }

    // MARK: - dismissed spans (durable #107 filter)

    func testParseDismissedSpansDropsMalformed() {
        let spans = WorkoutSource.parseDismissedSpans(["100:200", "bad", "5:5", "9:3", "300:400"])
        // "5:5" (zero width) and "9:3" (end<start) and "bad" are dropped.
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].start, 100); XCTAssertEqual(spans[0].end, 200)
        XCTAssertEqual(spans[1].start, 300); XCTAssertEqual(spans[1].end, 400)
    }

    func testIsDismissedOnlyHidesOverlappingDetectedRows() {
        let spans = WorkoutSource.parseDismissedSpans(["1000:2000"])
        let detectedOverlap = row(start: 1500, end: 2500, sport: "detected", source: "my-whoop-noop")
        let detectedClear = row(start: 3000, end: 4000, sport: "detected", source: "my-whoop-noop")
        let manualOverlap = row(start: 1500, end: 2500, sport: "Running", source: "manual")
        XCTAssertTrue(WorkoutSource.isDismissed(detectedOverlap, spans: spans))
        XCTAssertFalse(WorkoutSource.isDismissed(detectedClear, spans: spans))
        // A manual (or imported) row is NEVER auto-hidden by a dismissed span — only detected bouts.
        XCTAssertFalse(WorkoutSource.isDismissed(manualOverlap, spans: spans))
    }

    func testIsDismissedSurvivesStartTsDrift() {
        // A re-detected bout whose boundary drifted a little still overlaps the dismissed span.
        let spans = WorkoutSource.parseDismissedSpans(["1000:2000"])
        let drifted = row(start: 1040, end: 2030, sport: "detected", source: "my-whoop-noop")
        XCTAssertTrue(WorkoutSource.isDismissed(drifted, spans: spans))
    }

    func testDismissedTokenRoundTrips() {
        let r = row(start: 1700000000, end: 1700003600, sport: "detected", source: "my-whoop-noop")
        let token = WorkoutSource.dismissedToken(for: r)
        XCTAssertEqual(token, "1700000000:1700003600")
        let spans = WorkoutSource.parseDismissedSpans([token])
        XCTAssertTrue(WorkoutSource.isDismissed(r, spans: spans))
    }

    // MARK: - cross-source dedup (#687)

    private func richRow(start: Int, end: Int, sport: String, source: String) -> WorkoutRow {
        // A live strap session: HR trace, peak, strain, zones, distance, energy all captured.
        WorkoutRow(startTs: start, endTs: end, sport: sport, source: source,
                   durationS: Double(end - start), energyKcal: 600, avgHr: 150, maxHr: 178,
                   strain: 14.0, distanceM: 10_000, zonesJSON: #"{"z1":10}"#, notes: nil)
    }
    private func thinImport(start: Int, end: Int, sport: String, source: String) -> WorkoutRow {
        // A thin Health Connect / Apple import: only duration + calories.
        WorkoutRow(startTs: start, endTs: end, sport: sport, source: source,
                   durationS: Double(end - start), energyKcal: 590, avgHr: nil, maxHr: nil,
                   strain: nil, distanceM: nil, zonesJSON: nil, notes: nil)
    }

    func testSportKeyFoldsCamelCaseAndSpacing() {
        XCTAssertEqual(WorkoutSource.sportKey("TraditionalStrengthTraining"),
                       WorkoutSource.sportKey("Traditional Strength Training"))
        XCTAssertEqual(WorkoutSource.sportKey("Running"), WorkoutSource.sportKey("running"))
        XCTAssertNotEqual(WorkoutSource.sportKey("Running"), WorkoutSource.sportKey("Cycling"))
    }

    func testSameActivityRequiresSportAndMajorityOverlap() {
        let live = richRow(start: 1000, end: 4600, sport: "Running", source: "whoop")        // 60 min
        let importDrift = thinImport(start: 1040, end: 4570, sport: "Running", source: "health-connect")
        XCTAssertTrue(WorkoutSource.sameActivity(live, importDrift))      // same sport, near-full overlap
        // Different sport in the same window is NOT the same activity.
        let otherSport = thinImport(start: 1040, end: 4570, sport: "Cycling", source: "health-connect")
        XCTAssertFalse(WorkoutSource.sameActivity(live, otherSport))
        // Back-to-back same-sport sessions that only touch at the edge stay distinct (<50% overlap).
        let nextRun = richRow(start: 4500, end: 8100, sport: "Running", source: "whoop")
        XCTAssertFalse(WorkoutSource.sameActivity(live, nextRun))
    }

    func testDedupCollapsesLiveAndImportKeepingRicher() {
        let live = richRow(start: 1000, end: 4600, sport: "Running", source: "whoop")
        let hc = thinImport(start: 1030, end: 4580, sport: "Running", source: "health-connect")
        // Order shouldn't matter — the richer (live) row always survives.
        let a = WorkoutSource.dedupCrossSource([live, hc])
        let b = WorkoutSource.dedupCrossSource([hc, live])
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(a.first?.source, "whoop")
        XCTAssertEqual(b.first?.source, "whoop")
        XCTAssertEqual(a.first?.strain, 14.0)   // kept the row with the captured trace
    }

    func testDedupTraceKeptIsByteIdenticalAndNamesThePair() {
        // The Workouts test-mode dedup twin must return the SAME kept list dedupCrossSource does, plus a
        // decision line naming the kept vs dropped source. (Trace cannot diverge from the screen's list.)
        let live = richRow(start: 1000, end: 4600, sport: "Running", source: "whoop")
        let hc = thinImport(start: 1030, end: 4580, sport: "Running", source: "health-connect")
        let plain = WorkoutSource.dedupCrossSource([live, hc])
        let (kept, trace) = WorkoutSource.dedupCrossSourceTrace([live, hc])
        XCTAssertEqual(kept.map { $0.source }, plain.map { $0.source })
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.source, "whoop")
        // One dedup line, naming the strap row as kept and the apple/HC import as dropped.
        XCTAssertEqual(trace.count, 1)
        XCTAssertTrue(trace[0].contains("dedup sport=running"))
        XCTAssertTrue(trace[0].contains("kept=strap"))
        XCTAssertTrue(trace[0].contains("dropped=apple"))
        XCTAssertFalse(trace.contains { $0.contains("\u{2014}") })
    }

    func testDedupTraceEmitsNothingForDistinctSessions() {
        // No cross-source pair → no dedup line, and the kept list equals the input order.
        let run = richRow(start: 1000, end: 4600, sport: "Running", source: "whoop")
        let lift = richRow(start: 5000, end: 8600, sport: "Strength Training", source: "whoop")
        let (kept, trace) = WorkoutSource.dedupCrossSourceTrace([run, lift])
        XCTAssertEqual(kept.count, 2)
        XCTAssertTrue(trace.isEmpty, "no collapsed pair must emit zero dedup lines, got \(trace)")
    }

    func testDedupKeepsNonImportOnRichnessTie() {
        // Two equally-thin rows: a strap "manual" live row and a Health Connect import. Keep the strap one.
        let manual = thinImport(start: 1000, end: 4600, sport: "Walking", source: "manual")
        let hc = thinImport(start: 1010, end: 4590, sport: "Walking", source: "health-connect")
        let out = WorkoutSource.dedupCrossSource([hc, manual])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.source, "manual")
    }

    func testDedupLeavesDistinctSessionsAndIsStable() {
        let run = richRow(start: 1000, end: 4600, sport: "Running", source: "whoop")
        let lift = richRow(start: 5000, end: 8600, sport: "Strength Training", source: "whoop")
        let hcRun = thinImport(start: 1020, end: 4580, sport: "Running", source: "health-connect")
        let out = WorkoutSource.dedupCrossSource([run, lift, hcRun])
        // The run pair collapses to one; the lift is untouched. Two sessions, original order preserved.
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].sport, "Running")
        XCTAssertEqual(out[1].sport, "Strength Training")
    }

    // MARK: - detected-vs-real overlap collapse (#975)

    func testDetectedShadowIsDroppedWhenItOverlapsAManualSession() {
        // A live/manual "Strength" session and its detected twin (different sport, wider window) overlap
        // heavily. Before the next engine pass both show; the read-time guard drops the detected shadow.
        let manual = richRow(start: 1000, end: 4600, sport: "Strength Training", source: "manual")
        let detected = row(start: 900, end: 4800, sport: "detected", source: "my-whoop-noop",
                           avgHr: 175, maxHr: 190, strain: 19.0)   // wider window, implausibly hot
        let out = WorkoutSource.dedupCrossSource([detected, manual])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.source, "manual", "the real session survives, the detected shadow is dropped")
    }

    func testDetectedBoutKeptWhenItDoesNotOverlapAnyReal() {
        // A detected bout on its own (no real session in its window) is untouched.
        let detected = row(start: 1000, end: 4600, sport: "detected", source: "my-whoop-noop",
                           avgHr: 150, maxHr: 170, strain: 12.0)
        let manualLater = richRow(start: 20_000, end: 23_600, sport: "Running", source: "manual")
        let out = WorkoutSource.dedupCrossSource([detected, manualLater])
        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out.contains { WorkoutSource.classify($0.source) == .detected })
    }

    func testDetectedShadowNotDroppedForBriefTouchingOverlap() {
        // Back-to-back: a detected bout and a manual session that only touch at the edge (<50% of shorter)
        // are genuinely separate and both survive.
        let manual = richRow(start: 1000, end: 4600, sport: "Running", source: "manual")   // 60 min
        let detected = row(start: 4500, end: 8100, sport: "detected", source: "my-whoop-noop",
                           avgHr: 150, strain: 12.0)                                        // 60 min, 100 s overlap
        let out = WorkoutSource.dedupCrossSource([manual, detected])
        XCTAssertEqual(out.count, 2)
    }

    func testDedupTraceEmitsDroppedShadowLineAndStaysByteIdentical() {
        // The trace twin must drop the same detected shadow the plain path does AND name it, without diverging.
        let manual = richRow(start: 1000, end: 4600, sport: "Strength Training", source: "manual")
        let detected = row(start: 900, end: 4800, sport: "detected", source: "my-whoop-noop",
                           avgHr: 175, strain: 19.0)
        let plain = WorkoutSource.dedupCrossSource([detected, manual])
        let (kept, trace) = WorkoutSource.dedupCrossSourceTrace([detected, manual])
        XCTAssertEqual(kept.map { $0.source }, plain.map { $0.source })
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.source, "manual")
        XCTAssertTrue(trace.contains { $0.contains("detectedBout verdict=droppedShadow") }, "got \(trace)")
        XCTAssertTrue(trace.contains { $0.contains("overlapSource=manual") }, "got \(trace)")
        XCTAssertFalse(trace.contains { $0.contains("\u{2014}") })
    }

    // MARK: - trace privacy (L5) + dedup label (L8)

    func testTraceSportKeyWhitelistsCatalogAndFoldsFreeTextToCustom() {
        // L5 PRIVACY: a catalogue sport passes through as its key; a user-named free-text sport never
        // reaches the export and folds to "custom"; the detector's "Activity" token stays "activity".
        XCTAssertEqual(WorkoutSource.traceSportKey("Running"), "running")
        XCTAssertEqual(WorkoutSource.traceSportKey("Open-water swim"), WorkoutSource.sportKey("Open-water swim"))
        XCTAssertEqual(WorkoutSource.traceSportKey("detected"), "activity")
        // A free-typed name (#519 free text) MUST NOT surface verbatim.
        XCTAssertEqual(WorkoutSource.traceSportKey("Johns Birthday 5k"), "custom")
        XCTAssertNotEqual(WorkoutSource.traceSportKey("Johns Birthday 5k"), WorkoutSource.sportKey("Johns Birthday 5k"))
        // An off-catalogue WHOOP token also folds to custom (privacy-conservative).
        XCTAssertEqual(WorkoutSource.traceSportKey("TraditionalStrengthTraining"), "custom")
    }

    func testDedupTraceLabelsKeptDroppedOnSameStartSameSourcePair() {
        // L8: two rows sharing startTs AND source but differing in richness. The OLD (startTs, source)
        // tuple check could not tell which won; the label must follow the REAL keep rule (richer kept).
        let rich = richRow(start: 1000, end: 4600, sport: "Running", source: "whoop")        // richness high
        let thin = thinImport(start: 1000, end: 4600, sport: "Running", source: "whoop")      // same start+source, poorer
        // The richer row wins; the thinner same-start same-source row is the dropped one.
        let (_, trace) = WorkoutSource.dedupCrossSourceTrace([thin, rich])
        XCTAssertEqual(trace.count, 1)
        let keptRich = WorkoutSource.richness(rich), droppedRich = WorkoutSource.richness(thin)
        XCTAssertGreaterThan(keptRich, droppedRich)
        XCTAssertTrue(trace[0].contains("kept=strap(richness=\(keptRich))"), "got \(trace[0])")
        XCTAssertTrue(trace[0].contains("dropped=strap(richness=\(droppedRich))"), "got \(trace[0])")
    }

    // MARK: - buildManualRow validation

    func testBuildManualRowHappyPath() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(3600)
        let r = WorkoutSource.buildManualRow(start: start, durationMin: 45, sport: "  Running ",
                                             avgHr: 150, energyKcal: 540, now: now)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.sport, "Running")          // trimmed
        XCTAssertEqual(r?.source, "manual")
        XCTAssertEqual(r?.durationS, 45 * 60)
        XCTAssertEqual(r?.endTs, r!.startTs + 45 * 60)
        XCTAssertEqual(r?.avgHr, 150)
        XCTAssertNil(r?.strain)                       // never fabricated without a captured HR window
    }

    func testBuildManualRowRejectsBadInput() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(3600)
        XCTAssertNil(WorkoutSource.buildManualRow(start: start, durationMin: 0, sport: "Run", avgHr: nil, energyKcal: nil, now: now))
        XCTAssertNil(WorkoutSource.buildManualRow(start: start, durationMin: 25 * 60, sport: "Run", avgHr: nil, energyKcal: nil, now: now))
        XCTAssertNil(WorkoutSource.buildManualRow(start: start, durationMin: 30, sport: "   ", avgHr: nil, energyKcal: nil, now: now))
        // Future start.
        XCTAssertNil(WorkoutSource.buildManualRow(start: now.addingTimeInterval(60), durationMin: 30, sport: "Run", avgHr: nil, energyKcal: nil, now: now))
        // Out-of-range HR / kcal.
        XCTAssertNil(WorkoutSource.buildManualRow(start: start, durationMin: 30, sport: "Run", avgHr: 10, energyKcal: nil, now: now))
        XCTAssertNil(WorkoutSource.buildManualRow(start: start, durationMin: 30, sport: "Run", avgHr: nil, energyKcal: 99_999, now: now))
    }

    /// #1067 twin: a start at/before `now` still lets `start + duration` overshoot into the future. End
    /// exactly at `now` is valid; one second beyond is rejected.
    func testBuildManualRowRejectsAFutureEndButAllowsEndExactlyAtNow() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)   // 45 min = 2700 s
        // End exactly at now → valid.
        XCTAssertNotNil(WorkoutSource.buildManualRow(start: start, durationMin: 45, sport: "Run",
                                                     avgHr: nil, energyKcal: nil,
                                                     now: start.addingTimeInterval(2700)))
        // start ≤ now, but start + duration overshoots now by one second → rejected.
        XCTAssertNil(WorkoutSource.buildManualRow(start: start, durationMin: 45, sport: "Run",
                                                  avgHr: nil, energyKcal: nil,
                                                  now: start.addingTimeInterval(2699)))
    }

    func testBuildManualRowAcceptsAndBoundsDistance() {
        // #1195: distance is now a manual field. A valid entry is stored verbatim (metres); 0 and the
        // 1,000 km ceiling are allowed; negative and beyond are rejected; nil means "no distance".
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(3600)
        func build(_ d: Double?) -> WorkoutRow? {
            WorkoutSource.buildManualRow(start: start, durationMin: 30, sport: "Run",
                                         avgHr: nil, energyKcal: nil, distanceM: d, now: now)
        }
        XCTAssertEqual(build(5_234)?.distanceM, 5_234)
        XCTAssertNil(build(nil)?.distanceM)
        XCTAssertNotNil(build(0))
        XCTAssertNotNil(build(1_000_000))     // exactly 1,000 km
        XCTAssertNil(build(-1))
        XCTAssertNil(build(1_000_001))
    }

    // MARK: - preservingCaptured

    func testPreservingCapturedTakesDistanceFromTheRebuiltRowNotOld() {
        // #1195: distance is a sheet field now, so an edit's value wins over the old row's captured
        // distance (the sheet pre-fills from old, so an untouched field still round-trips it), while
        // maxHr/strain stay carried. A cleared field clears, not resurrects.
        let old = fullRow(start: 100, end: 3700, sport: "Running", source: "manual", dist: 10_000, maxHr: 175)
        let edited = fullRow(start: 100, end: 3700, sport: "Running", source: "manual", dist: 12_500)
        let merged = WorkoutSource.preservingCaptured(edited, from: old)
        XCTAssertEqual(merged.distanceM, 12_500)   // edited distance wins
        XCTAssertEqual(merged.maxHr, 175)          // maxHr still carried from old
        let cleared = fullRow(start: 100, end: 3700, sport: "Running", source: "manual", dist: nil)
        XCTAssertNil(WorkoutSource.preservingCaptured(cleared, from: old).distanceM)
    }

    func testPreservingCapturedCarriesUnexposedFieldsOnEdit() {
        // The sheet rebuilds a row from its 5 inputs; an edit must keep the original's captured
        // maxHr/strain (a live-tracked session has real values the sheet never shows).
        let old = row(start: 100, end: 3700, sport: "Workout", source: "manual",
                      avgHr: 130, maxHr: 175, strain: 13.5)
        let rebuilt = row(start: 100, end: 3700, sport: "Running", source: "manual", avgHr: 140)
        let merged = WorkoutSource.preservingCaptured(rebuilt, from: old)
        XCTAssertEqual(merged.sport, "Running")  // edited field kept
        XCTAssertEqual(merged.avgHr, 140)        // edited field kept
        XCTAssertEqual(merged.maxHr, 175)        // carried over from old
        XCTAssertEqual(merged.strain, 13.5)      // carried over from old
    }

    func testPreservingCapturedIsNoOpForFreshAdd() {
        let rebuilt = row(start: 100, end: 3700, sport: "Running", source: "manual", avgHr: 140)
        XCTAssertEqual(WorkoutSource.preservingCaptured(rebuilt, from: nil), rebuilt)
    }

    // MARK: - Filter predicate (#64)

    private func fullRow(start: Int, end: Int, sport: String, source: String,
                         avgHr: Int? = nil, kcal: Double? = nil, dist: Double? = nil,
                         strain: Double? = nil, maxHr: Int? = nil, notes: String? = nil) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: end, sport: sport, source: source,
                   durationS: Double(end - start), energyKcal: kcal, avgHr: avgHr, maxHr: maxHr,
                   strain: strain, distanceM: dist, zonesJSON: nil, notes: notes)
    }

    func testFilterInactiveWhenEmptyPassesEverythingUntouched() {
        let rows = [fullRow(start: 100, end: 3700, sport: "Running", source: "whoop"),
                    fullRow(start: 5000, end: 8600, sport: "Cycling", source: "manual")]
        let f = WorkoutFilter()
        XCTAssertFalse(f.isActive)
        XCTAssertEqual(f.apply(rows), rows)
    }

    func testFilterSportSourceAndSearchCompose() {
        let run = fullRow(start: 100, end: 3700, sport: "Running", source: "whoop")
        let manualRun = fullRow(start: 5000, end: 8600, sport: "Running", source: "manual")
        let cycle = fullRow(start: 9000, end: 12000, sport: "Cycling", source: "manual")
        let detected = fullRow(start: 13000, end: 14000, sport: "detected", source: "my-whoop-noop")
        let rows = [run, manualRun, cycle, detected]

        // Sport filter uses the DISPLAYED name.
        XCTAssertEqual(WorkoutFilter(sport: "Running").apply(rows), [run, manualRun])
        // "detected" folds to "Activity" for the sport facet.
        XCTAssertEqual(WorkoutFilter(sport: "Activity").apply(rows), [detected])
        // Source filter uses classify.
        XCTAssertEqual(WorkoutFilter(sourceClass: .manual).apply(rows), [manualRun, cycle])
        // Sport AND source compose (Running that is manual only).
        XCTAssertEqual(WorkoutFilter(sport: "Running", sourceClass: .manual).apply(rows), [manualRun])
        // Search is a case-insensitive substring of the displayed sport.
        XCTAssertEqual(WorkoutFilter(search: "cyc").apply(rows), [cycle])
        XCTAssertEqual(WorkoutFilter(search: "  RUN ").apply(rows), [run, manualRun])
        // All three compose.
        XCTAssertEqual(WorkoutFilter(sport: "Running", sourceClass: .whoop, search: "run").apply(rows), [run])
    }

    // MARK: - Merge (#64)

    func testMergeEligibilityGatesOnManualOrDetected() {
        let manual = fullRow(start: 100, end: 3700, sport: "Running", source: "manual")
        let detected = fullRow(start: 100, end: 3700, sport: "detected", source: "my-whoop-noop")
        let whoop = fullRow(start: 100, end: 3700, sport: "Running", source: "whoop")
        let apple = fullRow(start: 100, end: 3700, sport: "Running", source: "apple-health")
        XCTAssertTrue(WorkoutMerge.isMergeable(manual))
        XCTAssertTrue(WorkoutMerge.isMergeable(detected))
        XCTAssertFalse(WorkoutMerge.isMergeable(whoop))
        XCTAssertFalse(WorkoutMerge.isMergeable(apple))
        // canMerge needs 2+ and every row eligible (a single imported row poisons the set).
        XCTAssertTrue(WorkoutMerge.canMerge([manual, detected]))
        XCTAssertFalse(WorkoutMerge.canMerge([manual]))
        XCTAssertFalse(WorkoutMerge.canMerge([manual, whoop]))
    }

    func testMergeTwoManualSumsAndSpansAndWeightsHr() {
        // A run split in two: 60 min @ 150 and 40 min @ 120. Merge is one manual session.
        let a = fullRow(start: 1000, end: 4600, sport: "Running", source: "manual",
                        avgHr: 150, kcal: 600, dist: 10_000, maxHr: 178)
        let b = fullRow(start: 5000, end: 7400, sport: "Running", source: "manual",
                        avgHr: 120, kcal: 300, dist: 5_000, maxHr: 150)
        let m = WorkoutMerge.merge([a, b])
        XCTAssertNotNil(m)
        XCTAssertEqual(m?.source, "manual")
        XCTAssertEqual(m?.sport, "Running")
        XCTAssertEqual(m?.startTs, 1000)          // min start
        XCTAssertEqual(m?.endTs, 7400)            // max end
        XCTAssertEqual(m?.durationS, 6000)        // SUM of durations (3600 + 2400), not the 6400s span
        XCTAssertEqual(m?.energyKcal, 900)        // sum
        XCTAssertEqual(m?.distanceM, 15_000)      // sum
        XCTAssertEqual(m?.maxHr, 178)             // max peak
        XCTAssertNil(m?.strain)                   // rescored by analyzeRecent, never summed (non-additive)
        XCTAssertNil(m?.zonesJSON)
        // Avg HR = duration-weighted: (150*3600 + 120*2400) / 6000 = 138.
        XCTAssertEqual(m?.avgHr, 138)
    }

    func testMergeWeightsOnlyRowsWithHr() {
        // One row has no avg HR — it must NOT drag the weighted mean toward zero.
        let a = fullRow(start: 1000, end: 4600, sport: "Cycling", source: "manual", avgHr: 140)
        let b = fullRow(start: 5000, end: 7400, sport: "Cycling", source: "manual", avgHr: nil)
        let m = WorkoutMerge.merge([a, b])
        // Only `a` carried a HR, so the mean is a's 140 (b's null window is excluded from the weighting).
        XCTAssertEqual(m?.avgHr, 140)
    }

    func testMergeSportResolutionPrefersRealLabelOverDetected() {
        // A detected bout + a manual "Strength Training": the real label wins, detected never does.
        let detected = fullRow(start: 1000, end: 4600, sport: "detected", source: "my-whoop-noop")
        let manual = fullRow(start: 4600, end: 6000, sport: "Strength Training", source: "manual")
        XCTAssertEqual(WorkoutMerge.resolvedSport([detected, manual]), "Strength Training")
        XCTAssertEqual(WorkoutMerge.merge([detected, manual])?.sport, "Strength Training")
        // All-detected: no label to resolve, so the caller must pick (nil), and merge falls back to
        // "Activity" unless a sport override is supplied.
        let detected2 = fullRow(start: 6000, end: 7000, sport: "detected", source: "my-whoop-noop")
        XCTAssertNil(WorkoutMerge.resolvedSport([detected, detected2]))
        XCTAssertEqual(WorkoutMerge.merge([detected, detected2])?.sport, "Activity")
        XCTAssertEqual(WorkoutMerge.merge([detected, detected2], sport: "Yoga")?.sport, "Yoga")
    }

    func testMergeRejectsFewerThanTwo() {
        let a = fullRow(start: 1000, end: 4600, sport: "Running", source: "manual")
        XCTAssertNil(WorkoutMerge.merge([a]))
        XCTAssertNil(WorkoutMerge.merge([]))
    }

    func testMergeJoinsNotesAndOmitsAbsentSums() {
        // Notes join; energy/distance nil when NO row carried them (never a fabricated 0).
        let a = fullRow(start: 1000, end: 4600, sport: "Yoga", source: "manual", notes: "morning")
        let b = fullRow(start: 5000, end: 7400, sport: "Yoga", source: "manual", notes: "cooldown")
        let m = WorkoutMerge.merge([a, b])
        XCTAssertEqual(m?.notes, "morning · cooldown")
        XCTAssertNil(m?.energyKcal)
        XCTAssertNil(m?.distanceM)
        XCTAssertNil(m?.avgHr)
    }
}
