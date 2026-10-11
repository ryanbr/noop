package com.noop.ui

import com.noop.data.JournalEntry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import java.time.LocalDate

/**
 * Pins the pure journal-logging helpers (JournalLog.kt). Mirrored by the macOS JournalLogicTests
 * so the two platforms merge catalogs and entries identically — question strings are opaque
 * exact-match keys to the effects engines on both sides.
 */
class JournalLogTest {

    private fun e(dev: String, day: String, q: String, yes: Boolean) =
        JournalEntry(deviceId = dev, day = day, question = q, answeredYes = yes)

    @Test
    fun nativeWinsOnCollision() {
        val imported = listOf(e("my-whoop", "2026-06-09", "Did you drink any alcohol?", false))
        val native = listOf(e("noop-journal", "2026-06-09", "Did you drink any alcohol?", true))
        val merged = mergeJournalEntries(imported, native)
        assertEquals(1, merged.size)
        assertEquals(true, merged[0].answeredYes)
        assertEquals("noop-journal", merged[0].deviceId)
    }

    @Test
    fun disjointKeysUnionAndSort() {
        val imported = listOf(e("my-whoop", "2026-06-09", "B?", true))
        val native = listOf(
            e("noop-journal", "2026-06-10", "A?", false),
            e("noop-journal", "2026-06-09", "A?", true),
        )
        val merged = mergeJournalEntries(imported, native)
        assertEquals(3, merged.size)
        // Sorted day ASC then question ASC — matches the DAO/Swift read order.
        assertEquals(listOf("A?", "B?", "A?"), merged.map { it.question })
        assertEquals(listOf("2026-06-09", "2026-06-09", "2026-06-10"), merged.map { it.day })
    }

    @Test
    fun importedCasingWinsInCatalog() {
        val cat = resolveJournalItems(listOf("DID YOU DRINK ANY ALCOHOL?"), emptyList()).map { it.canonical }
        assertEquals("DID YOU DRINK ANY ALCOHOL?", cat[0])
        // The starter alcohol question deduped case-insensitively: 9 starters survive + 1 imported.
        assertEquals(STARTER_JOURNAL_QUESTIONS.size, cat.size)
    }

    @Test
    fun customsAppendAndBlanksDrop() {
        val saved = migrateLegacyJournalCatalog(listOf("  ", "Did you nap?", "did you NAP?"), emptyList())
        val cat = resolveJournalItems(emptyList(), saved).map { it.canonical }
        assertEquals(STARTER_JOURNAL_QUESTIONS, cat.take(STARTER_JOURNAL_QUESTIONS.size))
        assertEquals("Did you nap?", cat.last())
        assertEquals(STARTER_JOURNAL_QUESTIONS.size + 1, cat.size)
    }

    @Test
    fun hiddenQuestionsAreFilteredOutCaseInsensitively() {
        // Hide one starter (different casing) + one custom; both must drop from the merged catalog.
        val saved = migrateLegacyJournalCatalog(
            custom = listOf("Did you nap?"),
            hidden = listOf("did you drink any alcohol?", "DID YOU NAP?"),
        )
        val cat = resolveJournalItems(emptyList(), saved).map { it.canonical }
        assertFalse(cat.any { it.equals("Did you drink any alcohol?", ignoreCase = true) })
        assertFalse(cat.any { it.equals("Did you nap?", ignoreCase = true) })
        // The other 9 starters survive.
        assertEquals(STARTER_JOURNAL_QUESTIONS.size - 1, cat.size)
    }

    @Test
    fun importedMagnesiumWithTrailingWhitespaceDoesNotDoublePrompt() {
        // #224: a WHOOP export leaves a trailing newline / non-breaking space on the cell, so the
        // imported "Did you take magnesium?\n" must fold onto the starter, NOT add a second row.
        val cat = resolveJournalItems(
            imported = listOf("Did you take magnesium?\n", "Did you take  magnesium?", "Did you take magnesium?\u00a0"),
            savedItems = emptyList(),
        ).map { it.canonical }
        assertEquals(1, cat.count { normJournalKey(it) == normJournalKey("Did you take magnesium?") })
        // No net growth — both imported variants dedupe against the starter.
        assertEquals(STARTER_JOURNAL_QUESTIONS.size, cat.size)
    }

    @Test
    fun normaliseFoldsUnicodeWhitespaceAndNeverThrows() {
        // The key normaliser must (a) fold non-ASCII whitespace — non-breaking space U+00A0,
        // en-space U+2002 — onto the plain-space form, and (b) never throw. The previous
        // `Regex("(?U)\\s+")` did both on the desktop JVM but threw PatternSyntaxException on
        // Android's ICU regex engine, crashing the Insights screen (#224/#267).
        assertEquals("did you take magnesium?", normJournalKey("Did you take magnesium?\n"))
        assertEquals(normJournalKey("Did you take magnesium?"), normJournalKey("  Did you take magnesium? "))
    }

    @Test
    fun dayKeyTodayAndYesterday() {
        val today = LocalDate.of(2026, 6, 10)
        assertEquals("2026-06-10", journalDayKey(0, today))
        assertEquals("2026-06-09", journalDayKey(1, today))
        // Month boundary.
        assertEquals("2025-12-31", journalDayKey(1, LocalDate.of(2026, 1, 1)))
    }
}
