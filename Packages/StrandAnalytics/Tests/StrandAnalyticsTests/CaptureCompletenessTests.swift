import XCTest
@testable import StrandAnalytics

/// The report-completeness guard (#812, generalised): an ACTIVE domain whose killer trace landed reads OK;
/// an ACTIVE domain that produced no trace reads INCOMPLETE (the dead-trace warning). Also pins the token
/// map against the verbatim emitter tokens so a renamed emitter can't silently make the guard blind.
final class CaptureCompletenessTests: XCTestCase {

    // A report fragment carrying a real line per domain, in the exact shape the live emitters write.
    private let fullReport = """
    [sleep] gate run=2 spanS=1800 kept gate=arousal still in bed
    [sleep] sleepProvenance provenance=measured hoursAsleep=7 sourceRowId=42
    [connection] clockDrift newest=2026-06-28 02:00:00 wall=2026-06-28 02:01:00 newestVsWall=-60s clockOk
    [connection] bondState client-hello acked
    [workouts] autoDetect result windows=1 offered=1
    [workouts] session event=start sport=run hrSamples=120
    [display] dataVolume dbRows=900 importedDays=30 cacheRows=12
    [display] frameSummary frames=120 mean=8.0ms p95=16.0ms hitches=2 worst=40.0ms threshold=33.0ms
    [import] import stage=sleep rowsIn=10 rowsOut=10
    [steps] stepsRaw day=2026-06-28 counterSamples=4 deltas kept=3 dropped=0
    [battery] bank soc=82.0 t=1700000000s
    [recovery] charge day=2026-06-28 term hrv z=0.20 w=0.40 (higher HRV is better)
    [hrv] hrv rmssd=42.10ms sdnn=55.00ms meanNN=900.00ms
    [universal] dayOwner day=2026-06-28 readId=my-whoop writeActiveId=my-whoop hrRows=120 provenance=measured
    """

    func testActiveDomainWithTraceIsOK() {
        let checks = CaptureCompleteness.evaluate(activeDomains: [.sleep, .universal], reportText: fullReport)
        let sleep = checks.first { $0.domain == "sleep" }
        XCTAssertEqual(sleep?.status, .ok)
        XCTAssertEqual(sleep?.count, 2, "both gate run= and sleepProvenance lines should count")
        let universal = checks.first { $0.domain == "universal" }
        XCTAssertEqual(universal?.status, .ok)
        XCTAssertEqual(universal?.count, 1)
    }

    func testActiveDomainWithoutTraceIsIncomplete() {
        // Battery mode was on but NO `bank soc=` / `socSeries` line landed (a dead capture).
        let report = "[sleep] gate run=1 spanS=900 kept gate=onset\n[universal] dayOwner day=2026-06-28 readId=x writeActiveId=x hrRows=0 provenance=none"
        let checks = CaptureCompleteness.evaluate(activeDomains: [.battery, .universal], reportText: report)
        let battery = checks.first { $0.domain == "battery" }
        XCTAssertEqual(battery?.status, .incomplete)
        XCTAssertEqual(battery?.count, 0)
        XCTAssertEqual(battery?.tokens, ["bank soc=", "socSeries"], "the INCOMPLETE row names the missing tokens")
        // The universal trace DID land, so it stays OK even though battery is INCOMPLETE.
        XCTAssertEqual(checks.first { $0.domain == "universal" }?.status, .ok)
        XCTAssertTrue(CaptureCompleteness.anyIncomplete(checks))
    }

    func testUniversalOKFromClockDriftAloneWhenNoScoringPassRan() {
        // No scoring pass during the capture means no `dayOwner` line, but the universal clock-drift line
        // still rides the export, so universal must read OK off `strapClock` alone.
        let report = "[universal] strapClock newest=2026-06-28 00:00:00 wall=2026-06-28 00:01:00 newestVsWall=-60s firmware=v25 clockOk"
        let checks = CaptureCompleteness.evaluate(activeDomains: [.universal], reportText: report)
        XCTAssertEqual(checks.first { $0.domain == "universal" }?.status, .ok)
    }

    func testInactiveDomainIsNotGraded() {
        // Only sleep was active; connection has lines in the report but was OFF, so it must not appear.
        let checks = CaptureCompleteness.evaluate(activeDomains: [.sleep], reportText: fullReport)
        XCTAssertNil(checks.first { $0.domain == "connection" })
        XCTAssertEqual(checks.map { $0.domain }, ["sleep"])
    }

    func testDomainWithNoRegisteredTokensIsSkipped() {
        // notifications has no emitter / no token map entry, so an active-but-ungradable domain is skipped
        // rather than flagged INCOMPLETE (we never promised it a trace).
        let checks = CaptureCompleteness.evaluate(activeDomains: [.notifications, .universal],
                                                  reportText: fullReport)
        XCTAssertNil(checks.first { $0.domain == "notifications" })
        XCTAssertEqual(checks.first { $0.domain == "universal" }?.status, .ok)
    }

    func testEveryRegisteredDomainGradesOKOnTheFullReport() {
        let all: Set<TestDomain> = [.sleep, .connection, .workouts, .display, .dataImport,
                                    .steps, .battery, .recovery, .hrv, .universal]
        let checks = CaptureCompleteness.evaluate(activeDomains: all, reportText: fullReport)
        XCTAssertEqual(checks.count, all.count)
        for c in checks {
            XCTAssertEqual(c.status, .ok, "\(c.domain) should match its token in the full report")
        }
        XCTAssertFalse(CaptureCompleteness.anyIncomplete(checks))
    }

    func testStableOrderUniversalLast() {
        let all: Set<TestDomain> = [.universal, .battery, .sleep]
        let order = CaptureCompleteness.evaluate(activeDomains: all, reportText: fullReport).map { $0.domain }
        XCTAssertEqual(order, ["sleep", "battery", "universal"], "registry order, universal last")
    }

    func testReportSectionRendersOKAndIncomplete() {
        let report = "[sleep] gate run=1 spanS=900 kept gate=onset"
        let checks = CaptureCompleteness.evaluate(activeDomains: [.sleep, .battery], reportText: report)
        let section = CaptureCompleteness.reportSection(checks)
        XCTAssertTrue(section.contains("Capture check"))
        XCTAssertTrue(section.contains("[OK] sleep:"))
        XCTAssertTrue(section.contains("[INCOMPLETE] battery: mode was on but produced NO trace"))
        XCTAssertTrue(section.contains("bank soc="), "the missing token is named")
        XCTAssertFalse(section.contains("\u{2014}"), "no em-dashes")
    }

    func testEmptyChecksRenderNoSection() {
        XCTAssertEqual(CaptureCompleteness.reportSection([]), "")
    }

    func testSleepOKFromComputedProvenanceLineWithoutGateTrace() {
        // #127: `gate run=` / `sleepProvenance` only emit when the sleep-stager gate re-runs under the SLEEP
        // trace sink; a night scored on the backfill/post-sync pass (or already scored) won't re-fire them.
        // The always-on per-day `sleep day=` diagnostic still proves sleep was computed, so the capture must
        // read OK rather than INCOMPLETE. This is the exact #127 report shape (no gate run=).
        let report = """
        [universal] dayOwner day=2026-07-09 readId=my-whoop writeActiveId=my-whoop hrRows=27001 provenance=measured
        sleep day=2026-07-09 totalSleepMin=426 matched=1 source=computed
        """
        let checks = CaptureCompleteness.evaluate(activeDomains: [.sleep, .universal], reportText: report)
        XCTAssertEqual(checks.first { $0.domain == "sleep" }?.status, .ok,
                       "a computed-sleep capture is not INCOMPLETE even without the gate trace")
        XCTAssertFalse(CaptureCompleteness.anyIncomplete(checks))
    }

    func testSleepStillIncompleteWithNoSleepDiagnosticAtAll() {
        // The guard still fires when the capture carries NO sleep evidence of any kind.
        let report = "[universal] dayOwner day=2026-07-09 readId=x writeActiveId=x hrRows=0 provenance=none"
        let checks = CaptureCompleteness.evaluate(activeDomains: [.sleep, .universal], reportText: report)
        XCTAssertEqual(checks.first { $0.domain == "sleep" }?.status, .incomplete)
    }

    func testTokenMapMatchesEmitterTokensExactly() {
        // Guard against a silent emitter rename: each token must be the verbatim leading text that
        // reaches the REPORT.
        //
        // "mirror the *Trace files" is how the recovery token came to be wrong for as long as it was.
        // RecoveryScorer+Trace really does write "charge term ...", but IntelligenceEngine re-emits
        // every one of those lines as `charge day=<day> ` + the body before it is logged, so the
        // literal this guard was protecting could not occur in a single report. A token has to mirror
        // the END of the pipeline, not the start, or a guard like this passes while the thing it
        // guards is dead.
        XCTAssertEqual(CaptureCompleteness.expectedTokens(for: .recovery).first, "charge day=")
        XCTAssertTrue(CaptureCompleteness.expectedTokens(for: .hrv).contains("hrv rmssd="))
        XCTAssertTrue(CaptureCompleteness.expectedTokens(for: .steps).contains("stepsRaw"))
        XCTAssertTrue(CaptureCompleteness.expectedTokens(for: .universal).contains("dayOwner "))
        XCTAssertTrue(CaptureCompleteness.expectedTokens(for: .universal).contains("strapClock "))
        XCTAssertTrue(CaptureCompleteness.expectedTokens(for: .dataImport).contains("rowsIn="))
    }
}
