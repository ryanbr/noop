import XCTest
@testable import OuraProtocol

/// The read-only feature-status diagnostic: NOOP asks the ring its SpO2 (0x04) / real_steps (0x0b) feature
/// status with the SAME `0x20` read verb as `dhr_read`, decodes the `0x21` reply, and logs it once. It
/// confirms — from the ring itself — the server-flag gate that keeps those features off for an offline ring.
/// It must NEVER enable anything (no `0x22` set-mode) and must NOT disturb the live-HR triplet.
final class OuraFeatureStatusTests: XCTestCase {
    private let key: [UInt8] = Array(0..<16)

    // MARK: - Command bytes (read verb only)

    func testStatusQueryCommandsAreReadOnly() {
        XCTAssertEqual(OuraCommands.spo2ReadStatus().bytes, [0x2F, 0x02, 0x20, 0x04])
        XCTAssertEqual(OuraCommands.realStepsReadStatus().bytes, [0x2F, 0x02, 0x20, 0x0B])
        // sub-op 0x20 is READ; the enable would be 0x22 — neither query may ever carry it.
        XCTAssertEqual(OuraCommands.spo2ReadStatus().bytes[2], 0x20)
        XCTAssertEqual(OuraCommands.realStepsReadStatus().bytes[2], 0x20)
    }

    // MARK: - Decode

    func testDecodesTheFiveStatusBytes() {
        // The observed daytime-HR reply `2f 06 21 02 01 11 02 00` → sub-body `02 01 11 02 00`.
        let st = OuraDecoders.decodeFeatureStatus([0x02, 0x01, 0x11, 0x02, 0x00])
        XCTAssertEqual(st, OuraFeatureStatus(feature: 0x02, mode: 1, status: 0x11, state: 2, subscription: 0))
    }

    func testShortBodyDecodesToNil() {
        XCTAssertNil(OuraDecoders.decodeFeatureStatus([0x04, 0x01]))   // never fabricate a partial status
        XCTAssertNil(OuraDecoders.decodeFeatureStatus([]))
    }

    // MARK: - Driver routing (diagnostic vs the triplet)

    func testDaytimeHRReadStillAdvancesTheTriplet() {
        // A 0x21 for the daytime-HR feature (0x02) is step 1 of the live-HR triplet → must stay `.enableAck`.
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        let frame = OuraSecureFrame(subop: 0x21, subBody: [0x02, 0x01, 0x11, 0x02, 0x00])
        XCTAssertEqual(d.handleSecureFrame(frame), .enableAck)
    }

    func testSpO2AndStepsReadsSurfaceFeatureStatus() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        // An all-zero reply. The comment here used to read the zeros as "server-gated off"; it describes
        // the FIXTURE, not a ring's real answer, and #1629 showed a real ring answering otherwise.
        XCTAssertEqual(d.handleSecureFrame(OuraSecureFrame(subop: 0x21, subBody: [0x04, 0x00, 0x00, 0x00, 0x00])),
                       .featureStatus(OuraFeatureStatus(feature: 0x04, mode: 0, status: 0, state: 0, subscription: 0)))
        XCTAssertEqual(d.handleSecureFrame(OuraSecureFrame(subop: 0x21, subBody: [0x0B, 0x00, 0x00, 0x00, 0x00])),
                       .featureStatus(OuraFeatureStatus(feature: 0x0B, mode: 0, status: 0, state: 0, subscription: 0)))
    }

    /// #1629: the shape a REAL ring actually answers with. On-device captures read real_steps back as
    /// `status=1` from both an authenticated Oura-app session and NOOP's own offline, unauthenticated
    /// connection to the same ring. Until now the suite only ever exercised the all-zero reply, so the
    /// one reading anybody has actually observed on hardware was the one nothing pinned.
    ///
    /// This asserts the DECODE only. `status=1` says the ring reports the feature enabled; it is not
    /// evidence that the ring emits `0x7E`/`0x7F`, and nothing here should be read as claiming that.
    func testAnEnabledRealStepsStatusDecodesAsObservedOnHardware() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        XCTAssertEqual(d.handleSecureFrame(OuraSecureFrame(subop: 0x21, subBody: [0x0B, 0x00, 0x01, 0x00, 0x00])),
                       .featureStatus(OuraFeatureStatus(feature: 0x0B, mode: 0, status: 1, state: 0, subscription: 0)))
    }

    func testUndecodableDiagnosticReplyFallsBackToEnableAck() {
        // A too-short 0x21 (can't decode a feature) must not crash or mis-route; it stays `.enableAck` so
        // the triplet never stalls on a malformed reply.
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        XCTAssertEqual(d.handleSecureFrame(OuraSecureFrame(subop: 0x21, subBody: [0x04])), .enableAck)
    }
}
