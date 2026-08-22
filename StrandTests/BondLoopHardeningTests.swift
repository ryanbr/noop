import XCTest
import CoreBluetooth
@testable import Strand

/// Pins the #78 give-up hardening added alongside #747/#750:
///
///  - HOLE 1 (locale-proof refusal detection): Foundation LOCALIZES CoreBluetooth error strings, so the
///    old `localizedDescription.contains("encryption"/"authentication")` check silently never fired on a
///    non-English device - no pairing hint, no give-up, no #52 pin handoff. `isInsufficientAuthError`
///    classifies by ATT code FIRST, keeping the English string match as an additive fallback only.
///  - HOLE 4 (salvage probe): `shouldSalvageProbe` is the pure gate for the one bounded app-foreground
///    attempt while the pause is latched - what makes the give-up provably unable to strand a strap the
///    user has since freed, while never re-entering the refusal hammer.
final class BondLoopHardeningTests: XCTestCase {

    // MARK: isInsufficientAuthError (hole 1)

    /// The two ATT codes classify by CODE, regardless of what the (possibly localized) text says.
    func testAttCodes_classifyRegardlessOfText() {
        XCTAssertTrue(BLEManager.isInsufficientAuthError(CBATTError(.insufficientEncryption)))
        XCTAssertTrue(BLEManager.isInsufficientAuthError(CBATTError(.insufficientAuthentication)))
    }

    /// The German-device regression: a CBATTErrorDomain code-15 error whose LOCALIZED text contains
    /// neither English keyword must STILL classify - by code. This is the exact shape that silently
    /// disabled the whole #78 stack on non-English devices.
    func testLocalizedAttError_classifiesByCode() {
        let err = NSError(domain: CBATTErrorDomain,
                          code: CBATTError.insufficientEncryption.rawValue,
                          userInfo: [NSLocalizedDescriptionKey: "Die Verschluesselung ist unzureichend."])
        XCTAssertTrue(BLEManager.isInsufficientAuthError(err))
        let auth = NSError(domain: CBATTErrorDomain,
                           code: CBATTError.insufficientAuthentication.rawValue,
                           userInfo: [NSLocalizedDescriptionKey: "Authentifizierung fehlgeschlagen."])
        XCTAssertTrue(BLEManager.isInsufficientAuthError(auth))
    }

    /// The English free-text fallback is ADDITIVE, not replaced: a plain NSError outside the
    /// CBATTError domain whose text carries the keyword still classifies (no regression on paths that
    /// surface non-ATT errors).
    func testEnglishStringFallback_stillClassifies() {
        let enc = NSError(domain: "SomeOtherDomain", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Encryption is insufficient."])
        XCTAssertTrue(BLEManager.isInsufficientAuthError(enc))
        let auth = NSError(domain: "SomeOtherDomain", code: 1,
                           userInfo: [NSLocalizedDescriptionKey: "Authentication is insufficient."])
        XCTAssertTrue(BLEManager.isInsufficientAuthError(auth))
    }

    /// An unrelated error (wrong code, no keyword) never classifies - a timeout must not feed the
    /// refusal streak.
    func testUnrelatedErrors_doNotClassify() {
        XCTAssertFalse(BLEManager.isInsufficientAuthError(CBError(.connectionTimeout)))
        let other = NSError(domain: CBATTErrorDomain,
                            code: CBATTError.requestNotSupported.rawValue,
                            userInfo: [NSLocalizedDescriptionKey: "Request is not supported."])
        XCTAssertFalse(BLEManager.isInsufficientAuthError(other))
    }

    // MARK: shouldSalvageProbe (hole 4)

    private let floor = BLEManager.bondLoopSalvageFloorSeconds

    /// The happy salvage path: paused, link down, no user teardown, past the floor.
    func testProbe_firesPastFloorWhilePaused() {
        XCTAssertTrue(BLEManager.shouldSalvageProbe(pausedForBondLoop: true, connected: false,
                                                    intentionalDisconnect: false,
                                                    secondsSincePauseTripped: floor))
        XCTAssertTrue(BLEManager.shouldSalvageProbe(pausedForBondLoop: true, connected: false,
                                                    intentionalDisconnect: false,
                                                    secondsSincePauseTripped: floor + 3600))
    }

    /// Below the floor no probe fires - back-to-back foregrounds can't chain attempts.
    func testProbe_respectsTheFloor() {
        XCTAssertFalse(BLEManager.shouldSalvageProbe(pausedForBondLoop: true, connected: false,
                                                     intentionalDisconnect: false,
                                                     secondsSincePauseTripped: floor - 1))
        XCTAssertFalse(BLEManager.shouldSalvageProbe(pausedForBondLoop: true, connected: false,
                                                     intentionalDisconnect: false,
                                                     secondsSincePauseTripped: 0))
    }

    /// No trip timestamp = the pause never tripped this run = never probe.
    func testProbe_needsATripTimestamp() {
        XCTAssertFalse(BLEManager.shouldSalvageProbe(pausedForBondLoop: true, connected: false,
                                                     intentionalDisconnect: false,
                                                     secondsSincePauseTripped: nil))
    }

    /// Not paused (the normal healthy path) never probes - the probe exists ONLY for the latched pause.
    func testProbe_onlyWhilePaused() {
        XCTAssertFalse(BLEManager.shouldSalvageProbe(pausedForBondLoop: false, connected: false,
                                                     intentionalDisconnect: false,
                                                     secondsSincePauseTripped: floor))
    }

    /// A live link or an explicit user teardown always suppresses the probe.
    func testProbe_suppressedWhenConnectedOrUserTornDown() {
        XCTAssertFalse(BLEManager.shouldSalvageProbe(pausedForBondLoop: true, connected: true,
                                                     intentionalDisconnect: false,
                                                     secondsSincePauseTripped: floor))
        XCTAssertFalse(BLEManager.shouldSalvageProbe(pausedForBondLoop: true, connected: false,
                                                     intentionalDisconnect: true,
                                                     secondsSincePauseTripped: floor))
    }

    // MARK: shouldStandingConnectWhilePaused (#1539)

    /// The regression: a pause tripped while the app is backgrounded had no escape at all. The salvage
    /// probe fires on app-foreground, so a phone in a pocket never ran it, and the paused branch suppressed
    /// the one passive mechanism that could end the pause. `nil` elapsed means "just tripped" — that is the
    /// moment the parked connect must be armed, not skipped.
    func testJustTrippedArmsTheParkedConnectImmediately() {
        XCTAssertTrue(BLEManager.shouldStandingConnectWhilePaused(
            pausedForBondLoop: true, connected: false, intentionalDisconnect: false,
            secondsSincePauseTripped: nil))
    }

    /// Refreshes are floored, so a reachable strap that keeps refusing gets one attempt per window instead
    /// of spinning connect -> refuse -> pause -> connect. This is the anti-hammering property the pause was
    /// added for, and it has to survive the escape.
    func testARefreshInsideTheFloorIsRefused() {
        XCTAssertFalse(BLEManager.shouldStandingConnectWhilePaused(
            pausedForBondLoop: true, connected: false, intentionalDisconnect: false,
            secondsSincePauseTripped: 0))
        XCTAssertFalse(BLEManager.shouldStandingConnectWhilePaused(
            pausedForBondLoop: true, connected: false, intentionalDisconnect: false,
            secondsSincePauseTripped: BLEManager.bondLoopSalvageFloorSeconds - 1))
    }

    /// ...and is allowed once the floor has elapsed, which is what makes recovery eventual rather than
    /// dependent on the user.
    func testARefreshAtOrPastTheFloorIsAllowed() {
        XCTAssertTrue(BLEManager.shouldStandingConnectWhilePaused(
            pausedForBondLoop: true, connected: false, intentionalDisconnect: false,
            secondsSincePauseTripped: BLEManager.bondLoopSalvageFloorSeconds))
    }

    /// Never parks a connect when the pause is not latched, when a link is already up, or when the user
    /// tore the link down deliberately — the same three refusals the foreground probe makes.
    func testTheThreeRefusalsMatchTheForegroundProbe() {
        XCTAssertFalse(BLEManager.shouldStandingConnectWhilePaused(
            pausedForBondLoop: false, connected: false, intentionalDisconnect: false,
            secondsSincePauseTripped: nil))
        XCTAssertFalse(BLEManager.shouldStandingConnectWhilePaused(
            pausedForBondLoop: true, connected: true, intentionalDisconnect: false,
            secondsSincePauseTripped: nil))
        XCTAssertFalse(BLEManager.shouldStandingConnectWhilePaused(
            pausedForBondLoop: true, connected: false, intentionalDisconnect: true,
            secondsSincePauseTripped: nil))
    }
}
