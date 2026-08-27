import XCTest
import WhoopProtocol
@testable import Strand

/// The #1635 CLIENT_HELLO suppression, ported from Android.
///
/// The rules are pure so they can be pinned without a radio — which matters more here than usual, because
/// nothing else validates this path: BLE behaviour is not CI-testable, and the app target has no default
/// CI at all.
final class HelloSuppressionTests: XCTestCase {

    // MARK: - shouldSendClientHello

    func testTheHelloIsSentUntilTheLatchSets() {
        XCTAssertTrue(shouldSendClientHello(suppressedForDevice: false, userInitiated: false))
        XCTAssertFalse(shouldSendClientHello(suppressedForDevice: true, userInitiated: false))
    }

    /// Suppression is a fallback for AUTOMATIC reconnects, never a permanent verdict. Someone who puts the
    /// strap in pairing mode and presses Connect must get a fresh try — that is also the only way to clear
    /// the latch short of a genuine bond.
    func testAnExplicitConnectAlwaysReattempts() {
        XCTAssertTrue(shouldSendClientHello(suppressedForDevice: true, userInitiated: true))
        XCTAssertTrue(shouldSendClientHello(suppressedForDevice: false, userInitiated: true))
    }

    // MARK: - giveUpSuppressesHello

    /// The two give-up causes want OPPOSITE treatment, and collapsing them is the bug this split exists to
    /// undo: before it, a strap that could still stream live HR was treated exactly like one that could not.
    func testOnlyAnUnansweredHandshakeSuppresses() {
        XCTAssertTrue(giveUpSuppressesHello(authRefusal: false))   // vanished write -> keep the link
        XCTAssertFalse(giveUpSuppressesHello(authRefusal: true))   // strap said no  -> pause instead
    }

    // MARK: - countsAsBondRefusal

    /// The family gate is what keeps a WHOOP 4.0 out of this entirely. The latch is stored per device with
    /// no family in the key, so without this gate a 4.0 could latch and silently lose history sync.
    func testAFourOhCanNeverReachTheSuppression() {
        for family in DeviceFamily.allCases where family != .whoop5 {
            XCTAssertFalse(
                countsAsBondRefusal(isAuthRefusalStatus: true, helloUnacked: true,
                                    alreadyBonded: false, family: family),
                "\(family) must not count toward the 5/MG handshake give-up")
        }
    }

    func testBothCausesCountForAFiveMG() {
        // The strap actively declined.
        XCTAssertTrue(countsAsBondRefusal(isAuthRefusalStatus: true, helloUnacked: false,
                                          alreadyBonded: false, family: .whoop5))
        // The write simply vanished — invisible to this platform's give-up before the port.
        XCTAssertTrue(countsAsBondRefusal(isAuthRefusalStatus: false, helloUnacked: true,
                                          alreadyBonded: false, family: .whoop5))
        // Neither: an ordinary drop is not a pairing problem.
        XCTAssertFalse(countsAsBondRefusal(isAuthRefusalStatus: false, helloUnacked: false,
                                           alreadyBonded: false, family: .whoop5))
    }

    /// A bonded link that drops is not a pairing failure, and counting it would latch the suppression on a
    /// strap whose handshake demonstrably works.
    func testAlreadyBondedNeverCounts() {
        XCTAssertFalse(countsAsBondRefusal(isAuthRefusalStatus: true, helloUnacked: true,
                                           alreadyBonded: true, family: .whoop5))
    }

    // MARK: - the latch key

    /// Lowercased for the same reason the firmware key is: the same strap can present its identifier in
    /// different cases across sessions, and a case-sensitive key would latch a second time under a second
    /// key instead of reading the first.
    func testTheLatchKeyIsCaseInsensitiveAndTrimmed() {
        let upper = helloSuppressionPrefKey("AABBCCDD-1122")
        XCTAssertEqual(upper, "noop.helloUnanswered.aabbccdd-1122")
        XCTAssertEqual(helloSuppressionPrefKey("  aabbccdd-1122  "), upper)
    }

    func testTheLatchKeyRejectsNothingToKeyOn() {
        XCTAssertNil(helloSuppressionPrefKey(nil))
        XCTAssertNil(helloSuppressionPrefKey(""))
        XCTAssertNil(helloSuppressionPrefKey("   "))
    }

    // MARK: - the latch itself

    func testTheLatchRoundTripsAndClearsCompletely() {
        let id = "unit-test-\(#function)"
        defer { HelloSuppressionStore.setSuppressed(id, false) }

        XCTAssertFalse(HelloSuppressionStore.suppressed(id))
        HelloSuppressionStore.setSuppressed(id, true)
        XCTAssertTrue(HelloSuppressionStore.suppressed(id))
        // Case must not open a second latch beside the first.
        XCTAssertTrue(HelloSuppressionStore.suppressed(id.uppercased()))
        HelloSuppressionStore.setSuppressed(id, false)
        XCTAssertFalse(HelloSuppressionStore.suppressed(id))
        // Cleared means REMOVED, so a strap that never latched leaves nothing behind.
        XCTAssertNil(UserDefaults.standard.object(forKey: helloSuppressionPrefKey(id)!))
    }

    /// An unkeyable id must not throw or write a stray default.
    func testStoringAgainstNothingIsANoOp() {
        HelloSuppressionStore.setSuppressed(nil, true)
        XCTAssertFalse(HelloSuppressionStore.suppressed(nil))
    }

    // MARK: - the hints (byte-identical to the Kotlin twin)

    /// The suppression branch pauses NOTHING, so its hint must not say auto-reconnect stopped — that was
    /// the confidently-wrong diagnostic #1635 produced twice. It names what was lost and the one action
    /// that restores the attempt.
    func testTheSuppressionHintDoesNotClaimAnythingIsPaused() {
        let hint = BondRefusalGiveUp.helloSuppressedHint()
        XCTAssertTrue(hint.contains("live heart rate keeps streaming"))
        XCTAssertTrue(hint.contains("History sync stays unavailable"))
        XCTAssertTrue(hint.contains("Tap Connect"))
        XCTAssertFalse(hint.lowercased().contains("paused"))
        XCTAssertFalse(hint.lowercased().contains("stopped retrying"))
    }

    /// The unanswered-handshake hint must not name a cause. `pausedHint` blames the official WHOOP app or a
    /// stale pairing, which an INSUFFICIENT_AUTHENTICATION refusal supports and a vanished write does not.
    func testTheUnansweredHintNamesNoCause() {
        let unanswered = BondRefusalGiveUp.pausedHintHandshakeUnanswered()
        XCTAssertTrue(unanswered.contains("never completes"))
        XCTAssertFalse(unanswered.contains("WHOOP app"))
        XCTAssertFalse(unanswered.contains("Forget This Device"))
        // …whereas the auth-refusal hint is exactly where naming that cause belongs.
        XCTAssertTrue(BondRefusalGiveUp.pausedHint().contains("WHOOP app"))
    }

    /// Likewise the epitaph: `epitaphLine` asserts "almost certainly held by the official WHOOP app", which
    /// only an auth refusal supports.
    func testTheSuppressionEpitaphAssertsNoCause() {
        let e = BondRefusalGiveUp.helloSuppressedEpitaph(refusals: 5, opaqueId: "abcd1234")
        XCTAssertTrue(e.contains("[abcd1234]"))
        XCTAssertTrue(e.contains("5x in a row"))
        XCTAssertFalse(e.contains("almost certainly"))
        XCTAssertFalse(e.contains("\u{2014}"))          // project rule: no em-dash in these lines
    }

    // MARK: - the keep-alive gate

    /// The defect this gate exists for: the timer used to require the genuine encrypted bond, which a
    /// suppressed 5/MG never reaches — so the liveness watchdog was switched off for exactly the link the
    /// suppression keeps up for hours, and a stalled stream would have had nothing to bounce it.
    func testAStreamingSuppressedFiveMGReachesTheWatchdog() {
        XCTAssertTrue(keepAliveMayRun(connected: true, didBond: false, bonded: true, family: .whoop5))
    }

    /// Before HR arrives there is nothing to watch, so starting the timer early at the suppression point
    /// is harmless — the gate simply returns false until the stream marks the link established (#8).
    func testItStaysShutUntilTheStreamActuallyStarts() {
        XCTAssertFalse(keepAliveMayRun(connected: true, didBond: false, bonded: false, family: .whoop5))
    }

    /// Narrower than the Android twin on purpose: only a 5/MG is admitted unbonded. A 4.0 reaching here
    /// without a bond would be a real fault, not a suppressed link, and must not be kept alive.
    func testOnlyAFiveMGIsAdmittedWithoutABond() {
        for family in DeviceFamily.allCases where family != .whoop5 {
            XCTAssertFalse(keepAliveMayRun(connected: true, didBond: false, bonded: true, family: family),
                           "\(family) must not run the keep-alive unbonded")
        }
    }

    func testABondedLinkAlwaysRunsAndADroppedOneNever() {
        for family in DeviceFamily.allCases {
            XCTAssertTrue(keepAliveMayRun(connected: true, didBond: true, bonded: true, family: family))
            XCTAssertFalse(keepAliveMayRun(connected: false, didBond: true, bonded: true, family: family))
        }
    }
}

