import Foundation

/// Whether a guided capture counts nights (Sleep) or days (Battery).
public enum CaptureUnit: String, Sendable, Codable { case nights, days }

/// How a mode captures: a plain on/off toggle, or a guided "wear it for N nights/days" window.
public enum CaptureKind: Sendable, Codable, Equatable {
    case toggle
    case guided(unit: CaptureUnit, defaultCount: Int)   // "defaultCount" (not "default", a reserved word)
}

/// Display priority on the Test Centre screen.
public enum TestPriority: String, Sendable, Codable { case high, med, low }

/// One questionnaire prompt declared by a mode. Answers are stored in meta.json under `id`.
public struct Question: Sendable, Codable, Equatable {
    public let id: String          // stable key stored in the meta.json questionnaire map
    public let prompt: String
    public enum Kind: String, Sendable, Codable { case yesNo, text, time, choice }
    public let kind: Kind
    public let choices: [String]   // only for .choice; else []
    public init(id: String, prompt: String, kind: Kind, choices: [String] = []) {
        self.id = id; self.prompt = prompt; self.kind = kind; self.choices = choices
    }
}

/// A test mode is DATA, not code (spec section 3.1). The screen, the export and the questionnaire all
/// render from this. `captures` / `liveReadout` are declarative ids; the emitters and readout panels
/// bind to them by name. Phase 1 registers exactly `.sleep` and `.battery`.
public struct TestMode: Sendable, Identifiable {
    public let domain: TestDomain
    public let title: String
    public let blurb: String
    public let icon: String                 // SF Symbol on Apple; mapped to a drawable id on Android
    public let priority: TestPriority
    public let captures: [String]           // LogVariable ids, declarative
    public let questionnaire: [Question]
    public let liveReadout: [String]        // ReadoutSpec ids the in-app panel binds
    public let capture: CaptureKind
    public let includesScreenshot: Bool
    public let requires5MG: Bool
    public var id: String { domain.id }

    public init(domain: TestDomain, title: String, blurb: String, icon: String, priority: TestPriority,
                captures: [String], questionnaire: [Question], liveReadout: [String],
                capture: CaptureKind, includesScreenshot: Bool, requires5MG: Bool) {
        self.domain = domain; self.title = title; self.blurb = blurb; self.icon = icon
        self.priority = priority; self.captures = captures; self.questionnaire = questionnaire
        self.liveReadout = liveReadout; self.capture = capture
        self.includesScreenshot = includesScreenshot; self.requires5MG = requires5MG
    }
}

/// The single source the Test Centre IA iterates. Order is priority order on screen. The Kotlin twin is
/// TestModeRegistry.kt, byte-aligned (same ids, titles, captures), verified by a parity test.
public enum TestModeRegistry {

    /// Phase 1 shipped sleep + battery; Phase 2 appends the 🔴 high-pain domains plus the scoring chain
    /// (connection, workouts, display, import, steps, recovery, hrv). Order is screen priority order.
    public static let all: [TestMode] = [
        sleep, connection, workouts, display, dataImport, steps, battery, recovery, hrv,
    ]

    public static func mode(_ d: TestDomain) -> TestMode? { all.first { $0.domain == d } }

    static let sleep = TestMode(
        domain: .sleep, title: "Sleep & Rest",
        blurb: "Wear it a few nights so we can see which gate kept or dropped each sleep run.",
        icon: "bed.double.fill", priority: .high,
        captures: ["gateTrace", "gravityCoverage", "hrDensity", "wristOff", "perEpochFeatures",
                   "hypnogramV1V2", "ppgOnlyNight", "skinTempDsp", "restSubScores"],
        questionnaire: [
            Question(id: "sleepTimes", prompt: "Your actual sleep, wake and out-of-bed times?", kind: .text),
            Question(id: "awakeStill", prompt: "Any awake-but-still windows in bed?", kind: .text),
            Question(id: "naps", prompt: "Any naps?", kind: .text),
            Question(id: "shiftWork", prompt: "Shift work or an unusual schedule?", kind: .yesNo),
            Question(id: "chargeTiming", prompt: "When did you charge the strap?", kind: .text),
            Question(id: "healthSleep", prompt: "Is Apple Health / Health Connect also feeding sleep?", kind: .yesNo),
        ],
        liveReadout: ["hrDensityNow", "gravityCoverageNow", "lastNightGateFired"],
        capture: .guided(unit: .nights, defaultCount: 3),
        includesScreenshot: false, requires5MG: false)

    static let connection = TestMode(
        domain: .connection, title: "Connection & Sync",
        blurb: "Turn this on if the strap keeps dropping or won't finish a sync.",
        icon: "antenna.radiowaves.left.and.right", priority: .high,
        captures: ["connectTiming", "bondState", "frameTiming", "reconnectChurn", "offloadProgress",
                   "offloadStalls", "firmwareDecode", "clockDrift", "otherCentral"],
        questionnaire: [
            Question(id: "otherDevicePaired", prompt: "Is another phone or the WHOOP app paired to the strap right now?", kind: .yesNo),
        ],
        liveReadout: ["connectionUptime", "reconnectCount", "lastOffloadResult"],
        capture: .toggle,
        includesScreenshot: false, requires5MG: false)

    static let workouts = TestMode(
        domain: .workouts, title: "Workouts & GPS",
        blurb: "Turn this on if a workout went missing or auto-detect didn't fire.",
        icon: "figure.run", priority: .high,
        captures: ["sessionLifecycle", "hrSamples", "gpsFixes", "autoDetectThresholds",
                   "autoDetectWhy", "crossSourceDedup"],
        questionnaire: [
            Question(id: "startMethod", prompt: "Did you start it manually or expect auto-detect?", kind: .text),
        ],
        liveReadout: ["lastSessionSummary"],
        capture: .toggle,
        includesScreenshot: false, requires5MG: false)

    static let display = TestMode(
        domain: .display, title: "Display & Performance",
        blurb: "Turn this on if a screen looks wrong or feels laggy, then grab a shot.",
        icon: "paintbrush.fill", priority: .high,
        captures: ["screenshot", "deviceMetrics", "frameTimeTrace", "memoryHighWater"],
        questionnaire: [
            Question(id: "screenAndIssue", prompt: "What screen, and what looked or felt wrong (laggy/clipped)?", kind: .text),
        ],
        liveReadout: ["deviceMetricsNow"],
        capture: .toggle,
        includesScreenshot: true, requires5MG: false)

    static let dataImport = TestMode(
        domain: .dataImport, title: "Import & Data Ingest",
        blurb: "Turn this on if a file import dropped rows or came in wrong.",
        icon: "square.and.arrow.down", priority: .high,
        // Only the captures a production import actually emits: parser identity, file meta, per-stage
        // rows, reject counts and day deltas. firstFailingRow / failingFileSample / dedupMerge were
        // advertised but no emitter on either platform produces them (the import emit runs after the full
        // parse, not at the parser reject seam), so they were dropped from BOTH registries to keep the
        // mode honest and the platforms in parity rather than over-promising.
        captures: ["parserVersion", "fileMeta", "perStageRows", "rejectCounts", "dayDeltas"],
        questionnaire: [
            Question(id: "appFormatExpected", prompt: "Which app/format, and what did you expect to import?", kind: .text),
        ],
        liveReadout: ["lastImportSummary"],
        capture: .toggle,
        includesScreenshot: false, requires5MG: false)

    static let steps = TestMode(
        domain: .steps, title: "Steps",
        blurb: "Turn this on if your step count looks off versus your phone.",
        icon: "shoeprints.fill", priority: .high,
        captures: ["motionVolume", "stepCalibration", "phoneReferenceCount", "rawStepCounter",
                   "wrapAwareDeltas", "droppedDeltas"],
        questionnaire: [
            Question(id: "otherTrackerSteps", prompt: "What did your phone or another tracker report for the same day?", kind: .text),
        ],
        liveReadout: ["stepsToday", "calibrationState"],
        capture: .toggle,
        includesScreenshot: false, requires5MG: false)

    static let battery = TestMode(
        domain: .battery, title: "Battery & Charging",
        blurb: "Wear it a few days so we can fit your real discharge slope.",
        icon: "battery.50", priority: .med,
        captures: ["socSeries", "chargeSteps", "offWristGaps", "dischargeRun", "fittedSlope",
                   "sourceMeasuredVsRated", "batteryGates"],
        questionnaire: [
            Question(id: "whoopAppInstalled", prompt: "Is the official WHOOP app installed?", kind: .yesNo),
            Question(id: "otherPhonePaired", prompt: "Is another phone paired to the strap?", kind: .yesNo),
            Question(id: "chargedInWindow", prompt: "Did you charge during the capture?", kind: .yesNo),
            Question(id: "batterySaverApps", prompt: "Any battery-saver apps running?", kind: .text),
        ],
        liveReadout: ["currentSoc", "estimateDaysLeft", "slopeSource"],
        capture: .guided(unit: .days, defaultCount: 3),
        includesScreenshot: false, requires5MG: false)

    static let recovery = TestMode(
        domain: .recovery, title: "Recovery (Charge)",
        blurb: "Turn this on if Charge looks wrong, to see which term moved it.",
        icon: "heart.text.square.fill", priority: .med,
        captures: ["chargeTermBreakdown", "baselinesPerNight", "termZScores", "nilTerm",
                   "forecastInputs"],
        questionnaire: [
            Question(id: "recalHealthHrv", prompt: "Recent recalibration? Is Apple Health / Health Connect feeding HRV?", kind: .text),
        ],
        liveReadout: ["lastChargeBreakdown"],
        capture: .toggle,
        includesScreenshot: false, requires5MG: false)

    static let hrv = TestMode(
        domain: .hrv, title: "HRV & Autonomic",
        blurb: "Turn this on if HRV reads nil or looks off, to see the clean beats.",
        icon: "waveform.path.ecg", priority: .med,
        captures: ["rawRR", "nInputCleanRejected", "rmssdSdnn", "minBeatsCleared",
                   "spotVsContinuous", "respRsa"],
        questionnaire: [
            Question(id: "otherAppHrv", prompt: "Is another app feeding HRV to Apple Health / Health Connect?", kind: .yesNo),
        ],
        liveReadout: ["lastHrvComputation"],
        capture: .toggle,
        includesScreenshot: false, requires5MG: false)
}
