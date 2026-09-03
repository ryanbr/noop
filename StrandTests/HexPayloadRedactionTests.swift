import XCTest
@testable import Strand

/// #1833: a WHOOP serial that arrives as HEX rather than as text.
///
/// Every rule in `LiveState.redactPii` matches an identifier written as characters, so none of them can
/// see one encoded as hex. On a 5/MG, event 109 carries the strap serial as plain ASCII inside its
/// payload, and this side dumps hex in several places — `frame=` (the clock diagnostic), `[raw …]` and
/// `(raw …)` (the alarm readback), and the #900 whole-frame dump. The serial went into the log we ask
/// people to attach to public issues while the MAC rule kept firing, so the line still looked redacted.
///
/// Twin of the Kotlin `PiiRedactionTest` cases; the payload below is the real one from the capture on
/// #1825, which is how the leak was found.
final class HexPayloadRedactionTests: XCTestCase {

    /// `…WBB5AP0539852…` — a real serial, ASCII inside the payload bytes.
    private let payloadWithSerial = "142e1c0001d36e3d1c12a3574242354150303533393835320000"
    private let serialAsHex = "4242354150303533393835"

    func testSerialInsideAHexPayloadIsMasked() {
        let out = LiveState.redactPii("[event] 0x6D(109) payload=\(payloadWithSerial)")
        XCTAssertFalse(out.contains(serialAsHex), "serial must not survive as hex: \(out)")
        XCTAssertTrue(out.contains("142e1c0001d36e3d1c12a3"),
                      "the non-serial bytes are the reason the dump exists: \(out)")
    }

    /// Not keyed on a label: this side writes the same dumps four different ways.
    func testMaskedUnderEveryLabelThisSideUses() {
        for line in ["frame=\(payloadWithSerial)",
                     "[raw \(payloadWithSerial)]",
                     "(raw \(payloadWithSerial))",
                     "raw frame (#900) \(payloadWithSerial)",
                     payloadWithSerial] {
            XCTAssertFalse(LiveState.redactPii(line).contains(serialAsHex),
                           "serial survived under this label: \(line)")
        }
    }

    /// The run regex matches consecutive hex characters, so a dump abutting other hex-valid text gives
    /// an ODD-length match. Bailing on that returned the serial unredacted while Kotlin masked it — the
    /// two halves of one rule must not disagree about which lines are safe.
    func testOddLengthRunStillMasksTheSerial() {
        let out = LiveState.redactPii("payload=\(payloadWithSerial)f")   // 1 trailing half-byte
        XCTAssertFalse(out.contains(serialAsHex), "odd-length run left the serial exposed: \(out)")
    }

    /// The Kotlin rule is a regex over the printable projection (`[A-Za-z][0-9A-Za-z]{8,}`), so it finds
    /// a serial ANYWHERE inside an alphanumeric run. Testing only the run's first byte left the serial
    /// exposed when a digit preceded it with no separator — masked on Android, printed on Apple.
    func testSerialIsMaskedEvenWhenDigitsPrecedeItInTheSameRun() {
        // "0123" + "WBB5AP0539852" as one unbroken alphanumeric run, then a NUL to close it.
        let hex = "3031323357424235415030353339383532" + "00" + "0000000000000000"
        let out = LiveState.redactPii("payload=\(hex)")
        XCTAssertFalse(out.contains(serialAsHex), "digit-prefixed run left the serial exposed: \(out)")
        XCTAssertTrue(out.contains("30313233"), "the non-serial digits must survive: \(out)")
    }

    func testPayloadWithNoAsciiRunIsUntouched() {
        // The charging payloads from the same capture carry no ASCII run — they must pass through whole.
        for p in ["707d0000707d0000", "b87e0000b87e0000", "0000000000000000"] {
            XCTAssertEqual(LiveState.redactPii("payload=\(p)"), "payload=\(p)")
        }
    }

    /// The existing text rules must keep working — the hex pass runs first and must not eat them.
    func testTextRulesStillApply() {
        XCTAssertEqual(LiveState.redactPii("connecting to A1:B2:C3:D4:E5:F6"),
                       "connecting to A1:••:••:••:••:F6")
        XCTAssertTrue(LiveState.redactPii("Discovered WHOOP 4A2B9C1D").contains("<serial>"))
    }

    /// A vendor/service UUID's longest contiguous hex run is 12 characters, below the 16 the rule needs,
    /// so a UUID cannot be partially masked into something unreadable.
    func testServiceUuidIsNotTouched() {
        let uuid = "61080003-8d6d-82b8-614a-1c8cb0f8dcc6"
        XCTAssertTrue(LiveState.redactPii("Notify active \(uuid)").contains("8d6d"))
    }

    /// Odd-length or non-hex content returns unchanged rather than throwing: a redactor that throws
    /// withholds the entire line.
    func testMalformedHexIsLeftAlone() {
        XCTAssertEqual(LiveState.redactPii("payload=zzzzzzzzzzzzzzzzzz"), "payload=zzzzzzzzzzzzzzzzzz")
    }
}
