package com.noop.ui

import com.noop.analytics.WorkoutsTrace
import com.noop.data.DismissedWorkout
import com.noop.data.WorkoutRow
import kotlin.math.roundToInt

/*
 * WorkoutEditing.kt — pure, Compose-free workout-editing logic (manual add/edit, detected-bout
 * re-label / dismiss). Kotlin mirror of macOS Strand/Data/WorkoutSource.swift, kept free of Room /
 * Compose so the unit test can pin it without an instrumented harness.
 *
 * Android's WorkoutRow carries deviceId; we still classify on `source` to stay byte-for-byte aligned
 * with the macOS read model (which has no deviceId), so a cache moved between platforms classifies
 * the same way.
 */

/** Origin of a workout row, classified from its stored `source` column. */
enum class WorkoutSource { WHOOP, APPLE, DETECTED, MANUAL, LIFTING, ACTIVITY_FILE }

object WorkoutEditing {

    /**
     * Classify a row's origin from its `source`. Order matters: the computed detected source
     * "<id>-noop" also contains "whoop", so the "-noop" suffix is checked FIRST — otherwise a
     * detected bout would read as an imported WHOOP row and become un-dismissable.
     */
    fun classify(source: String): WorkoutSource {
        val s = source.lowercase()
        return when {
            s.endsWith("-noop") -> WorkoutSource.DETECTED // BEFORE whoop: "my-whoop-noop" contains "whoop"
            s == "manual" -> WorkoutSource.MANUAL
            s == "lifting" -> WorkoutSource.LIFTING       // imported Hevy / Liftosaur strength session
            s == "activity-file" -> WorkoutSource.ACTIVITY_FILE // imported GPX / TCX / FIT activity file
            s.contains("whoop") -> WorkoutSource.WHOOP
            else -> WorkoutSource.APPLE
        }
    }

    /**
     * Sport-cell text. "detected" reads as a neutral "Activity". WHOOP sport names arrive as
     * concatenated camelCase (e.g. "TraditionalStrengthTraining"), which reads as one long
     * unbreakable word and truncates badly — split it into words on the lower→Upper boundary so it
     * renders "Traditional Strength Training". Already-spaced labels (manual/edited) pass through. (#175)
     */
    fun displaySport(sport: String): String {
        if (sport == "detected") return "Activity"
        if (sport.isEmpty() || sport.contains(" ")) return sport
        val out = StringBuilder()
        var prev: Char? = null
        for (ch in sport) {
            val p = prev
            if (p != null && ch.isUpperCase() && !p.isUpperCase()) out.append(' ')
            out.append(ch)
            prev = ch
        }
        return out.toString()
    }

    // MARK: - Dismissed detected bouts (durable across re-detection)

    /**
     * Read-time filter: a DETECTED row is hidden when it OVERLAPS any dismissed marker's
     * [startTs, endTs] span. Span-overlap (not an exact-key match) survives the small startTs drift a
     * bout's boundary can take as more HR arrives, matching the macOS dismissed-span semantics exactly.
     * Imported / manual rows are never auto-hidden (the user deletes those outright). Half-open overlap
     * test: `row.start < span.end && span.start < row.end`. (#107)
     */
    fun isDismissed(row: WorkoutRow, markers: List<DismissedWorkout>): Boolean =
        classify(row.source) == WorkoutSource.DETECTED &&
            markers.any { row.startTs < it.endTs && it.startTs < row.endTs }

    /** The durable marker for a detected [row] (caller inserts it into `dismissedWorkout`). */
    fun dismissedMarker(row: WorkoutRow): DismissedWorkout =
        DismissedWorkout(deviceId = row.deviceId, startTs = row.startTs, endTs = row.endTs)

    /**
     * Filter dismissed detected bouts out of a loaded list. Centralised so every caller agrees,
     * exactly like macOS Repository.workoutRows applies the span filter once.
     */
    fun filterDismissed(rows: List<WorkoutRow>, markers: List<DismissedWorkout>): List<WorkoutRow> {
        if (markers.isEmpty()) return rows
        return rows.filter { !isDismissed(it, markers) }
    }

    // MARK: - Cross-source dedup (#687)
    //
    // The SAME activity can land twice: once live, Bluetooth-tracked under the strap (rich — real HR
    // trace, strain, zones, route), and once imported from Health Connect / Apple Health for the same
    // window (thin — usually just duration + calories). They sit under different deviceIds/sources, so
    // the workout list shows both as separate sessions. Collapse a pair that is clearly the same bout
    // (overlapping time window + same sport) to a single richer entry. Mirrors macOS WorkoutSource
    // dedupCrossSource bound-for-bound.

    /**
     * Normalised sport key for cross-source matching. Folds the WHOOP camelCase token and a
     * human-readable import label to the same key ("TraditionalStrengthTraining" and
     * "Traditional Strength Training" -> "traditionalstrengthtraining"), case- and space-insensitive.
     */
    fun sportKey(sport: String): String =
        displaySport(sport).lowercase().filter { !it.isWhitespace() }

    /** The set of [sportKey]s for the named catalogue (Running, Cycling, … Padel, Other). Used ONLY by the
     *  TRACE path to decide whether a key is a known, non-PII catalogue sport. Mirrors Swift catalogSportKeys. */
    private val catalogSportKeys: Set<String> =
        com.noop.analytics.WorkoutSport.all.map { sportKey(it.name) }.toSet()

    /**
     * PRIVACY (TRACE PATH ONLY): a redaction-safe sport key for the Workouts test-mode trace. [sportKey]
     * returns a free-typed name verbatim (folded), so a user-named sport like "Johns Birthday 5k" would
     * otherwise surface as `sport=johnsbirthday5k` in the export, which redactStrapLogPii cannot catch. Here
     * we emit the key ONLY when it matches the named catalogue; any off-catalogue / free-text sport folds to
     * the generic "custom" so genuine user text can never enter a shared bundle. The user-facing
     * [displaySport] is unchanged. "detected"/"Activity" fold to "activity" (a catalogue-independent known
     * token) and are allowed through. Mirrors Swift WorkoutSource.traceSportKey.
     */
    fun traceSportKey(sport: String): String {
        val key = sportKey(sport)
        if (key == "activity") return key // the detector's neutral token, never user text
        return if (key in catalogSportKeys) key else "custom"
    }

    /**
     * How many "rich" captured signals a row carries — the tiebreak for which duplicate to keep. A
     * live-tracked strap session scores high (HR trace, peak, strain, zones, distance); a thin import
     * scores low. Energy is the most commonly-present import field so it is weighted lowest.
     */
    fun richness(row: WorkoutRow): Int {
        var n = 0
        if (row.avgHr != null) n++
        if (row.maxHr != null) n++
        if (row.strain != null) n++
        if (!row.zonesJSON.isNullOrEmpty()) n++
        if ((row.distanceM ?: 0.0) > 0.0) n++
        if ((row.energyKcal ?: 0.0) > 0.0) n++
        return n
    }

    /**
     * True when two rows are the SAME activity from different sources: same normalised sport AND their
     * time windows overlap by more than half of the shorter session. The >50%-of-shorter test keeps two
     * genuinely back-to-back same-sport sessions distinct while still catching the small start/end drift
     * between a live capture and its import.
     */
    fun sameActivity(a: WorkoutRow, b: WorkoutRow): Boolean =
        sportKey(a.sport) == sportKey(b.sport) && overlapsInTime(a, b)

    /**
     * The time-overlap half of [sameActivity]: the two windows overlap by more than half of the shorter
     * session. Sport equality is checked separately — [collapseCrossSource] buckets rows by sport, so within
     * a bucket only this (allocation-free) half remains, which is what makes the collapse walk near-linear.
     */
    private fun overlapsInTime(a: WorkoutRow, b: WorkoutRow): Boolean {
        val overlap = minOf(a.endTs, b.endTs) - maxOf(a.startTs, b.startTs)
        if (overlap <= 0) return false
        val shorter = maxOf(1L, minOf(a.endTs - a.startTs, b.endTs - b.startTs))
        return overlap.toDouble() > 0.5 * shorter.toDouble()
    }

    /**
     * Of two same-activity rows, the one to KEEP. Prefer the richer (more captured signals); on a tie
     * prefer the strap-native source (live/manual/detected/whoop carry the real trace) over a thin
     * import (Apple Health / Health Connect); final tie -> the longer session, then [a] (stable).
     */
    fun preferred(a: WorkoutRow, b: WorkoutRow): WorkoutRow {
        val ra = richness(a)
        val rb = richness(b)
        if (ra != rb) return if (ra > rb) a else b
        val ia = classify(a.source) == WorkoutSource.APPLE
        val ib = classify(b.source) == WorkoutSource.APPLE
        if (ia != ib) return if (ia) b else a // keep the non-import on a richness tie
        val da = a.endTs - a.startTs
        val db = b.endTs - b.startTs
        if (da != db) return if (da > db) a else b
        return a
    }

    // MARK: - Detected-vs-real overlap collapse (#975)
    //
    // The engine derives a "detected" bout from raw HR and DROPS it when it overlaps a real logged session,
    // but only on the next analyze pass. Between a live/manual session ending and that pass, BOTH the manual
    // row AND the detected shadow of the same bout show, and the detected shadow (a wider, sport-agnostic HR
    // window) reads an implausibly high interpolated Effort/HR next to the real one. sameActivity cannot
    // collapse them because their SPORTS differ ("detected" vs the user's sport). This read-time guard mirrors
    // the engine's rule so the list never shows the transient duplicate. Runs before the same-sport dedup.

    /**
     * True when [detected] (a detected bout) is a redundant shadow of [real] (a non-detected logged session):
     * their windows overlap by more than half of the shorter session. The caller enforces the row roles.
     */
    fun detectedShadowsReal(detected: WorkoutRow, real: WorkoutRow): Boolean {
        val overlap = minOf(detected.endTs, real.endTs) - maxOf(detected.startTs, real.startTs)
        if (overlap <= 0) return false
        val shorter = maxOf(1L, minOf(detected.endTs - detected.startTs, real.endTs - real.startTs))
        return overlap.toDouble() > 0.5 * shorter.toDouble()
    }

    /**
     * Drop every DETECTED row whose window shadows a REAL (non-detected) session in the same list (#975), so
     * the live/manual session and its detected twin never both show. Order-stable; a list with no detected row
     * (or no real row) passes through unchanged. Runs before [dedupCrossSource]. Mirrors Swift.
     */
    fun dropDetectedShadows(rows: List<WorkoutRow>): List<WorkoutRow> {
        val reals = rows.filter { classify(it.source) != WorkoutSource.DETECTED }
        if (reals.isEmpty()) return rows
        return rows.filter { row ->
            if (classify(row.source) != WorkoutSource.DETECTED) return@filter true
            reals.none { detectedShadowsReal(row, it) }
        }
    }

    /**
     * Collapse cross-source duplicates of the same activity, keeping the richer row of each pair.
     * Order-stable: walks the input once, and a row that duplicates one already kept is dropped (with
     * the kept row swapped for the richer of the two). Single-source lists pass through unchanged.
     * #975: a DETECTED bout that shadows a real logged session is dropped FIRST so the transient
     * live+detected duplicate never shows and can't pollute the Effort/HR read-out.
     */
    fun dedupCrossSource(rows: List<WorkoutRow>): List<WorkoutRow> =
        collapseCrossSource(dropDetectedShadows(rows))

    /**
     * The shared cross-source collapse walk behind [dedupCrossSource] and [dedupCrossSourceTrace]. Byte-
     * identical to the naive "compare every kept row" walk — same first match (kept insertion order), same
     * [preferred] winner, same resulting list — but near-linear instead of O(n²): [sportKey] is computed
     * ONCE per row (not twice per comparison), rows are bucketed by it, and a candidate only ever compares
     * against kept rows of the SAME sport (a cross-sport pair can never be [sameActivity]). That removes the
     * per-comparison string-normalisation that made a large imported history freeze the workout screens.
     * [onMerge] is invoked with (winner, loser) for each collapsed pair so the trace path can record it.
     */
    private fun collapseCrossSource(
        input: List<WorkoutRow>,
        onMerge: ((winner: WorkoutRow, loser: WorkoutRow) -> Unit)? = null,
    ): List<WorkoutRow> {
        val kept = ArrayList<WorkoutRow>(input.size)
        // sportKey -> indices into `kept` for that sport, in insertion order (preserves first-match semantics).
        val bySport = HashMap<String, ArrayList<Int>>()
        for (row in input) {
            val bucket = bySport.getOrPut(sportKey(row.sport)) { ArrayList() }
            var merged = false
            for (idx in bucket) {
                if (overlapsInTime(kept[idx], row)) { // same sport guaranteed by the bucket
                    val winner = preferred(kept[idx], row)
                    if (onMerge != null) onMerge(winner, if (winner === kept[idx]) row else kept[idx])
                    kept[idx] = winner
                    merged = true
                    break
                }
            }
            if (!merged) {
                bucket.add(kept.size)
                kept.add(row)
            }
        }
        return kept
    }

    /** A short, source-only descriptor of a row for the Workouts test-mode dedup trace. Mirrors Swift. */
    fun sourceLabel(row: WorkoutRow): String = when (classify(row.source)) {
        WorkoutSource.WHOOP -> "strap"
        WorkoutSource.APPLE -> "apple"
        WorkoutSource.DETECTED -> "detected"
        WorkoutSource.MANUAL -> "manual"
        WorkoutSource.LIFTING -> "lifting"
        WorkoutSource.ACTIVITY_FILE -> "activityFile"
    }

    /**
     * Diagnostic twin of [dedupCrossSource] for the Workouts & GPS test mode: returns the BYTE-IDENTICAL kept
     * list (the SAME walk, the SAME [preferred] choice) plus a trace line per collapsed pair naming the kept
     * vs dropped source and their richness. The kept output equals [dedupCrossSource] exactly. Mirrors Swift.
     */
    fun dedupCrossSourceTrace(rows: List<WorkoutRow>): Pair<List<WorkoutRow>, List<String>> {
        val lines = ArrayList<String>()
        // #975: detected-shadow drop first (byte-identical to dedupCrossSource's dropDetectedShadows), tracing
        // each drop with a `detectedBout verdict=droppedShadow` line naming the real row it collided with.
        val reals = rows.filter { classify(it.source) != WorkoutSource.DETECTED }
        val input = ArrayList<WorkoutRow>(rows.size)
        for (row in rows) {
            if (classify(row.source) == WorkoutSource.DETECTED) {
                val hit = reals.firstOrNull { detectedShadowsReal(row, it) }
                if (hit != null) {
                    val durMin = maxOf(0L, (row.endTs - row.startTs) / 60L).toInt()
                    lines.add(
                        WorkoutsTrace.detectedBoutLine(
                            verdict = "droppedShadow", durMin = durMin, avgBpm = row.avgHr ?: 0,
                            overlapSource = sourceLabel(hit),
                        ),
                    )
                    continue
                }
            }
            input.add(row)
        }
        // Same bucketed collapse as the plain path, so the kept list can never diverge from what the screen
        // shows; the callback records one dedup line per collapsed pair. winner/loser come from the REAL
        // [preferred] decision (identity, not a startTs+source tuple that collides on a same-start same-source
        // pair). traceSportKey reads the winner's sport — same sportKey as the loser, so the token is stable.
        val kept = collapseCrossSource(input) { winner, loser ->
            lines.add(
                WorkoutsTrace.dedupLine(
                    sportKey = traceSportKey(winner.sport), // PRIVACY: catalogue key or "custom", never free text
                    keptSource = sourceLabel(winner), droppedSource = sourceLabel(loser),
                    keptRichness = richness(winner), droppedRichness = richness(loser),
                ),
            )
        }
        return kept to lines
    }

    // MARK: - Building / preserving rows

    /**
     * Carry the captured fields the add/edit sheet does NOT expose (maxHr, strain, distanceM,
     * zonesJSON, notes, routePolyline) over from the row being edited. A live-tracked session has real
     * captured strain/maxHr/route; rebuilding from the sheet's inputs alone would wipe them on an edit.
     * No-op for a fresh add (old == null).
     */
    fun preservingCaptured(row: WorkoutRow, old: WorkoutRow?): WorkoutRow {
        if (old == null) return row
        return row.copy(
            maxHr = old.maxHr,
            strain = old.strain,
            distanceM = old.distanceM,
            zonesJSON = old.zonesJSON,
            notes = old.notes,
            routePolyline = old.routePolyline,
        )
    }

    /**
     * #18: true when an edit changes the Avg HR on a row that carries CAPTURED strain or zones. Those
     * captured signals are preserved verbatim by [preservingCaptured], so the saved row shows a typed
     * average while the HR graph, zones and Effort stay from the recorded session. That mismatch is
     * silent, so the edit sheet surfaces a one-line note. We do NOT re-score from a single number (that
     * would fabricate a strain); this is purely an honest disclosure. False for a fresh add (old == null).
     * Pure mirror of macOS ManualWorkoutSheet.avgHrEditedNote.
     */
    fun avgHrEdited(built: WorkoutRow, old: WorkoutRow?): Boolean {
        if (old == null) return false
        val captured = old.strain != null || !old.zonesJSON.isNullOrEmpty()
        return captured && built.avgHr != old.avgHr
    }

    /**
     * Build a retroactive manual workout (source "manual", written under the strap [deviceId] by the
     * caller — where live sessions land). Returns null when the input can't make an honest row.
     * strain/zones stay null: with no captured HR window an APPROXIMATE strain is never fabricated.
     * Mirrors macOS WorkoutSource.buildManualRow validation bound-for-bound.
     *
     * @param startSeconds workout start, unix seconds.
     * @param nowSeconds wall-clock now (unix seconds); injectable for tests.
     */
    fun buildManualRow(
        deviceId: String,
        startSeconds: Long,
        durationMin: Int,
        sport: String,
        avgHr: Int?,
        energyKcal: Double?,
        nowSeconds: Long = System.currentTimeMillis() / 1000L,
    ): WorkoutRow? {
        if (durationMin <= 0 || durationMin > 24 * 60) return null
        val trimmed = sport.trim()
        if (trimmed.isEmpty() || startSeconds > nowSeconds || startSeconds <= 0) return null
        if (avgHr != null && avgHr !in 25..250) return null
        if (energyKcal != null && (energyKcal < 0 || energyKcal > 20_000)) return null
        val durationSeconds = durationMin.toLong() * 60L
        // Keep both the addition and the future-end check overflow-safe. A valid start can be close to
        // Long.MAX_VALUE in a boundary test even though production timestamps are much smaller.
        if (durationSeconds > Long.MAX_VALUE - startSeconds) return null
        val endSeconds = startSeconds + durationSeconds
        if (endSeconds > nowSeconds) return null
        return WorkoutRow(
            deviceId = deviceId,
            startTs = startSeconds,
            endTs = endSeconds,
            sport = trimmed,
            source = "manual",
            durationS = durationSeconds.toDouble(),
            energyKcal = energyKcal,
            avgHr = avgHr,
            maxHr = null,
            strain = null,
            distanceM = null,
            zonesJSON = null,
            notes = null,
            routePolyline = null,
        )
    }

    /** Common sports offered when re-labelling a detected bout (the user can fine-tune via Edit). */
    val relabelSports: List<String> = listOf(
        "Running", "Walking", "Cycling", "Strength Training", "Swimming", "Rowing", "Yoga", "HIIT",
        "CrossFit", "Hiking", "Tennis",
    )
}

// MARK: - Filter predicate (#64)
//
// The Workouts list filters beyond the time range: a SPORT filter (a specific displayed sport, or all),
// a SOURCE filter (Whoop / Apple / Detected / Manual / Lifting / File, or all), and a free-text SEARCH
// over the displayed sport name. All three are pure and compose with the time-range window the screen
// already computes, so the whole screen reads one filtered set. Kotlin mirror of macOS WorkoutFilter.

/**
 * One workout-list filter state. [sport] is a displayed-sport key ([WorkoutEditing.displaySport]), null =
 * all sports. [sourceClass] is the origin class, null = all sources. [search] is a free-text query over
 * the displayed sport name (trimmed, case-insensitive; empty = no search).
 */
data class WorkoutFilter(
    val sport: String? = null,
    val sourceClass: WorkoutSource? = null,
    val search: String = "",
) {
    /** True when no facet is active — the caller can skip the walk and keep the input verbatim. */
    val isActive: Boolean
        get() = sport != null || sourceClass != null || search.trim().isNotEmpty()

    /**
     * Does one row pass every active facet? Sport matches on the DISPLAYED name (so "detected" folds to
     * "Activity", camelCase splits); source matches on classify; search is a case-insensitive substring
     * of the displayed sport.
     */
    fun matches(row: WorkoutRow): Boolean {
        if (sport != null && WorkoutEditing.displaySport(row.sport) != sport) return false
        if (sourceClass != null && WorkoutEditing.classify(row.source) != sourceClass) return false
        val q = search.trim()
        if (q.isNotEmpty() && !WorkoutEditing.displaySport(row.sport).contains(q, ignoreCase = true)) {
            return false
        }
        return true
    }

    /** Apply the filter to a windowed list, preserving order. A no-op when nothing is active. */
    fun apply(rows: List<WorkoutRow>): List<WorkoutRow> = if (!isActive) rows else rows.filter { matches(it) }
}

// MARK: - Merge (#64)
//
// Merge two or more overlapping / adjacent MANUAL or DETECTED sessions into one, keeping the richer
// captured signals. Imported history (whoop / apple / lifting / activityFile) is read-only and is NEVER
// merged — the eligibility gate enforces it, and the persistence path (WhoopRepository.mergeWorkouts)
// only ever writes through the manual-row path. Pure + deterministic, byte-for-byte with macOS WorkoutMerge.

object WorkoutMerge {

    /** Only MANUAL and DETECTED rows can be merged (imported history stays read-only). */
    fun isMergeable(row: WorkoutRow): Boolean = when (WorkoutEditing.classify(row.source)) {
        WorkoutSource.MANUAL, WorkoutSource.DETECTED -> true
        WorkoutSource.WHOOP, WorkoutSource.APPLE, WorkoutSource.LIFTING, WorkoutSource.ACTIVITY_FILE -> false
    }

    /** True when a set of selected rows can be merged: two or more, and every one is mergeable. */
    fun canMerge(rows: List<WorkoutRow>): Boolean = rows.size >= 2 && rows.all { isMergeable(it) }

    /**
     * The sport the merge should carry: the most-frequent non-"detected" sport across the inputs (ties
     * broken by first appearance), or null when every input is a bare detected bout — then the caller asks
     * the user to pick. "detected"/"Activity" never wins so a merge with any real label keeps it.
     */
    fun resolvedSport(rows: List<WorkoutRow>): String? {
        val counts = LinkedHashMap<String, Int>()
        for (r in rows) if (r.sport != "detected") counts[r.sport] = (counts[r.sport] ?: 0) + 1
        if (counts.isEmpty()) return null
        // Highest count, ties resolved by first appearance (LinkedHashMap preserves insertion order).
        return counts.entries.reduce { best, e -> if (e.value > best.value) e else best }.key
    }

    /**
     * Merge the given rows into one manual row under [strapDeviceId]. [sport] overrides the resolved sport
     * (used when the inputs are all detected and the user picked one); when null the resolved sport is used,
     * falling back to "Activity" only if there is genuinely no label. Returns null for fewer than two rows.
     *
     * Math (per the #64 brief): startTs = min, endTs = max (the honest span); durationS = SUM of the
     * per-session durations (honest active time, NOT the span); energyKcal = SUM; avgHr = duration-weighted
     * mean of the sessions that carry one; maxHr = max; distanceM = SUM; strain = null (the repo rescores it
     * from strap HR via analyzeRecent, the #598 pattern); zonesJSON = null; routePolyline = null (re-keyed by
     * the repo); notes = joined. Mirrors macOS WorkoutMerge.merge value-for-value.
     */
    fun merge(rows: List<WorkoutRow>, sport: String? = null, strapDeviceId: String = "my-whoop"): WorkoutRow? {
        if (rows.size < 2) return null
        val start = rows.minOf { it.startTs }
        val end = rows.maxOf { it.endTs }

        val durationS = rows.sumOf { it.durationS ?: maxOf(0L, it.endTs - it.startTs).toDouble() }

        val kcals = rows.mapNotNull { it.energyKcal }
        val energyKcal = if (kcals.isEmpty()) null else kcals.sum()
        val dists = rows.mapNotNull { it.distanceM }
        val distanceM = if (dists.isEmpty()) null else dists.sum()

        var hrWeight = 0.0
        var hrSum = 0.0
        for (r in rows) {
            val hr = r.avgHr ?: continue
            val w = r.durationS ?: maxOf(1L, r.endTs - r.startTs).toDouble()
            hrWeight += w
            hrSum += hr * w
        }
        val avgHr = if (hrWeight > 0.0) (hrSum / hrWeight).roundToInt() else null
        val maxHr = rows.mapNotNull { it.maxHr }.maxOrNull()

        val notes = rows.mapNotNull { it.notes?.trim() }.filter { it.isNotEmpty() }
        val mergedNotes = if (notes.isEmpty()) null else notes.joinToString(" · ")

        val mergedSport = sport ?: resolvedSport(rows) ?: "Activity"

        return WorkoutRow(
            deviceId = strapDeviceId,
            startTs = start,
            endTs = end,
            sport = mergedSport,
            source = "manual",
            durationS = durationS,
            energyKcal = energyKcal,
            avgHr = avgHr,
            maxHr = maxHr,
            strain = null,
            distanceM = distanceM,
            zonesJSON = null,
            notes = mergedNotes,
            routePolyline = null,
        )
    }
}
