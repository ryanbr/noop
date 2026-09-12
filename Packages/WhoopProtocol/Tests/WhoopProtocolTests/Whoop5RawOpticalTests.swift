import XCTest
@testable import WhoopProtocol

/// R20 (layout-v20, 2,140-byte) optical decoder.
///
/// The golden vectors live in `Resources/r20_optical_oracle.json`, a byte-identical copy of
/// `android/app/src/test/resources/r20_optical_oracle.json`. Both platforms decode the same REAL
/// captured records and assert the same expected values, which were produced by an independent third
/// implementation of the published byte layout — so a one-sided offset edit fails on the platform that
/// moved, not silently on both. Same idiom as `DecoderOracleTests`.
final class Whoop5RawOpticalTests: XCTestCase {

    // MARK: - Oracle fixture

    private struct Oracle: Decodable {
        let layout: Layout
        let records: [Record]
        let crcRejection: CRCRejection
        enum CodingKeys: String, CodingKey {
            case layout, records
            case crcRejection = "crc_rejection"
        }
    }
    private struct Layout: Decodable {
        let bufferLength: Int
        let blockBases: [Int]
        let blockLength: Int
        let headLength: Int
        let slotLength: Int
        let slotCapacity: Int
        let checksumOffset: Int
        let sampleMin: Int
        let sampleMax: Int
        enum CodingKeys: String, CodingKey {
            case bufferLength = "buffer_length"
            case blockBases = "block_bases"
            case blockLength = "block_length"
            case headLength = "head_length"
            case slotLength = "slot_length"
            case slotCapacity = "slot_capacity"
            case checksumOffset = "checksum_offset"
            case sampleMin = "sample_min"
            case sampleMax = "sample_max"
        }
    }
    private struct Record: Decodable {
        let name: String
        let hex: String
        let expect: Expect
    }
    private struct Expect: Decodable {
        let layoutVersion: Int
        let recordClass: Int
        let recordIndex: Int
        let baseTs: Int
        let checksum: UInt32
        let sampleCounts: [Int]
        let blocks: [BlockExpect]
        enum CodingKeys: String, CodingKey {
            case layoutVersion = "layout_version"
            case recordClass = "record_class"
            case recordIndex = "record_index"
            case baseTs = "base_ts"
            case checksum
            case sampleCounts = "sample_counts"
            case blocks
        }
    }
    private struct BlockExpect: Decodable {
        let index: Int
        let sampleCount: Int
        let sourceA: Int
        let driveA: Int
        let sourceB: Int
        let driveB: Int
        let detectorASelect: Int
        let rangeA: Int
        let offsetA: Int
        let detectorBSelect: Int
        let rangeB: Int
        let offsetB: Int
        let reserved: Int
        let readingsA: [Int32]
        let readingsB: [Int32]
        enum CodingKeys: String, CodingKey {
            case index
            case sampleCount = "sample_count"
            case sourceA = "source_a"
            case driveA = "drive_a"
            case sourceB = "source_b"
            case driveB = "drive_b"
            case detectorASelect = "detector_a_select"
            case rangeA = "range_a"
            case offsetA = "offset_a"
            case detectorBSelect = "detector_b_select"
            case rangeB = "range_b"
            case offsetB = "offset_b"
            case reserved
            case readingsA = "readings_a"
            case readingsB = "readings_b"
        }
    }
    private struct CRCRejection: Decodable {
        let source: String
        let cases: [CRCCase]
    }
    private struct CRCCase: Decodable {
        let name: String
        let offset: Int
        let xor: UInt8
        let why: String
    }

    private func loadOracle() throws -> Oracle {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "r20_optical_oracle", withExtension: "json"),
                                "missing r20_optical_oracle.json test resource")
        return try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
    }

    private func hexToBytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    // MARK: - Golden vectors

    /// Every field of every block of every fixture record, against expectations computed independently
    /// of this decoder. This is the whole byte map executing.
    func testOracleRecordsDecodeToPublishedLayout() throws {
        let oracle = try loadOracle()
        XCTAssertGreaterThan(oracle.records.count, 0, "no oracle records loaded")

        for record in oracle.records {
            let bytes = hexToBytes(record.hex)
            XCTAssertEqual(bytes.count, oracle.layout.bufferLength, "\(record.name): length")
            let decoded = try XCTUnwrap(Whoop5RawOptical.decode(bytes), "\(record.name) failed to decode")

            XCTAssertEqual(Int(decoded.layoutVersion), record.expect.layoutVersion, "\(record.name).layout_version")
            XCTAssertEqual(decoded.recordIndex, record.expect.recordIndex, "\(record.name).record_index")
            XCTAssertEqual(decoded.baseTs, record.expect.baseTs, "\(record.name).base_ts")
            XCTAssertEqual(decoded.checksum, record.expect.checksum, "\(record.name).checksum")
            XCTAssertEqual(decoded.blocks.map(\.sampleCount), record.expect.sampleCounts,
                           "\(record.name).sample_counts")

            XCTAssertEqual(decoded.blocks.count, record.expect.blocks.count, "\(record.name): block count")
            for want in record.expect.blocks {
                let block = decoded.blocks[want.index]
                let label = "\(record.name).blk\(want.index)"
                let config = block.config
                XCTAssertEqual(block.index, want.index, "\(label).index")
                XCTAssertEqual(config.sampleCount, want.sampleCount, "\(label).sample_count")
                XCTAssertEqual(Int(config.sourceA), want.sourceA, "\(label).source_a")
                XCTAssertEqual(Int(config.driveA), want.driveA, "\(label).drive_a")
                XCTAssertEqual(Int(config.sourceB), want.sourceB, "\(label).source_b")
                XCTAssertEqual(Int(config.driveB), want.driveB, "\(label).drive_b")
                XCTAssertEqual(Int(config.detectorASelect), want.detectorASelect, "\(label).detector_a_select")
                XCTAssertEqual(Int(config.rangeA), want.rangeA, "\(label).range_a")
                XCTAssertEqual(Int(config.offsetA), want.offsetA, "\(label).offset_a")
                XCTAssertEqual(Int(config.detectorBSelect), want.detectorBSelect, "\(label).detector_b_select")
                XCTAssertEqual(Int(config.rangeB), want.rangeB, "\(label).range_b")
                XCTAssertEqual(Int(config.offsetB), want.offsetB, "\(label).offset_b")
                XCTAssertEqual(Int(block.reserved), want.reserved, "\(label).reserved")
                XCTAssertEqual(block.readingsA, want.readingsA, "\(label).readings_a")
                XCTAssertEqual(block.readingsB, want.readingsB, "\(label).readings_b")

                // The 21-byte head is fully consumed by the eleven named fields, and the raw view
                // still round-trips.
                XCTAssertEqual(block.rawHeader.count, oracle.layout.headLength, "\(label).rawHeader")
                let base = oracle.layout.blockBases[want.index]
                XCTAssertEqual(block.rawHeader, Array(bytes[base..<(base + oracle.layout.headLength)]),
                               "\(label): rawHeader must reproduce the on-wire head bytes")
            }
        }
    }

    /// The block pattern that defines this record: three sampling blocks and two whose entire
    /// 400-byte reading area is zero. `sample_count == 0` must yield NO readings, not 50 zeros.
    func testBlockPatternIsThreeActiveTwoDark() throws {
        let oracle = try loadOracle()
        for record in oracle.records {
            let decoded = try XCTUnwrap(Whoop5RawOptical.decode(hexToBytes(record.hex)))
            XCTAssertEqual(decoded.blocks.map(\.sampleCount), [25, 0, 0, 25, 25], record.name)
            for block in decoded.blocks {
                // Both physical slots exist regardless; only their contents differ.
                XCTAssertEqual(block.channels.count, 2, "\(record.name).blk\(block.index)")
                XCTAssertEqual(block.readingsA.count, block.sampleCount, "\(record.name).blk\(block.index).a")
                XCTAssertEqual(block.readingsB.count, block.sampleCount, "\(record.name).blk\(block.index).b")
                XCTAssertEqual(block.reserved, 0, "\(record.name).blk\(block.index).reserved")
            }
            // Block 3 is the corpus's built-in dark control: sampling, but with both drives at zero.
            XCTAssertEqual(decoded.blocks[3].config.sampleCount, 25, record.name)
            XCTAssertEqual(decoded.blocks[3].config.driveA, 0, record.name)
            XCTAssertEqual(decoded.blocks[3].config.driveB, 0, record.name)
        }
    }

    /// Sign extension. The containers are already sign-extended on the wire, so the failure this
    /// guards is a decoder that reads them unsigned or re-extends from bit 19: either turns
    /// `ab a9 ff ff` into a large positive number instead of -22,101.
    func testNegativeReadingsSignExtend() throws {
        let oracle = try loadOracle()
        var sawNegative = false
        for record in oracle.records {
            let decoded = try XCTUnwrap(Whoop5RawOptical.decode(hexToBytes(record.hex)))
            for block in decoded.blocks {
                for value in block.readingsA + block.readingsB {
                    XCTAssertGreaterThanOrEqual(value, Whoop5RawOptical.sampleMin,
                                                "\(record.name): below the signed 20-bit floor")
                    XCTAssertLessThanOrEqual(value, Whoop5RawOptical.sampleMax,
                                             "\(record.name): above the signed 20-bit rail")
                    if value < 0 { sawNegative = true }
                }
            }
        }
        XCTAssertTrue(sawNegative, "fixture must contain negative readings or it proves nothing")
        XCTAssertEqual(Whoop5RawOptical.sampleMin, -524_288)
        XCTAssertEqual(Whoop5RawOptical.sampleMax, 524_287)

        // The exact on-wire container from the fixture's first record, decoded in isolation.
        let first = try XCTUnwrap(Whoop5RawOptical.decode(hexToBytes(oracle.records[0].hex)))
        XCTAssertEqual(first.blocks[0].readingsB.first, -22_101,
                       "wire ab a9 ff ff is -22,101; 1,048,491 or 4,294,945,195 means the sign was dropped")
    }

    /// The positive rail: exactly 2^19-1, never exceeded anywhere in the corpus. A decoder that
    /// mis-sizes the container would land somewhere else entirely.
    func testSaturationRailIsExactly2Pow19Minus1() throws {
        let oracle = try loadOracle()
        let record = try XCTUnwrap(oracle.records.first { $0.name == "rails_saturation_and_negatives" },
                                   "fixture must carry a saturated record")
        let decoded = try XCTUnwrap(Whoop5RawOptical.decode(hexToBytes(record.hex)))
        let all = decoded.blocks.flatMap { $0.readingsA + $0.readingsB }
        XCTAssertEqual(all.max(), 524_287, "positive rail")
        XCTAssertGreaterThan(all.filter { $0 == 524_287 }.count, 0, "record must actually saturate")
        XCTAssertLessThan(all.min() ?? 0, 0, "record must also carry negatives")
    }

    /// CRC gating. Bad bytes never become data: every single-bit corruption in the fixture must be
    /// REJECTED, not decoded best-effort. Each case names the checksum it trips so a regression
    /// identifies which gate was lost.
    func testSingleBitCorruptionIsRejected() throws {
        let oracle = try loadOracle()
        let source = try XCTUnwrap(oracle.records.first { $0.name == oracle.crcRejection.source })
        let clean = hexToBytes(source.hex)
        XCTAssertNotNil(Whoop5RawOptical.decode(clean), "control: the unmodified record must decode")
        XCTAssertGreaterThan(oracle.crcRejection.cases.count, 0, "no rejection cases loaded")

        for c in oracle.crcRejection.cases {
            var corrupted = clean
            corrupted[c.offset] ^= c.xor
            XCTAssertNotEqual(corrupted, clean, "\(c.name): fixture flipped nothing")
            XCTAssertNil(Whoop5RawOptical.decode(corrupted),
                         "\(c.name) (\(c.why)) decoded despite a broken checksum")
        }
    }

    /// The CRC input range, asserted directly, because the previously published value was `[26:2136]`
    /// and anything built on it rejects every real record. This is the standard WHOOP 5 envelope rule.
    func testChecksumCoversByte8ThroughPayloadEnd() throws {
        let oracle = try loadOracle()
        let bytes = hexToBytes(oracle.records[0].hex)
        let trailer = UInt32(bytes[2136]) | (UInt32(bytes[2137]) << 8)
            | (UInt32(bytes[2138]) << 16) | (UInt32(bytes[2139]) << 24)
        XCTAssertEqual(crc32(bytes, 8, 2136), trailer, "CRC32 input is [8:2136]")
        XCTAssertNotEqual(crc32(bytes, 26, 2136), trailer, "the retracted [26:2136] range must NOT match")
        // Header bytes 6:7, listed as unidentified in the write-up, are the envelope's CRC16-Modbus.
        let headerCRC = UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)
        XCTAssertEqual(crc16Modbus(bytes, 0, 6), headerCRC, "header CRC16-Modbus over [0:6]")
        XCTAssertTrue(verifyFrame(bytes, family: .whoop5).ok, "both checksums verify as one envelope check")
    }

    // MARK: - Full-corpus verification

    /// Runs the decoder over a whole deep-buffer capture and asserts the published invariants on every
    /// record. Two golden vectors prove the offsets; this proves they hold at scale, which is the claim
    /// issue #423 actually makes.
    ///
    /// Opt-in, because the capture is far too large to commit:
    ///
    ///     WHOOP_R20_CORPUS=/path/to/buffers2140.jsonl swift test --filter testFullCorpus
    ///
    /// The file is the recorder's own JSONL — one object per line with `hex`, `size` and `strap_ts`.
    /// Verified against a 29,203-record WHOOP 5.0/MG capture: 29,203/29,203 decode, 0 mismatches.
    func testFullCorpusDecodesWithPublishedInvariants() throws {
        guard let path = ProcessInfo.processInfo.environment["WHOOP_R20_CORPUS"] else {
            throw XCTSkip("set WHOOP_R20_CORPUS to a deep-buffer JSONL to run the full-corpus check")
        }
        let text = try String(contentsOfFile: path, encoding: .utf8)

        let driveSet: Set<UInt16> = [1150, 1400, 1750, 2200, 2750, 3350]
        var total = 0, decoded = 0, mismatched = 0
        var failures: [String] = []

        text.enumerateLines { line, _ in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let size = obj["size"] as? Int, size == Whoop5RawOptical.bufferLength,
                  let hex = obj["hex"] as? String else { return }
            total += 1
            let bytes = self.hexToBytes(hex)
            guard let frame = Whoop5RawOptical.decode(bytes) else {
                if failures.count < 5 { failures.append("record \(total) failed to decode") }
                return
            }
            decoded += 1

            var problems: [String] = []
            // The recorder's own envelope timestamp must agree with the decoded field.
            if let strapTs = obj["strap_ts"] as? Int, frame.baseTs != strapTs {
                problems.append("base_ts \(frame.baseTs) != strap_ts \(strapTs)")
            }
            if frame.blocks.map(\.sampleCount) != [25, 0, 0, 25, 25] { problems.append("block pattern") }
            let blk0 = frame.blocks[0].config
            if !driveSet.contains(blk0.driveA) { problems.append("drive_a \(blk0.driveA) outside the six-value set") }
            if Int(blk0.driveB) != Int(blk0.driveA) * 2 { problems.append("drive_b != 2 * drive_a") }
            for block in frame.blocks {
                if block.reserved != 0 { problems.append("blk\(block.index) reserved != 0") }
                if block.config.offsetA % 800 != 0 || block.config.offsetB % 800 != 0 {
                    problems.append("blk\(block.index) offset not a multiple of 800")
                }
                if block.readingsA.count != block.sampleCount || block.readingsB.count != block.sampleCount {
                    problems.append("blk\(block.index) reading count != sample_count")
                }
                if let out = (block.readingsA + block.readingsB).first(where: {
                    $0 < Whoop5RawOptical.sampleMin || $0 > Whoop5RawOptical.sampleMax
                }) {
                    problems.append("blk\(block.index) sample \(out) outside the signed 20-bit domain")
                }
            }
            if !problems.isEmpty {
                mismatched += 1
                if failures.count < 5 { failures.append("record \(total): \(problems.joined(separator: ", "))") }
            }
        }

        print("R20 corpus: \(decoded)/\(total) decoded, \(mismatched) invariant mismatches")
        XCTAssertGreaterThan(total, 0, "no 2,140-byte records found in \(path)")
        XCTAssertEqual(decoded, total, "every record must decode. first failures: \(failures)")
        XCTAssertEqual(mismatched, 0, "published invariants must hold on every record: \(failures)")
    }

    // MARK: - Structural gates

    func testStrictShapeAndCountGates() {
        var frame = Self.sealedSyntheticFrame()
        XCTAssertNotNil(Whoop5RawOptical.decode(frame))

        // A sample count beyond the 50-slot capacity cannot be honoured, even with valid checksums.
        frame[Whoop5RawOptical.blockStart] = UInt8(Whoop5RawOptical.channelCapacity + 1)
        XCTAssertNil(Whoop5RawOptical.decode(Self.reseal(frame)))

        // Wrong length, wrong record class, wrong layout version.
        XCTAssertNil(Whoop5RawOptical.decode(Self.sealedSyntheticFrame() + [0]))
        var wrongClass = Self.sealedSyntheticFrame(); wrongClass[8] = 0x2E
        XCTAssertNil(Whoop5RawOptical.decode(Self.reseal(wrongClass)))
        var wrongVersion = Self.sealedSyntheticFrame(); wrongVersion[9] = 21
        XCTAssertNil(Whoop5RawOptical.decode(Self.reseal(wrongVersion)))
    }

    func testInterpreterExposesHeadersWithoutWavelengthLabels() {
        let parsed = parseFrame(Whoop5HistoricalV2021Tests.realFrameV20Bytes, family: .whoop5).parsed
        XCTAssertEqual(parsed["sensor_block_count"]?.intValue, 5)
        XCTAssertEqual(parsed["block_b0_sample_count"]?.intValue, 25)
        XCTAssertEqual(parsed["block_b1_sample_count"]?.intValue, 0)
        XCTAssertEqual(parsed["block_b4_header"]?.intArrayValue?.count, 21)
        XCTAssertEqual(parsed["channel_b4_0"]?.intArrayValue?.count, 25)
        XCTAssertEqual(parsed["channel_b4_1"]?.intArrayValue?.count, 25)
        XCTAssertNil(parsed["red"])
        XCTAssertNil(parsed["ir"])
    }

    /// The Swift and Android copies of the oracle MUST be byte-identical, so neither platform can edit
    /// its fixture without the other. Mirrors `DecoderOracleTests.testOracleCopiesAreIdentical`.
    func testOracleCopiesAreIdentical() throws {
        let swiftURL = try XCTUnwrap(Bundle.module.url(forResource: "r20_optical_oracle", withExtension: "json"))
        let swiftData = try Data(contentsOf: swiftURL)

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // WhoopProtocolTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // WhoopProtocol
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo root
        let androidURL = repoRoot.appendingPathComponent("android/app/src/test/resources/r20_optical_oracle.json")
        guard FileManager.default.fileExists(atPath: androidURL.path) else {
            throw XCTSkip("android oracle copy not present at \(androidURL.path)")
        }
        XCTAssertEqual(swiftData, try Data(contentsOf: androidURL),
                       "r20_optical_oracle.json copies differ — keep Swift and Android in lockstep")
    }

    // MARK: - Synthetic frame helpers

    /// A minimal, structurally valid, checksum-sealed v20 frame. Sealing is not optional any more:
    /// the decoder CRC-gates, so a hand-built frame has to carry real checksums exactly like a strap's.
    static func sealedSyntheticFrame() -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: Whoop5RawOptical.bufferLength)
        frame[0] = 0xAA
        frame[1] = 0x01
        frame[2] = 0x54          // declared length 2132 = 2140 - 8
        frame[3] = 0x08
        frame[4] = 0x01
        frame[8] = Whoop5RawOptical.recordClass
        frame[9] = Whoop5RawOptical.layoutVersion
        return reseal(frame)
    }

    /// Recompute both checksums after mutating a frame, so a test asserts the gate it means to.
    static func reseal(_ frame: [UInt8]) -> [UInt8] {
        var out = frame
        guard out.count >= 12 else { return out }
        let headerCRC = crc16Modbus(out, 0, 6)
        out[6] = UInt8(headerCRC & 0xFF)
        out[7] = UInt8((headerCRC >> 8) & 0xFF)
        let end = Whoop5RawOptical.checksumOffset
        guard out.count >= end + 4 else { return out }
        let payloadCRC = crc32(out, 8, end)
        out[end] = UInt8(payloadCRC & 0xFF)
        out[end + 1] = UInt8((payloadCRC >> 8) & 0xFF)
        out[end + 2] = UInt8((payloadCRC >> 16) & 0xFF)
        out[end + 3] = UInt8((payloadCRC >> 24) & 0xFF)
        return out
    }

    // MARK: - direct caller of the verifier (2.5): the useful path is unchanged

    /// `Whoop5RawOptical.decode` calls `verifyFrame` directly. The real captured record must still
    /// decode under the tightened verifier — the 2,140-byte buffer declares 2,132, so its total is
    /// exact and it clears the structural rules — and the reason on the check must be `none`, not just
    /// a positive verdict by accident.
    func testTheRealRecordStillDecodesUnderTheTightenedVerifier() throws {
        let oracle = try loadOracle()
        let bytes = hexToBytes(oracle.records[0].hex)
        let check = verifyFrame(bytes, family: .whoop5)
        XCTAssertTrue(check.ok)
        XCTAssertEqual(check.reason, .none)
        XCTAssertNotNil(Whoop5RawOptical.decode(bytes), "the useful path must be untouched")
    }

    /// And the frame class the verifier newly rejects is refused before any sample is read.
    func testARecordWithABrokenHeaderChecksumIsRefused() {
        var frame = Self.sealedSyntheticFrame()
        XCTAssertNotNil(Whoop5RawOptical.decode(frame), "control: the sealed frame decodes")
        frame[6] ^= 0xFF                                  // header CRC16 only; the payload CRC32 stands
        XCTAssertEqual(verifyFrame(frame, family: .whoop5).crc32OK, true)
        XCTAssertEqual(verifyFrame(frame, family: .whoop5).reason, .headerChecksumMismatch)
        XCTAssertNil(Whoop5RawOptical.decode(frame))
    }
}
