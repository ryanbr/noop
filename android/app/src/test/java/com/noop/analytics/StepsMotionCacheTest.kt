package com.noop.analytics

import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The steps-calibration motion cache's key and readout. Twin of the Swift `StepsMotionCacheTests`,
 * pinned against the SAME literals — the two sides must invalidate on the same facts, and pinning the
 * rendered strings is how a one-sided change to either rule is caught.
 */
class StepsMotionCacheTest {

    @Test
    fun keyIsStableForUnchangedInputs() {
        val a = StepsMotionCache.cacheKey("my-whoop", 8640, 1_757_000_000L)
        val b = StepsMotionCache.cacheKey("my-whoop", 8640, 1_757_000_000L)
        assertEquals(a, b)
        assertEquals("my-whoop|8640|1757000000", a)
    }

    /**
     * The three facts that MUST invalidate a fold, one at a time. A row added moves the count; a row
     * replacing another at a newer timestamp moves the max; a day changing hands moves the owner.
     */
    @Test
    fun everyInputInvalidates() {
        val base = StepsMotionCache.cacheKey("my-whoop", 8640, 1_757_000_000L)
        assertNotEquals(base, StepsMotionCache.cacheKey("my-whoop", 8641, 1_757_000_000L))
        assertNotEquals(base, StepsMotionCache.cacheKey("my-whoop", 8640, 1_757_000_001L))
        assertNotEquals(base, StepsMotionCache.cacheKey("whoop-5mg", 8640, 1_757_000_000L))
    }

    /**
     * An empty day is a real, cacheable answer — the key for it is well-formed and distinct from a day
     * that has rows. Caching it is what stops an unworn gap re-reading its whole stream every pass.
     */
    @Test
    fun emptyDayHasItsOwnKey() {
        assertEquals("my-whoop|0|0", StepsMotionCache.cacheKey("my-whoop", 0, 0L))
        assertNotEquals(StepsMotionCache.cacheKey("my-whoop", 0, 0L),
            StepsMotionCache.cacheKey("my-whoop", 1, 0L))
    }

    /** The owner is the FIRST field, so two devices cannot collide by arranging their counts. */
    @Test
    fun ownerBoundaryCannotBeForgedByCounts() {
        assertNotEquals(StepsMotionCache.cacheKey("a", 1, 2L), StepsMotionCache.cacheKey("a|1", 2, 0L))
    }

    @Test
    fun logLineReportsTheRatioAndSize() {
        assertEquals("analyzeRecent stepsMotion reused=58/60 size=60",
            StepsMotionCache.logLine(58, 2, 60))
        // A cold process: everything folded, nothing reused. This is the line a FIRST pass prints, and
        // seeing it on every pass is the symptom that the key is moving when it should not.
        assertEquals("analyzeRecent stepsMotion reused=0/60 size=60",
            StepsMotionCache.logLine(0, 60, 60))
    }

    /**
     * The invariant the whole cache rests on, and the one that would fail SILENTLY.
     *
     * A day is re-folded only when its gravity witness (row count and newest timestamp) moves. That is
     * sound only while re-offloading a second already banked cannot rewrite its vector: with
     * `OnConflictStrategy.IGNORE` the first value stands, so an unchanged witness means an unchanged
     * fold. Flip it to REPLACE and the values under a day change while its count and newest timestamp
     * hold still — the cache then serves a motion volume for data it no longer describes, with no
     * failing read anywhere to notice.
     *
     * Asserted against the SOURCE rather than the annotation: Room's annotations are not retained at
     * runtime, and this module has no Robolectric or in-memory Room, so the DAO cannot be exercised in a
     * JVM unit test. The Swift twin pins the same contract behaviourally in `GravityWitnessTests`.
     */
    @Test
    fun gravityInsertsMustKeepTheFirstVectorNotTheNewest() {
        val dao = String(Files.readAllBytes(locateDaoSource()), StandardCharsets.UTF_8)
        val declaration = Regex("""@Insert\(onConflict = OnConflictStrategy\.(\w+)\)\s*\n\s*suspend fun insertGravity\b""")
            .find(dao)
        assertTrue("Could not find the insertGravity declaration in WhoopDao.kt", declaration != null)
        assertEquals(
            "gravitySample inserts must IGNORE a conflicting second; REPLACE would rewrite a vector " +
                "under an unchanged StepsMotionCache witness",
            "IGNORE",
            declaration!!.groupValues[1],
        )
    }

    private fun locateDaoSource(): Path {
        val suffixes = listOf(
            Path.of("app/src/main/java/com/noop/data/WhoopDao.kt"),
            Path.of("src/main/java/com/noop/data/WhoopDao.kt"),
        )
        val matches = LinkedHashSet<Path>()
        var directory: Path? = Path.of(System.getProperty("user.dir")).toAbsolutePath().normalize()
        while (directory != null) {
            for (suffix in suffixes) {
                val candidate = directory.resolve(suffix).normalize()
                if (Files.isRegularFile(candidate)) matches.add(candidate.toRealPath())
            }
            directory = directory.parent
        }
        assertEquals("Could not locate WhoopDao.kt from user.dir=${System.getProperty("user.dir")}: $matches",
            1, matches.size)
        return matches.single()
    }

    // ---- Persistence ----

    /**
     * The exact payload the cache renders, pinned as a literal. This is the cross-platform contract that
     * matters most now the cache is stored: the Swift twin pins the SAME string, so a one-sided change to
     * the header, the separators or the number rendering is caught here rather than by a user whose folds
     * silently stopped being reused after an update.
     */
    private val vector =
        "stepsMotion v1\n" +
            "2026-09-01\tmy-whoop|8640|1757000000\t4659742922898407424\n" +
            "2026-09-02\tmy-whoop|0|0\t0"

    private val vectorEntries = mapOf(
        "2026-09-01" to ("my-whoop|8640|1757000000" to 3421.75),
        "2026-09-02" to ("my-whoop|0|0" to 0.0),
    )

    @Test
    fun serializeRendersThePinnedPayload() {
        assertEquals(vector, StepsMotionCache.serialize(vectorEntries))
    }

    @Test
    fun roundTripPreservesKeysAndVolumes() {
        val back = StepsMotionCache.deserialize(StepsMotionCache.serialize(vectorEntries))
        assertEquals(2, back.size)
        for ((day, want) in vectorEntries) {
            assertEquals(want.first, back[day]?.first)
            assertEquals(want.second, back[day]?.second!!, 0.0)
        }
    }

    /**
     * A ZERO fold is a cached VALUE, not a missing one — the engine caches a zero from a read that
     * succeeded so unworn gaps stop re-reading their whole stream every pass. A round trip that dropped it
     * would quietly reintroduce exactly the cost the cache exists to remove, on the sparse libraries it is
     * worst for, so the zero day is asserted present rather than merely equal.
     */
    @Test
    fun zeroFoldSurvivesTheRoundTrip() {
        val back = StepsMotionCache.deserialize(StepsMotionCache.serialize(vectorEntries))
        assertTrue(back.containsKey("2026-09-02"))
        assertEquals(0.0, back["2026-09-02"]?.second!!, 0.0)
    }

    /**
     * Rendering is sorted, so an unchanged cache re-renders byte-identically and the store write coalesces
     * instead of churning a 60-entry payload on every pass.
     */
    @Test
    fun renderingIsStableAcrossMapOrder() {
        val shuffled = LinkedHashMap<String, Pair<String, Double>>()
        for (day in vectorEntries.keys.sortedDescending()) shuffled[day] = vectorEntries.getValue(day)
        assertEquals(StepsMotionCache.serialize(vectorEntries), StepsMotionCache.serialize(shuffled))
    }

    /**
     * An older fold's payload must be DISCARDED, not read. [StepsMotionCache.cacheKey] witnesses the inputs
     * only, so a day whose gravity has not moved keys identically across an app update — without the header
     * check the pre-update volume would be served until that day's stream happened to change.
     */
    @Test
    fun olderFoldVersionIsDiscarded() {
        assertTrue(StepsMotionCache.deserialize(vector.replace("stepsMotion v1", "stepsMotion v0")).isEmpty())
    }

    /**
     * Anything that is not a payload this cache wrote yields an empty cache and one re-fold, never a
     * partially-trusted one.
     */
    @Test
    fun unreadablePayloadsYieldNothing() {
        for (raw in listOf("", "stepsMotion", "garbage", "\n", "v1\n2026-09-01\tk\t0")) {
            assertTrue("expected empty for '$raw'", StepsMotionCache.deserialize(raw).isEmpty())
        }
    }

    /**
     * A malformed line is skipped and its neighbours survive: a truncated write should cost the days it
     * truncated, not the whole window.
     */
    @Test
    fun malformedLinesAreSkippedIndividually() {
        val raw = "stepsMotion v1\n" +
            "2026-09-01\tmy-whoop|8640|1757000000\t4659742922898407424\n" +
            "2026-09-02\tmissing-a-field\n" +
            "2026-09-03\tmy-whoop|1|2\tnot-a-number\n" +
            "\tempty-day\t0\n" +
            "2026-09-05\t\t0\n" +
            "2026-09-06\tmy-whoop|3|4\t4623226492472524800"
        val back = StepsMotionCache.deserialize(raw)
        assertEquals(setOf("2026-09-01", "2026-09-06"), back.keys)
        assertEquals(12.5, back["2026-09-06"]?.second!!, 0.0)
    }

    /**
     * The writer prunes to the calibration window every pass, so a payload far above it did not come from
     * this cache. Rejecting it whole keeps a hand-edited or corrupt store from being parsed at length.
     */
    @Test
    fun implausiblyLargePayloadIsRejected() {
        val sb = StringBuilder("stepsMotion v1")
        for (i in 0..513) sb.append("\nday-").append(i).append("\tmy-whoop|1|2\t0")
        assertTrue(StepsMotionCache.deserialize(sb.toString()).isEmpty())
    }

    /**
     * Rendering is a FIXPOINT over a payload this build wrote. The engine skips the store write when the
     * rendered cache equals what is stored, so a pass that reused every day must produce the string it
     * read: if this ever stopped holding, every pass of an offload storm would write ~4 KB to say nothing.
     */
    @Test
    fun renderingIsAFixpoint() {
        val once = StepsMotionCache.serialize(vectorEntries)
        assertEquals(once, StepsMotionCache.serialize(StepsMotionCache.deserialize(once)))
    }

    /**
     * The other half of that guard: a payload carrying a line this build DROPS must not re-render to
     * itself, so the cleaned version is written back once rather than being re-parsed every launch.
     */
    @Test
    fun droppedLinesReRenderDifferentlyAndAreRewritten() {
        val dirty = vector + "\n2026-09-03\tmy-whoop|1|2\tnot-a-number"
        val cleaned = StepsMotionCache.serialize(StepsMotionCache.deserialize(dirty))
        assertNotEquals(dirty, cleaned)
        assertEquals(vector, cleaned)
    }
}
