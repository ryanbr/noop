import XCTest
@testable import StrandAnalytics

final class TestModeRegistryTests: XCTestCase {

    func testRegistryOrderAndIds() {
        // Phase 1 shipped sleep + battery; Phase 2 appended the 5 high-pain domains plus recovery + hrv.
        // Screen priority order: sleep, connection, workouts, display, import, steps, battery, recovery, hrv.
        XCTAssertEqual(TestModeRegistry.all.map(\.domain),
                       [.sleep, .connection, .workouts, .display, .dataImport, .steps, .battery, .recovery, .hrv])
        XCTAssertEqual(TestModeRegistry.all.map(\.id),
                       ["sleep", "connection", "workouts", "display", "import", "steps", "battery", "recovery", "hrv"])
        XCTAssertEqual(TestModeRegistry.all.count, 9)
    }

    func testLookupByDomain() {
        XCTAssertEqual(TestModeRegistry.mode(.sleep)?.title, "Sleep & Rest")
        XCTAssertEqual(TestModeRegistry.mode(.connection)?.title, "Connection & Sync")
        XCTAssertEqual(TestModeRegistry.mode(.workouts)?.title, "Workouts & GPS")
        XCTAssertEqual(TestModeRegistry.mode(.display)?.title, "Display & Performance")
        XCTAssertEqual(TestModeRegistry.mode(.dataImport)?.title, "Import & Data Ingest")
        XCTAssertEqual(TestModeRegistry.mode(.steps)?.title, "Steps")
        XCTAssertEqual(TestModeRegistry.mode(.battery)?.title, "Battery & Charging")
        XCTAssertEqual(TestModeRegistry.mode(.recovery)?.title, "Recovery (Charge)")
        XCTAssertEqual(TestModeRegistry.mode(.hrv)?.title, "HRV & Autonomic")
        XCTAssertNil(TestModeRegistry.mode(.notifications))
    }

    func testSleepCaptureSet() {
        XCTAssertEqual(TestModeRegistry.mode(.sleep)?.captures, [
            "gateTrace", "gravityCoverage", "hrDensity", "wristOff", "perEpochFeatures",
            "hypnogramV1V2", "ppgOnlyNight", "skinTempDsp", "restSubScores",
        ])
    }

    func testSleepIsGuidedThreeNights() {
        guard case .guided(let unit, let count)? = TestModeRegistry.mode(.sleep)?.capture else {
            return XCTFail("sleep should be guided")
        }
        XCTAssertEqual(unit, .nights)
        XCTAssertEqual(count, 3)
    }

    func testBatteryIsGuidedThreeDays() {
        guard case .guided(let unit, let count)? = TestModeRegistry.mode(.battery)?.capture else {
            return XCTFail("battery should be guided")
        }
        XCTAssertEqual(unit, .days)
        XCTAssertEqual(count, 3)
    }

    func testBatteryCaptureSetAndReadout() {
        XCTAssertEqual(TestModeRegistry.mode(.battery)?.captures, [
            "socSeries", "chargeSteps", "offWristGaps", "dischargeRun", "fittedSlope",
            "sourceMeasuredVsRated", "batteryGates",
        ])
        XCTAssertEqual(TestModeRegistry.mode(.battery)?.liveReadout, ["currentSoc", "estimateDaysLeft", "slopeSource"])
    }

    func testSleepQuestionnaireKeys() {
        XCTAssertEqual(TestModeRegistry.mode(.sleep)?.questionnaire.map(\.id), [
            "sleepTimes", "awakeStill", "naps", "shiftWork", "chargeTiming", "healthSleep",
        ])
    }

    func testScreenshotAndRequires5MGFlags() {
        // Only Display & Performance carries a screenshot; nothing registered yet requires 5/MG.
        for m in TestModeRegistry.all {
            XCTAssertFalse(m.requires5MG, "\(m.id) should not require 5/MG")
            XCTAssertEqual(m.includesScreenshot, m.domain == .display, "\(m.id) screenshot flag")
        }
    }

    func testPhase2HighPainAreToggles() {
        for d in [TestDomain.connection, .workouts, .display, .dataImport, .steps, .recovery, .hrv] {
            XCTAssertEqual(TestModeRegistry.mode(d)?.capture, .toggle, "\(d.id) should be a plain toggle")
        }
    }

    func testPhase2Priorities() {
        XCTAssertEqual(TestModeRegistry.mode(.connection)?.priority, .high)
        XCTAssertEqual(TestModeRegistry.mode(.workouts)?.priority, .high)
        XCTAssertEqual(TestModeRegistry.mode(.display)?.priority, .high)
        XCTAssertEqual(TestModeRegistry.mode(.dataImport)?.priority, .high)
        XCTAssertEqual(TestModeRegistry.mode(.steps)?.priority, .high)
        XCTAssertEqual(TestModeRegistry.mode(.recovery)?.priority, .med)
        XCTAssertEqual(TestModeRegistry.mode(.hrv)?.priority, .med)
    }

    func testPhase2CaptureSets() {
        XCTAssertEqual(TestModeRegistry.mode(.connection)?.captures, [
            "connectTiming", "bondState", "frameTiming", "reconnectChurn", "offloadProgress",
            "offloadStalls", "firmwareDecode", "clockDrift", "otherCentral",
        ])
        XCTAssertEqual(TestModeRegistry.mode(.workouts)?.captures, [
            "sessionLifecycle", "hrSamples", "gpsFixes", "autoDetectThresholds",
            "autoDetectWhy", "crossSourceDedup",
        ])
        XCTAssertEqual(TestModeRegistry.mode(.display)?.captures, [
            "screenshot", "deviceMetrics", "frameTimeTrace", "memoryHighWater",
        ])
        XCTAssertEqual(TestModeRegistry.mode(.dataImport)?.captures, [
            "parserVersion", "fileMeta", "perStageRows", "rejectCounts", "dayDeltas",
        ])
        XCTAssertEqual(TestModeRegistry.mode(.steps)?.captures, [
            "motionVolume", "stepCalibration", "phoneReferenceCount", "rawStepCounter",
            "wrapAwareDeltas", "droppedDeltas",
        ])
        XCTAssertEqual(TestModeRegistry.mode(.recovery)?.captures, [
            "chargeTermBreakdown", "baselinesPerNight", "termZScores", "nilTerm", "forecastInputs",
        ])
        XCTAssertEqual(TestModeRegistry.mode(.hrv)?.captures, [
            "rawRR", "nInputCleanRejected", "rmssdSdnn", "minBeatsCleared", "spotVsContinuous", "respRsa",
        ])
    }

    func testPhase2QuestionnaireIdsAndKinds() {
        XCTAssertEqual(TestModeRegistry.mode(.connection)?.questionnaire.map(\.id), ["otherDevicePaired"])
        XCTAssertEqual(TestModeRegistry.mode(.connection)?.questionnaire.first?.kind, .yesNo)
        XCTAssertEqual(TestModeRegistry.mode(.workouts)?.questionnaire.map(\.id), ["startMethod"])
        XCTAssertEqual(TestModeRegistry.mode(.workouts)?.questionnaire.first?.kind, .text)
        XCTAssertEqual(TestModeRegistry.mode(.display)?.questionnaire.map(\.id), ["screenAndIssue"])
        XCTAssertEqual(TestModeRegistry.mode(.display)?.questionnaire.first?.kind, .text)
        XCTAssertEqual(TestModeRegistry.mode(.dataImport)?.questionnaire.map(\.id), ["appFormatExpected"])
        XCTAssertEqual(TestModeRegistry.mode(.dataImport)?.questionnaire.first?.kind, .text)
        XCTAssertEqual(TestModeRegistry.mode(.steps)?.questionnaire.map(\.id), ["otherTrackerSteps"])
        XCTAssertEqual(TestModeRegistry.mode(.steps)?.questionnaire.first?.kind, .text)
        XCTAssertEqual(TestModeRegistry.mode(.recovery)?.questionnaire.map(\.id), ["recalHealthHrv"])
        XCTAssertEqual(TestModeRegistry.mode(.recovery)?.questionnaire.first?.kind, .text)
        XCTAssertEqual(TestModeRegistry.mode(.hrv)?.questionnaire.map(\.id), ["otherAppHrv"])
        XCTAssertEqual(TestModeRegistry.mode(.hrv)?.questionnaire.first?.kind, .yesNo)
    }

    func testPhase2LiveReadoutIds() {
        XCTAssertEqual(TestModeRegistry.mode(.connection)?.liveReadout,
                       ["connectionUptime", "reconnectCount", "lastOffloadResult"])
        XCTAssertEqual(TestModeRegistry.mode(.workouts)?.liveReadout, ["lastSessionSummary"])
        XCTAssertEqual(TestModeRegistry.mode(.display)?.liveReadout, ["deviceMetricsNow"])
        XCTAssertEqual(TestModeRegistry.mode(.dataImport)?.liveReadout, ["lastImportSummary"])
        XCTAssertEqual(TestModeRegistry.mode(.steps)?.liveReadout, ["stepsToday", "calibrationState"])
        XCTAssertEqual(TestModeRegistry.mode(.recovery)?.liveReadout, ["lastChargeBreakdown"])
        XCTAssertEqual(TestModeRegistry.mode(.hrv)?.liveReadout, ["lastHrvComputation"])
    }

    func testNoQuestionnairePromptHasEmDash() {
        for m in TestModeRegistry.all {
            for q in m.questionnaire {
                XCTAssertFalse(q.prompt.contains("\u{2014}"), "\(m.id)/\(q.id) prompt has an em-dash")
            }
            XCTAssertFalse(m.blurb.contains("\u{2014}"), "\(m.id) blurb has an em-dash")
        }
    }
}

// MARK: - Group E (Sleep & Rest): pin the questionnaire kinds + live-readout ids against drift.
// The ids are meta.json keys and the readout ids the panel binds; a later edit that renames or drops
// one must fail here. The id ORDER is already covered by TestModeRegistryTests.testSleepQuestionnaireKeys.

final class TestModeRegistrySleepTests: XCTestCase {
    func testSleepQuestionnaireIdsAndKinds() {
        let sleep = TestModeRegistry.mode(.sleep)!
        XCTAssertEqual(sleep.questionnaire.map(\.id),
                       ["sleepTimes", "awakeStill", "naps", "shiftWork", "chargeTiming", "healthSleep"])
        XCTAssertEqual(sleep.questionnaire.first { $0.id == "shiftWork" }?.kind, .yesNo)
        XCTAssertEqual(sleep.questionnaire.first { $0.id == "healthSleep" }?.kind, .yesNo)
        XCTAssertEqual(sleep.questionnaire.first { $0.id == "sleepTimes" }?.kind, .text)
        XCTAssertEqual(sleep.questionnaire.first { $0.id == "naps" }?.kind, .text)
        // No em-dash in any prompt (the writing-voice rule applies to user-facing strings too).
        XCTAssertFalse(sleep.questionnaire.contains { $0.prompt.contains("\u{2014}") })
    }

    func testSleepLiveReadoutIds() {
        let sleep = TestModeRegistry.mode(.sleep)!
        XCTAssertEqual(sleep.liveReadout, ["hrDensityNow", "gravityCoverageNow", "lastNightGateFired"])
    }
}
