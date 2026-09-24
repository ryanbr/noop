import XCTest
@testable import Strand

/// A connect asked for before the radio is up is replayed against a FRESH retrieve, so a bonded device
/// is connected by identifier instead of being left to a background scan (#2433).
///
/// The reported shape: NOOP is relaunched into the background, `connect(_:)` runs while the source's
/// central is still `.unknown`, `retrievePeripherals` answers nothing because of that, and the empty
/// answer is read as "this ring has never been seen here". The id is parked, a scan is armed, and the
/// replay on `.poweredOn` looks only in `seenPeripherals` — empty for the same reason — so it starts the
/// scan. iOS throttles background scanning hard: the report has a ring bonded for weeks found 29 min
/// 54 s after the relaunch, beside a WHOOP central that attached immediately.
///
/// The decision is a pure function so it can be pinned without a radio. What it cannot prove is the
/// hardware half: a background relaunch followed within seconds by a connect line rather than a scan.
final class PendingConnectReplayTests: XCTestCase {

    /// The regression. `isHeld` false with `didRetrieve` true is exactly the state a bonded device is in
    /// on `.poweredOn`: never discovered this launch, but retrievable now the radio answers. This used to
    /// fall through to the scan branch, and it is the whole reason the retrieve is re-issued.
    func testARetrievableDeviceConnectsEvenThoughItWasNeverDiscoveredThisLaunch() {
        XCTAssertEqual(
            PendingConnect.replay(isPending: true, isHeld: false, didRetrieve: true, isScanning: true),
            .connect,
            "a device the radio can now resolve must be connected by identifier, not scanned for"
        )
    }

    /// A scan being armed must not win over a peripheral we can reach. `connect(_:)` used to arm one on
    /// its way past, so the losing case had `isScanning: true` set by the very call that parked the id.
    func testAnArmedScanDoesNotBeatAReachablePeripheral() {
        for held in [true, false] {
            XCTAssertEqual(
                PendingConnect.replay(isPending: true, isHeld: held, didRetrieve: !held, isScanning: true),
                .connect
            )
        }
    }

    /// Already holding the peripheral is the path that always worked; it must keep working.
    func testAHeldPeripheralConnects() {
        XCTAssertEqual(
            PendingConnect.replay(isPending: true, isHeld: true, didRetrieve: false, isScanning: false),
            .connect
        )
    }

    /// Genuinely unknown, with a scan already armed and deferred: resume it rather than re-arming, which
    /// would wipe `seenPeripherals` for no reason. This is the case the old code applied to everything.
    func testAnUnknownDeviceResumesAnAlreadyArmedScan() {
        XCTAssertEqual(
            PendingConnect.replay(isPending: true, isHeld: false, didRetrieve: false, isScanning: true),
            .scan
        )
    }

    /// Unknown with nothing armed: discovery has to be STARTED, not skipped.
    ///
    /// This is the case a first-ever pairing arrives in when the connect is asked for before the radio is
    /// up. Parking the intent before the retrieve means nothing called `scan()` on the way past, so there
    /// is no deferred scan for the replay to resume. Answering `.idle` here would drop the connect in
    /// silence, which is how the first cut of this change behaved, and how its first test said it should.
    func testAnUnknownDeviceWithNothingArmedStartsDiscovery() {
        XCTAssertEqual(
            PendingConnect.replay(isPending: true, isHeld: false, didRetrieve: false, isScanning: false),
            .discover,
            "a parked connect for an unresolvable device must arm discovery, not evaporate"
        )
    }

    /// The whole space at once. A parked connect is never dropped, and nothing is ever started for a
    /// caller who asked for nothing. These two are the invariants; the cases above are the examples.
    func testNoParkedConnectIsEverDroppedAndNothingStartsUnasked() {
        for isPending in [true, false] {
            for isHeld in [true, false] {
                for didRetrieve in [true, false] {
                    for isScanning in [true, false] {
                        let out = PendingConnect.replay(isPending: isPending, isHeld: isHeld,
                                                        didRetrieve: didRetrieve, isScanning: isScanning)
                        let where_ = "held=\(isHeld) retrieved=\(didRetrieve) scanning=\(isScanning)"
                        if isPending {
                            XCTAssertNotEqual(out, .idle, "parked connect dropped: \(where_)")
                        } else {
                            XCTAssertNotEqual(out, .connect, "connected unasked: \(where_)")
                            XCTAssertNotEqual(out, .discover, "discovery armed unasked: \(where_)")
                        }
                    }
                }
            }
        }
    }

    /// No parked connect: the transition is only about resuming a scan that was deferred.
    func testWithNothingParkedOnlyADeferredScanResumes() {
        XCTAssertEqual(
            PendingConnect.replay(isPending: false, isHeld: false, didRetrieve: false, isScanning: true),
            .scan
        )
        XCTAssertEqual(
            PendingConnect.replay(isPending: false, isHeld: false, didRetrieve: false, isScanning: false),
            .idle
        )
    }

    /// A peripheral is never connected when nothing asked for it, whatever the lookups say. Guards the
    /// `isPending` gate itself: dropping it would connect on any `.poweredOn` with a stale handle around.
    func testNothingParkedNeverConnects() {
        for held in [true, false] {
            for retrieved in [true, false] {
                for scanning in [true, false] {
                    XCTAssertNotEqual(
                        PendingConnect.replay(isPending: false, isHeld: held,
                                              didRetrieve: retrieved, isScanning: scanning),
                        .connect
                    )
                }
            }
        }
    }
}
