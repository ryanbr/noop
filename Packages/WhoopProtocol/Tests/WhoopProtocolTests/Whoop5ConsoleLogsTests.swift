import XCTest
@testable import WhoopProtocol

/// WHOOP 5.0 ("puffin") CONSOLE_LOGS (type 50) decode, verified against real captured frames.
///
/// The strap streams its firmware console as fixed-size text chunks: record header (`console_sequence`
/// u8@9, raw byte @10, `unix` u32@12, `subsec` u16@16, chunk_len u16@18, channel u8@20), then the raw text at @21
/// with NUL padding up to the CRC32 trailer. One log line routinely spans several frames — the two
/// consecutive fixtures below split "…start response a" / "ck, start burst" mid-word — so consumers
/// retain arrival order and check wrapping sequences before reading. Existing fixtures are from a 2026-07-12
/// history sync (the strap narrating its own transfer); they carry no device name / serial / token.
final class Whoop5ConsoleLogsTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    /// Real console chunk: a full log line plus the continuation space, NUL-terminated.
    private let sendHistoricalHex =
        "aa014400010030b132ac020052b4526a33733400013134363535323131393a20424c455f434d443a2043" +
        "6f6d6d616e642053656e6420486973746f726963616c20446174610a200018d8fbf6"

    func testConsoleChunkDecodesHeaderAndText() {
        let f = parseFrame(bytes(sendHistoricalHex), family: .whoop5)
        XCTAssertEqual(f.typeName, "CONSOLE_LOGS")
        XCTAssertEqual(f.crcOK, true)
        XCTAssertEqual(f.parsed["console_sequence"]?.intValue, 172)
        XCTAssertEqual(f.parsed["console_header_byte_10"]?.intValue, 2)
        XCTAssertNil(f.parsed["record_index"])
        XCTAssertEqual(f.parsed["unix"]?.intValue, 1783805010)
        XCTAssertEqual(f.parsed["subsec"]?.intValue, 29491)
        XCTAssertEqual(f.parsed["log"]?.stringValue,
                       "146552119: BLE_CMD: Command Send Historical Data\n ")
    }

    /// The next two chunks of the same stream: one log line split mid-word ("…response a" | "ck,
    /// start burst…") across consecutive sequence values.
    private let splitLineAHex =
        "aa014400010030b132ad020052b4526a337334000131392c203134363535323131393a20424c453a2068" +
        "697374207472616e7366657220737461727420726573706f6e7365206100324a7906"
    private let splitLineBHex =
        "aa014400010030b132ae020052b4526a3373340001636b2c2073746172742062757273740a2031392c20" +
        "3134363535343633303a20424c453a20486973746f727920627572737400e67d611f"

    func testConsecutiveChunksCarryContiguousSequences() {
        let a = parseFrame(bytes(splitLineAHex), family: .whoop5)
        let b = parseFrame(bytes(splitLineBHex), family: .whoop5)
        XCTAssertEqual(a.crcOK, true)
        XCTAssertEqual(b.crcOK, true)
        XCTAssertEqual(a.parsed["console_sequence"]?.intValue, 173)
        XCTAssertEqual(b.parsed["console_sequence"]?.intValue, 174)
        XCTAssertEqual(a.parsed["log"]?.stringValue,
                       "19, 146552119: BLE: hist transfer start response a")
        XCTAssertEqual(b.parsed["log"]?.stringValue,
                       "ck, start burst\n 19, 146554630: BLE: History burst")
    }

    /// Synthetic headers reproduce the independently captured 255 -> 0 wrap while @10 stays 2.
    /// No raw user capture is embedded. A u16 read would report 767 -> 512 instead.
    func testConsoleSequenceWrapDoesNotCarryIntoHeaderByte() {
        for sequence: UInt8 in [254, 255, 0, 1] {
            var frame = consoleFrame(textBytes: Array("fragment".utf8))
            frame[9] = sequence
            frame[10] = 2
            let parsed = parseFrame(frame, family: .whoop5).parsed
            XCTAssertEqual(parsed["console_sequence"]?.intValue, Int(sequence))
            XCTAssertEqual(parsed["console_header_byte_10"]?.intValue, 2)
            XCTAssertNil(parsed["record_index"], "console chunks have no monotonic historical index")
            XCTAssertEqual(parsed["log"]?.stringValue, "fragment")
        }
    }

    func testConsoleHeaderByteDoesNotChangeSequence() {
        for headerByte: UInt8 in [0, 2, 255] {
            var frame = consoleFrame(textBytes: Array("fragment".utf8))
            frame[9] = 7
            frame[10] = headerByte
            let parsed = parseFrame(frame, family: .whoop5).parsed
            XCTAssertEqual(parsed["console_sequence"]?.intValue, 7)
            XCTAssertEqual(parsed["console_header_byte_10"]?.intValue, Int(headerByte))
        }
    }

    /// A truncated frame (header only, no text region) must not decode a log — and must not crash.
    func testHeaderOnlyFrameYieldsNoLog() {
        let full = bytes(sendHistoricalHex)
        let truncated = Array(full[0..<20])
        let f = parseFrame(truncated, family: .whoop5)
        XCTAssertNil(f.parsed["log"])
    }

    // MARK: - Text-region hardening edges (synthetic frames)

    /// A synthetic CONSOLE_LOGS frame carrying `textBytes` at @21. The CRC32 trailer is left zero:
    /// field decode is CRC-independent (the flag is only reported, never gated on), so these pin the
    /// trim/cap edges without a real capture — the fixtures above already prove the happy path + CRC.
    private func consoleFrame(textBytes: [UInt8]) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: 21)   // envelope + record header (all zero but @0/@1/@8)
        f[0] = 0xAA
        f[1] = 0x01
        f[8] = 0x32                                 // CONSOLE_LOGS (type 50)
        f.append(contentsOf: textBytes)
        f.append(contentsOf: [0, 0, 0, 0])          // CRC32 trailer (unchecked)
        let declaredLength = f.count - 8            // payload + 4-byte CRC32 (u16 LE @2)
        f[2] = UInt8(declaredLength & 0xFF)
        f[3] = UInt8((declaredLength >> 8) & 0xFF)
        return f
    }

    /// The 2 KB cap (a garbled/malicious peer must not pin arbitrary bytes as a String). A real chunk
    /// is ~51 bytes and can never reach this from the strap, so it needs a synthetic oversize frame.
    func testOversizedTextIsCappedAt2048() {
        let f = consoleFrame(textBytes: [UInt8](repeating: 0x41, count: 2100))  // 'A' × 2100
        let p = parseFrame(f, family: .whoop5)
        XCTAssertEqual(p.parsed["log"]?.stringValue?.count, 2048)
    }

    /// An all-NUL (padding-only) text region trims to empty → no `log` key at all, not an empty string.
    func testAllNulTextRegionYieldsNoLog() {
        let f = consoleFrame(textBytes: [0, 0, 0, 0, 0, 0])
        let p = parseFrame(f, family: .whoop5)
        XCTAssertNil(p.parsed["log"])
    }

    /// Only TRAILING NULs are trimmed; the text before them is kept verbatim.
    func testTrailingNulsAreTrimmed() {
        let f = consoleFrame(textBytes: Array("AB".utf8) + [0, 0, 0])
        let p = parseFrame(f, family: .whoop5)
        XCTAssertEqual(p.parsed["log"]?.stringValue, "AB")
    }
}
