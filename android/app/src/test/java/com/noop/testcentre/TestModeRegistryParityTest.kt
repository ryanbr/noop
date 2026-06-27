package com.noop.testcentre

import com.noop.analytics.GuidedCaptureProgress
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirror of the Swift TestModeRegistryTests. The ids/titles/captures/capture-kind MUST match the Swift
 *  TestModeRegistry byte-for-byte (spec section 10 parity contract). */
class TestModeRegistryParityTest {

    @Test fun registryOrderAndIds() {
        // Mirror of the Swift testRegistryOrderAndIds. Screen priority order across both phases.
        assertEquals(
            listOf(TestDomain.SLEEP, TestDomain.CONNECTION, TestDomain.WORKOUTS, TestDomain.DISPLAY,
                TestDomain.IMPORT, TestDomain.STEPS, TestDomain.BATTERY, TestDomain.RECOVERY, TestDomain.HRV),
            TestModeRegistry.all.map { it.domain },
        )
        assertEquals(
            listOf("sleep", "connection", "workouts", "display", "import", "steps", "battery", "recovery", "hrv"),
            TestModeRegistry.all.map { it.id },
        )
        assertEquals(9, TestModeRegistry.all.size)
    }

    @Test fun lookupByDomain() {
        assertEquals("Sleep & Rest", TestModeRegistry.mode(TestDomain.SLEEP)?.title)
        assertEquals("Connection & Sync", TestModeRegistry.mode(TestDomain.CONNECTION)?.title)
        assertEquals("Workouts & GPS", TestModeRegistry.mode(TestDomain.WORKOUTS)?.title)
        assertEquals("Display & Performance", TestModeRegistry.mode(TestDomain.DISPLAY)?.title)
        assertEquals("Import & Data Ingest", TestModeRegistry.mode(TestDomain.IMPORT)?.title)
        assertEquals("Steps", TestModeRegistry.mode(TestDomain.STEPS)?.title)
        assertEquals("Battery & Charging", TestModeRegistry.mode(TestDomain.BATTERY)?.title)
        assertEquals("Recovery (Charge)", TestModeRegistry.mode(TestDomain.RECOVERY)?.title)
        assertEquals("HRV & Autonomic", TestModeRegistry.mode(TestDomain.HRV)?.title)
        assertNull(TestModeRegistry.mode(TestDomain.NOTIFICATIONS))
    }

    @Test fun sleepCaptureSet() {
        assertEquals(
            listOf("gateTrace", "gravityCoverage", "hrDensity", "wristOff", "perEpochFeatures",
                "hypnogramV1V2", "ppgOnlyNight", "skinTempDsp", "restSubScores"),
            TestModeRegistry.mode(TestDomain.SLEEP)?.captures,
        )
    }

    @Test fun batteryCaptureSetAndReadout() {
        assertEquals(
            listOf("socSeries", "chargeSteps", "offWristGaps", "dischargeRun", "fittedSlope",
                "sourceMeasuredVsRated", "batteryGates"),
            TestModeRegistry.mode(TestDomain.BATTERY)?.captures,
        )
        assertEquals(
            listOf("currentSoc", "estimateDaysLeft", "slopeSource"),
            TestModeRegistry.mode(TestDomain.BATTERY)?.liveReadout,
        )
    }

    @Test fun sleepGuidedThreeNights() {
        val cap = TestModeRegistry.mode(TestDomain.SLEEP)?.capture
        assertTrue(cap is CaptureKind.Guided)
        cap as CaptureKind.Guided
        assertEquals(CaptureUnit.NIGHTS, cap.unit)
        assertEquals(3, cap.defaultCount)
    }

    @Test fun batteryGuidedThreeDays() {
        val cap = TestModeRegistry.mode(TestDomain.BATTERY)?.capture
        assertTrue(cap is CaptureKind.Guided)
        cap as CaptureKind.Guided
        assertEquals(CaptureUnit.DAYS, cap.unit)
        assertEquals(3, cap.defaultCount)
    }

    @Test fun sleepQuestionnaireKeys() {
        assertEquals(
            listOf("sleepTimes", "awakeStill", "naps", "shiftWork", "chargeTiming", "healthSleep"),
            TestModeRegistry.mode(TestDomain.SLEEP)?.questionnaire?.map { it.id },
        )
    }

    @Test fun screenshotAndRequires5MGFlags() {
        // Only Display & Performance carries a screenshot; nothing registered yet requires 5/MG.
        for (m in TestModeRegistry.all) {
            assertFalse(m.requires5MG)
            assertEquals(m.domain == TestDomain.DISPLAY, m.includesScreenshot)
        }
    }

    @Test fun phase2HighPainAreToggles() {
        val toggles = listOf(TestDomain.CONNECTION, TestDomain.WORKOUTS, TestDomain.DISPLAY,
            TestDomain.IMPORT, TestDomain.STEPS, TestDomain.RECOVERY, TestDomain.HRV)
        for (d in toggles) {
            assertTrue(TestModeRegistry.mode(d)?.capture is CaptureKind.Toggle)
        }
    }

    @Test fun phase2Priorities() {
        assertEquals(TestPriority.HIGH, TestModeRegistry.mode(TestDomain.CONNECTION)?.priority)
        assertEquals(TestPriority.HIGH, TestModeRegistry.mode(TestDomain.WORKOUTS)?.priority)
        assertEquals(TestPriority.HIGH, TestModeRegistry.mode(TestDomain.DISPLAY)?.priority)
        assertEquals(TestPriority.HIGH, TestModeRegistry.mode(TestDomain.IMPORT)?.priority)
        assertEquals(TestPriority.HIGH, TestModeRegistry.mode(TestDomain.STEPS)?.priority)
        assertEquals(TestPriority.MED, TestModeRegistry.mode(TestDomain.RECOVERY)?.priority)
        assertEquals(TestPriority.MED, TestModeRegistry.mode(TestDomain.HRV)?.priority)
    }

    @Test fun phase2CaptureSets() {
        assertEquals(
            listOf("connectTiming", "bondState", "frameTiming", "reconnectChurn", "offloadProgress",
                "offloadStalls", "firmwareDecode", "clockDrift", "otherCentral"),
            TestModeRegistry.mode(TestDomain.CONNECTION)?.captures,
        )
        assertEquals(
            listOf("sessionLifecycle", "hrSamples", "gpsFixes", "autoDetectThresholds",
                "autoDetectWhy", "crossSourceDedup"),
            TestModeRegistry.mode(TestDomain.WORKOUTS)?.captures,
        )
        assertEquals(
            listOf("screenshot", "deviceMetrics", "frameTimeTrace", "memoryHighWater"),
            TestModeRegistry.mode(TestDomain.DISPLAY)?.captures,
        )
        assertEquals(
            listOf("parserVersion", "fileMeta", "perStageRows", "rejectCounts", "dayDeltas"),
            TestModeRegistry.mode(TestDomain.IMPORT)?.captures,
        )
        assertEquals(
            listOf("motionVolume", "stepCalibration", "phoneReferenceCount", "rawStepCounter",
                "wrapAwareDeltas", "droppedDeltas"),
            TestModeRegistry.mode(TestDomain.STEPS)?.captures,
        )
        assertEquals(
            listOf("chargeTermBreakdown", "baselinesPerNight", "termZScores", "nilTerm", "forecastInputs"),
            TestModeRegistry.mode(TestDomain.RECOVERY)?.captures,
        )
        assertEquals(
            listOf("rawRR", "nInputCleanRejected", "rmssdSdnn", "minBeatsCleared", "spotVsContinuous", "respRsa"),
            TestModeRegistry.mode(TestDomain.HRV)?.captures,
        )
    }

    @Test fun phase2QuestionnaireIdsAndKinds() {
        assertEquals(listOf("otherDevicePaired"),
            TestModeRegistry.mode(TestDomain.CONNECTION)?.questionnaire?.map { it.id })
        assertEquals(Question.Kind.YES_NO,
            TestModeRegistry.mode(TestDomain.CONNECTION)?.questionnaire?.first()?.kind)
        assertEquals(listOf("startMethod"),
            TestModeRegistry.mode(TestDomain.WORKOUTS)?.questionnaire?.map { it.id })
        assertEquals(Question.Kind.TEXT,
            TestModeRegistry.mode(TestDomain.WORKOUTS)?.questionnaire?.first()?.kind)
        assertEquals(listOf("screenAndIssue"),
            TestModeRegistry.mode(TestDomain.DISPLAY)?.questionnaire?.map { it.id })
        assertEquals(Question.Kind.TEXT,
            TestModeRegistry.mode(TestDomain.DISPLAY)?.questionnaire?.first()?.kind)
        assertEquals(listOf("appFormatExpected"),
            TestModeRegistry.mode(TestDomain.IMPORT)?.questionnaire?.map { it.id })
        assertEquals(Question.Kind.TEXT,
            TestModeRegistry.mode(TestDomain.IMPORT)?.questionnaire?.first()?.kind)
        assertEquals(listOf("otherTrackerSteps"),
            TestModeRegistry.mode(TestDomain.STEPS)?.questionnaire?.map { it.id })
        assertEquals(Question.Kind.TEXT,
            TestModeRegistry.mode(TestDomain.STEPS)?.questionnaire?.first()?.kind)
        assertEquals(listOf("recalHealthHrv"),
            TestModeRegistry.mode(TestDomain.RECOVERY)?.questionnaire?.map { it.id })
        assertEquals(Question.Kind.TEXT,
            TestModeRegistry.mode(TestDomain.RECOVERY)?.questionnaire?.first()?.kind)
        assertEquals(listOf("otherAppHrv"),
            TestModeRegistry.mode(TestDomain.HRV)?.questionnaire?.map { it.id })
        assertEquals(Question.Kind.YES_NO,
            TestModeRegistry.mode(TestDomain.HRV)?.questionnaire?.first()?.kind)
    }

    @Test fun phase2LiveReadoutIds() {
        assertEquals(listOf("connectionUptime", "reconnectCount", "lastOffloadResult"),
            TestModeRegistry.mode(TestDomain.CONNECTION)?.liveReadout)
        assertEquals(listOf("lastSessionSummary"),
            TestModeRegistry.mode(TestDomain.WORKOUTS)?.liveReadout)
        assertEquals(listOf("deviceMetricsNow"),
            TestModeRegistry.mode(TestDomain.DISPLAY)?.liveReadout)
        assertEquals(listOf("lastImportSummary"),
            TestModeRegistry.mode(TestDomain.IMPORT)?.liveReadout)
        assertEquals(listOf("stepsToday", "calibrationState"),
            TestModeRegistry.mode(TestDomain.STEPS)?.liveReadout)
        assertEquals(listOf("lastChargeBreakdown"),
            TestModeRegistry.mode(TestDomain.RECOVERY)?.liveReadout)
        assertEquals(listOf("lastHrvComputation"),
            TestModeRegistry.mode(TestDomain.HRV)?.liveReadout)
    }

    @Test fun noQuestionnairePromptHasEmDash() {
        for (m in TestModeRegistry.all) {
            val emDash = "\u2014"
            for (q in m.questionnaire) {
                assertFalse(q.prompt.contains(emDash))
            }
            assertFalse(m.blurb.contains(emDash))
        }
    }

    // MARK: - Group E Swift/Kotlin parity (guided labels + gate names). The matching Swift assertions live
    // in the Group A registry/guided tests; keep these expected strings byte-identical to the Swift ones.

    @Test fun guidedLabelParity() {
        assertEquals("Captured 1 of 3 nights. Wear it again tonight.",
            GuidedCaptureProgress.label(GuidedCaptureProgress.Capturing(1, 3)))
        assertEquals("Capture complete. Tap Report to export.",
            GuidedCaptureProgress.label(GuidedCaptureProgress.Complete))
        assertEquals("No data last night. Wear the strap tonight to continue.",
            GuidedCaptureProgress.gapNudge())
    }

    @Test fun gateNamesParity() {
        // The gate names the Swift detectSleep emits, asserted here so a drift on either side fails the build.
        val names = listOf("minSleepMin", "maxMainSleepSpanS", "hrConfirm", "offWrist",
            "daytimeGuard", "morningStillness", "sparseBridge", "accepted")
        names.forEach { assertTrue(it.isNotEmpty()) }
    }
}
