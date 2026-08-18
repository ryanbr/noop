import XCTest
@testable import Strand

/// "Low refresh" (Settings → Power saving sub-option) moves the BASE periodic-offload cadence from 15 min
/// to 60 min. The invariant that matters is COMPOSITION: every other lever stretches FROM that base with
/// `max`, so no lever can ever hand back a faster cadence than the user asked for, and a lever that would
/// have stretched a 15-min base is a no-op once the base is already longer.
///
/// Cadence only, by design: low refresh deliberately does NOT touch the keep-alive (that tick re-arms the
/// WHOOP 4 realtime burst each cycle and evaluates the 120 s stall fuse) and does NOT release continuous
/// HRV capture (that is the separate "Pause HRV capture" lever / #927's overnight window). Those are the
/// two places a quieter radio would cost real data rather than merely delaying it.
//
// BLEManager is @MainActor, so its static helpers are main-actor-isolated; the test methods must run on
// the main actor to call them (matches Whoop5BatteryBackfillThrottleTests etc.). Class-level @MainActor
// covers all.
@MainActor
final class LowRefreshCadenceTests: XCTestCase {

    func testBaseIsFifteenMinutesWhenOff() {
        XCTAssertEqual(BLEManager.baseBackfillInterval(lowRefresh: false), BLEManager.backfillIntervalSeconds)
        XCTAssertEqual(BLEManager.backfillIntervalSeconds, 900)
    }

    func testBaseIsHourlyWhenOn() {
        XCTAssertEqual(BLEManager.baseBackfillInterval(lowRefresh: true), BLEManager.lowRefreshBackfillIntervalSeconds)
        XCTAssertEqual(BLEManager.lowRefreshBackfillIntervalSeconds, 3600)
    }

    /// The low-battery lever (45 min) is SHORTER than low refresh (60 min): composed with `max` it must
    /// leave the hourly cadence alone rather than speeding it back up.
    func testLowBatteryLeverNeverShortensLowRefresh() {
        let base = BLEManager.baseBackfillInterval(lowRefresh: true)
        let composed = BLEManager.offloadInterval(
            baseSeconds: base,
            lowSeconds: max(base, BLEManager.lowBatteryBackfillIntervalSeconds),
            batteryPct: 10, charging: false, thresholdPct: 20)   // lever fully engaged
        XCTAssertEqual(composed, BLEManager.lowRefreshBackfillIntervalSeconds)
    }

    /// Without low refresh the same engaged lever still stretches 15 → 45 min, i.e. this change is inert
    /// for everyone who does not turn it on.
    func testDefaultBehaviourIsUnchangedWhenOff() {
        let base = BLEManager.baseBackfillInterval(lowRefresh: false)
        XCTAssertEqual(
            BLEManager.offloadInterval(baseSeconds: base,
                                       lowSeconds: max(base, BLEManager.lowBatteryBackfillIntervalSeconds),
                                       batteryPct: 10, charging: false, thresholdPct: 20),
            BLEManager.lowBatteryBackfillIntervalSeconds)
        // …and an idle/charged strap keeps the plain 15-min cadence.
        XCTAssertEqual(
            BLEManager.offloadInterval(baseSeconds: base,
                                       lowSeconds: max(base, BLEManager.lowBatteryBackfillIntervalSeconds),
                                       batteryPct: 90, charging: false, thresholdPct: 20),
            BLEManager.backfillIntervalSeconds)
    }

    /// The 5/MG empty-history stretch (45 min) composes the same way: it may quieten a 15-min base, but
    /// must not pull an already-hourly cadence back down.
    func testWhoop5EmptyHistoryStretchNeverShortensLowRefresh() {
        let base = BLEManager.baseBackfillInterval(lowRefresh: true)
        XCTAssertEqual(
            BLEManager.whoop5EmptyHistoryBackfillInterval(
                baseSeconds: base,
                lowSeconds: max(base, BLEManager.lowBatteryBackfillIntervalSeconds),
                historyEmpty: true),
            BLEManager.lowRefreshBackfillIntervalSeconds)
    }
}
