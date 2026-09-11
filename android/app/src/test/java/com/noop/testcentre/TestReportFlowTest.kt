package com.noop.testcentre

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Mirrors the Swift TestReportFlowTests: the saved bundle filename pattern, the attach toast that
 * names the file (and carries no em-dash), and that the Copy-report.txt fallback is offered on the
 * Android mobile platform. Pure plan only (no Android runtime types).
 */
class TestReportFlowTest {

    @Test
    fun bundleNameFollowsProfilePlatformVersionPattern() {
        val name = TestReportFlow.Plan.bundleName(
            profile = TestDomain.SLEEP, platform = "android", version = "7.3.0",
            nowMs = 1_781_500_320_000L)
        assertTrue(name.startsWith("noop-sleep-android-v7.3.0-"))
        assertTrue(name.endsWith(".zip"))
    }

    @Test
    fun attachToastNamesTheSavedFileAndHasNoEmDash() {
        val toast = TestReportFlow.Plan.attachToast("noop-sleep-android-v7.3.0-260626-0712.zip")
        assertTrue(toast.contains("noop-sleep-android-v7.3.0-260626-0712.zip"))
        assertTrue(toast.contains("Attach"))
        assertFalse(toast.contains("\u2014"))
        // The flow no longer opens a GitHub issue composer, so the toast must not walk the user through
        // one. It used to say "On the next screen tap the paperclip and pick it", describing a screen
        // that will never appear now.
        assertFalse(toast.contains("paperclip"))
        assertFalse(toast.contains("next screen"))
    }

    @Test
    fun copyFallbackOfferedOnAndroid() {
        assertTrue(TestReportFlow.Plan.offersCopyFallback("android"))
        assertFalse(TestReportFlow.Plan.offersCopyFallback("macOS"))
    }
}
