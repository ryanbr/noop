import XCTest
@testable import WhoopStore

/// The per-day probe counters' ARITHMETIC, pinned against the Kotlin twin's.
///
/// The twin sums `System.nanoTime()` deltas into an `AtomicLong` and divides once at render. This side has
/// to do the same thing, not merely a similar thing: dividing each call to `Double` seconds and summing
/// those would spend sixty to eighty roundings where the twin spends none, and the difference survives into
/// the rendered millisecond whenever the true total sits near a half-millisecond boundary. Both platforms
/// render into ONE shared strap log, so a divergence there is read as two devices behaving differently.
final class StoreProbeCountsTests: XCTestCase {

    /// Sixty calls of exactly 20 ms. Integer accumulation makes this exactly 1.2 s, so it renders 1200ms;
    /// per-call `Double` division would land a hair either side. The literal matches the Kotlin
    /// `StoreProbeTallyTest.recordAccumulatesIntegerNanosLikeTheSwiftTwin`.
    func testAccumulatesIntegerNanosRatherThanSummingDoubles() {
        var probe = StoreProbeCounts.Probe()
        for _ in 0..<60 { probe.record(nanos: 20_000_000) }
        XCTAssertEqual(probe.calls, 60)
        XCTAssertEqual(probe.nanos, 1_200_000_000)
        XCTAssertEqual(probe.seconds, 1.2, accuracy: 0)
    }

    /// A probe that was never called contributes nothing and says so, which is what makes `ownerHr=0/0ms`
    /// on a single-strap install (#970) a finding rather than a missing measurement.
    func testUncalledProbeIsZeroNotAbsent() {
        let probe = StoreProbeCounts.Probe()
        XCTAssertEqual(probe.calls, 0)
        XCTAssertEqual(probe.seconds, 0)
    }

    /// `takeProbeCounts()` DRAINS. A line has to describe one pass, and the passes this runs under are the
    /// back-to-back ones an offload storm is made of, so a read that left the counters standing would make
    /// every pass after the first report its predecessors' work as its own.
    func testTakeDrainsSoAPassCannotInheritTheLastOne() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try? await store.hasHrInWindow(deviceId: "d", from: 0, to: 1)
        let first = await store.takeProbeCounts()
        XCTAssertEqual(first.ownerHr.calls, 1)
        let second = await store.takeProbeCounts()
        XCTAssertEqual(second.ownerHr.calls, 0)
        XCTAssertEqual(second.ownerHr.seconds, 0)
    }
}
