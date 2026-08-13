import XCTest
@testable import WhoopProtocol

// ReTools — the four offline RE aids. Frames are built by decoding controlled JSON through
// `ParsedFrame`'s own Codable conformance, so each test drives exact field spans / byte values without
// depending on the wire format or CRC. The point is the analysis math, and it must be deterministic.
final class ReToolsTests: XCTestCase {

    // Build a ParsedFrame with the given type, version (seq), named field spans, and decoded dict.
    private func frame(type: String, seq: Int? = nil, len: Int,
                       named: [(off: Int, len: Int)] = [], ok: Bool = true, crcOK: Bool = true,
                       parsed: [String: Any] = [:]) -> ParsedFrame {
        let fields: [[String: Any]] = named.map { span in
            ["off": span.off, "len": span.len, "name": "f\(span.off)", "cat": "x",
             "value": NSNull(), "raw": "", "note": NSNull()]
        }
        var dict: [String: Any] = [
            "ok": ok, "typeName": type, "seq": seq as Any? ?? NSNull(), "cmdName": NSNull(),
            "crcOK": crcOK, "lenBytes": len, "rawHex": "", "fields": fields, "parsed": parsed,
        ]
        if seq == nil { dict["seq"] = NSNull() }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(ParsedFrame.self, from: data)
    }

    private func rec(_ f: ParsedFrame, bytes: [UInt8], ts: Int? = nil) -> ReTools.Record {
        ReTools.Record(frame: f, bytes: bytes, tsMs: ts, hr: nil)
    }

    // MARK: - group key: HISTORICAL_DATA splits by version (seq), others don't

    func testGroupKeyVersionsHistoricalOnly() {
        XCTAssertEqual(ReTools.groupKey(frame(type: "HISTORICAL_DATA", seq: 18, len: 4)), "HISTORICAL_DATA/v18")
        XCTAssertEqual(ReTools.groupKey(frame(type: "HISTORICAL_DATA", seq: 20, len: 4)), "HISTORICAL_DATA/v20")
        // A non-historical type ignores seq (seq there is a command counter, not a layout selector).
        XCTAssertEqual(ReTools.groupKey(frame(type: "EVENT", seq: 7, len: 4)), "EVENT")
    }

    // MARK: - A) coverage: covered count, constant vs varying unknowns

    func testCoverageNamesConstantAndVaryingUnknowns() {
        // 6-byte HISTORICAL_DATA v18: bytes 0..1 named (a 2-byte field). 2 = constant unknown,
        // 3 = varying unknown, 4..5 unnamed too (both varying).
        let f = { (b: [UInt8]) in self.rec(self.frame(type: "HISTORICAL_DATA", seq: 18, len: 6,
                                                       named: [(0, 2)]), bytes: b) }
        let recs = [f([0xAA, 0x01, 0x09, 0x10, 0x00, 0x00]),
                    f([0xBB, 0x02, 0x09, 0x20, 0x01, 0xFF]),
                    f([0xCC, 0x03, 0x09, 0x30, 0x02, 0x80])]
        let cov = ReTools.coverage(recs)
        XCTAssertEqual(cov.count, 1)
        let g = cov[0]
        XCTAssertEqual(g.key, "HISTORICAL_DATA/v18")
        XCTAssertEqual(g.frameCount, 3)
        XCTAssertEqual(g.frameLen, 6)
        XCTAssertEqual(g.coveredBytes, 2)          // only offsets 0,1 named
        XCTAssertEqual(g.totalBytes, 6)
        XCTAssertEqual(g.unknownBytes.map { $0.offset }, [2, 3, 4, 5])
        let byOff = Dictionary(uniqueKeysWithValues: g.unknownBytes.map { ($0.offset, $0) })
        XCTAssertTrue(byOff[2]!.constant)          // always 0x09
        XCTAssertEqual(byOff[2]!.minValue, 0x09)
        XCTAssertEqual(byOff[2]!.maxValue, 0x09)
        XCTAssertFalse(byOff[3]!.constant)         // 0x10/0x20/0x30
        XCTAssertEqual(byOff[3]!.distinctValues, 3)
        XCTAssertEqual(byOff[3]!.minValue, 0x10)
        XCTAssertEqual(byOff[3]!.maxValue, 0x30)
    }

    func testCoverageUsesModalLengthAndUnionsConditionalFields() {
        // A lone truncated frame must not skew offsets: modal length wins.
        let full = frame(type: "REALTIME_DATA", len: 4, named: [(0, 1)])
        let short = frame(type: "REALTIME_DATA", len: 2, named: [(0, 1)])
        let recs = [rec(full, bytes: [0x01, 0x02, 0x03, 0x04]),
                    rec(full, bytes: [0x01, 0x02, 0x03, 0x05]),
                    rec(short, bytes: [0x01, 0x02])]
        let g = ReTools.coverage(recs).first { $0.key == "REALTIME_DATA" }!
        XCTAssertEqual(g.frameLen, 4)              // modal, not the 2-byte outlier
        XCTAssertEqual(g.unknownBytes.map { $0.offset }, [1, 2, 3])
    }

    func testCoverageEntropyFlagsRandomButNotStructured() {
        // Structured: unknown bytes are a constant + a small ramp → low entropy, never flagged.
        var structured: [ReTools.Record] = []
        for i in 0..<300 {
            let ramp = UInt8(i % 4)
            let bytes: [UInt8] = [0x01, 0x09, ramp]   // off1 constant, off2 tiny range
            structured.append(rec(frame(type: "HISTORICAL_DATA", seq: 20, len: 3, named: [(0, 1)]), bytes: bytes))
        }
        let sg = ReTools.coverage(structured)[0]
        XCTAssertLessThan(sg.unknownEntropyBits, 3.0)   // structured: far below the 7.5 encrypted flag
        XCTAssertFalse(sg.likelyEncrypted)

        // Random-looking: unknown bytes sweep the full 0..255 space → entropy ≈ 8, flagged.
        var random: [ReTools.Record] = []
        for i in 0..<300 {
            let a = UInt8(i % 256)
            let b = UInt8((i * 37 + 11) % 256)
            let bytes: [UInt8] = [0x01, a, b]
            random.append(rec(frame(type: "HISTORICAL_DATA", seq: 21, len: 3, named: [(0, 1)]), bytes: bytes))
        }
        let rg = ReTools.coverage(random)[0]
        XCTAssertGreaterThan(rg.unknownEntropyBits, 7.5)
        XCTAssertGreaterThanOrEqual(rg.unknownSampleCount, 256)
        XCTAssertTrue(rg.likelyEncrypted)
    }

    func testCoverageEntropyIsPerOffsetNotPooled() {
        // Each unknown offset holds a DIFFERENT constant. Pooled entropy would read ~log2(8)=3 bits and
        // look "somewhat random"; per-offset entropy is 0 at every position → mean 0. This is the whole
        // point of measuring per-position, not pooled.
        var recs: [ReTools.Record] = []
        for _ in 0..<300 {
            let bytes: [UInt8] = [0xAA, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]  // off0 named, 1..7 distinct constants
            recs.append(rec(frame(type: "HISTORICAL_DATA", seq: 20, len: 8, named: [(0, 1)]), bytes: bytes))
        }
        let g = ReTools.coverage(recs)[0]
        XCTAssertEqual(g.unknownEntropyBits, 0.0, accuracy: 1e-9)   // every position constant → 0, despite 7 distinct values
        XCTAssertFalse(g.likelyEncrypted)
        XCTAssertEqual(g.unknownSampleCount, 300)                   // frames, not bytes
        XCTAssertTrue(g.unknownBytes.allSatisfy { $0.constant })
    }

    // MARK: - C) inventory: census sorted by count, ok/crc, ts span, len spread

    func testInventoryCensus() {
        let hist = frame(type: "HISTORICAL_DATA", seq: 26, len: 8, ok: true, crcOK: true)
        let bad = frame(type: "HISTORICAL_DATA", seq: 26, len: 6, ok: false, crcOK: false)
        let evt = frame(type: "EVENT", len: 4, ok: true, crcOK: true)
        let recs = [rec(hist, bytes: Array(repeating: 0, count: 8), ts: 1000),
                    rec(hist, bytes: Array(repeating: 0, count: 8), ts: 3000),
                    rec(bad, bytes: Array(repeating: 0, count: 6), ts: 2000),
                    rec(evt, bytes: [0, 0, 0, 0], ts: 500)]
        let inv = ReTools.inventory(recs)
        XCTAssertEqual(inv.first?.key, "HISTORICAL_DATA/v26")   // 3 records → most common, sorts first
        let h = inv.first!
        XCTAssertEqual(h.count, 3)
        XCTAssertEqual(h.okCount, 2)
        XCTAssertEqual(h.crcOkCount, 2)
        XCTAssertEqual(h.firstTsMs, 1000)
        XCTAssertEqual(h.lastTsMs, 3000)
        XCTAssertEqual(h.minLen, 6)
        XCTAssertEqual(h.maxLen, 8)
    }

    // MARK: - B) diff: presence + feature-linked (disjoint) offsets

    func testDiffPresenceAndDisjointOffsets() {
        // Capture A: two record types. Capture B: one shared type with a flipped byte, plus a type A lacks.
        let sharedA = frame(type: "HISTORICAL_DATA", seq: 26, len: 4, named: [(0, 1)])
        let sharedB = frame(type: "HISTORICAL_DATA", seq: 26, len: 4, named: [(0, 1)])
        let onlyA = frame(type: "METADATA", len: 4)
        let onlyB = frame(type: "REALTIME_RAW_DATA", len: 4)
        // Offset 2 is disjoint (A always 0x00, B always 0x01) → the feature-linked byte.
        let a = [rec(sharedA, bytes: [0x0A, 0x0B, 0x00, 0x0C]),
                 rec(sharedA, bytes: [0x0A, 0x0B, 0x00, 0x0D]),
                 rec(onlyA, bytes: [0, 0, 0, 0])]
        let b = [rec(sharedB, bytes: [0x0A, 0x0B, 0x01, 0x0C]),
                 rec(sharedB, bytes: [0x0A, 0x0B, 0x01, 0x0D]),
                 rec(onlyB, bytes: [0, 0, 0, 0])]
        let d = ReTools.diff(a, b)
        let byKey = Dictionary(uniqueKeysWithValues: d.map { ($0.key, $0) })
        XCTAssertEqual(byKey["METADATA"]?.inA, true)
        XCTAssertEqual(byKey["METADATA"]?.inB, false)
        XCTAssertEqual(byKey["REALTIME_RAW_DATA"]?.inB, true)
        XCTAssertEqual(byKey["REALTIME_RAW_DATA"]?.inA, false)
        let shared = byKey["HISTORICAL_DATA/v26"]!
        XCTAssertTrue(shared.inA && shared.inB)
        let changed = shared.changedOffsets
        XCTAssertEqual(changed.map { $0.offset }, [2])   // only offset 2 differs; 3 shares {0C,0D}
        XCTAssertTrue(changed[0].disjoint)
        XCTAssertEqual(changed[0].aValues, [0x00])
        XCTAssertEqual(changed[0].bValues, [0x01])
    }

    func testDiffSurfacesLengthMismatch() {
        // Same type/version, but B's layout grew by two trailing bytes (a feature that ADDS bytes) —
        // those extra bytes are past the overlap and must be flagged, not silently dropped.
        let a = [rec(frame(type: "HISTORICAL_DATA", seq: 26, len: 4), bytes: [0x01, 0x02, 0x03, 0x04])]
        let b = [rec(frame(type: "HISTORICAL_DATA", seq: 26, len: 6), bytes: [0x01, 0x02, 0x03, 0x04, 0x09, 0x0A])]
        let g = ReTools.diff(a, b).first { $0.key == "HISTORICAL_DATA/v26" }!
        XCTAssertTrue(g.lengthDiffers)
        XCTAssertEqual(g.lenA, 4)
        XCTAssertEqual(g.lenB, 6)
        XCTAssertTrue(g.changedOffsets.isEmpty)   // the 4-byte overlap is identical; the growth is the signal
    }

    // MARK: - D) ground truth: MAE / bias / Pearson, and honest coverage

    func testGroundTruthScoresAndReportsUnmatched() {
        let mk = { (ts: Int, v: Double) in
            self.rec(self.frame(type: "HISTORICAL_DATA", seq: 26, len: 4, parsed: ["hrv": v]),
                     bytes: [0, 0, 0, 0], ts: ts)
        }
        // Decoded hrv tracks truth +1 (bias +1), perfectly correlated.
        let recs = [mk(1000, 51), mk(2000, 61), mk(3000, 71)]
        let truth = [ReTools.TruthPoint(tsMs: 1000, value: 50),
                     ReTools.TruthPoint(tsMs: 2000, value: 60),
                     ReTools.TruthPoint(tsMs: 3000, value: 70),
                     ReTools.TruthPoint(tsMs: 999_999, value: 99)]   // no record within Δt → unmatched
        let s = ReTools.groundTruth(records: recs, truth: truth, fieldName: "hrv", maxDtMs: 60_000)
        XCTAssertEqual(s.n, 3)                          // 4th truth point has no decode
        XCTAssertEqual(s.meanAbsError!, 1.0, accuracy: 1e-9)
        XCTAssertEqual(s.bias!, 1.0, accuracy: 1e-9)
        XCTAssertEqual(s.pearson!, 1.0, accuracy: 1e-9)
        XCTAssertEqual(s.residuals.count, 4)
        XCTAssertNil(s.residuals.last?.decoded)         // the far truth point decodes to nil
    }

    func testGroundTruthMatchesFieldBearingRecordNotNearestFrame() {
        // A truth point at t=1000. The NEAREST record by time (t=1000) is some other packet that does
        // NOT carry `hrv`; the field-bearing record is farther (t=6000, Δt=5s, still within maxDt).
        // The scorer must pair with the field-bearing one — not report "no decode" off the nearer frame.
        let nearNoField = rec(frame(type: "REALTIME_DATA", len: 4, parsed: [:]), bytes: [0, 0, 0, 0], ts: 1000)
        let farWithField = rec(frame(type: "HISTORICAL_DATA", seq: 26, len: 4, parsed: ["hrv": 55.0]),
                               bytes: [0, 0, 0, 0], ts: 6000)
        let s = ReTools.groundTruth(records: [nearNoField, farWithField],
                                    truth: [ReTools.TruthPoint(tsMs: 1000, value: 55)],
                                    fieldName: "hrv", maxDtMs: 60_000)
        XCTAssertEqual(s.n, 1)                          // matched the field-bearing record, not the nearer empty one
        XCTAssertEqual(s.residuals.first?.decoded, 55.0)
        XCTAssertEqual(s.residuals.first?.dtMs, 5000)   // Δt to the field-bearing record, not 0
        XCTAssertEqual(s.meanAbsError!, 0.0, accuracy: 1e-9)
    }

    func testGroundTruthNilStatsWhenNothingMatches() {
        let recs = [rec(frame(type: "HISTORICAL_DATA", seq: 26, len: 4, parsed: ["hrv": 50.0]),
                        bytes: [0, 0, 0, 0], ts: 1000)]
        // Field name that isn't in the decoded dict → no numeric decode → n=0, nil stats.
        let s = ReTools.groundTruth(records: recs, truth: [ReTools.TruthPoint(tsMs: 1000, value: 50)],
                                    fieldName: "not_a_field", maxDtMs: 60_000)
        XCTAssertEqual(s.n, 0)
        XCTAssertNil(s.meanAbsError)
        XCTAssertNil(s.pearson)
    }
}
