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
}
