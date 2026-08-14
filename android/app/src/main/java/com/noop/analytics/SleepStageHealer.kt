package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.OuraRespScale
import com.noop.data.RespSample
import com.noop.data.RrInterval
import com.noop.data.SleepSession
import com.noop.data.StepSample
import com.noop.data.WhoopRepository
import kotlin.math.max

/**
 * Post-sync self-heal for the edit-races-sync bug. Port of iOS PR #449
 * (Repository.restageFromRaw + Repository.selfHealEditedStages).
 *
 * THE BUG: when a user hand-corrects a night's wake (or bed) time via
 * [WhoopRepository.updateSleepSessionTimes], the stages are reshaped by [SleepWindowReclip] — which
 * FABRICATES a trailing "wake" block when no real per-second staging is available — and the row is
 * stamped `userEdited = true`. If the correction was made BEFORE the strap sync imported that night's
 * raw streams (or even after, but the reclip still only reshapes the stored summary), the post-sync
 * recompute PRESERVES the edit (correct) but NEVER re-derives the real stage breakdown from the
 * now-available raw sensor data — so the approximate/reclipped stages are frozen forever instead of
 * the real per-second staging WHOOP would show.
 *
 * THE FIX: a pass invoked from [IntelligenceEngine] (which runs after each sync backfill, before the
 * scoring loop) re-derives stages from the now-available raw over each edited night's LOCKED bounds
 * (effective onset → wake) and rewrites the stage breakdown ONLY — never the user's bed/wake
 * correction, never the `userEdited` flag. Lives in the analytics package (not the repository, as on
 * iOS) because [SleepStager.stageSession] is `internal` to `com.noop.analytics`; it takes the
 * [WhoopRepository] as a parameter, exactly as [IntelligenceEngine] already does.
 *
 * Idempotent + safe:
 *   - A night already staged from raw re-derives to byte-identical JSON ([AnalyticsEngine.encodeStages]
 *     is deterministic — sorted keys), so the equality check skips the write (steady state, no churn).
 *   - A night edited-too-early heals the moment its raw arrives and is dense.
 *   - A true imported night (raw never dense) is left untouched ([restageFromRaw] returns null).
 *   - Only ever touches `userEdited = 1` rows (the DAO query is scoped), and never moves the bounds.
 */
object SleepStageHealer {

    /**
     * Re-derive stages from the raw streams for `[start, end]` (read under the strap [deviceId]),
     * returning the encoded `stagesJSON`, or `null` when the strap does NOT densely cover the window —
     * i.e. there isn't enough worn-night data to stage (a couple of stray samples must not trigger a
     * degenerate [SleepStager.stageSession] that overwrites a good breakdown). ~1 sample / 2 min is
     * the floor (`max(20, windowSeconds / 120)`), matching iOS `Repository.restageFromRaw` exactly.
     *
     * The raw is read over a ±1h padded window (`[start - 3600, end + 3600]`) so the stager has lead-in
     * context, but the density gate counts ONLY samples strictly within `[start, end]` — padding must
     * not make a sparse in-window night look dense.
     */
    suspend fun restageFromRaw(
        repo: WhoopRepository,
        deviceId: String,
        start: Long,
        end: Long,
        // Experimental staging (Settings → Experimental · Sleep staging). The analytics layer is
        // Context-free, so the flag is threaded in from the Context-aware caller. When true, stage with
        // SleepStagerV2; else V1. This PARAMETER defaults false so existing callers / tests are unaffected
        // — the stored preference the app threads in is default TRUE, so the shipped app gets V2. (V7 3b)
        useExperimentalSleepV2: Boolean = false,
        // Opt-in motion-aware wake refinement (#364 "Proposal 2" follow-up; density gate precedent #345).
        // Same Context-free threading as [useExperimentalSleepV2]; default false so existing callers/tests
        // are unaffected. Runs AFTER whichever stager above just ran and self-gates on the night's OWN
        // observed gravity + step density, so turning it on is a no-op for any night too sparse to trust
        // (e.g. a WHOOP 4.0, which never emits a step sample at all).
        useMotionAwareWake: Boolean = false,
    ): String? {
        val lo = start - 3_600L
        val hi = end + 3_600L
        val grav = repo.gravitySamples(deviceId, lo, hi, IntelligenceEngine.STREAM_LIMIT)
        // Cheap density gate FIRST (count only) so a sparse imported night skips the three further reads.
        if (!isDense(grav, start, end)) return null
        val hr = repo.hrSamples(deviceId, lo, hi, IntelligenceEngine.STREAM_LIMIT)
        val rr = repo.rrIntervals(deviceId, lo, hi, IntelligenceEngine.STREAM_LIMIT)
        // Same provenance refusal as the nightly scan: an Oura ring's respiration rows are its own
        // per-window RATE stored as instrumentation, not the ~1 Hz raw ADC waveform this stager reads,
        // so they never reach a re-stage either. See `OuraRespScale.forScoring`. Mirrors Swift.
        val resp = OuraRespScale.forScoring(
            repo.respSamples(deviceId, lo, hi, IntelligenceEngine.STREAM_LIMIT), deviceId,
        )
        // Only read when the refinement might actually use it — no point paying for it on the (default) off path.
        val steps = if (useMotionAwareWake) repo.stepSamples(deviceId, lo, hi, IntelligenceEngine.STREAM_LIMIT) else emptyList()
        return restageFromSamples(start, end, grav, hr, rr, resp, useExperimentalSleepV2, steps, useMotionAwareWake)
    }

    /**
     * The density gate, in isolation: is the gravity stream dense enough over `[start, end]` to stage?
     * ~1 sample / 2 min, floored at 20 (`max(20, windowSeconds / 120)`) — matches iOS exactly. Counts
     * ONLY samples strictly within `[start, end]` (inclusive), so the ±1h read padding can't make a
     * sparse in-window night look dense. Pure — extracted so the heal-path test can assert the gate
     * without a repository.
     */
    fun isDense(grav: List<GravitySample>, start: Long, end: Long): Boolean {
        val inWindowGravity = grav.count { it.ts in start..end }
        val windowSeconds = max(1L, end - start)
        return inWindowGravity >= max(20L, windowSeconds / 120L)
    }

    /**
     * Pure re-stage: gate on gravity density, then run [SleepStager.stageSession] over the LOCKED
     * `[start, end]` bounds and encode deterministically via [AnalyticsEngine.encodeStages]. Returns
     * `null` when the raw isn't dense (caller keeps the stored stages). No I/O — the test feeds raw
     * sample lists directly. The `grav` list is the SAME ±1h-padded read [restageFromRaw] fetched;
     * [SleepStager.stageSession] clips each stream to `[start, end]` itself (`rowsBetween`), so passing
     * the padded lists is correct and matches the in-engine staging.
     */
    fun restageFromSamples(
        start: Long,
        end: Long,
        grav: List<GravitySample>,
        hr: List<HrSample>,
        rr: List<RrInterval>,
        resp: List<RespSample>,
        // Opt-in experimental staging: V2 cardiorespiratory recipe when true, else default V1 (default false
        // so existing callers / tests stay on V1 — the V1 path is byte-identical). (V7 Pillar 3b)
        useExperimentalSleepV2: Boolean = false,
        // Step stream for the motion-aware wake refinement below. Default empty keeps every existing
        // positional caller/test byte-identical (the refinement is a no-op with no steps either way).
        steps: List<StepSample> = emptyList(),
        // Opt-in motion-aware wake refinement (#364 follow-up): a post-pass over whichever stager above
        // just ran, reclassifying a hot-but-still wake segment to light. Default false, self-gated on
        // observed density either way — see [WakeMotionRefinement].
        useMotionAwareWake: Boolean = false,
    ): String? {
        if (!isDense(grav, start, end)) return null
        val segs = if (useExperimentalSleepV2) {
            SleepStagerV2.stageSession(start = start, end = end, grav = grav, hr = hr, rr = rr, resp = resp)
        } else {
            SleepStager.stageSession(start = start, end = end, grav = grav, hr = hr, rr = rr, resp = resp)
        }
        val refined = WakeMotionRefinement.apply(segs, grav, steps, useMotionAwareWake)
        return AnalyticsEngine.encodeStages(refined)
    }

    /**
     * Self-heal pass: re-derive stages from the now-available raw for every user-edited night in
     * `[windowStart, windowEnd]` under the COMPUTED source ([computedDeviceId]), and rewrite the stage
     * breakdown ONLY (via [WhoopRepository.updateSleepStages], scoped to `userEdited = 1`), never the
     * user's bed/wake correction. Reads/writes the COMPUTED source — the SAME one [IntelligenceEngine]
     * reads its edited rows from — so the healed stages flow straight into the daily aggregate this run.
     *
     * Idempotent: a night already staged from raw re-derives to the same JSON (equality-skip, no
     * write); a night edited-too-early heals the moment its raw arrives; a true imported night (raw
     * never dense) is left untouched ([restageFromRaw] returns null). Returns the (possibly refreshed)
     * edited rows so the caller scores the corrected breakdown — mirrors iOS
     * `Repository.selfHealEditedStages`.
     */
    suspend fun selfHealEditedStages(
        repo: WhoopRepository,
        computedDeviceId: String,
        strapDeviceId: String,
        windowStart: Long,
        windowEnd: Long,
        // Experimental staging, threaded from IntelligenceEngine (read off SharedPreferences by the
        // Context-aware caller). This PARAMETER defaults false so callers/tests that don't pass it are
        // unaffected; the stored preference is default TRUE, so the shipped app gets V2. (3b)
        useExperimentalSleepV2: Boolean = false,
        // Opt-in motion-aware wake refinement (#364 follow-up), threaded the same way. Default false.
        useMotionAwareWake: Boolean = false,
    ): List<SleepSession> {
        suspend fun editedRows(): List<SleepSession> =
            repo.sleepSessions(computedDeviceId, windowStart, windowEnd).filter { it.userEdited }

        val edited = editedRows()
        if (edited.isEmpty()) return emptyList()
        var healed = false
        for (row in edited) {
            // Re-derive over the LOCKED corrected window (effective onset → wake), reading raw under the
            // STRAP id (where the sensor streams live), not the computed namespace. Skip when the raw
            // isn't dense yet, or when the result already matches what's stored (steady state — no write).
            val newJSON = restageFromRaw(repo, strapDeviceId, row.effectiveStartTs, row.endTs,
                useExperimentalSleepV2, useMotionAwareWake) ?: continue
            if (newJSON == row.stagesJSON) continue
            // Keyed by the IMMUTABLE detected startTs (never effectiveStartTs) so it lands on the right
            // primary-key row; the DAO scopes the write to userEdited = 1.
            val n = repo.updateSleepStages(computedDeviceId, row.startTs, newJSON)
            if (n > 0) healed = true
        }
        return if (healed) editedRows() else edited
    }
}
