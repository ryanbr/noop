import XCTest
import CoreBluetooth
@testable import Strand

/// #1635 / #78 hole-1: a BLE failure line has to carry something a reader in ANY locale can match.
///
/// Foundation localizes CoreBluetooth error strings. `isInsufficientAuthError` already documents what
/// that costs: the old `localizedDescription.contains("encryption")` classification silently never
/// matched on a non-English device, for the entire localized user base. The classification was made
/// code-first then; the LOGGING still said only what the phone's locale said, so a shared strap log from
/// a French phone carried a refusal nobody triaging could match.
///
/// Android was always immune because it matches GATT status ints, which is why this exists: the tokens
/// line up with `gattWriteStatusLabel`'s 5 and 15 by construction.
final class BondErrorTokenTests: XCTestCase {

    /// The two codes that mean "the strap refused the encrypted bond" are exactly Android's 5 and 15.
    /// Pinned as numbers, because the whole point is that the two platforms' logs can be read the same way.
    func testRefusalCodesMatchTheAndroidGattStatuses() {
        XCTAssertEqual(CBATTError.Code.insufficientAuthentication.rawValue, 5)
        XCTAssertEqual(CBATTError.Code.insufficientEncryption.rawValue, 15)
        XCTAssertEqual(BLEManager.bleErrorToken(CBATTError(.insufficientAuthentication)), "cbAttError5")
        XCTAssertEqual(BLEManager.bleErrorToken(CBATTError(.insufficientEncryption)), "cbAttError15")
    }

    /// The suffix is additive and bracketed, so it can be spotted in a line whose other half is localized.
    func testSuffixIsBracketedAndAppendable() {
        XCTAssertEqual(BLEManager.bleErrorSuffix(CBATTError(.insufficientAuthentication)), " [cbAttError5]")
    }

    /// No error means no suffix: a clean disconnect line is unchanged, so this adds nothing to the
    /// overwhelmingly common healthy path.
    func testNoErrorAddsNothing() {
        XCTAssertEqual(BLEManager.bleErrorSuffix(nil), "")
    }

    /// An error from neither CoreBluetooth domain reads `code?` rather than leaking free text. Some
    /// CoreBluetooth paths do surface plain NSErrors, which is why the description is kept alongside
    /// rather than replaced.
    func testForeignErrorDomainCarriesNoFreeText() {
        let foreign = NSError(domain: "com.example.other", code: 42,
                              userInfo: [NSLocalizedDescriptionKey: "some localized text"])
        XCTAssertEqual(BLEManager.bleErrorSuffix(foreign), " [code?]")
        XCTAssertFalse(BLEManager.bleErrorSuffix(foreign).contains("localized"))
    }

    /// The CBError domain is tokenised too, so a connect failure is as matchable as a write failure.
    func testConnectionDomainErrorsAreTokenised() {
        XCTAssertEqual(BLEManager.bleErrorToken(CBError(.connectionTimeout)),
                       "cbError\(CBError.Code.connectionTimeout.rawValue)")
    }
}
