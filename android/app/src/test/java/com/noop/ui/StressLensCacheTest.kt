package com.noop.ui

import com.noop.analytics.DaytimeStress
import com.noop.data.WhoopDao
import com.noop.data.WhoopRepository
import java.lang.reflect.Proxy
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The personal daytime-stress lens is resolved once per local day, not once per surface.
 *
 * The drain (#2535): with the lens on, a wearer saw Today showing 09:30 at 22:20 while Stress detail showed
 * the current curve fifteen seconds after opening. Both are the same latency. The resolver folds the thirty
 * days BEFORE today, and every surface paid that fold independently: Today's fifteen-minute loop, detail on
 * open, the widget pass. Today's loop is gated on STARTED so it suspends while backgrounded and scores on
 * resume, and the card holds its previous curve while that runs, so the morning's curve stayed on screen
 * looking current for as long as the fold took.
 *
 * The span ends YESTERDAY, which is what makes the memo sound: today's heart rate arrives all day and
 * cannot move the key.
 */
class StressLensCacheTest {

    @Before fun reset() = StressLensCache.clear()

    /** A DAO that answers only what the resolver reads, and counts the per-day HR reads. */
    private class Dao(val hrRowsPerDay: Int, val windowCount: Int, val windowMaxTs: Long) {
        var dayReads = 0
        fun handle(name: String): Any? = when (name) {
            "pairedDevices" -> emptyList<Any>()
            "countHrInWindow" -> windowCount
            "maxHrTsInWindow" -> windowMaxTs
            "hrSamples" -> { dayReads++; emptyList<Any>() }
            else -> throw UnsupportedOperationException("resolver touched $name")
        }
    }

    private fun repoOf(dao: Dao): WhoopRepository {
        val proxy = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, _ -> dao.handle(method.name) } as WhoopDao
        return WhoopRepository(proxy)
    }

    private fun resolve(repo: WhoopRepository, day: LocalDate) = runBlocking {
        selectedDaytimeStressMode(
            repo, "my-whoop", day, ZoneId.of("UTC"), personalBaseline = true,
        )
    }

    @Test
    fun `the lens is folded once and reused for the same day and history`() {
        val dao = Dao(hrRowsPerDay = 0, windowCount = 120, windowMaxTs = 1_700_000_000L)
        val repo = repoOf(dao)
        val day = LocalDate.of(2026, 9, 27)

        resolve(repo, day)
        val afterFirst = dao.dayReads
        assertTrue("the first resolve must actually fold the history", afterFirst > 0)

        resolve(repo, day)
        assertEquals("a second resolve on unchanged history must read nothing", afterFirst, dao.dayReads)
    }

    @Test
    fun `a change inside the past window re-folds`() {
        val day = LocalDate.of(2026, 9, 27)
        val first = Dao(hrRowsPerDay = 0, windowCount = 120, windowMaxTs = 1_700_000_000L)
        resolve(repoOf(first), day)
        val baseline = first.dayReads

        // A backfill landing rows INSIDE the past window moves the count, which is the half MAX(ts) alone
        // would miss, so the memo must not serve the previous answer.
        val second = Dao(hrRowsPerDay = 0, windowCount = 121, windowMaxTs = 1_700_000_000L)
        resolve(repoOf(second), day)
        assertEquals("a moved fingerprint must re-fold", baseline, second.dayReads)
        assertTrue(second.dayReads > 0)
    }

    @Test
    fun `a new local day re-folds even on identical history`() {
        val dao = Dao(hrRowsPerDay = 0, windowCount = 120, windowMaxTs = 1_700_000_000L)
        val repo = repoOf(dao)
        resolve(repo, LocalDate.of(2026, 9, 27))
        val afterFirst = dao.dayReads
        resolve(repo, LocalDate.of(2026, 9, 28))
        assertTrue("the span moved, so the fold must run again", dao.dayReads > afterFirst)
    }

    @Test
    fun `the lens is not resolved at all when the personal baseline is off`() {
        val dao = Dao(hrRowsPerDay = 0, windowCount = 120, windowMaxTs = 1_700_000_000L)
        val mode = runBlocking {
            selectedDaytimeStressMode(
                repoOf(dao), "my-whoop", LocalDate.of(2026, 9, 27), ZoneId.of("UTC"),
                personalBaseline = false,
            )
        }
        assertEquals(DaytimeStress.ScoringMode.DayRelative, mode)
        assertEquals("the off path must not read history or the fingerprint", 0, dao.dayReads)
    }

    @Test
    fun `clear forces the next resolve to fold again`() {
        val dao = Dao(hrRowsPerDay = 0, windowCount = 120, windowMaxTs = 1_700_000_000L)
        val repo = repoOf(dao)
        val day = LocalDate.of(2026, 9, 27)
        resolve(repo, day)
        val afterFirst = dao.dayReads
        StressLensCache.clear()
        resolve(repo, day)
        assertTrue(dao.dayReads > afterFirst)
    }

    /**
     * Two callers arriving together fold ONCE, which is the half a plain memo misses.
     *
     * The reported sequence is exactly this: Today's loop scores on resume and Stress detail is opened a
     * few seconds later, while the first fold is still running. Without the lock the second caller misses
     * the cache it is about to be handed and starts its own thirty-day fold.
     */
    @Test
    fun `concurrent callers fold once and the waiter reuses the result`() = runBlocking {
        var folds = 0
        val fold: suspend () -> DaytimeStress.ScoringMode = {
            folds++
            delay(50)
            DaytimeStress.ScoringMode.DayRelative
        }
        val a = async { StressLensCache.resolve("same-key", fold) }
        val b = async { StressLensCache.resolve("same-key", fold) }
        assertEquals(DaytimeStress.ScoringMode.DayRelative, a.await())
        assertEquals(DaytimeStress.ScoringMode.DayRelative, b.await())
        assertEquals("the waiter must reuse rather than re-fold", 1, folds)
    }

    /** A different key genuinely needs its own fold, lock or not. */
    @Test
    fun `a different key still folds`() = runBlocking {
        var folds = 0
        val fold: suspend () -> DaytimeStress.ScoringMode = {
            folds++
            DaytimeStress.ScoringMode.DayRelative
        }
        StressLensCache.resolve("key-a", fold)
        StressLensCache.resolve("key-b", fold)
        assertEquals(2, folds)
    }
}
