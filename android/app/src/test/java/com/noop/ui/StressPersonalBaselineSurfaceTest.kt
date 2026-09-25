package com.noop.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #2430: a selected personal daytime-stress lens must reach both foreground surfaces.
 *
 * This is wiring, not analytics math: [DaytimeBaselinesTest] already proves the resolver's output.
 * Source tripwires are appropriate here because Compose/SwiftUI call sites otherwise compile while
 * quietly omitting the preference, which is exactly how Today diverged from Stress detail.
 */
class StressPersonalBaselineSurfaceTest {
    private fun repoRoot(): File {
        val userDir = File(System.getProperty("user.dir") ?: ".")
        val candidates = listOf(userDir, File(userDir, ".."), File(userDir, "../.."))
        return candidates.firstOrNull { File(it, "Strand/Data/StressDayCurve.swift").isFile }
            ?: error("could not locate the repo root from ${userDir.absolutePath}")
    }

    private fun source(path: String): String = File(repoRoot(), path).readText()

    @Test
    fun `android detail and Today resolve and analyze the same selected lens`() {
        val detail = source("android/app/src/main/java/com/noop/ui/StressScreen.kt")
        val producer = source("android/app/src/main/java/com/noop/widget/StressWidgetProducer.kt")
        val today = source("android/app/src/main/java/com/noop/ui/TodayScreen.kt")

        assertTrue(
            "Stress detail must use the shared foreground mode resolver",
            detail.contains("val mode = selectedDaytimeStressMode("),
        )
        assertTrue(
            "Today's producer must use the same resolver before analyzing the curve",
            producer.contains("val mode = selectedDaytimeStressMode("),
        )
        assertTrue(
            "the producer must feed that selected mode into the series scorer",
            Regex("DaytimeStress\\.analyze\\([\\s\\S]*?tzOffsetSeconds,\\s*mode,")
                .containsMatchIn(producer),
        )
        assertTrue(
            "Today must pass the user's selected personal-baseline preference",
            Regex(
                "StressWidgetProducer\\.todayCurve\\([\\s\\S]*?" +
                    "personalBaseline\\s*=\\s*NoopPrefs\\.stressPersonalBaseline\\(context\\)",
            ).containsMatchIn(today),
        )
        // A SLOT PER LENS, not one slot that compares the lens. Comparing kept the two surfaces from
        // reading each other's curve but made every call miss whenever they alternated, which is every
        // Today tick with a background publish between. Keying keeps each surface's fingerprint gate.
        assertTrue(
            "the producer must keep a memo slot per lens, not one slot carrying the lens",
            producer.contains("memos[personalBaseline]"),
        )
        assertTrue(
            "those slots must stay volatile: four concurrent callers reach this producer",
            producer.contains("@Volatile") &&
                producer.contains("private var memos: Map<Boolean, Memo>"),
        )
        assertTrue(
            "Today must not seed a personal-lens card from the widget's default-lens snapshot",
            today.contains("if (NoopPrefs.stressPersonalBaseline(context)) return@LaunchedEffect"),
        )
    }

    @Test
    fun `android background widget callers retain the cheap default lens`() {
        val backgroundCallers = listOf(
            "android/app/src/main/java/com/noop/ui/AppViewModel.kt",
            "android/app/src/main/java/com/noop/ble/WhoopConnectionService.kt",
            "android/app/src/main/java/com/noop/widget/StressWidgetRefresh.kt",
        )
        for (path in backgroundCallers) {
            assertFalse(
                "$path must not opt an unprompted widget tick into 30 days of raw reads",
                source(path).contains("personalBaseline ="),
            )
        }
    }

    @Test
    fun `Apple detail and both Today implementations share the selected lens`() {
        val detail = source("Strand/Screens/StressView.swift")
        val producer = source("Strand/Data/StressDayCurve.swift")
        val today = source("Strand/Screens/TodayView.swift")
        val liquidToday = source("Strand/Liquid/LiquidTodayView.swift")
        val widget = source("StrandiOS/Widgets/WidgetPublish.swift")

        assertTrue(detail.contains("let mode = await DaytimeStressMode.selected("))
        assertTrue(producer.contains("let mode = await DaytimeStressMode.selected("))
        assertTrue(
            "the shared Apple producer must analyze with the selected mode",
            Regex("DaytimeStress\\.analyze\\([\\s\\S]*?mode:\\s*mode,")
                .containsMatchIn(producer),
        )
        for ((name, body) in listOf("TodayView" to today, "LiquidTodayView" to liquidToday)) {
            assertTrue(
                "$name must pass the selected personal-baseline preference",
                Regex(
                    "StressDayCurve\\.today\\([\\s\\S]*?" +
                        "personalBaseline:\\s*PuffinExperiment\\.stressPersonalBaselineEnabled",
                ).containsMatchIn(body),
            )
        }
        assertTrue(
            "the Apple producer must keep a memo slot per lens, not one slot carrying the lens",
            producer.contains("memos[personalBaseline]"),
        )
        assertFalse(
            "the iOS widget publisher must retain StressDayCurve.today's day-relative default",
            widget.contains("personalBaseline:"),
        )
    }
}
