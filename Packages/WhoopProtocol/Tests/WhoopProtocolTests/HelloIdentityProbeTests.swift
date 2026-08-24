import XCTest
@testable import WhoopProtocol

/// #1303: the GET_HELLO candidate-serial probe.
///
/// The probe exists to locate a strap serial in a block the decoder already receives and discards. Its
/// value depends entirely on two properties, and both are pinned here: it must SURFACE a serial-shaped
/// run, and it must WITHHOLD the session token that shares the block.
///
/// Byte-parity twin of Kotlin `HelloIdentityProbeTest`.
final class HelloIdentityProbeTests: XCTestCase {

    /// Build a payload with printable runs at chosen offsets, zero-filled elsewhere — zeros are the
    /// non-printable filler a real block has between its fields.
    private func payload(length: Int, runs: [(offset: Int, text: String)]) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: length)
        for run in runs {
            for (k, b) in Array(run.text.utf8).enumerated() { p[run.offset + k] = b }
        }
        return p
    }

    /// The point of the whole probe: a serial-shaped run away from the name is printed, so it can be
    /// matched against the serial on the strap's own casing.
    func testASerialShapedRunIsPrinted() {
        let p = payload(length: 120, runs: [(40, "3A1B2405003655")])
        let lines = HelloIdentityProbe.candidateLines(payload: p)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first, #"off=40 len=14 alnum "3A1B2405003655""#)
    }

    /// The privacy contract. A NON-alphanumeric run is described but never quoted — that is the shape a
    /// session token takes, and the decoder deliberately never reads it.
    func testAMixedRunIsDescribedButWithheld() {
        let p = payload(length: 120, runs: [(40, "tok!en-{}~payload")])
        let lines = HelloIdentityProbe.candidateLines(payload: p)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first, "off=40 len=17 mixed (withheld)")
        XCTAssertFalse(lines.first!.contains("tok"), "a mixed run's contents must never reach the log")
    }

    /// Length is a filter too: an alphanumeric run far longer than any serial is withheld. A long
    /// alphanumeric blob is much more likely to be a token than an id.
    func testAnOverlongAlnumRunIsWithheld() {
        let p = payload(length: 200, runs: [(40, String(repeating: "a", count: 64))])
        let lines = HelloIdentityProbe.candidateLines(payload: p)
        XCTAssertEqual(lines.first, "off=40 len=64 alnum (withheld)")
    }

    /// The device name is already surfaced by the decoder, so it is labelled rather than quoted — it is
    /// not a serial candidate and repeating it would only pad the line.
    func testTheKnownNameRunIsLabelledNotQuoted() {
        let p = payload(length: 120, runs: [(16, "WHOOP-FAKE01")])
        let lines = HelloIdentityProbe.candidateLines(payload: p)
        XCTAssertEqual(lines.first, "off=16 len=12 mixed (device name, already decoded)")
    }

    /// Short runs are dropped. Binary payloads throw off two- and three-byte printable sequences by
    /// chance, and reporting them would bury the real candidate.
    func testShortRunsAreIgnored() {
        let p = payload(length: 60, runs: [(10, "ab"), (30, "xyz")])
        XCTAssertTrue(HelloIdentityProbe.candidateLines(payload: p).isEmpty)
    }

    /// Several runs are reported in offset order, so the reader can line them up against the block.
    func testRunsAreReportedInOffsetOrder() {
        let p = payload(length: 200, runs: [(16, "WHOOP-FAKE01"), (40, "SER1234567"), (80, "zz!!zz??")])
        let lines = HelloIdentityProbe.candidateLines(payload: p)
        XCTAssertEqual(lines, [
            "off=16 len=12 mixed (device name, already decoded)",
            #"off=40 len=10 alnum "SER1234567""#,
            "off=80 len=8 mixed (withheld)",
        ])
    }

    /// A run reaching the very end of the payload must not be lost to an off-by-one on the scan bound.
    func testARunFlushWithTheEndIsReported() {
        var p = [UInt8](repeating: 0, count: 20)
        for (k, b) in Array("SERIAL99".utf8).enumerated() { p[12 + k] = b }
        XCTAssertEqual(HelloIdentityProbe.candidateLines(payload: p).first,
                       #"off=12 len=8 alnum "SERIAL99""#)
    }

    /// "No printable runs" is a real answer, not a failure: it says the serial is not ASCII here and the
    /// search moves on. The length still prints, so the reader knows the block was seen.
    func testAnAllBinaryBlockReportsNoneWithItsLength() {
        XCTAssertEqual(HelloIdentityProbe.report(payload: [UInt8](repeating: 0, count: 42)),
                       "HELLO(145) block len=42 runs: none")
    }

    /// An empty payload must not crash the scan.
    func testAnEmptyPayloadIsSafe() {
        XCTAssertTrue(HelloIdentityProbe.candidateLines(payload: []).isEmpty)
        XCTAssertEqual(HelloIdentityProbe.report(payload: []), "HELLO(145) block len=0 runs: none")
    }
}
