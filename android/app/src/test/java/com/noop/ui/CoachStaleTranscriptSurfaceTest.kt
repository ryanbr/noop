package com.noop.ui

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #2087: opening Coach on a new day must retire the previous day's transcript BEFORE the scheduled
 * brief is offered to it, on both platforms.
 *
 * This is wiring, not logic: [CoachConversationDayTest] already pins the day rule itself. A source
 * tripwire is the right instrument because the screen-level call sites compile perfectly while
 * omitting a step, and because the bug is invisible in any short-lived test: the persisted-message
 * load runs once per PROCESS, so only a process that survives midnight reaches the broken state.
 * Neither a JVM test nor an instrumented one can hold a ViewModel across a real day boundary.
 */
class CoachStaleTranscriptSurfaceTest {
    private fun repoRoot(): File {
        val userDir = File(System.getProperty("user.dir") ?: ".")
        val candidates = listOf(userDir, File(userDir, ".."), File(userDir, "../.."))
        return candidates.firstOrNull { File(it, "Strand/AI/AICoach.swift").isFile }
            ?: error("could not locate the repo root from ${userDir.absolutePath}")
    }

    private fun source(path: String): String = File(repoRoot(), path).readText()

    /** The body of a declaration, from its signature to the next closing brace at [indent]. */
    private fun body(src: String, signature: String, indent: String = "    "): String {
        val start = src.indexOf(signature)
        assertTrue("missing declaration: $signature", start >= 0)
        val end = src.indexOf("\n$indent}", start)
        assertTrue("unterminated declaration: $signature", end > start)
        return src.substring(start, end)
    }

    @Test
    fun `android retires the stale transcript between the restore and the brief`() {
        val screen = source("android/app/src/main/java/com/noop/ui/CoachScreen.kt")
        val load = screen.indexOf("vm.loadPersistedMessagesIfNeeded()")
        val retire = screen.indexOf("vm.retireStaleConversationIfNeeded()")
        val brief = screen.indexOf("vm.consumeScheduledBriefIfAny(")
        assertTrue("the Coach screen must restore the persisted transcript", load >= 0)
        assertTrue("the Coach screen must retire a transcript from an earlier day", retire >= 0)
        assertTrue("the Coach screen must offer the scheduled brief", brief >= 0)
        assertTrue("retiring must follow the restore, or it retires nothing", load < retire)
        assertTrue("retiring must precede the brief, or the brief is refused", retire < brief)
    }

    @Test
    fun `ios retires the stale transcript between the restore and the brief`() {
        val view = source("Strand/Screens/CoachView.swift")
        val load = view.indexOf("await coach.loadPersistedMessagesIfNeeded()")
        val retire = view.indexOf("coach.retireStaleConversationIfNeeded()")
        val brief = view.indexOf("coach.surfaceScheduledBrief(")
        assertTrue("CoachView must restore the persisted transcript", load >= 0)
        assertTrue("CoachView must retire a transcript from an earlier day", retire >= 0)
        assertTrue("CoachView must offer the scheduled brief", brief >= 0)
        assertTrue("retiring must follow the restore, or it retires nothing", load < retire)
        assertTrue("retiring must precede the brief, or the brief is refused", retire < brief)
    }

    /**
     * A day whose only message is its brief must still date the transcript. Left null, the day rule
     * reads "nothing sent yet, never stale", so the brief-only transcript is never retired and the
     * NEXT day's brief is refused — the half of #2087 that reproduces without a typed turn.
     */
    @Test
    fun `both scheduled-brief paths date the transcript they create`() {
        val vm = body(
            source("android/app/src/main/java/com/noop/ui/CoachViewModel.kt"),
            "fun consumeScheduledBriefIfAny(",
        )
        assertTrue(
            "consumeScheduledBriefIfAny must set conversationDay",
            vm.contains("conversationDay = LocalDate.now().toEpochDay()"),
        )
        val engine = body(
            source("Strand/AI/AICoach.swift"),
            "func surfaceScheduledBrief(",
        )
        assertTrue(
            "surfaceScheduledBrief must set conversationDay",
            engine.contains("conversationDay = Self.localEpochDay()"),
        )
    }
}
