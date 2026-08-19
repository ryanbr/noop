package com.noop.ui

import com.noop.data.DismissedWorkout
import com.noop.data.WorkoutRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the pure workout-editing logic (manual add/edit, detected-bout re-label / dismiss). Kotlin
 * mirror of the macOS WorkoutSourceTests case-for-case: source classification, the durable
 * dismissed-marker filter that keeps a re-detected bout hidden (#107), manual-row validation, and
 * field preservation on edit.
 */
class WorkoutEditingTest {

    private fun row(
        deviceId: String,
        start: Long,
        end: Long,
        sport: String,
        source: String,
        avgHr: Int? = null,
        maxHr: Int? = null,
        strain: Double? = null,
    ) = WorkoutRow(
        deviceId = deviceId, startTs = start, endTs = end, sport = sport, source = source,
        durationS = (end - start).toDouble(), energyKcal = null, avgHr = avgHr, maxHr = maxHr,
        strain = strain,
    )

    // MARK: - classify

    @Test
    fun classify_ordersNoopBeforeWhoop() {
        // "my-whoop-noop" contains "whoop" — the -noop suffix MUST win, else a detected bout would
        // classify as imported WHOOP and become un-dismissable.
        assertEquals(WorkoutSource.DETECTED, WorkoutEditing.classify("my-whoop-noop"))
        assertEquals(WorkoutSource.WHOOP, WorkoutEditing.classify("whoop"))
        assertEquals(WorkoutSource.MANUAL, WorkoutEditing.classify("manual"))
        assertEquals(WorkoutSource.LIFTING, WorkoutEditing.classify("lifting"))
        assertEquals(WorkoutSource.ACTIVITY_FILE, WorkoutEditing.classify("activity-file"))
        assertEquals(WorkoutSource.APPLE, WorkoutEditing.classify("apple-health"))
        assertEquals(WorkoutSource.APPLE, WorkoutEditing.classify("Apple Health"))
    }

    @Test
    fun displaySport_renamesDetectedToken() {
        assertEquals("Activity", WorkoutEditing.displaySport("detected"))
        assertEquals("Running", WorkoutEditing.displaySport("Running"))
    }

    // MARK: - dismissed markers (durable #107 filter)

    @Test
    fun isDismissed_onlyHidesOverlappingDetectedRows() {
        val markers = listOf(DismissedWorkout("my-whoop-noop", 1000, 2000))
        val detectedOverlap = row("my-whoop-noop", 1500, 2500, "detected", "my-whoop-noop")
        val detectedClear = row("my-whoop-noop", 3000, 4000, "detected", "my-whoop-noop")
        val manualOverlap = row("my-whoop", 1500, 2500, "Running", "manual")
        assertTrue(WorkoutEditing.isDismissed(detectedOverlap, markers))
        assertFalse(WorkoutEditing.isDismissed(detectedClear, markers))
        // A manual (or imported) row is NEVER auto-hidden by a marker — only detected bouts.
        assertFalse(WorkoutEditing.isDismissed(manualOverlap, markers))
    }

    @Test
    fun isDismissed_survivesStartTsDrift() {
        // A re-detected bout whose boundary drifted a little still overlaps the dismissed span.
        val markers = listOf(DismissedWorkout("my-whoop-noop", 1000, 2000))
        val drifted = row("my-whoop-noop", 1040, 2030, "detected", "my-whoop-noop")
        assertTrue(WorkoutEditing.isDismissed(drifted, markers))
    }

    @Test
    fun filterDismissed_removesOnlyMarkedDetected() {
        val detectedA = row("my-whoop-noop", 1000, 2000, "detected", "my-whoop-noop")
        val detectedB = row("my-whoop-noop", 3000, 4000, "detected", "my-whoop-noop")
        val imported = row("my-whoop", 1000, 2000, "Running", "whoop")
        val markers = listOf(WorkoutEditing.dismissedMarker(detectedA))
        val out = WorkoutEditing.filterDismissed(listOf(detectedA, detectedB, imported), markers)
        // detectedA is hidden; detectedB and the imported row survive.
        assertEquals(listOf(detectedB, imported), out)
    }

    @Test
    fun filterDismissed_noMarkers_isIdentity() {
        val rows = listOf(row("my-whoop-noop", 1000, 2000, "detected", "my-whoop-noop"))
        assertEquals(rows, WorkoutEditing.filterDismissed(rows, emptyList()))
    }

    @Test
    fun dismissedMarker_capturesSpan() {
        val r = row("my-whoop-noop", 1_700_000_000, 1_700_003_600, "detected", "my-whoop-noop")
        val m = WorkoutEditing.dismissedMarker(r)
        assertEquals(DismissedWorkout("my-whoop-noop", 1_700_000_000, 1_700_003_600), m)
    }

    // MARK: - cross-source dedup (#687)

    // A live strap session: HR trace, peak, strain, zones, distance, energy all captured.
    private fun richRow(start: Long, end: Long, sport: String, source: String) = WorkoutRow(
        deviceId = "my-whoop", startTs = start, endTs = end, sport = sport, source = source,
        durationS = (end - start).toDouble(), energyKcal = 600.0, avgHr = 150, maxHr = 178,
        strain = 14.0, distanceM = 10_000.0, zonesJSON = "{\"z1\":10}",
    )

    // A thin Health Connect / Apple import: only duration + calories.
    private fun thinImport(start: Long, end: Long, sport: String, source: String) = WorkoutRow(
        deviceId = "health-connect", startTs = start, endTs = end, sport = sport, source = source,
        durationS = (end - start).toDouble(), energyKcal = 590.0,
    )

    @Test
    fun sportKey_foldsCamelCaseAndSpacing() {
        assertEquals(
            WorkoutEditing.sportKey("TraditionalStrengthTraining"),
            WorkoutEditing.sportKey("Traditional Strength Training"),
        )
        assertEquals(WorkoutEditing.sportKey("Running"), WorkoutEditing.sportKey("running"))
        assertNotEquals(WorkoutEditing.sportKey("Running"), WorkoutEditing.sportKey("Cycling"))
    }

    @Test
    fun sameActivity_requiresSportAndMajorityOverlap() {
        val live = richRow(1000, 4600, "Running", "whoop")              // 60 min
        val importDrift = thinImport(1040, 4570, "Running", "health-connect")
        assertTrue(WorkoutEditing.sameActivity(live, importDrift))       // same sport, near-full overlap
        // Different sport in the same window is NOT the same activity.
        val otherSport = thinImport(1040, 4570, "Cycling", "health-connect")
        assertFalse(WorkoutEditing.sameActivity(live, otherSport))
        // Back-to-back same-sport sessions that only touch at the edge stay distinct (<50% overlap).
        val nextRun = richRow(4500, 8100, "Running", "whoop")
        assertFalse(WorkoutEditing.sameActivity(live, nextRun))
    }

    @Test
    fun dedupCrossSource_collapsesLiveAndImportKeepingRicher() {
        val live = richRow(1000, 4600, "Running", "whoop")
        val hc = thinImport(1030, 4580, "Running", "health-connect")
        // Order shouldn't matter — the richer (live) row always survives.
        val a = WorkoutEditing.dedupCrossSource(listOf(live, hc))
        val b = WorkoutEditing.dedupCrossSource(listOf(hc, live))
        assertEquals(1, a.size)
        assertEquals(1, b.size)
        assertEquals("whoop", a.first().source)
        assertEquals("whoop", b.first().source)
        assertEquals(14.0, a.first().strain!!, 1e-9) // kept the row with the captured trace
    }

    @Test
    fun dedupCrossSourceTrace_keptIsByteIdenticalAndNamesThePair() {
        // The Workouts test-mode dedup twin must return the SAME kept list dedupCrossSource does, plus a
        // decision line naming the kept vs dropped source. Mirrors the Swift dedup-trace parity test.
        val live = richRow(1000, 4600, "Running", "whoop")
        val hc = thinImport(1030, 4580, "Running", "health-connect")
        val plain = WorkoutEditing.dedupCrossSource(listOf(live, hc))
        val (kept, trace) = WorkoutEditing.dedupCrossSourceTrace(listOf(live, hc))
        assertEquals(plain.map { it.source }, kept.map { it.source })
        assertEquals(1, kept.size)
        assertEquals("whoop", kept.first().source)
        assertEquals(1, trace.size)
        assertTrue(trace[0].contains("dedup sport=running"))
        assertTrue(trace[0].contains("kept=strap"))
        assertTrue(trace[0].contains("dropped=apple"))
        assertFalse(trace.any { it.contains("\u2014") })
    }

    @Test
    fun dedupCrossSourceTrace_emitsNothingForDistinctSessions() {
        val run = richRow(1000, 4600, "Running", "whoop")
        val lift = richRow(5000, 8600, "Strength Training", "whoop")
        val (kept, trace) = WorkoutEditing.dedupCrossSourceTrace(listOf(run, lift))
        assertEquals(2, kept.size)
        assertTrue(trace.isEmpty())
    }

    @Test
    fun dedupCrossSource_keepsNonImportOnRichnessTie() {
        // Two equally-thin rows: a strap "manual" live row and a Health Connect import. Keep the strap one.
        val manual = thinImport(1000, 4600, "Walking", "manual")
        val hc = thinImport(1010, 4590, "Walking", "health-connect")
        val out = WorkoutEditing.dedupCrossSource(listOf(hc, manual))
        assertEquals(1, out.size)
        assertEquals("manual", out.first().source)
    }

    @Test
    fun dedupCrossSource_leavesDistinctSessionsAndIsStable() {
        val run = richRow(1000, 4600, "Running", "whoop")
        val lift = richRow(5000, 8600, "Strength Training", "whoop")
        val hcRun = thinImport(1020, 4580, "Running", "health-connect")
        val out = WorkoutEditing.dedupCrossSource(listOf(run, lift, hcRun))
        // The run pair collapses to one; the lift is untouched. Two sessions, original order preserved.
        assertEquals(2, out.size)
        assertEquals("Running", out[0].sport)
        assertEquals("Strength Training", out[1].sport)
    }

    // MARK: - detected-vs-real overlap collapse (#975)

    @Test
    fun detectedShadow_isDroppedWhenItOverlapsAManualSession() {
        val manual = richRow(1000, 4600, "Strength Training", "manual")
        val detected = row("my-whoop-noop", 900, 4800, "detected", "my-whoop-noop",
            avgHr = 175, maxHr = 190, strain = 19.0)   // wider window, implausibly hot
        val out = WorkoutEditing.dedupCrossSource(listOf(detected, manual))
        assertEquals(1, out.size)
        assertEquals("manual", out.first().source)
    }

    @Test
    fun detectedBout_keptWhenItDoesNotOverlapAnyReal() {
        val detected = row("my-whoop-noop", 1000, 4600, "detected", "my-whoop-noop",
            avgHr = 150, maxHr = 170, strain = 12.0)
        val manualLater = richRow(20_000, 23_600, "Running", "manual")
        val out = WorkoutEditing.dedupCrossSource(listOf(detected, manualLater))
        assertEquals(2, out.size)
        assertTrue(out.any { WorkoutEditing.classify(it.source) == WorkoutSource.DETECTED })
    }

    @Test
    fun detectedShadow_notDroppedForBriefTouchingOverlap() {
        val manual = richRow(1000, 4600, "Running", "manual")            // 60 min
        val detected = row("my-whoop-noop", 4500, 8100, "detected", "my-whoop-noop",
            avgHr = 150, strain = 12.0)                                  // 60 min, 100 s overlap
        val out = WorkoutEditing.dedupCrossSource(listOf(manual, detected))
        assertEquals(2, out.size)
    }

    @Test
    fun dedupTrace_emitsDroppedShadowLineAndStaysByteIdentical() {
        val manual = richRow(1000, 4600, "Strength Training", "manual")
        val detected = row("my-whoop-noop", 900, 4800, "detected", "my-whoop-noop",
            avgHr = 175, strain = 19.0)
        val plain = WorkoutEditing.dedupCrossSource(listOf(detected, manual))
        val (kept, trace) = WorkoutEditing.dedupCrossSourceTrace(listOf(detected, manual))
        assertEquals(plain.map { it.source }, kept.map { it.source })
        assertEquals(1, kept.size)
        assertEquals("manual", kept.first().source)
        assertTrue(trace.any { it.contains("detectedBout verdict=droppedShadow") })
        assertTrue(trace.any { it.contains("overlapSource=manual") })
        assertFalse(trace.any { it.contains("—") })
    }

    // MARK: - trace privacy (L5) + dedup label (L8)

    @Test
    fun traceSportKey_whitelistsCatalogAndFoldsFreeTextToCustom() {
        // L5 PRIVACY: a catalogue sport passes through as its key; a user-named free-text sport never reaches
        // the export and folds to "custom"; the detector's "Activity" token stays "activity".
        assertEquals("running", WorkoutEditing.traceSportKey("Running"))
        assertEquals(WorkoutEditing.sportKey("Open-water swim"), WorkoutEditing.traceSportKey("Open-water swim"))
        assertEquals("activity", WorkoutEditing.traceSportKey("detected"))
        // A free-typed name (#519 free text) MUST NOT surface verbatim.
        assertEquals("custom", WorkoutEditing.traceSportKey("Johns Birthday 5k"))
        assertNotEquals(WorkoutEditing.sportKey("Johns Birthday 5k"), WorkoutEditing.traceSportKey("Johns Birthday 5k"))
        // An off-catalogue WHOOP token also folds to custom (privacy-conservative).
        assertEquals("custom", WorkoutEditing.traceSportKey("TraditionalStrengthTraining"))
    }

    @Test
    fun dedupTrace_labelsKeptDroppedOnSameStartSameSourcePair() {
        // L8: two rows sharing startTs AND source but differing in richness. The OLD (startTs, source) tuple
        // check could not tell which won; the label must follow the REAL keep rule (richer kept).
        val rich = richRow(1000, 4600, "Running", "whoop") // richness high
        // Same start AND source as `rich`, but poorer (energy only) - forces the tuple-collision case.
        val thin = WorkoutRow(
            deviceId = "my-whoop", startTs = 1000, endTs = 4600, sport = "Running", source = "whoop",
            durationS = 3600.0, energyKcal = 590.0,
        )
        val (_, trace) = WorkoutEditing.dedupCrossSourceTrace(listOf(thin, rich))
        assertEquals(1, trace.size)
        val keptRich = WorkoutEditing.richness(rich)
        val droppedRich = WorkoutEditing.richness(thin)
        assertTrue(keptRich > droppedRich)
        assertTrue(trace[0], trace[0].contains("kept=strap(richness=$keptRich)"))
        assertTrue(trace[0], trace[0].contains("dropped=strap(richness=$droppedRich)"))
    }

    // MARK: - buildManualRow validation

    @Test
    fun buildManualRow_happyPath() {
        val now = 1_700_003_600L
        val r = WorkoutEditing.buildManualRow(
            deviceId = "my-whoop", startSeconds = 1_700_000_000L, durationMin = 45,
            sport = "  Running ", avgHr = 150, energyKcal = 540.0, nowSeconds = now,
        )
        requireNotNull(r)
        assertEquals("Running", r.sport)        // trimmed
        assertEquals("manual", r.source)
        assertEquals("my-whoop", r.deviceId)
        assertEquals(45 * 60.0, r.durationS!!, 1e-9)
        assertEquals(r.startTs + 45 * 60L, r.endTs)
        assertEquals(150, r.avgHr)
        assertNull(r.strain)                      // never fabricated without a captured HR window
    }

    @Test
    fun buildManualRow_rejectsBadInput() {
        val start = 1_700_000_000L
        val now = start + 3600
        assertNull(WorkoutEditing.buildManualRow("my-whoop", start, 0, "Run", null, null, now))
        assertNull(WorkoutEditing.buildManualRow("my-whoop", start, 25 * 60, "Run", null, null, now))
        assertNull(WorkoutEditing.buildManualRow("my-whoop", start, 30, "   ", null, null, now))
        // Future start.
        assertNull(WorkoutEditing.buildManualRow("my-whoop", now + 60, 30, "Run", null, null, now))
        // Out-of-range HR / kcal.
        assertNull(WorkoutEditing.buildManualRow("my-whoop", start, 30, "Run", 10, null, now))
        assertNull(WorkoutEditing.buildManualRow("my-whoop", start, 30, "Run", null, 99_999.0, now))
    }

    @Test
    fun buildManualRow_acceptsEndExactlyAtNow_rejectsOneSecondFuture() {
        val now = 1_700_003_600L
        val endingNow = WorkoutEditing.buildManualRow(
            "my-whoop", startSeconds = now - 60, durationMin = 1, sport = "Run",
            avgHr = null, energyKcal = null, nowSeconds = now,
        )
        requireNotNull(endingNow)
        assertEquals(now, endingNow.endTs)

        val endingOneSecondFuture = WorkoutEditing.buildManualRow(
            "my-whoop", startSeconds = now - 59, durationMin = 1, sport = "Run",
            avgHr = null, energyKcal = null, nowSeconds = now,
        )
        assertNull(endingOneSecondFuture)
    }

    @Test
    fun buildManualRow_rejectsEndTimestampOverflow() {
        val now = Long.MAX_VALUE
        assertNull(
            WorkoutEditing.buildManualRow(
                "my-whoop", startSeconds = Long.MAX_VALUE - 30, durationMin = 1, sport = "Run",
                avgHr = null, energyKcal = null, nowSeconds = now,
            ),
        )
    }

    @Test
    fun buildManualRow_acceptsAndBoundsDistance() {
        // #1195: distance is now a manual field. A valid entry is stored verbatim (metres); 0 and the
        // 1,000 km ceiling are allowed; negative and beyond are rejected; null means "no distance".
        val now = 1_700_003_600L
        fun build(d: Double?) = WorkoutEditing.buildManualRow(
            "my-whoop", startSeconds = now - 1800, durationMin = 30, sport = "Run",
            avgHr = null, energyKcal = null, nowSeconds = now, distanceM = d,
        )
        assertEquals(5_234.0, build(5_234.0)?.distanceM)
        assertNull(build(null)?.distanceM)
        assertNotNull(build(0.0))
        assertNotNull(build(1_000_000.0))   // exactly 1,000 km
        assertNull(build(-1.0))
        assertNull(build(1_000_001.0))
    }

    // MARK: - preservingCaptured

    @Test
    fun preservingCaptured_takesDistanceFromRebuiltNotOld() {
        // #1195: distance is a sheet field now, so an edit's value wins over the old row's captured
        // distance (the sheet pre-fills from old, so an untouched field still round-trips it), while
        // maxHr/route stay carried. A cleared field clears, not resurrects.
        val old = row("my-whoop", 100, 3700, "Running", "manual", maxHr = 175)
            .copy(distanceM = 10_000.0, routePolyline = "abc")
        val edited = row("my-whoop", 100, 3700, "Running", "manual").copy(distanceM = 12_500.0)
        val merged = WorkoutEditing.preservingCaptured(edited, old)
        assertEquals(12_500.0, merged.distanceM)   // edited distance wins
        assertEquals(175, merged.maxHr)            // maxHr still carried
        assertEquals("abc", merged.routePolyline)  // route still carried
        val cleared = row("my-whoop", 100, 3700, "Running", "manual").copy(distanceM = null)
        assertNull(WorkoutEditing.preservingCaptured(cleared, old).distanceM)
    }

    /**
     * #1444: per-session steps (#1058) has NO sheet field, so buildManualRow leaves it null and copy()
     * carries the NEW row's null rather than the stored value — copy() only protects a field when the
     * row being copied IS the stored one. Renaming the sport silently wiped a value the user never saw
     * and never touched. Twin of Swift `testPreservingCapturedCarriesStepsFromOld`.
     */
    @Test
    fun preservingCaptured_carriesStepsFromOld() {
        val old = row("my-whoop", 100, 3700, "Running", "manual").copy(steps = 4_200)
        val edited = row("my-whoop", 100, 3700, "Trail Running", "manual")
        assertNull(edited.steps)   // the sheet cannot supply steps
        assertEquals(4_200, WorkoutEditing.preservingCaptured(edited, old).steps)
    }

    @Test
    fun preservingCaptured_carriesUnexposedFieldsOnEdit() {
        val old = row("my-whoop", 100, 3700, "Workout", "manual", avgHr = 130, maxHr = 175, strain = 13.5)
        val rebuilt = row("my-whoop", 100, 3700, "Running", "manual", avgHr = 140)
        val merged = WorkoutEditing.preservingCaptured(rebuilt, old)
        assertEquals("Running", merged.sport) // edited field kept
        assertEquals(140, merged.avgHr)       // edited field kept
        assertEquals(175, merged.maxHr)       // carried over
        assertEquals(13.5, merged.strain!!, 1e-9) // carried over
    }

    @Test
    fun preservingCaptured_noOpForFreshAdd() {
        val rebuilt = row("my-whoop", 100, 3700, "Running", "manual", avgHr = 140)
        assertEquals(rebuilt, WorkoutEditing.preservingCaptured(rebuilt, null))
    }

    // MARK: - avgHrEdited (#18 honest disclosure)

    @Test
    fun avgHrEdited_trueWhenAvgChangesOnCapturedStrainRow() {
        // A recorded session carries captured strain; the user edits the Avg HR. The graph/zones/Effort
        // stay from the recording, so the note must fire.
        val old = row("my-whoop", 100, 3700, "Running", "manual", avgHr = 130, strain = 13.5)
        val built = WorkoutEditing.preservingCaptured(old.copy(avgHr = 150), old)
        assertTrue(WorkoutEditing.avgHrEdited(built, old))
    }

    @Test
    fun avgHrEdited_trueWhenAvgChangesOnCapturedZonesRow() {
        // Captured zones (no strain) are enough to make the graph/zones stale on an avg edit.
        val old = row("my-whoop", 100, 3700, "Running", "manual", avgHr = 130).copy(zonesJSON = "{\"z1\":50}")
        val built = WorkoutEditing.preservingCaptured(old.copy(avgHr = 145), old)
        assertTrue(WorkoutEditing.avgHrEdited(built, old))
    }

    @Test
    fun avgHrEdited_falseWhenAvgUnchanged() {
        val old = row("my-whoop", 100, 3700, "Running", "manual", avgHr = 130, strain = 13.5)
        val built = WorkoutEditing.preservingCaptured(old.copy(sport = "Cycling"), old)
        assertFalse(WorkoutEditing.avgHrEdited(built, old))
    }

    @Test
    fun avgHrEdited_falseWhenNothingCaptured() {
        // A thin manual row with no captured strain/zones has nothing to go stale, so no note.
        val old = row("my-whoop", 100, 3700, "Running", "manual", avgHr = 130)
        val built = old.copy(avgHr = 160)
        assertFalse(WorkoutEditing.avgHrEdited(built, old))
    }

    @Test
    fun avgHrEdited_falseForFreshAdd() {
        val built = row("my-whoop", 100, 3700, "Running", "manual", avgHr = 140)
        assertFalse(WorkoutEditing.avgHrEdited(built, null))
    }

    // MARK: - Filter predicate (#64)

    private fun fullRow(
        start: Long, end: Long, sport: String, source: String,
        avgHr: Int? = null, kcal: Double? = null, dist: Double? = null,
        strain: Double? = null, maxHr: Int? = null, notes: String? = null,
    ) = WorkoutRow(
        deviceId = "my-whoop", startTs = start, endTs = end, sport = sport, source = source,
        durationS = (end - start).toDouble(), energyKcal = kcal, avgHr = avgHr, maxHr = maxHr,
        strain = strain, distanceM = dist, zonesJSON = null, notes = notes, routePolyline = null,
    )

    @Test
    fun filter_inactiveWhenEmptyPassesEverythingUntouched() {
        val rows = listOf(
            fullRow(100, 3700, "Running", "whoop"),
            fullRow(5000, 8600, "Cycling", "manual"),
        )
        val f = WorkoutFilter()
        assertFalse(f.isActive)
        assertEquals(rows, f.apply(rows))
    }

    @Test
    fun filter_sportSourceAndSearchCompose() {
        val run = fullRow(100, 3700, "Running", "whoop")
        val manualRun = fullRow(5000, 8600, "Running", "manual")
        val cycle = fullRow(9000, 12000, "Cycling", "manual")
        val detected = fullRow(13000, 14000, "detected", "my-whoop-noop")
        val rows = listOf(run, manualRun, cycle, detected)

        assertEquals(listOf(run, manualRun), WorkoutFilter(sport = "Running").apply(rows))
        // "detected" folds to "Activity" for the sport facet.
        assertEquals(listOf(detected), WorkoutFilter(sport = "Activity").apply(rows))
        assertEquals(listOf(manualRun, cycle), WorkoutFilter(sourceClass = WorkoutSource.MANUAL).apply(rows))
        assertEquals(
            listOf(manualRun),
            WorkoutFilter(sport = "Running", sourceClass = WorkoutSource.MANUAL).apply(rows),
        )
        assertEquals(listOf(cycle), WorkoutFilter(search = "cyc").apply(rows))
        assertEquals(listOf(run, manualRun), WorkoutFilter(search = "  RUN ").apply(rows))
        assertEquals(
            listOf(run),
            WorkoutFilter(sport = "Running", sourceClass = WorkoutSource.WHOOP, search = "run").apply(rows),
        )
    }

    // MARK: - Merge (#64)

    @Test
    fun merge_eligibilityGatesOnManualOrDetected() {
        val manual = fullRow(100, 3700, "Running", "manual")
        val detected = fullRow(100, 3700, "detected", "my-whoop-noop")
        val whoop = fullRow(100, 3700, "Running", "whoop")
        val apple = fullRow(100, 3700, "Running", "apple-health")
        assertTrue(WorkoutMerge.isMergeable(manual))
        assertTrue(WorkoutMerge.isMergeable(detected))
        assertFalse(WorkoutMerge.isMergeable(whoop))
        assertFalse(WorkoutMerge.isMergeable(apple))
        assertTrue(WorkoutMerge.canMerge(listOf(manual, detected)))
        assertFalse(WorkoutMerge.canMerge(listOf(manual)))
        assertFalse(WorkoutMerge.canMerge(listOf(manual, whoop)))
    }

    @Test
    fun merge_twoManualSumsAndSpansAndWeightsHr() {
        val a = fullRow(1000, 4600, "Running", "manual", avgHr = 150, kcal = 600.0, dist = 10_000.0, maxHr = 178)
        val b = fullRow(5000, 7400, "Running", "manual", avgHr = 120, kcal = 300.0, dist = 5_000.0, maxHr = 150)
        val m = WorkoutMerge.merge(listOf(a, b))
        assertEquals("manual", m?.source)
        assertEquals("Running", m?.sport)
        assertEquals(1000L, m?.startTs)
        assertEquals(7400L, m?.endTs)
        assertEquals(6000.0, m?.durationS)      // SUM of durations, not the 6400s span
        assertEquals(900.0, m?.energyKcal)
        assertEquals(15_000.0, m?.distanceM)
        assertEquals(178, m?.maxHr)
        assertNull(m?.strain)                    // rescored by analyzeRecent, never summed
        assertNull(m?.zonesJSON)
        assertEquals(138, m?.avgHr)              // (150*3600 + 120*2400) / 6000
    }

    /**
     * #1444: steps is cumulative per session, exactly like distance, so a merge must SUM it rather than
     * drop it. It was dropped until the Swift twin's explicit-field audit forced the question. Twin of
     * Swift `testMergeSumsStepsLikeDistance`.
     */
    @Test
    fun merge_sumsStepsLikeDistance() {
        val a = fullRow(1000, 4600, "Running", "manual", dist = 10_000.0).copy(steps = 6_200)
        val b = fullRow(5000, 7400, "Running", "manual", dist = 5_000.0).copy(steps = 3_100)
        assertEquals(9_300, WorkoutMerge.merge(listOf(a, b))?.steps)
        // Nothing carried steps -> null, never a fake 0 (same rule energy and distance follow).
        val c = fullRow(1000, 4600, "Running", "manual")
        val d = fullRow(5000, 7400, "Running", "manual")
        assertNull(WorkoutMerge.merge(listOf(c, d))?.steps)
    }

    @Test
    fun merge_weightsOnlyRowsWithHr() {
        val a = fullRow(1000, 4600, "Cycling", "manual", avgHr = 140)
        val b = fullRow(5000, 7400, "Cycling", "manual", avgHr = null)
        assertEquals(140, WorkoutMerge.merge(listOf(a, b))?.avgHr)
    }

    @Test
    fun merge_sportResolutionPrefersRealLabelOverDetected() {
        val detected = fullRow(1000, 4600, "detected", "my-whoop-noop")
        val manual = fullRow(4600, 6000, "Strength Training", "manual")
        assertEquals("Strength Training", WorkoutMerge.resolvedSport(listOf(detected, manual)))
        assertEquals("Strength Training", WorkoutMerge.merge(listOf(detected, manual))?.sport)
        val detected2 = fullRow(6000, 7000, "detected", "my-whoop-noop")
        assertNull(WorkoutMerge.resolvedSport(listOf(detected, detected2)))
        assertEquals("Activity", WorkoutMerge.merge(listOf(detected, detected2))?.sport)
        assertEquals("Yoga", WorkoutMerge.merge(listOf(detected, detected2), sport = "Yoga")?.sport)
    }

    @Test
    fun merge_rejectsFewerThanTwo() {
        val a = fullRow(1000, 4600, "Running", "manual")
        assertNull(WorkoutMerge.merge(listOf(a)))
        assertNull(WorkoutMerge.merge(emptyList()))
    }

    @Test
    fun merge_joinsNotesAndOmitsAbsentSums() {
        val a = fullRow(1000, 4600, "Yoga", "manual", notes = "morning")
        val b = fullRow(5000, 7400, "Yoga", "manual", notes = "cooldown")
        val m = WorkoutMerge.merge(listOf(a, b))
        assertEquals("morning · cooldown", m?.notes)
        assertNull(m?.energyKcal)
        assertNull(m?.distanceM)
        assertNull(m?.avgHr)
    }

    @Test
    fun merge_landsUnderStrapDeviceId() {
        // Merge writes through the manual-row path — the merged row must live under the strap deviceId,
        // never a detected/computed one, so imported history is never touched.
        val a = fullRow(1000, 4600, "Running", "manual")
        val b = fullRow(5000, 7400, "Running", "manual")
        assertEquals("my-whoop", WorkoutMerge.merge(listOf(a, b))?.deviceId)
        assertEquals("dev2", WorkoutMerge.merge(listOf(a, b), strapDeviceId = "dev2")?.deviceId)
    }

    // MARK: - dedup perf refactor: bucketed collapse == naive walk (byte-identical)

    /** The ORIGINAL O(n²) collapse, kept here verbatim as the oracle the bucketed version must match. */
    private fun naiveDedupCrossSource(rows: List<WorkoutRow>): List<WorkoutRow> {
        val input = WorkoutEditing.dropDetectedShadows(rows)
        val kept = ArrayList<WorkoutRow>(input.size)
        outer@ for (row in input) {
            for (i in kept.indices) {
                if (WorkoutEditing.sameActivity(kept[i], row)) {
                    kept[i] = WorkoutEditing.preferred(kept[i], row)
                    continue@outer
                }
            }
            kept.add(row)
        }
        return kept
    }

    /**
     * The bucketed [WorkoutEditing.dedupCrossSource] must be BYTE-IDENTICAL to the naive walk it replaced —
     * same kept set, same order, same [WorkoutEditing.preferred] winner per collapse — over thousands of
     * randomised inputs. Sport strings include case/space variants that fold to the same sportKey (so the
     * bucket key is exercised) and detected/real mixes (so dropDetectedShadows runs). This is what lets the
     * O(n²)->near-linear change ship without a device: correctness is proven against the old behaviour.
     */
    @Test
    fun dedupCrossSource_bucketedMatchesNaiveOverRandomInputs() {
        val sports = listOf(
            "Running", "running", "Cycling", "yoga", "custom", "Walking",
            "TraditionalStrengthTraining", "Traditional Strength Training", "detected",
        )
        val sources = listOf("apple-health", "whoop", "my-whoop", "manual", "my-whoop-noop", "lifting", "activity-file")
        val rnd = java.util.Random(20260713L)
        repeat(2000) {
            val n = rnd.nextInt(14)
            val rows = ArrayList<WorkoutRow>(n)
            repeat(n) {
                val start = 1_000L + rnd.nextInt(20) * 300L          // clustered starts -> real overlaps
                val dur = 300L + rnd.nextInt(12) * 300L
                rows.add(
                    WorkoutRow(
                        deviceId = "dev",
                        startTs = start,
                        endTs = start + dur,
                        sport = sports[rnd.nextInt(sports.size)],
                        source = sources[rnd.nextInt(sources.size)],
                        durationS = dur.toDouble(),
                        energyKcal = if (rnd.nextBoolean()) rnd.nextInt(800).toDouble() else null,
                        avgHr = if (rnd.nextBoolean()) 90 + rnd.nextInt(80) else null,
                        maxHr = if (rnd.nextBoolean()) 120 + rnd.nextInt(80) else null,
                        strain = if (rnd.nextBoolean()) rnd.nextDouble() * 21.0 else null,
                        distanceM = if (rnd.nextBoolean()) rnd.nextInt(15000).toDouble() else null,
                    ),
                )
            }
            val expected = naiveDedupCrossSource(rows)
            val actual = WorkoutEditing.dedupCrossSource(rows)
            assertEquals("bucketed dedup diverged from naive for input: $rows", expected, actual)
            // The trace twin must return the exact same kept list the plain path does.
            assertEquals(actual, WorkoutEditing.dedupCrossSourceTrace(rows).first)
        }
    }
}
