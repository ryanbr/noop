package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #904 + #908 HR READ-SPINE UNION (Android twin of the Swift Repository.hrSamples/hrBuckets union body):
 *
 * A strap re-added through the in-app device manager gets a FRESH registry id ("whoop-<uuid>") and the
 * Collector banks its LIVE raw HR under THAT id, NOT the canonical "my-whoop". A Today-curve / live-Effort
 * read pinned to the hardcoded "my-whoop" then finds NOTHING, so the day looks frozen (#908) and Effort
 * integrates to 0 off an empty series (#904). The union reads (active id) AND the canonical "my-whoop"
 * (active FIRST, so the active strap wins a ts/bucket tie), which is byte-identical for a single-WHOOP
 * install (one id).
 *
 * These exercise the PURE companion merge seams the union overloads
 * ([WhoopRepository.hrSamplesUnion] / [WhoopRepository.hrBucketsUnion]) are built on, so they run on the
 * JVM with no Room:
 *   - [WhoopRepository.mergeHrByTs] merges HR samples, deduped by ts, active-first winning;
 *   - [WhoopRepository.mergeHrBucketsByStart] merges HR buckets, deduped by bucket start, active-first.
 */
class HrReadUnionTest {

    private val canonical = "my-whoop"
    private val reAdded = "whoop-abc" // the id a re-added strap gets (whoop-<uuid>)

    private fun sample(ts: Long, bpm: Int, source: String = canonical) =
        HrSample(deviceId = source, ts = ts, bpm = bpm)

    // A flat synthetic bucket: these tests are about which bucket WINS a union, not about the spread
    // inside one, so the extremes equal the mean rather than inventing a range nothing here reads.
    private fun bucket(start: Long, avg: Double) =
        HrBucket(bucket = start, avgBpm = avg, minBpm = avg, maxBpm = avg)

    private fun step(ts: Long, activityClass: Int?, source: String = canonical) =
        StepSample(deviceId = source, ts = ts, counter = 0, activityClass = activityClass)

    // --- (a) single-id list is returned unchanged (byte-identical passthrough) ---

    /** A single-WHOOP install resolves to ONE source id, so [mergeHrByTs] must return that same list
     *  instance untouched (no copy, no re-sort), so the union is byte-identical to the pre-fix read. */
    @Test
    fun singleIdSampleListReturnedUnchanged() {
        val only = listOf(sample(100, 60), sample(101, 61), sample(102, 62))
        val merged = WhoopRepository.mergeHrByTs(listOf(only))
        assertSame("single-id read must be the same list reference, untouched", only, merged)
    }

    /** Same byte-identical passthrough for the downsampled bucket read on a single-WHOOP install. */
    @Test
    fun singleIdBucketListReturnedUnchanged() {
        val only = listOf(bucket(0, 55.0), bucket(300, 58.0), bucket(600, 61.0))
        val merged = WhoopRepository.mergeHrBucketsByStart(listOf(only))
        assertSame("single-id read must be the same list reference, untouched", only, merged)
    }

    // --- (b) two id lists merge time-ordered, deduped by ts/bucket, FIRST (active) list wins on a tie ---

    /** Two-id samples merge into ONE time-ordered stream; on a shared ts the FIRST (active) list's bpm
     *  wins, and distinct ts from either list all survive. */
    @Test
    fun twoIdSamplesMergeTimeOrderedActiveWinsTie() {
        // Active strap (first list) and canonical import (second list) overlap at ts=101.
        val active = listOf(sample(101, 90, reAdded), sample(103, 92, reAdded))
        val canonicalImport = listOf(sample(100, 50), sample(101, 51), sample(102, 52))

        val merged = WhoopRepository.mergeHrByTs(listOf(active, canonicalImport))

        assertEquals("time-ordered, deduped by ts", listOf(100L, 101L, 102L, 103L), merged.map { it.ts })
        assertEquals("active strap wins the ts=101 tie", 90, merged.first { it.ts == 101L }.bpm)
        assertEquals("canonical-only ts survives", 50, merged.first { it.ts == 100L }.bpm)
        assertEquals("active-only ts survives", 92, merged.first { it.ts == 103L }.bpm)
    }

    /** Two-id buckets merge into ONE time-ordered stream; on a shared bucket start the FIRST (active) list
     *  wins, and distinct starts from either list all survive. */
    @Test
    fun twoIdBucketsMergeTimeOrderedActiveWinsTie() {
        val active = listOf(bucket(300, 100.0), bucket(900, 110.0))
        val canonicalImport = listOf(bucket(0, 40.0), bucket(300, 41.0), bucket(600, 42.0))

        val merged = WhoopRepository.mergeHrBucketsByStart(listOf(active, canonicalImport))

        assertEquals("time-ordered, deduped by bucket start", listOf(0L, 300L, 600L, 900L), merged.map { it.bucket })
        assertEquals("active strap wins the start=300 tie", 100.0, merged.first { it.bucket == 300L }.avgBpm, 0.0)
        assertEquals("canonical-only bucket survives", 40.0, merged.first { it.bucket == 0L }.avgBpm, 0.0)
        assertEquals("active-only bucket survives", 110.0, merged.first { it.bucket == 900L }.avgBpm, 0.0)
    }

    // --- (c) a dense-HR day banked under a re-added id is surfaced by the union; my-whoop-only is empty ---

    /**
     * The core #904/#908 regression: a re-added strap banks a dense live-HR day under its OWN fresh id
     * ("whoop-abc"), so the canonical "my-whoop" holds nothing for today. A read pinned to "my-whoop"
     * returns EMPTY (frozen curve, Effort = 0); the union (resolved from [importedSourceIdsFor] active
     * FIRST, then merged by [mergeHrByTs]) surfaces the whole dense day.
     */
    @Test
    fun denseDayBankedUnderReAddedIdIsSurfacedByUnion() {
        // A dense day of live HR, all under the re-added strap's id; the canonical id has nothing today.
        val dense = (0 until 120).map { sample(1_000L + it, 60 + (it % 40), reAdded) }
        val byId = mapOf(reAdded to dense, canonical to emptyList<HrSample>())

        // A pinned "my-whoop" read finds nothing: this is the frozen-curve / zero-Effort bug.
        assertEquals("pinned my-whoop read is empty for a re-added strap", 0, byId.getValue(canonical).size)

        // The union read (what hrSamplesUnion does) resolves the source ids active-first, then merges.
        val ids = WhoopRepository.importedSourceIdsFor(reAdded) // [whoop-abc, my-whoop]
        assertEquals(listOf(reAdded, canonical), ids)
        val union = WhoopRepository.mergeHrByTs(ids.map { byId.getValue(it) })

        assertEquals("the union surfaces the full dense day", dense.size, union.size)
        assertEquals("union is time-ordered", dense.map { it.ts }, union.map { it.ts })
        assertEquals("union carries the re-added strap's live bpm", dense.map { it.bpm }, union.map { it.bpm })
    }

    /** The same regression at the bucket (downsampled Today-curve) grain: a dense day of buckets under the
     *  re-added id is surfaced by the union while a "my-whoop"-only read is empty. */
    @Test
    fun denseBucketDayBankedUnderReAddedIdIsSurfacedByUnion() {
        val dense = (0 until 96).map { bucket(it * 300L, 50.0 + (it % 30)) }
        val byId = mapOf(reAdded to dense, canonical to emptyList<HrBucket>())

        assertEquals("pinned my-whoop bucket read is empty for a re-added strap", 0, byId.getValue(canonical).size)

        val ids = WhoopRepository.importedSourceIdsFor(reAdded)
        val union = WhoopRepository.mergeHrBucketsByStart(ids.map { byId.getValue(it) })

        assertEquals("the union surfaces the full dense bucket day", dense.size, union.size)
        assertEquals("union is time-ordered by bucket start", dense.map { it.bucket }, union.map { it.bucket })
    }

    // --- #316 / @63 step activity-class union (the Steps tile icon), parity with iOS ---

    /** Single list reduces to "last non-null class in that list": a trailing null-class sample does not blank
     *  the icon, so the earlier real walk (1) wins. */
    @Test
    fun latestActivityClassSingleListTakesLastNonNull() {
        val single = listOf(step(10, 0), step(20, 1), step(30, null))
        assertEquals(1, WhoopRepository.latestActivityClass(listOf(single)))
    }

    /** Two lists: the greatest-ts classed sample across the union wins, and an exact ts tie favours the FIRST
     *  (active) list, matching the union's active-wins rule. */
    @Test
    fun latestActivityClassUnionGreatestTsAndActiveWinsTie() {
        val active = listOf(step(100, 2, reAdded))
        val canonicalImport = listOf(step(90, 0))
        assertEquals("greatest-ts classed sample wins", 2,
            WhoopRepository.latestActivityClass(listOf(active, canonicalImport)))

        val activeTie = listOf(step(200, 1, reAdded))
        val canonicalTie = listOf(step(200, 0))
        assertEquals("active strap wins a ts tie", 1,
            WhoopRepository.latestActivityClass(listOf(activeTie, canonicalTie)))
    }

    /** The regression at the step grain: a re-added strap banks its classed step samples under its OWN id, so a
     *  pinned "my-whoop" read is empty (no icon) while the union surfaces the re-added strap's latest class. */
    @Test
    fun latestActivityClassSurfacesReAddedStrapClass() {
        val live = (0 until 20).map { step(1_000L + it, if (it == 19) 2 else 1, reAdded) }
        val byId = mapOf(reAdded to live, canonical to emptyList<StepSample>())

        // A pinned "my-whoop" read finds no class: this is the vanished-icon bug.
        assertEquals(null, byId.getValue(canonical).lastOrNull { it.activityClass != null }?.activityClass)

        val ids = WhoopRepository.importedSourceIdsFor(reAdded)
        assertEquals("union surfaces the re-added strap's latest class", 2,
            WhoopRepository.latestActivityClass(ids.map { byId.getValue(it) }))
    }

    /** An empty union returns null (no icon), never a crash. */
    @Test
    fun latestActivityClassEmptyUnionIsNull() {
        assertEquals(null, WhoopRepository.latestActivityClass(listOf(emptyList(), emptyList())))
    }

    // --- (d) the union carries a bucket's EXTREMES, not just its mean (#2032) ---

    /**
     * The active strap's bucket wins whole, extremes included.
     *
     * `mergeHrBucketsByStart` dedupes by bucket start with the first list winning, and it has always
     * carried the winning row rather than blending values. That stayed true when the row gained its
     * min and max, but a merge that reached inside to recombine fields would be wrong in a way nothing
     * else here would catch: it would mix one strap's spread with another's mean.
     */
    @Test
    fun aMergedBucketKeepsTheWinningStrapsExtremes() {
        val active = listOf(HrBucket(bucket = 300L, avgBpm = 61.5, minBpm = 61.0, maxBpm = 62.0))
        val other = listOf(HrBucket(bucket = 300L, avgBpm = 99.0, minBpm = 40.0, maxBpm = 190.0))
        val merged = WhoopRepository.mergeHrBucketsByStart(listOf(active, other))
        assertEquals(1, merged.size)
        assertEquals(61.5, merged[0].avgBpm, 0.0)
        assertEquals("the winner's own low, not the other strap's", 61.0, merged[0].minBpm, 0.0)
        assertEquals("the winner's own peak, not the other strap's", 62.0, merged[0].maxBpm, 0.0)
    }

    /**
     * A bucket's extremes are independent of its mean, which is the whole point of carrying them: a
     * five-minute mean of 61.5 can hide a 62 peak, and that gap is what made a workout's max exceed the
     * day's on the Today card.
     */
    @Test
    fun aBucketsExtremesAreNotItsMean() {
        val b = HrBucket(bucket = 0L, avgBpm = 61.5, minBpm = 61.0, maxBpm = 62.0)
        assertNotEquals(b.avgBpm, b.maxBpm, 0.0)
        assertTrue("the peak is at or above the mean", b.maxBpm >= b.avgBpm)
        assertTrue("the low is at or below the mean", b.minBpm <= b.avgBpm)
    }
}
