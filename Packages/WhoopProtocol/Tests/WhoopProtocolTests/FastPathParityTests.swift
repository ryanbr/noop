import XCTest
@testable import WhoopProtocol

private struct FrameEntry: Decodable {
    let hex: String
}

/// D#742 decode-only fast path guard.
///
/// `parseFrame(collectFields: false)` is the DEFAULT and the path the live 1Hz+ stream and the
/// 5/MG offload burst ride (FrameRouter / Collector / Backfiller / extractStreams read only the
/// flat `parsed` dict). These tests pin the two contracts the optimisation rests on, over REAL
/// captured frames (the parity fixture corpus plus the hardware whoop5 vectors), never synthetic
/// bytes:
///   (a) the fast path decodes byte-identically to the full diagnostic path in every property
///       except `fields`, which it leaves empty;
///   (b) the full diagnostic path (whoop-decode, field-asserting tests) still produces the same
///       annotated `fields`, including each field's per-field `raw` hex slice, as before.
final class FastPathParityTests: XCTestCase {

    // MARK: - Real whoop5 hardware vectors (shared with Whoop5RealtimeTests / Whoop5HistoricalTests
    // / DeviceFamilyFramingTests; see those files for the capture provenance).

    /// type-40 REALTIME_DATA: hr=98, rr=[603,587] ms, unix ts=1780916382.
    private static let whoop5RealtimeHex =
        "aa011800010022e128029ea0266aae4762025b024b020000000001005ed515dc"
    /// type-47 HISTORICAL_DATA v18, worn (captured 2026-06-08): unix=1780916150, hr=102.
    private static let whoop5HistoricalHex =
        "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"
    /// type-47 HISTORICAL_DATA v18, off-wrist (HR=0 sentinel record).
    private static let whoop5HistoricalOffWristHex =
        "aa01740001003fb12f12803a3d84018889266a3d0a00000000000000000000000000000000000000000064c33b52b47d3fe1ba1dbda470ecbd000064000000000000000000e500e200c708000c010c020c0000000000000000000000000000000000000000000000010000008080000000000000000000009ffafe6c"
    /// puffin METADATA (type 56 alias).
    private static let whoop5MetadataHex = "aa010c000001e741380300abcd00000060153281"
    /// puffin COMMAND_RESPONSE (type 36).
    private static let whoop5CommandResponseHex = "aa010c000001e74124070211223344557481f36e"

    private static let whoop5Vectors: [(label: String, hex: String)] = [
        ("whoop5 realtime", whoop5RealtimeHex),
        ("whoop5 historical v18 worn", whoop5HistoricalHex),
        ("whoop5 historical v18 off-wrist", whoop5HistoricalOffWristHex),
        ("whoop5 metadata", whoop5MetadataHex),
        ("whoop5 command_response", whoop5CommandResponseHex),
    ]

    // MARK: - Helpers (mirrors ParityTests)

    private func resourceURL(_ name: String, _ ext: String) throws -> URL {
        let url = Bundle.module.url(forResource: name, withExtension: ext)
        return try XCTUnwrap(url, "missing test resource \(name).\(ext); run scripts/gen_golden.py")
    }

    private func loadFrames(_ resource: String) throws -> [[UInt8]] {
        let data = try Data(contentsOf: resourceURL(resource, "json"))
        let entries = try JSONDecoder().decode([FrameEntry].self, from: data)
        XCTAssertGreaterThan(entries.count, 0, "no frames loaded from \(resource).json")
        return entries.map { hexToBytes($0.hex) }
    }

    private func hexToBytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            out.append(UInt8(s[idx..<next], radix: 16)!)
            idx = next
        }
        return out
    }

    private func hexOf(_ bytes: ArraySlice<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Contract (a): the default (fast) decode equals the full diagnostic decode in every property
    /// except `fields` AND `rawHex`, which the fast path leaves empty (D#969 gates rawHex on
    /// collectFields, the same way D#742 gated fields — the live path reads neither).
    private func assertFastMatchesFull(_ frame: [UInt8], family: DeviceFamily, _ label: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let fast = parseFrame(frame, family: family)   // default collectFields: false
        let full = parseFrame(frame, family: family, collectFields: true)
        XCTAssertEqual(fast.parsed, full.parsed, "parsed drift at \(label)", file: file, line: line)
        XCTAssertEqual(fast.ok, full.ok, "ok drift at \(label)", file: file, line: line)
        XCTAssertEqual(fast.typeName, full.typeName, "typeName drift at \(label)", file: file, line: line)
        XCTAssertEqual(fast.seq, full.seq, "seq drift at \(label)", file: file, line: line)
        XCTAssertEqual(fast.cmdName, full.cmdName, "cmdName drift at \(label)", file: file, line: line)
        XCTAssertEqual(fast.crcOK, full.crcOK, "crcOK drift at \(label)", file: file, line: line)
        XCTAssertEqual(fast.lenBytes, full.lenBytes, "lenBytes drift at \(label)", file: file, line: line)
        // rawHex: fast path leaves it empty; full path carries the exact whole-frame hex (D#969).
        XCTAssertEqual(fast.rawHex, "", "fast path built rawHex at \(label)", file: file, line: line)
        XCTAssertEqual(full.rawHex, hexOf(frame[...]), "rawHex drift at \(label)", file: file, line: line)
        XCTAssertTrue(fast.fields.isEmpty, "fast path built fields at \(label)", file: file, line: line)
        if full.ok {
            XCTAssertFalse(full.fields.isEmpty, "full path lost its fields at \(label)",
                           file: file, line: line)
        }
    }

    /// Contract (b): every annotated field's `raw` is exactly the hex of the frame bytes it covers
    /// (clamped to the frame, empty when out of range), i.e. the pre-D#742 hexString behaviour.
    private func assertFieldRawsMatchFrameBytes(_ frame: [UInt8], family: DeviceFamily, _ label: String,
                                                file: StaticString = #filePath, line: UInt = #line) {
        let full = parseFrame(frame, family: family, collectFields: true)
        for f in full.fields {
            let end = min(f.off + f.len, frame.count)
            let expected = f.off <= frame.count ? hexOf(frame[max(0, f.off)..<max(f.off, end)]) : ""
            XCTAssertEqual(f.raw, expected, "per-field raw hex drift for \(f.name) at \(label)",
                           file: file, line: line)
        }
    }

    // MARK: - (a) fast path == full path

    func testFastPathMatchesFullPathOnWhoop4ParityCorpus() throws {
        for (i, frame) in try loadFrames("frames").enumerated() {
            assertFastMatchesFull(frame, family: .whoop4, "frames.json #\(i)")
        }
    }

    func testFastPathMatchesFullPathOnWhoop4HistoricalCorpus() throws {
        for (i, frame) in try loadFrames("historical_frames").enumerated() {
            assertFastMatchesFull(frame, family: .whoop4, "historical_frames.json #\(i)")
        }
    }

    func testFastPathMatchesFullPathOnWhoop5HardwareVectors() {
        for v in Self.whoop5Vectors {
            assertFastMatchesFull(hexToBytes(v.hex), family: .whoop5, v.label)
        }
    }

    /// #47: `frameTypeName` (the cheap type-only peek used by the offload gesture pre-filter) must agree with
    /// a full `parseFrame` on TWO things, or the pre-filter's `guard frameTypeName == "EVENT"` could diverge
    /// from the full-parse `guard typeName == "EVENT"` — over-admitting (a wasted parse) or, dangerously,
    /// DROPPING a real gesture:
    ///   1. for a frame that decodes at all, the exact type name matches (the peek says nothing about
    ///      INTEGRITY — `parseFrame.ok` is the verifier's verdict, and the two deliberately differ there);
    ///   2. for ANY frame (incl. malformed/short/wrong-SOF), the EVENT *decision* matches — this is the
    ///      property the pre-filter actually rests on, and it must hold even where the two disagree on the
    ///      name (frameTypeName returns nil for a short frame; parseFrame calls it "INVALID/FRAGMENT" — both
    ///      are "not EVENT", so the pre-filter skips exactly as the full parse would).
    func testFrameTypeNamePreFilterMatchesFullParse() throws {
        func check(_ frame: [UInt8], _ family: DeviceFamily, _ label: String) {
            let peek = frameTypeName(frame, family: family)
            let full = parseFrame(frame, family: family)
            // Compared on PARSABILITY, not on the integrity verdict: `ok` now reports whether the
            // frame is intact, and a corrupt frame still decodes a type name the peek must match.
            if full.typeName != "INVALID/FRAGMENT" {
                XCTAssertEqual(peek, full.typeName, "frameTypeName != parseFrame.typeName at \(label)")
            }
            // The contract the offload gesture pre-filter depends on: never drop/over-admit an EVENT.
            XCTAssertEqual(peek == "EVENT", full.typeName == "EVENT", "EVENT-decision drift at \(label)")
        }
        for (i, frame) in try loadFrames("frames").enumerated() { check(frame, .whoop4, "frames.json #\(i)") }
        for (i, frame) in try loadFrames("historical_frames").enumerated() {
            check(frame, .whoop4, "historical_frames.json #\(i)")
        }
        for v in Self.whoop5Vectors { check(hexToBytes(v.hex), .whoop5, v.label) }
        // Malformed / boundary frames the corpus doesn't carry, where a false-negative would silently drop a
        // gesture on real BLE (fragments, corruption). Both peek and full parse must land on "not EVENT".
        check([], .whoop4, "empty")
        check([0xAA, 0x01, 0x02], .whoop4, "short (below the 11-byte min)")
        check([0x00, 0x18, 0x00, 0xff, 0x28, 0x02, 0x0f, 0x00], .whoop4, "wrong SOF")
        check(hexToBytes("aa010c000001"), .whoop5, "short 5/MG (below the 13-byte min)")
    }

    /// The DEFAULT call is the fast path on both entry points, so every live/offload call site
    /// (FrameRouter, Collector, Backfiller, rejectedHistoricalRecords, BLEManager clock
    /// correlation) gets the optimisation without a call-site change.
    func testDefaultIsTheDecodeOnlyFastPath() {
        let w4 = hexToBytes("aa1800ff28020f3de10128663c0000000000000000000000da855212")
        XCTAssertTrue(parseFrame(w4).ok)
        XCTAssertTrue(parseFrame(w4).fields.isEmpty)
        XCTAssertTrue(parseFrame(w4, family: .whoop4).fields.isEmpty)
        let w5 = hexToBytes(Self.whoop5RealtimeHex)
        XCTAssertTrue(parseFrame(w5, family: .whoop5).ok)
        XCTAssertTrue(parseFrame(w5, family: .whoop5).fields.isEmpty)
    }

    // MARK: - (b) the diagnostic path is unchanged

    func testFullPathFieldRawHexMatchesFrameBytesAcrossCorpus() throws {
        for (i, frame) in try loadFrames("frames").enumerated() {
            assertFieldRawsMatchFrameBytes(frame, family: .whoop4, "frames.json #\(i)")
        }
        for (i, frame) in try loadFrames("historical_frames").enumerated() {
            assertFieldRawsMatchFrameBytes(frame, family: .whoop4, "historical_frames.json #\(i)")
        }
        for v in Self.whoop5Vectors {
            assertFieldRawsMatchFrameBytes(hexToBytes(v.hex), family: .whoop5, v.label)
        }
    }

    /// Hard goldens for the known 4.0 REALTIME_DATA envelope frame (the InterpreterEnvelopeTests
    /// vector): exact off/len/raw/note values produced by the pre-D#742 decoder, so any drift in
    /// the diagnostic path fails here even if the slice-recompute above drifted with it.
    func testFullPathFieldGoldensOnKnownWhoop4Frame() {
        let frame = hexToBytes("aa1800ff28020f3de10128663c0000000000000000000000da855212")
        let full = parseFrame(frame, collectFields: true)
        XCTAssertTrue(full.ok)

        let sof = full.fields.first { $0.name == "SOF" }
        XCTAssertEqual(sof?.off, 0)
        XCTAssertEqual(sof?.raw, "aa")

        let type = full.fields.first { $0.name == "packet_type" }
        XCTAssertEqual(type?.off, 4)
        XCTAssertEqual(type?.raw, "28")
        XCTAssertEqual(type?.value, .string("REALTIME_DATA"))

        let hr = full.fields.first { $0.name == "heart_rate" }
        XCTAssertEqual(hr?.off, 12)
        XCTAssertEqual(hr?.len, 1)
        XCTAssertEqual(hr?.raw, "3c")
        XCTAssertEqual(hr?.value, .int(60))

        let crc32 = full.fields.first { $0.name == "crc32" }
        XCTAssertEqual(crc32?.off, 24)
        XCTAssertEqual(crc32?.raw, "da855212")
        XCTAssertEqual(crc32?.note, "OK")
    }
}
