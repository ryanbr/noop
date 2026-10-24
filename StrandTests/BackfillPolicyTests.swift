import XCTest
import CryptoKit
@testable import Strand

/// `BackfillPolicy` rate-limiter, incl. the empty-streak backoff that stops an off-wrist / not-banking
/// strap from being re-offloaded every event floor (#77/#120/#216). Pure value logic, no CoreBluetooth seam.
final class BackfillPolicyTests: XCTestCase {
    private let fe = BackfillPolicy.eventFloorSeconds      // 90
    private let fp = BackfillPolicy.periodicFloorSeconds   // 900

    // Compiled from the production Swift helper with swiftc; Kotlin pins the same 5,760 outcomes.
    func testPowerSavingDecisionOracle() {
        let triggers: [BackfillTrigger] = [.periodic, .connect, .foreground, .manual, .strap, .autoContinue]
        let times: [Double] = [-1, 0, 89, 90, 479, 480, 899, 900, 1799, 1800, 2699, 2700, 3599, 3600, 7199, 7200]
        var bits = Data()
        for trigger in triggers {
            for last: Double? in [nil, 0] {
                for now in times {
                    for streak in [0, 2, 3, 4, 99] {
                        for untrusted in [false, true] {
                            for floor in [0.0, 2700.0, 3600.0] {
                                let run = BackfillPolicy.shouldRun(trigger: trigger, now: now,
                                    lastBackfillAt: last, emptyStreak: streak, clockUntrusted: untrusted,
                                    automaticFloorSeconds: floor)
                                bits.append(run ? 49 : 48)
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(bits.count, 5760)
        XCTAssertEqual(SHA256.hash(data: bits).map { String(format: "%02x", $0) }.joined(),
            "66d75a86f19bc42e51993cc47554f4cc514267e071953b79670a3b771c3766f9")
    }

    func testLowRefreshCannotBeBypassedByStrapEvents() {
        var last = 0.0
        var starts: [Int] = []
        for now in stride(from: 90, through: 7200, by: 90) {
            if BackfillPolicy.shouldRun(trigger: .strap, now: Double(now), lastBackfillAt: last,
                                        automaticFloorSeconds: 3600) {
                starts.append(now)
                last = Double(now)
            }
        }
        XCTAssertEqual(starts, [3600, 7200])
    }

    func testPowerSavingFloorsBothAutomaticTriggersAtTheBoundary() {
        for trigger in [BackfillTrigger.strap, .periodic] {
            for floor in [2700.0, 3600.0] {
                XCTAssertFalse(BackfillPolicy.shouldRun(trigger: trigger, now: floor - 1,
                    lastBackfillAt: 0, automaticFloorSeconds: floor))
                XCTAssertTrue(BackfillPolicy.shouldRun(trigger: trigger, now: floor,
                    lastBackfillAt: 0, automaticFloorSeconds: floor))
            }
        }
        // A manual sync becomes the new reference for subsequent automatic attempts too.
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .manual, now: 600,
            lastBackfillAt: 0, automaticFloorSeconds: 3600))
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .strap, now: 3600,
            lastBackfillAt: 600, automaticFloorSeconds: 3600))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .strap, now: 4200,
            lastBackfillAt: 600, automaticFloorSeconds: 3600))
    }

    func testPowerSavingNeverDelaysRecoveryOrAnActiveDrain() {
        for trigger in [BackfillTrigger.connect, .foreground, .manual, .autoContinue] {
            XCTAssertTrue(BackfillPolicy.shouldRun(trigger: trigger, now: 90,
                lastBackfillAt: 0, emptyStreak: 99, clockUntrusted: true, automaticFloorSeconds: 3600))
        }
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .strap, now: 1,
            lastBackfillAt: nil, automaticFloorSeconds: 3600))
    }

    func testPowerSavingComposesWithEmptyBackoffAndUntrustedClock() {
        // Existing periodic backoff (3600 s) wins over low-battery saving (2700 s).
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .periodic, now: 2700,
            lastBackfillAt: 0, emptyStreak: 5, automaticFloorSeconds: 2700))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .periodic, now: 3600,
            lastBackfillAt: 0, emptyStreak: 5, automaticFloorSeconds: 2700))
        // Hourly saving wins over the event backoff, without multiplying it to four hours.
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .strap, now: 3600,
            lastBackfillAt: 0, emptyStreak: 99, automaticFloorSeconds: 3600))
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .strap, now: 7200,
            lastBackfillAt: 0, clockUntrusted: true, automaticFloorSeconds: 3600))
    }

    func testFirstSyncAlwaysRuns() {
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .periodic, now: 1000, lastBackfillAt: nil))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: nil))
    }

    func testManualAlwaysRunsRegardlessOfFloorOrStreak() {
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .manual, now: 1000, lastBackfillAt: 999, emptyStreak: 99))
    }

    // #364: the expedited auto-continue is deliberately un-floored like .manual — it must run even
    // immediately after the previous backfill (a 60s session just ended). Its runaway protection lives in
    // BLEManager's consecutive-cap + trim spin-detector, NOT in this policy, so the floor must NOT block it.
    func testAutoContinueAlwaysRunsRegardlessOfFloorOrStreak() {
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .autoContinue, now: 1000, lastBackfillAt: 999, emptyStreak: 99))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .autoContinue, now: 1000, lastBackfillAt: 1000))
    }

    func testBaselineFloors() {
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: 1000 - fe + 1))
        XCTAssertTrue (BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: 1000 - fe))
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .periodic, now: 10000, lastBackfillAt: 10000 - fp + 1))
        XCTAssertTrue (BackfillPolicy.shouldRun(trigger: .periodic, now: 10000, lastBackfillAt: 10000 - fp))
    }

    func testEmptyStreakBacksOffStrap() {
        // 200s elapsed: passes at baseline (floor 90), blocked once the 4x cap applies (floor 360).
        let last = 1000.0 - 200
        XCTAssertTrue (BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: last, emptyStreak: 0))
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: last, emptyStreak: 5))
    }

    func testBackoffIsGraduatedThenCapped() {
        // streak 3 → 2x floor (180s): 100s elapsed passes at baseline, blocked at 2x.
        let last = 1000.0 - 100
        XCTAssertTrue (BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: last, emptyStreak: 0))
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: last, emptyStreak: 3))
        // cap holds: a huge streak never stretches beyond 4x (floor 360); 360s elapsed still passes.
        XCTAssertTrue (BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: 1000 - fe * 4, emptyStreak: 99))
    }

    func testBackoffNeverDelaysConnectOrForeground() {
        let last = 1000 - fe   // exactly at the baseline event floor
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .connect, now: 1000, lastBackfillAt: last, emptyStreak: 99))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .foreground, now: 1000, lastBackfillAt: last, emptyStreak: 99))
    }

    // MARK: - #160: future-dated clock backoff

    /// #160: a future-dated-clock strap's recurring automatic offloads are SKIPPED ENTIRELY (not just
    /// throttled) — each ~60s offload starves the WHOOP4 realtime-HR re-arm, and #1012 won't trust the
    /// range anyway. `.strap` never runs while `clockUntrusted`, no matter how long since the last pass.
    func testClockUntrustedSkipsStrapEntirely() {
        // A huge elapsed that would trivially pass every floor: still skipped when the clock is untrusted.
        XCTAssertTrue (BackfillPolicy.shouldRun(trigger: .strap, now: 1_000_000, lastBackfillAt: 0,
                                                emptyStreak: 0, clockUntrusted: false))
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .strap, now: 1_000_000, lastBackfillAt: 0,
                                                emptyStreak: 0, clockUntrusted: true))
    }

    func testClockUntrustedSkipsPeriodicEntirely() {
        XCTAssertTrue (BackfillPolicy.shouldRun(trigger: .periodic, now: 1_000_000, lastBackfillAt: 0,
                                                clockUntrusted: false))
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .periodic, now: 1_000_000, lastBackfillAt: 0,
                                                clockUntrusted: true))
    }

    /// The skip is independent of `emptyStreak`: a clock-untrusted strap that is ALSO banking real rows
    /// (emptyStreak 0) is skipped just the same as one with a long empty streak.
    func testClockUntrustedSkipRegardlessOfEmptyStreak() {
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .strap, now: 1_000_000, lastBackfillAt: 0,
                                                emptyStreak: 0, clockUntrusted: true))
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .periodic, now: 1_000_000, lastBackfillAt: 0,
                                                emptyStreak: 99, clockUntrusted: true))
    }

    /// clockUntrusted must never delay a user- or connection-driven sync — the .connect pass is exactly
    /// how a self-corrected clock gets picked up again after the automatic triggers were skipped.
    func testClockUntrustedNeverDelaysConnectForegroundManualOrAutoContinue() {
        let last = 1000 - fe
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .connect, now: 1000, lastBackfillAt: last, clockUntrusted: true))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .foreground, now: 1000, lastBackfillAt: last, clockUntrusted: true))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .manual, now: 1000, lastBackfillAt: 999, clockUntrusted: true))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .autoContinue, now: 1000, lastBackfillAt: 999, clockUntrusted: true))
    }
}
