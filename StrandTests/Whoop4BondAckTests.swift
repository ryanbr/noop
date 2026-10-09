import XCTest
@testable import Strand

/// Pins what a WHOOP 4.0 confirmed-write ack records. The case that motivated it: the Mac's Bluetooth radio
/// powers off and back on, CoreBluetooth sends no disconnect, the app re-attaches, and `didConnect` clears
/// `encryptedBond` while `didBond` survives. The next ack must restore the encrypted bond rather than skip it,
/// or the strap reads "Live HR (not fully paired)" and buzz is refused for the rest of the link.
final class Whoop4BondAckTests: XCTestCase {

    func testFirstAckOnALinkIsTheFirstBond() {
        XCTAssertEqual(Whoop4BondAck.classify(didBond: false, encryptedBond: false), .firstBond)
    }

    func testAckAfterAReenteredConnectReprovesTheEncryptedBond() {
        XCTAssertEqual(Whoop4BondAck.classify(didBond: true, encryptedBond: false), .reprove)
    }

    func testLaterAcksOnAProvenLinkRecordNothing() {
        // Every SEND_HISTORICAL / HISTORY_END ack lands here during an offload; none may re-run bond bookkeeping.
        XCTAssertEqual(Whoop4BondAck.classify(didBond: true, encryptedBond: true), .alreadyProven)
    }

    func testAStaleEncryptedFlagWithoutABondIsStillTheFirstBond() {
        // didBond is the link-level fact; a first ack always runs the full first-bond path.
        XCTAssertEqual(Whoop4BondAck.classify(didBond: false, encryptedBond: true), .firstBond)
    }
}
