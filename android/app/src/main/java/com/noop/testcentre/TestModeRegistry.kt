package com.noop.testcentre

/** Whether a guided capture counts nights (Sleep) or days (Battery). */
enum class CaptureUnit { NIGHTS, DAYS }

/** How a mode captures: a plain toggle, or a guided "wear it N nights/days" window. Twin of the Swift
 *  CaptureKind. */
sealed class CaptureKind {
    object Toggle : CaptureKind()
    data class Guided(val unit: CaptureUnit, val defaultCount: Int) : CaptureKind()
}

/** Display priority on the Test Centre screen. */
enum class TestPriority { HIGH, MED, LOW }

/** One questionnaire prompt declared by a mode. Answers stored in meta.json under [id]. */
data class Question(
    val id: String,
    val prompt: String,
    val kind: Kind,
    val choices: List<String> = emptyList(),
) {
    enum class Kind { YES_NO, TEXT, TIME, CHOICE }
}

/** A test mode is DATA, not code (spec section 3.1). The screen, export and questionnaire all render
 *  from this. Twin of the Swift TestMode, byte-aligned by a parity test. */
data class TestMode(
    val domain: TestDomain,
    val title: String,
    val blurb: String,
    val icon: String,                 // drawable id on Android; SF Symbol on Apple
    val priority: TestPriority,
    val captures: List<String>,
    val questionnaire: List<Question>,
    val liveReadout: List<String>,
    val capture: CaptureKind,
    val includesScreenshot: Boolean,
    val requires5MG: Boolean,
) {
    val id: String get() = domain.id
}

/** The single source the Test Centre IA iterates. Order is priority order. Twin of the Swift
 *  TestModeRegistry; same ids/titles/captures, verified by [TestModeRegistryParityTest]. */
object TestModeRegistry {

    val all: List<TestMode> = listOf(
        sleep(), connection(), workouts(), display(), dataImport(), steps(), battery(), recovery(), hrv(),
    )

    fun mode(d: TestDomain): TestMode? = all.firstOrNull { it.domain == d }

    private fun sleep() = TestMode(
        domain = TestDomain.SLEEP, title = "Sleep & Rest",
        blurb = "Wear it a few nights so we can see which gate kept or dropped each sleep run.",
        icon = "ic_bed", priority = TestPriority.HIGH,
        captures = listOf("gateTrace", "gravityCoverage", "hrDensity", "wristOff", "perEpochFeatures",
            "hypnogramV1V2", "ppgOnlyNight", "skinTempDsp", "restSubScores"),
        questionnaire = listOf(
            Question("sleepTimes", "Your actual sleep, wake and out-of-bed times?", Question.Kind.TEXT),
            Question("awakeStill", "Any awake-but-still windows in bed?", Question.Kind.TEXT),
            Question("naps", "Any naps?", Question.Kind.TEXT),
            Question("shiftWork", "Shift work or an unusual schedule?", Question.Kind.YES_NO),
            Question("chargeTiming", "When did you charge the strap?", Question.Kind.TEXT),
            Question("healthSleep", "Is Apple Health / Health Connect also feeding sleep?", Question.Kind.YES_NO),
        ),
        liveReadout = listOf("hrDensityNow", "gravityCoverageNow", "lastNightGateFired"),
        capture = CaptureKind.Guided(CaptureUnit.NIGHTS, 3),
        includesScreenshot = false, requires5MG = false,
    )

    private fun connection() = TestMode(
        domain = TestDomain.CONNECTION, title = "Connection & Sync",
        blurb = "Turn this on if the strap keeps dropping or won't finish a sync.",
        icon = "ic_antenna", priority = TestPriority.HIGH,
        captures = listOf("connectTiming", "bondState", "frameTiming", "reconnectChurn", "offloadProgress",
            "offloadStalls", "firmwareDecode", "clockDrift", "otherCentral"),
        questionnaire = listOf(
            Question("otherDevicePaired", "Is another phone or the WHOOP app paired to the strap right now?", Question.Kind.YES_NO),
        ),
        liveReadout = listOf("connectionUptime", "reconnectCount", "lastOffloadResult"),
        capture = CaptureKind.Toggle,
        includesScreenshot = false, requires5MG = false,
    )

    private fun workouts() = TestMode(
        domain = TestDomain.WORKOUTS, title = "Workouts & GPS",
        blurb = "Turn this on if a workout went missing or auto-detect didn't fire.",
        icon = "ic_run", priority = TestPriority.HIGH,
        captures = listOf("sessionLifecycle", "hrSamples", "gpsFixes", "autoDetectThresholds",
            "autoDetectWhy", "crossSourceDedup"),
        questionnaire = listOf(
            Question("startMethod", "Did you start it manually or expect auto-detect?", Question.Kind.TEXT),
        ),
        liveReadout = listOf("lastSessionSummary"),
        capture = CaptureKind.Toggle,
        includesScreenshot = false, requires5MG = false,
    )

    private fun display() = TestMode(
        domain = TestDomain.DISPLAY, title = "Display & Performance",
        blurb = "Turn this on if a screen looks wrong or feels laggy, then grab a shot.",
        icon = "ic_paintbrush", priority = TestPriority.HIGH,
        captures = listOf("screenshot", "deviceMetrics", "frameTimeTrace", "memoryHighWater"),
        questionnaire = listOf(
            Question("screenAndIssue", "What screen, and what looked or felt wrong (laggy/clipped)?", Question.Kind.TEXT),
        ),
        liveReadout = listOf("deviceMetricsNow"),
        capture = CaptureKind.Toggle,
        includesScreenshot = true, requires5MG = false,
    )

    private fun dataImport() = TestMode(
        domain = TestDomain.IMPORT, title = "Import & Data Ingest",
        blurb = "Turn this on if a file import dropped rows or came in wrong.",
        icon = "ic_import", priority = TestPriority.HIGH,
        // Only the captures a production import actually emits (parser identity, file meta, per-stage rows,
        // reject counts, day deltas). firstFailingRow / failingFileSample / dedupMerge were advertised but
        // no emitter on either platform produces them, so they are dropped from BOTH registries (parity)
        // rather than over-promising the mode.
        captures = listOf("parserVersion", "fileMeta", "perStageRows", "rejectCounts", "dayDeltas"),
        questionnaire = listOf(
            Question("appFormatExpected", "Which app/format, and what did you expect to import?", Question.Kind.TEXT),
        ),
        liveReadout = listOf("lastImportSummary"),
        capture = CaptureKind.Toggle,
        includesScreenshot = false, requires5MG = false,
    )

    private fun steps() = TestMode(
        domain = TestDomain.STEPS, title = "Steps",
        blurb = "Turn this on if your step count looks off versus your phone.",
        icon = "ic_steps", priority = TestPriority.HIGH,
        captures = listOf("motionVolume", "stepCalibration", "phoneReferenceCount", "rawStepCounter",
            "wrapAwareDeltas", "droppedDeltas"),
        questionnaire = listOf(
            Question("otherTrackerSteps", "What did your phone or another tracker report for the same day?", Question.Kind.TEXT),
        ),
        liveReadout = listOf("stepsToday", "calibrationState"),
        capture = CaptureKind.Toggle,
        includesScreenshot = false, requires5MG = false,
    )

    private fun battery() = TestMode(
        domain = TestDomain.BATTERY, title = "Battery & Charging",
        blurb = "Wear it a few days so we can fit your real discharge slope.",
        icon = "ic_battery", priority = TestPriority.MED,
        captures = listOf("socSeries", "chargeSteps", "offWristGaps", "dischargeRun", "fittedSlope",
            "sourceMeasuredVsRated", "batteryGates"),
        questionnaire = listOf(
            Question("whoopAppInstalled", "Is the official WHOOP app installed?", Question.Kind.YES_NO),
            Question("otherPhonePaired", "Is another phone paired to the strap?", Question.Kind.YES_NO),
            Question("chargedInWindow", "Did you charge during the capture?", Question.Kind.YES_NO),
            Question("batterySaverApps", "Any battery-saver apps running?", Question.Kind.TEXT),
        ),
        liveReadout = listOf("currentSoc", "estimateDaysLeft", "slopeSource"),
        capture = CaptureKind.Guided(CaptureUnit.DAYS, 3),
        includesScreenshot = false, requires5MG = false,
    )

    private fun recovery() = TestMode(
        domain = TestDomain.RECOVERY, title = "Recovery (Charge)",
        blurb = "Turn this on if Charge looks wrong, to see which term moved it.",
        icon = "ic_recovery", priority = TestPriority.MED,
        captures = listOf("chargeTermBreakdown", "baselinesPerNight", "termZScores", "nilTerm",
            "forecastInputs"),
        questionnaire = listOf(
            Question("recalHealthHrv", "Recent recalibration? Is Apple Health / Health Connect feeding HRV?", Question.Kind.TEXT),
        ),
        liveReadout = listOf("lastChargeBreakdown"),
        capture = CaptureKind.Toggle,
        includesScreenshot = false, requires5MG = false,
    )

    private fun hrv() = TestMode(
        domain = TestDomain.HRV, title = "HRV & Autonomic",
        blurb = "Turn this on if HRV reads nil or looks off, to see the clean beats.",
        icon = "ic_hrv", priority = TestPriority.MED,
        captures = listOf("rawRR", "nInputCleanRejected", "rmssdSdnn", "minBeatsCleared",
            "spotVsContinuous", "respRsa"),
        questionnaire = listOf(
            Question("otherAppHrv", "Is another app feeding HRV to Apple Health / Health Connect?", Question.Kind.YES_NO),
        ),
        liveReadout = listOf("lastHrvComputation"),
        capture = CaptureKind.Toggle,
        includesScreenshot = false, requires5MG = false,
    )
}
