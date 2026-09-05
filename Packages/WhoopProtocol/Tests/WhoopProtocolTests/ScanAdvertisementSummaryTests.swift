import Foundation
import XCTest
@testable import WhoopProtocol

/// The advertisement summary (#1635) — the twin of the Kotlin `ScanAdvertisementSummaryTest`, same
/// cases and same expected text so the two platforms cannot describe a strap differently.
///
/// Its job is to make two advertising modes distinguishable in a strap log without carrying anything
/// that identifies a person or a device. WHOOP names a strap "<Name>'s Whoop" by default, so the local
/// name is the one field that must never appear.
final class ScanAdvertisementSummaryTests: XCTestCase {

    private func line(flags: Int? = 0x06,
                      svc: [String] = ["61080001-8d6d-82b8-614a-1c8cb0f8dcc6"],
                      svcData: [String: Int] = [:],
                      mfg: [Int: Int] = [:],
                      tx: Int? = nil,
                      nameLen: Int? = 12,
                      connectable: Bool = true) -> String {
        ScanAdvertisementSummary.line(flags: flags, serviceUuids: svc, serviceDataLengths: svcData,
                                      manufacturerDataLengths: mfg, txPower: tx,
                                      localNameLength: nameLen, connectable: connectable)
    }

    /// The headline guarantee: shape is reported, payload never is.
    func testSummaryCarriesNoPayloadBytesAndNoName() {
        let s = line(svcData: ["fd4b": 9], mfg: [0x01D9: 14], nameLen: 13)
        XCTAssertTrue(s.contains("fd4b:9B"))
        XCTAssertTrue(s.contains("0x01d9:14B"))
        XCTAssertTrue(s.contains("nameLen=13"))
        XCTAssertFalse(s.contains("Whoop"))
        XCTAssertFalse(s.contains("'s"))
    }

    /// The point of the line: two advertising modes must produce different text, or the #1635 question
    /// stays unanswerable.
    func testDifferentAdvertisingModeReadsDifferently() {
        let normal = line(flags: 0x06, svcData: [:])
        let pairing = line(flags: 0x05, svcData: ["fd4b": 4])
        XCTAssertNotEqual(normal, pairing)
        XCTAssertTrue(normal.contains("flags=0x06"))
        XCTAssertTrue(pairing.contains("flags=0x05"))
        XCTAssertTrue(normal.contains("svcData=none"))
        XCTAssertTrue(pairing.contains("fd4b:4B"))
    }

    /// Absent fields say so rather than vanishing, so two logs stay comparable field by field.
    func testAbsentFieldsAreNamedNotOmitted() {
        let s = line(flags: nil, svc: [], tx: nil, nameLen: nil)
        XCTAssertTrue(s.contains("flags=none"))
        XCTAssertTrue(s.contains("svc=none"))
        XCTAssertTrue(s.contains("tx=none"))
        XCTAssertTrue(s.contains("nameLen=none"))
    }

    /// Deterministic ordering, so two captures diff cleanly instead of by dictionary order.
    func testOutputIsStableRegardlessOfInputOrder() {
        let a = ScanAdvertisementSummary.line(flags: 6, serviceUuids: ["b", "a"],
                                              serviceDataLengths: ["y": 1, "x": 2],
                                              manufacturerDataLengths: [2: 1, 1: 2],
                                              txPower: nil, localNameLength: 4, connectable: true)
        let b = ScanAdvertisementSummary.line(flags: 6, serviceUuids: ["a", "b"],
                                              serviceDataLengths: ["x": 2, "y": 1],
                                              manufacturerDataLengths: [1: 2, 2: 1],
                                              txPower: nil, localNameLength: 4, connectable: true)
        XCTAssertEqual(a, b)
    }

    /// Connectability separates a pairing-ready strap from a beacon-only one.
    func testConnectabilityIsReported() {
        XCTAssertTrue(line(connectable: true).contains("connectable=true"))
        XCTAssertTrue(line(connectable: false).contains("connectable=false"))
    }
}
