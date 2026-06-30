package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.SleepSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Post-sync self-heal of edit-before-sync stages — Android port of iOS PR #449
 * (Repository.restageFromRaw + selfHealEditedStages; MetricsCache.updateSleepStages;
 * AnalyticsEngine.encodeStages → sorted keys).
 *
 * THE BUG: a wake/bed correction made BEFORE (or while) the strap sync delivered the night's raw
 * fabricates [SleepWindowReclip] stages (a trailing "wake" block) and stamps `userEdited = 1`, which
 * then freezes that approximate breakdown against every later sync. The fix re-derives the REAL stages
 * from the now-available raw over the night's LOCKED bounds and rewrites the stage breakdown only.
 *
 * Pure-function style (no Room/coroutines/Robolectric), matching SleepEditDurabilityTest /
 * ManualWorkoutRescoreTest: the heal's decision kernel ([SleepStageHealer.restageFromSamples] +
 * [SleepStageHealer.isDense]) is exercised against synthetic streams, and the end-to-end
 * heal/no-op/idempotent flow is driven through an in-memory store using the EXACT loop body of
 * [SleepStageHealer.selfHealEditedStages].
 */
class SleepStageHealTest {

    private val dev = "test"

    /** 2025-06-10 00:00:00 UTC — fixed midnight (ref % 86400 == 0), as in SleepStagerSparseGravityTest. */
    private val refMidnight = 1_749_513_600L
    private fun startAtHour(hourUTC: Int): Long = refMidnight + hourUTC * 3_600L

    /** Dense still gravity (constant orientation) at 1 Hz over [start, start+durationS). */
    private fun stillGravity(start: Long, durationS: Int): List<GravitySample> =
        (0 until durationS).map { GravitySample(deviceId = dev, ts = start + it, x = 0.0, y = 0.0, z = 1.0) }

    private fun hrStream(start: Long, durationS: Int, bpm: Int): List<HrSample> =
        (0 until durationS).map { HrSample(deviceId = dev, ts = start + it, bpm = bpm) }

    /** Encode a single-stage span to the on-device `[{...}]` stagesJSON (the encoder under test). */
    private fun encoded(start: Long, end: Long, stage: String): String =
        AnalyticsEngine.encodeStages(listOf(StageSegment(start = start, end = end, stage = stage)))!!

    // ── 1. Heal once: edited-before-sync night re-derives to REAL stages when dense raw arrives ──────

    @Test
    fun editedBeforeSyncHealsToRealStagesOnceRawArrives() {
        val start = startAtHour(1)
        val dur = 6 * 60 * 60
        val end = start + dur - 1
        val grav = stillGravity(start, dur)
        val hr = hrStream(start, dur, 50)

        // The fabricated breakdown the user got at edit time (raw wasn't present yet): the production
        // SleepWindowReclip path — a stored short "light" block extended to the corrected wake, which
        // appends a trailing fabricated "wake" segment. This is EXACTLY what the heal must replace.
        val storedDetected = encoded(start, start + 3 * 60 * 60, "light") // a 3h detected block
        val fabricated = SleepWindowReclip.reclip(storedDetected, start, start + 3 * 60 * 60, start, end)!!

        val real = SleepStageHealer.restageFromSamples(start, end, grav, hr, emptyList(), emptyList())
        assertNotNull("dense raw over the locked window must re-derive real stages", real)
        assertNotEquals("real stages must differ from the fabricated reclip block", fabricated, real)
        // The real re-derive is a genuine multi-segment hypnogram over the 6h window, not the 2-segment
        // reclip approximation: a dense sleep night yields several stage transitions.
        assertTrue("re-derived JSON must be a segment array", real!!.trimStart().startsWith("["))
        val realSegments = SleepStageTotals.minutes(real)
        assertNotNull("real stages must decode to stage minutes", realSegments)
        assertTrue("a 6h dense night must record real asleep time, not all-wake",
            realSegments!!.asleep > 0.0)
    }

    // ── 2. No-raw night stays as-edited (imported night: gravity never dense) ────────────────────────

    @Test
    fun noRawNightStaysAsEdited() {
        val start = startAtHour(2)
        val end = start + 6 * 60 * 60 - 1
        // A genuine imported night: a handful of stray gravity samples, far below max(20, windowS/120).
        val sparseGrav = (0 until 5).map { GravitySample(dev, start + it * 600L, 0.0, 0.0, 1.0) }
        assertFalse("5 samples over a 6 h window must NOT clear the density gate",
            SleepStageHealer.isDense(sparseGrav, start, end))

        val derived = SleepStageHealer.restageFromSamples(start, end, sparseGrav, emptyList(), emptyList(), emptyList())
        assertNull("a non-dense night must return null so the stored stages are kept", derived)
    }

    @Test
    fun densityGateMatchesIosFloor() {
        val start = startAtHour(3)
        val end = start + 6 * 60 * 60 // windowSeconds == 21600, /120 == 180 → floor is max(20, 180) = 180
        // 179 samples just inside the window → still below the floor.
        val justUnder = (0 until 179).map { GravitySample(dev, start + it, 0.0, 0.0, 1.0) }
        assertFalse(SleepStageHealer.isDense(justUnder, start, end))
        // 180 in-window samples clears it; out-of-window padding must not be counted.
        val atFloor = (0 until 180).map { GravitySample(dev, start + it, 0.0, 0.0, 1.0) } +
            (0 until 50).map { GravitySample(dev, start - 100L - it, 0.0, 0.0, 1.0) } // before window
        assertTrue(SleepStageHealer.isDense(atFloor, start, end))
    }

    // ── 3. Second pass is a no-op (idempotent) — re-derive over identical bounds+raw equals stored ───

    @Test
    fun secondPassIsIdempotent() {
        val start = startAtHour(4)
        val dur = 6 * 60 * 60
        val end = start + dur - 1
        val grav = stillGravity(start, dur)
        val hr = hrStream(start, dur, 50)

        val first = SleepStageHealer.restageFromSamples(start, end, grav, hr, emptyList(), emptyList())
        val second = SleepStageHealer.restageFromSamples(start, end, grav, hr, emptyList(), emptyList())
        assertNotNull(first)
        assertEquals("re-deriving over identical bounds+raw must be byte-identical (equality-skip)", first, second)
    }

    // ── End-to-end: drive selfHealEditedStages' exact loop over an in-memory store ───────────────────

    /**
     * Replays the EXACT body of [SleepStageHealer.selfHealEditedStages] against an in-memory map keyed
     * by detected startTs, with `restage` supplying the per-night re-derive (null = raw not dense). The
     * userEdited=1 scoping the real DAO enforces in SQL is modelled by only ever passing edited rows in.
     * Returns (refreshedRows, writeCount) so the test asserts both the heal write and the idempotent skip.
     */
    private fun runHealLoop(
        store: MutableMap<Long, SleepSession>,
        edited: List<SleepSession>,
        restage: (SleepSession) -> String?,
    ): Pair<List<SleepSession>, Int> {
        var writes = 0
        for (row in edited) {
            val newJSON = restage(row) ?: continue
            if (newJSON == row.stagesJSON) continue
            // updateSleepStages: stages-only write, bounds + userEdited untouched, keyed by detected startTs.
            store[row.startTs] = store.getValue(row.startTs).copy(stagesJSON = newJSON)
            writes++
        }
        return store.values.filter { it.userEdited } to writes
    }

    @Test
    fun endToEndHealsThenIsIdempotent() {
        val start = startAtHour(5)
        val dur = 6 * 60 * 60
        val end = start + dur - 1
        val grav = stillGravity(start, dur)
        val hr = hrStream(start, dur, 50)

        // Stored edited night with FABRICATED stages (trailing-wake reclip) — userEdited, bounds locked.
        val fabricated = encoded(start, end, "wake")
        val edited = SleepSession(
            deviceId = "my-whoop-noop", startTs = start, endTs = end,
            stagesJSON = fabricated, userEdited = true,
        )
        val store = mutableMapOf(start to edited)
        val restage: (SleepSession) -> String? = { row ->
            SleepStageHealer.restageFromSamples(row.effectiveStartTs, row.endTs, grav, hr, emptyList(), emptyList())
        }

        // Pass 1: heals (one write); bounds + userEdited preserved, only stagesJSON changes.
        val (afterFirst, w1) = runHealLoop(store, listOf(edited), restage)
        assertEquals("the edited-before-sync night must heal exactly once", 1, w1)
        val healed = afterFirst.single()
        assertEquals("bed bound must be untouched", start, healed.startTs)
        assertEquals("wake bound must be untouched", end, healed.endTs)
        assertTrue("userEdited must stay set", healed.userEdited)
        assertNotEquals("stages must have been replaced", fabricated, healed.stagesJSON)

        // Pass 2: re-derive equals the now-stored real stages → NO write (idempotent steady state).
        val (_, w2) = runHealLoop(store, afterFirst, restage)
        assertEquals("a second pass must be a no-op", 0, w2)
    }

    @Test
    fun endToEndNoRawLeavesEditUntouched() {
        val start = startAtHour(6)
        val end = start + 6 * 60 * 60 - 1
        val fabricated = encoded(start, end, "wake")
        val edited = SleepSession(
            deviceId = "my-whoop-noop", startTs = start, endTs = end,
            stagesJSON = fabricated, userEdited = true,
        )
        val store = mutableMapOf(start to edited)
        // restage returns null (imported night: raw never dense).
        val (rows, writes) = runHealLoop(store, listOf(edited)) { null }
        assertEquals("a no-raw night must not be written", 0, writes)
        assertEquals("the user's edited (fabricated) stages must remain", fabricated, rows.single().stagesJSON)
    }

    // ── 4. Encoder determinism (the linchpin: equality-skip relies on stable key order) ──────────────

    @Test
    fun encodeStagesEmitsSortedKeysDeterministically() {
        val segs = listOf(
            StageSegment(start = 100, end = 200, stage = "deep"),
            StageSegment(start = 200, end = 300, stage = "rem"),
        )
        val json = AnalyticsEngine.encodeStages(segs)!!
        // Keys alphabetical (end, stage, start) — parity with Swift JSONEncoder.outputFormatting=.sortedKeys.
        assertEquals(
            """[{"end":200,"stage":"deep","start":100},{"end":300,"stage":"rem","start":200}]""",
            json,
        )
    }

    @Test
    fun encodeStagesIsStableAcrossCalls() {
        val segs = listOf(StageSegment(start = 1, end = 2, stage = "light"))
        val a = AnalyticsEngine.encodeStages(segs)
        val b = AnalyticsEngine.encodeStages(segs.map { it.copy() })
        assertEquals("identical segments must encode byte-identically every call", a, b)
    }
}
