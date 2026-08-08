import XCTest
@testable import Strand

/// #battery: pins the two 5/MG battery-drain fixes.
///
/// 1. `shouldPollWhoop5Battery` — the 5/MG 0x2A19 battery read was issued every ~30 s by the keep-alive
///    tick (2 880 GATT reads/day, 2× the Android twin's ~60 s cadence and 20× finer than the
///    BatteryEstimator's 600 s same-% throttle). This throttle spaces it to ~60 s while still reading
///    promptly on the first call of a connection (post-bond / CLIENT_HELLO-ack) and after a disconnect
///    re-seed.
///
/// 2. `whoop5EmptyHistoryBackfillInterval` — a 5/MG whose history offload is known-empty (experimental on
///    5.0) is stretched to the 45-min low-battery floor regardless of battery %, so the 15-min periodic
///    kick stops holding the link ~60 s for zero data. Engages after the tracker's 2-empty threshold
///    (one cycle earlier than the BackfillPolicy 3-empty backoff) and stacks with it.
///
/// Pure static logic → no CoreBluetooth seam. Twin of Android `nextBackfillDelayMs`'s
/// `whoop5EmptyOffload.historyEmpty` branch.
// BLEManager is @MainActor, so its static helpers are main-actor-isolated; the test methods must run on
// the main actor to call them (matches BackfillerSessionTallyTests etc.). Class-level @MainActor covers all.
@MainActor
final class Whoop5BatteryBackfillThrottleTests: XCTestCase {

    // MARK: - 5/MG battery-read throttle

    // No prior read → always poll (the first read of a connection, post-bond / CLIENT_HELLO-ack, or after
    // a disconnect re-seed). This is what makes the prompt connect-time reads still fire.
    func testFirstReadAlwaysPolls() {
        XCTAssertTrue(BLEManager.shouldPollWhoop5Battery(lastReadAt: nil))
    }

    // Under the 60 s floor → blocked. The 30 s keep-alive tick no longer re-reads every cycle.
    func testUnderFloorBlocked() {
        let now = Date()
        let last = now.addingTimeInterval(-29)
        XCTAssertFalse(BLEManager.shouldPollWhoop5Battery(lastReadAt: last, now: now))
    }

    // At exactly the floor → polls (>= is the boundary).
    func testAtFloorPolls() {
        let now = Date()
        let last = now.addingTimeInterval(-BLEManager.whoop5BatteryReadMinIntervalSeconds)
        XCTAssertTrue(BLEManager.shouldPollWhoop5Battery(lastReadAt: last, now: now))
    }

    // Past the floor → polls.
    func testPastFloorPolls() {
        let now = Date()
        let last = now.addingTimeInterval(-BLEManager.whoop5BatteryReadMinIntervalSeconds - 1)
        XCTAssertTrue(BLEManager.shouldPollWhoop5Battery(lastReadAt: last, now: now))
    }

    // The floor matches the Android twin's ~60 s cadence (keepAliveTick % 2 == 0 on a 30 s timer).
    func testFloorMatchesAndroidCadence() {
        XCTAssertEqual(BLEManager.whoop5BatteryReadMinIntervalSeconds, 60)
        XCTAssertEqual(BLEManager.keepAliveIntervalSeconds, 30)
    }

    // MARK: - empty-history 5/MG backfill stretch

    // History NOT known-empty → unchanged (the normal 15-min cadence; the lever only acts on a sustained
    // empty streak, never on a healthy or unknown strap).
    func testNonEmptyReturnsBase() {
        XCTAssertEqual(
            BLEManager.whoop5EmptyHistoryBackfillInterval(
                baseSeconds: BLEManager.backfillIntervalSeconds,
                lowSeconds: BLEManager.lowBatteryBackfillIntervalSeconds,
                historyEmpty: false),
            BLEManager.backfillIntervalSeconds)
    }

    // History known-empty → stretched to the 45-min low-battery floor.
    func testEmptyStretchesToLowFloor() {
        XCTAssertEqual(
            BLEManager.whoop5EmptyHistoryBackfillInterval(
                baseSeconds: BLEManager.backfillIntervalSeconds,
                lowSeconds: BLEManager.lowBatteryBackfillIntervalSeconds,
                historyEmpty: true),
            BLEManager.lowBatteryBackfillIntervalSeconds)
    }

    // The stretch is the same value the low-battery lever uses (parity with #477).
    func testStretchMatchesLowBatteryFloor() {
        XCTAssertEqual(BLEManager.backfillIntervalSeconds, 900)       // 15 min
        XCTAssertEqual(BLEManager.lowBatteryBackfillIntervalSeconds, 2700) // 45 min
    }

    // Defensive: a misconfigured low floor below the base never SHORTENS the cadence (max, not min).
    func testNeverShortensBelowBase() {
        XCTAssertEqual(
            BLEManager.whoop5EmptyHistoryBackfillInterval(baseSeconds: 900, lowSeconds: 300, historyEmpty: true),
            900)
    }
}
