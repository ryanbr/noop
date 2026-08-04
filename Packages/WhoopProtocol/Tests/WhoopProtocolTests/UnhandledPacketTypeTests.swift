import XCTest
@testable import WhoopProtocol

/// #891 — a history offload must not silently discard a packet type nobody has mapped.
///
/// `extractHistoricalStreams` switches on four of the schema's sixteen packet types and `default:`s the
/// rest, and `rejectedHistoricalRecords` archives only type-47 ("Console (50) and METADATA frames have a
/// different type byte, so they never pass this gate — they are excluded by construction"). So before this
/// census an unmapped record was dropped twice and counted zero times, and the sync reported clean.
///
/// That is not a hypothetical gap. `HISTORICAL_IMU_DATA_STREAM(52)` is a banked raw-stream type the schema
/// already names and the funnel does not handle. It is also the shape #891's leading hypothesis predicts:
/// if a 5/MG banks ECG to flash after the Labrador toggles, the experiment that would find it cannot
/// currently produce a finding, because nothing would report the record.
///
/// These mirror the Android `HistoricalStreamsUnhandledTypeTest` 1:1 — SAME exclusions, SAME names.
final class UnhandledPacketTypeTests: XCTestCase {

    private let wallNow = Int(Date().timeIntervalSince1970) - 7 * 86_400

    /// A CRC-valid frame of `typeName` carrying nothing the funnel wants — the shape of a record whose
    /// envelope decodes but whose body this decoder has no rows for.
    private func frame(_ typeName: String) -> ParsedFrame {
        ParsedFrame(ok: true, typeName: typeName, seq: 0, cmdName: nil, crcOK: true,
                    lenBytes: 0, rawHex: "", fields: [], parsed: [:])
    }

    private func histFrame(unix: Int, bpm: Int = 60) -> ParsedFrame {
        ParsedFrame(
            ok: true, typeName: "HISTORICAL_DATA", seq: 24, cmdName: nil, crcOK: true,
            lenBytes: 0, rawHex: "", fields: [],
            parsed: ["hist_version": .int(24), "unix": .int(unix), "heart_rate": .int(bpm)]
        )
    }

    private func extract(_ frames: [ParsedFrame]) -> Streams {
        extractHistoricalStreams(frames, deviceClockRef: wallNow, wallClockRef: wallNow)
    }

    // MARK: - the gap this closes

    /// A schema-NAMED type the funnel has no case for is counted, not silently dropped. This is the
    /// banked-raw-stream type behind #891 hypothesis (b).
    func testNamedButUnhandledTypeIsCounted() {
        let st = extract([frame("HISTORICAL_IMU_DATA_STREAM"), frame("HISTORICAL_IMU_DATA_STREAM")])
        XCTAssertEqual(st.unhandledPacketTypes, ["HISTORICAL_IMU_DATA_STREAM": 2])
        XCTAssertTrue(st.isEmpty, "it still yields no rows — this is a census, not a decoder")
    }

    /// A byte the schema does not name at all renders `type<N>` (`Schema.typeName`) and is counted under
    /// that name, so the number reaches the strap log even with no vocabulary for it.
    func testUnmappedByteIsCountedUnderItsRenderedName() {
        let st = extract([frame("type53")])
        XCTAssertEqual(st.unhandledPacketTypes, ["type53": 1])
    }

    /// Several unmapped types in one chunk are counted separately, so a report names each.
    func testDistinctTypesAreTalliedSeparately() {
        let st = extract([frame("type53"), frame("HISTORICAL_IMU_DATA_STREAM"), frame("type53")])
        XCTAssertEqual(st.unhandledPacketTypes, ["type53": 2, "HISTORICAL_IMU_DATA_STREAM": 1])
    }

    // MARK: - and does not cry wolf

    /// METADATA and CONSOLE_LOGS reach `default:` on a normal sync and decode to zero rows BY DESIGN.
    /// Counting them would put a scary line in every strap log and train people to ignore the one that
    /// matters, so they are excluded by name.
    func testExpectedUnhandledTypesAreNotCounted() {
        let st = extract([frame("CONSOLE_LOGS"), frame("METADATA"), frame("CONSOLE_LOGS")])
        XCTAssertTrue(st.unhandledPacketTypes.isEmpty)
    }

    /// The exclusion set is pinned: it must stay exactly these two, and must stay in lockstep with Android.
    /// Adding to it is how this census would quietly stop reporting the thing it was built for.
    func testExclusionSetIsExactlyMetadataAndConsole() {
        XCTAssertEqual(expectedUnhandledHistoricalTypes, ["METADATA", "CONSOLE_LOGS"])
    }

    /// A normal offload logs nothing — the common case must stay silent or the signal is worthless.
    func testOrdinaryRecordsProduceNoCensus() {
        let st = extract([histFrame(unix: wallNow), histFrame(unix: wallNow + 1)])
        XCTAssertEqual(st.hr.count, 2)
        XCTAssertTrue(st.unhandledPacketTypes.isEmpty)
    }

    /// A CRC-failed frame is skipped before the switch and is NOT reported as an unhandled type — it is a
    /// different failure with its own archive (`rejectedHistoricalRecords`), and conflating them would
    /// misattribute a corrupt frame to an unknown firmware feature.
    func testCrcFailedFrameIsNotCountedAsUnhandled() {
        let bad = ParsedFrame(ok: true, typeName: "HISTORICAL_IMU_DATA_STREAM", seq: 0, cmdName: nil,
                              crcOK: false, lenBytes: 0, rawHex: "", fields: [], parsed: [:])
        XCTAssertTrue(extract([bad]).unhandledPacketTypes.isEmpty)
    }

    /// END TO END, through the real parser — the test that actually proves the feature works.
    ///
    /// Every other case here hand-builds a `ParsedFrame` with `ok: true`, which assumes the thing most
    /// likely to be wrong: `extractHistoricalStreams` skips `!r.ok` BEFORE its switch, so if `parseFrame`
    /// marked an unmapped type not-ok the census would never fire on a real frame and every assertion above
    /// would still pass. It does not — `spec == nil` annotates the payload and falls through to `ok: true` —
    /// but that is a fact about the parser, and a fact the census depends on belongs in a test rather than
    /// in my reading of it. The Kotlin twin builds real bytes throughout; this is the Swift equivalent.
    func testRealFrameOfAnUnmappedTypeReachesTheCensus() {
        // WHOOP 4.0 envelope: [AA][len lo][len hi][crc8(len)] + inner + crc32(inner). Type byte leads the
        // inner record, so this is a well-formed frame of a type the schema does not name.
        let inner: [UInt8] = [99, 0x11, 0x00]
        // The length field covers the inner record PLUS the 4-byte CRC32 trailer, not the record alone —
        // get it wrong and the parser cannot locate the trailer, so `crcOK` comes back nil rather than
        // true and the frame is malformed in a way that still counts. Same convention as
        // Whoop4ResponseResultTests ([0xAA, 7, 0, 0] for a 3-byte inner).
        var frame: [UInt8] = [0xAA, UInt8(inner.count + 4), 0, 0]
        frame[3] = crc8(Array(frame[1..<3]))
        frame += inner
        let c32 = crc32(inner)
        frame += [UInt8(c32 & 0xFF), UInt8((c32 >> 8) & 0xFF),
                  UInt8((c32 >> 16) & 0xFF), UInt8((c32 >> 24) & 0xFF)]

        let parsed = parseFrame(frame)
        XCTAssertTrue(parsed.ok, "an unmapped type must still parse, or the census is unreachable")
        XCTAssertEqual(parsed.crcOK, true)
        XCTAssertEqual(parsed.typeName, "type99")

        let st = extract([parsed])
        XCTAssertEqual(st.unhandledPacketTypes, ["type99": 1])
    }

    /// The rendering is FAMILY-AWARE: a WHOOP 4.0 frame renders through `schema.typeName` (no aliasing), a
    /// 5/MG frame through `canonicalTypeName`.
    ///
    /// Type 56 is where that bites. Here it is PUFFIN_METADATA and gets counted; had Android always aliased
    /// (its `Framing.typeName` does), it would have become METADATA there and been silently EXCLUDED — the
    /// two platforms disagreeing about an anomalous frame, which is the single case the census exists for.
    /// A puffin type arriving on a 4.0 is worth reporting, not swallowing.
    func testPuffinMetadataOnWhoop4IsCountedNotAliasedIntoTheExclusion() {
        XCTAssertEqual(extract([frame("PUFFIN_METADATA")]).unhandledPacketTypes, ["PUFFIN_METADATA": 1])
    }

    /// The 4.0 rendering never aliases 38 either — same rule, the other puffin type.
    func testPuffinCommandResponseOnWhoop4KeepsItsOwnName() {
        XCTAssertEqual(extract([frame("PUFFIN_COMMAND_RESPONSE")]).unhandledPacketTypes,
                       ["PUFFIN_COMMAND_RESPONSE": 1])
    }

    /// The census is transient diagnostics: it must not ride the Codable path that golden fixtures assert.
    func testCensusIsNotEncoded() throws {
        var st = Streams()
        st.unhandledPacketTypes = ["HISTORICAL_IMU_DATA_STREAM": 3]
        let json = String(data: try JSONEncoder().encode(st), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("HISTORICAL_IMU_DATA_STREAM"))
        XCTAssertFalse(json.contains("unhandledPacketTypes"))
    }
}
