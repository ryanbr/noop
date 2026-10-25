package com.noop.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins when the Coach model catalogue is pulled again.
 *
 * The rule decides how often the app talks to a provider without being asked, so it is worth holding
 * still. Written against the companion function rather than the ViewModel, which needs an Application:
 * the same split [CoachConversationDayTest] uses for [CoachViewModel.isStaleConversation].
 */
class CoachCatalogueStaleTest {

    @Test
    fun `opening settings invokes the gated refresh rather than an unconditional pull`() {
        var dir: File? = File(requireNotNull(System.getProperty("user.dir")))
        var source: String? = null
        repeat(5) {
            val current = dir ?: return@repeat
            val file = File(current, "app/src/main/java/com/noop/ui/CoachSettingsScreen.kt")
            if (file.isFile) source = file.readText()
            dir = current.parentFile
        }
        val code = requireNotNull(source) { "CoachSettingsScreen.kt not found" }
            .replace(Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL), "")
            .replace(Regex("//[^\\n]*"), "")
        val effect = requireNotNull(
            Regex("LaunchedEffect\\(Unit\\)\\s*\\{([^}]*)}").find(code),
        ) { "settings entry effect not found" }.groupValues[1]
        assertEquals(1, Regex("vm\\.refreshModelsIfStale\\(context\\)").findAll(effect).count())
        assertFalse("entry must keep the weekly/key/Custom gates", effect.contains("vm.refreshModels("))
    }

    private val week = CoachViewModel.MODEL_REFRESH_INTERVAL_MS
    private val now = 1_800_000_000_000L

    @Test
    fun `a catalogue never pulled is stale`() {
        // The first visit has to fetch, or the live list never arrives for anyone.
        assertTrue(CoachViewModel.isCatalogueStale(0L, now))
    }

    @Test
    fun `a catalogue pulled just now is fresh`() {
        assertFalse(CoachViewModel.isCatalogueStale(now, now))
    }

    @Test
    fun `one millisecond short of the interval is still fresh`() {
        assertFalse(CoachViewModel.isCatalogueStale(now - week + 1, now))
    }

    @Test
    fun `exactly the interval is due`() {
        // The boundary is inclusive, so a weekly visitor refreshes rather than never qualifying.
        assertTrue(CoachViewModel.isCatalogueStale(now - week, now))
    }

    @Test
    fun `well past the interval is due`() {
        assertTrue(CoachViewModel.isCatalogueStale(now - week * 5, now))
    }

    @Test
    fun `a clock moved backwards keeps the cached list`() {
        // A negative age must not read as "very stale" and refetch on every single visit until the
        // clock catches up. Same direction isStaleConversation takes for a backwards clock.
        assertFalse(CoachViewModel.isCatalogueStale(now + week, now))
    }

    @Test
    fun `the interval is a week`() {
        assertTrue(week == 7L * 24 * 60 * 60 * 1000)
    }
}
