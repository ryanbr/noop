import XCTest
@testable import WhoopProtocol

/// GOLDEN DECODER ORACLE (lane-4 A8) , the Swift half of a shared Swift<->Kotlin drift guard.
///
/// `Resources/decoder_oracle.json` is a fixture of REAL captured WHOOP type-47 HISTORICAL_DATA frames
/// plus their expected decode. The IDENTICAL file is committed at
/// `android/app/src/test/resources/decoder_oracle.json`, and `DecoderOracleTest.kt` runs the same
/// assertions through the Kotlin `decodeHistorical`. Because both decoders are independent
/// reimplementations of the same byte layout, decoding the same fixture and asserting the same output
/// is what catches a one-sided edit (a moved offset / changed scaling on one platform only).
///
/// The fixture was seeded from existing in-repo test vectors (Whoop4HistoricalV24HardwareTests,
/// Whoop4HistoricalV25Tests, Whoop5HistoricalTests and their Kotlin twins), so every expected value is
/// already independently grounded , this test only proves the two decoders agree on it.
///
/// The oracle pins THREE layers, each with a twin test in `DecoderOracleTest.kt` (#647, #775):
///  1. `frames`         , decoded VALUES. A per-platform fixture-hex test cannot catch a 32-vs-64-bit
///                        or signedness divergence: the wire bytes are identical on both platforms and
///                        each suite asserts its own answer. Comparing the decoded NUMBERS against one
///                        shared expectation is what catches it (PR #848: a u32 with bit 31 set read
///                        3232194973 on Swift and -1062772323 on Kotlin).
///  2. `stream_batches` , the ASSEMBLED shape. Frame decode agreeing does not imply assembly agrees ,
///                        PR #848 also shipped a Kotlin `StreamBatch.isEmpty` that omitted a stream
///                        Swift's `Streams.isEmpty` included, and `insert` early-returns on empty, so
///                        that batch banked nothing on Android alone.
///  3. `coverage`       , the self-defence manifest, so the oracle cannot silently stop covering
///                        something. Deleting an `expect` key, a frame or a batch fails a test.
final class DecoderOracleTests: XCTestCase {

    // Mirrors the JSON shape. `expect` is a heterogeneous map decoded leniently below.
    private struct Oracle: Decodable {
        let tolerance: Double
        let coverage: Coverage
        let frames: [Frame]
        let streamBatches: [StreamBatchCase]
        private enum CodingKeys: String, CodingKey {
            case tolerance, coverage, frames
            case streamBatches = "stream_batches"
        }
    }
    /// The self-defence manifest , see the `coverage._comment` block in the JSON.
    private struct Coverage: Decodable {
        /// Pinned decoder key -> how many fixture frames assert it. The COUNT, not just the name: a set
        /// alone would let one frame quietly drop a key another frame still carries.
        let fields: [String: Int]
        let derivedFields: [String]
        let frames: [String]
        let batches: [String]
        let streams: [String]
        let nonStreamLists: [String]
        private enum CodingKeys: String, CodingKey {
            case fields, frames, batches, streams
            case derivedFields = "derived_fields"
            case nonStreamLists = "non_stream_lists"
        }
    }
    /// One pinned stream-assembly case: named fixture frames in, one pinned `Streams` shape out.
    private struct StreamBatchCase: Decodable {
        let name: String
        let family: String
        let frames: [String]
        let deviceClockRef: Int
        let wallClockRef: Int
        let sessionOldestUnix: Int?
        let sessionNewestUnix: Int?
        /// Optional #547 future-bound override. Absent → the production default (the live clock).
        /// A batch whose records are post-2038 MUST set it, or the live clock rejects them for an
        /// unrelated reason and the batch asserts nothing. Kotlin passes the same value.
        let wallNow: Int?
        let expect: BatchExpect
        private enum CodingKeys: String, CodingKey {
            case name, family, frames, expect
            case deviceClockRef = "device_clock_ref"
            case wallClockRef = "wall_clock_ref"
            case sessionOldestUnix = "session_oldest_unix"
            case sessionNewestUnix = "session_newest_unix"
            case wallNow = "wall_now"
        }
    }
    private struct BatchExpect: Decodable {
        let isEmpty: Bool
        let droppedImplausible: Int
        let counts: [String: Int]
        private enum CodingKeys: String, CodingKey {
            case counts
            case isEmpty = "is_empty"
            case droppedImplausible = "dropped_implausible"
        }
    }
    private struct Frame: Decodable {
        let name: String
        let family: String
        let hex: String
        let expect: [String: ExpectValue]
    }
    /// One expected field: an int, a double, or an int array. The JSON uses bare numbers; we accept
    /// either an Int or a Double for a numeric field so `1.0` and `1` both decode.
    private enum ExpectValue: Decodable {
        case int(Int)
        case double(Double)
        case intArray([Int])
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let a = try? c.decode([Int].self) { self = .intArray(a); return }
            if let i = try? c.decode(Int.self) { self = .int(i); return }
            if let d = try? c.decode(Double.self) { self = .double(d); return }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unhandled expect value")
        }
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

    private func loadOracle() throws -> Oracle {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "decoder_oracle", withExtension: "json"),
                                "missing decoder_oracle.json test resource")
        return try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
    }

    /// Each fixture frame decodes to the expected fields. ints exact, doubles within `tolerance`,
    /// gravity asserted by magnitude (`gravity_mag`) since the components are family-specific.
    func testOracleFramesDecodeToExpectedOutput() throws {
        let oracle = try loadOracle()
        XCTAssertGreaterThan(oracle.frames.count, 0, "no oracle frames loaded")

        for frame in oracle.frames {
            let family: DeviceFamily = frame.family == "whoop5" ? .whoop5 : .whoop4
            let parsed = parseFrame(hexToBytes(frame.hex), family: family).parsed

            for (key, expected) in frame.expect {
                switch key {
                case "gravity_mag":
                    // A whole-number magnitude like 1.0 decodes as .int(1) here, because OracleValue tries
                    // Int before Double and Foundation's JSONDecoder accepts `1.0` as Int — so accept both
                    // forms (an integer magnitude is still a valid double).
                    let wantMag: Double
                    switch expected {
                    case .double(let d): wantMag = d
                    case .int(let i): wantMag = Double(i)
                    default: XCTFail("gravity_mag must be a number in \(frame.name)"); continue
                    }
                    let gx = parsed["gravity_x"]?.doubleValue
                    let gy = parsed["gravity_y"]?.doubleValue
                    let gz = parsed["gravity_z"]?.doubleValue
                    XCTAssertNotNil(gx, "\(frame.name): gravity did not decode")
                    // Typed sub-terms: the one-liner ((gx ?? 0)*(gx ?? 0) + …).squareRoot() made Swift's
                    // type-checker time out ("unable to type-check in reasonable time") — six `?? 0` literals
                    // over the multiply/add tree. Binding explicit Doubles removes the inference blow-up.
                    let x: Double = gx ?? 0
                    let y: Double = gy ?? 0
                    let z: Double = gz ?? 0
                    let mag = (x * x + y * y + z * z).squareRoot()
                    XCTAssertEqual(mag, wantMag, accuracy: 0.1, "\(frame.name): |gravity|")
                default:
                    switch expected {
                    case .int(let want):
                        XCTAssertEqual(parsed[key]?.intValue, want, "\(frame.name).\(key)")
                    case .intArray(let want):
                        XCTAssertEqual(parsed[key]?.intArrayValue ?? [], want, "\(frame.name).\(key)")
                    case .double(let want):
                        let got = try XCTUnwrap(parsed[key]?.doubleValue, "\(frame.name).\(key) missing")
                        XCTAssertEqual(got, want, accuracy: oracle.tolerance, "\(frame.name).\(key)")
                    }
                }
            }
        }
    }

    // MARK: - Layer 2: stream assembly

    /// Per-stream row counts + the emptiness verdict for each pinned batch. Frame decode agreeing does
    /// not imply assembly agrees: `extractHistoricalStreams` gates each stream separately (bpm 0 writes
    /// no HR row, skin temp has a thermal gate, v25 carries gravity but no HR), and the emptiness verdict
    /// is what `insert` early-returns on. Every stream is pinned INCLUDING the zeros, so a stream that
    /// materialises on one platform only is a failure rather than an unasserted extra.
    func testOracleStreamBatchesAssembleToExpectedShape() throws {
        let oracle = try loadOracle()
        XCTAssertGreaterThan(oracle.streamBatches.count, 0, "no oracle stream batches loaded")
        var byName: [String: Frame] = [:]
        for f in oracle.frames { byName[f.name] = f }

        for batch in oracle.streamBatches {
            let family: DeviceFamily = batch.family == "whoop5" ? .whoop5 : .whoop4
            let parsed: [ParsedFrame] = try batch.frames.map { name in
                let f = try XCTUnwrap(byName[name], "\(batch.name): unknown fixture frame '\(name)'")
                return parseFrame(hexToBytes(f.hex), family: family)
            }
            let s = extractHistoricalStreams(parsed, deviceClockRef: batch.deviceClockRef,
                                             wallClockRef: batch.wallClockRef,
                                             sessionOldestUnix: batch.sessionOldestUnix,
                                             sessionNewestUnix: batch.sessionNewestUnix,
                                             wallNow: batch.wallNow)
            let got = Self.streamCounts(s)
            for (stream, want) in batch.expect.counts {
                let have = try XCTUnwrap(got[stream], "\(batch.name): unknown stream '\(stream)'")
                XCTAssertEqual(have, want, "\(batch.name).\(stream) row count")
            }
            XCTAssertEqual(s.isEmpty, batch.expect.isEmpty, "\(batch.name): emptiness verdict")
            XCTAssertEqual(s.droppedImplausible, batch.expect.droppedImplausible,
                           "\(batch.name): #547 dropped-record count")
            // The verdict must also AGREE with the counts, so a platform whose isEmpty forgets a stream
            // is caught even on a batch that wasn't written to target that stream.
            XCTAssertEqual(s.isEmpty, got.values.allSatisfy { $0 == 0 },
                           "\(batch.name): isEmpty disagrees with the per-stream counts")
        }
    }

    /// Row count per stream, keyed by the oracle's (and `Streams.CodingKeys`') wire names.
    private static func streamCounts(_ s: Streams) -> [String: Int] {
        [
            "hr": s.hr.count, "rr": s.rr.count, "spo2": s.spo2.count, "skin_temp": s.skinTemp.count,
            "resp": s.resp.count, "gravity": s.gravity.count, "steps": s.steps.count,
            "sleep_state": s.sleepState.count, "ppg_hr": s.ppgHr.count,
            "ppg_waveform": s.ppgWaveform.count, "ecg_waveform": s.ecgWaveform.count,
            "v18_aux": s.v18Aux.count,
            "events": s.events.count, "battery": s.battery.count,
        ]
    }

    /// EVERY stream on its own makes the batch non-empty. This is the exhaustive form of the #848 bug:
    /// Kotlin's `StreamBatch.isEmpty` omitted one stream, and because `insert` early-returns on an empty
    /// batch, a batch carrying ONLY that stream banked nothing on Android. A batch fixture can only catch
    /// that for the streams it happens to populate; constructing a one-stream batch per stream catches it
    /// for all of them. The cases are keyed by the oracle's stream names and cross-checked against the
    /// manifest, so a stream added to `Streams` without a case here fails `testDeclaredStreams…` below.
    func testEmptinessVerdictCoversEveryStream() throws {
        let oracle = try loadOracle()
        let oneOf: [String: Streams] = [
            "hr": Streams(hr: [HRSample(ts: 1, bpm: 60)]),
            "rr": Streams(rr: [RRInterval(ts: 1, rrMs: 900)]),
            "spo2": Streams(spo2: [SpO2Sample(ts: 1, red: 1, ir: 1)]),
            "skin_temp": Streams(skinTemp: [SkinTempSample(ts: 1, raw: 3000)]),
            "resp": Streams(resp: [RespSample(ts: 1, raw: 3000)]),
            "gravity": Streams(gravity: [GravitySample(ts: 1, x: 0, y: 0, z: 1)]),
            "steps": Streams(steps: [StepSample(ts: 1, counter: 1)]),
            "sleep_state": Streams(sleepState: [SleepStateSample(ts: 1, state: 2)]),
            "ppg_hr": Streams(ppgHr: [PpgHrSample(ts: 1, bpm: 60, conf: 0.5)]),
            "ppg_waveform": Streams(ppgWaveform: [PpgWaveformSample(ts: 1, samples: [1, 2])]),
            // A FULL-LENGTH record, not a short one: `EcgWaveformSample` carries the inner record and
            // the store asserts `r16InnerLength`, so a one-byte stand-in would pass here and fail where
            // it matters.
            "ecg_waveform": Streams(ecgWaveform: [
                EcgWaveformSample(ts: 1, sequence: 1,
                                  record: [UInt8](repeating: 0, count: Whoop5Ecg.r16InnerLength))]),
            // Carries a real slot value rather than a bare `ts`: `V18AuxSample.isEmpty` is "every slot is
            // nil", so an all-nil sample would still make the ARRAY non-empty and pass this check while
            // saying nothing about a row that carries data.
            "v18_aux": Streams(v18Aux: [V18AuxSample(ts: 1, recordIndex: 1)]),
            "events": Streams(events: [WhoopEvent(ts: 1, kind: "BOOT", payload: [:])]),
            "battery": Streams(battery: [BatterySample(ts: 1, soc: 50, mv: 3900)]),
        ]
        XCTAssertEqual(Set(oneOf.keys), Set(oracle.coverage.streams),
                       "one-stream cases and the oracle's stream manifest disagree")
        XCTAssertTrue(Streams().isEmpty, "a Streams with no rows must be empty")
        for (stream, s) in oneOf {
            XCTAssertFalse(s.isEmpty, "Streams carrying only '\(stream)' must NOT be empty , "
                           + "isEmpty gates the insert, so a stream missing from the verdict is silent data loss")
            XCTAssertEqual(Self.streamCounts(s).values.reduce(0, +), 1,
                           "'\(stream)' case must populate exactly one row in exactly one stream")
        }
    }

    // MARK: - Layer 3: the oracle defends itself

    /// The manifest and the fixtures must agree EXACTLY, in both directions. Without this, deleting an
    /// `expect` key, a whole frame or a whole batch passes both suites and coverage silently shrinks.
    /// Precedent: PR #848 needed a test that every storage slot's decoder key exists in a real decode,
    /// because a rename had broken an extractor and nothing failed.
    func testOracleCoverageManifestMatchesFixtures() throws {
        let oracle = try loadOracle()
        let cov = oracle.coverage

        XCTAssertEqual(oracle.frames.map(\.name), cov.frames,
                       "coverage.frames must list every fixture frame, in order")
        XCTAssertEqual(Set(oracle.streamBatches.map(\.name)), Set(cov.batches),
                       "coverage.batches must list every stream batch")

        // Field -> how many frames assert it. Counting (not just naming) is what makes EVERY individual
        // assertion load-bearing: dropping `heart_rate` from one frame leaves the key set unchanged.
        var asserted: [String: Int] = [:]
        for f in oracle.frames { for key in f.expect.keys { asserted[key, default: 0] += 1 } }
        XCTAssertEqual(asserted, cov.fields,
                       "coverage.fields must name every 'expect' key and how many frames assert it")
        XCTAssertTrue(Set(cov.derivedFields).isSubset(of: Set(cov.fields.keys)),
                      "coverage.derived_fields must be a subset of coverage.fields")

        // Every pinned batch pins EVERY stream, zeros included , otherwise "absent on one platform"
        // and "not asserted" are indistinguishable.
        for batch in oracle.streamBatches {
            XCTAssertEqual(Set(batch.expect.counts.keys), Set(cov.streams),
                           "\(batch.name): counts must pin every stream in coverage.streams")
            XCTAssertEqual(batch.expect.isEmpty, batch.expect.counts.values.allSatisfy { $0 == 0 },
                           "\(batch.name): pinned is_empty contradicts the pinned counts")
        }

        // Every non-derived pinned field must appear in at least one REAL decode. A field that no
        // decoder emits any more would otherwise sit in the manifest looking covered.
        let derived = Set(cov.derivedFields)
        var seen = Set<String>()
        for f in oracle.frames {
            let family: DeviceFamily = f.family == "whoop5" ? .whoop5 : .whoop4
            let parsed = parseFrame(hexToBytes(f.hex), family: family).parsed
            seen.formUnion(parsed.keys)
        }
        for field in cov.fields.keys where !derived.contains(field) {
            XCTAssertTrue(seen.contains(field),
                          "coverage.fields lists '\(field)' but no fixture decode emits that key")
        }
    }

    /// The oracle's stream manifest must equal the array-typed fields `Streams` actually declares. This
    /// is the direction the manifest alone cannot cover: a NEW stream added to `Streams` (and to the
    /// emptiness verdict) but never given oracle counts would otherwise be invisible to every check
    /// above. Diagnostics that are arrays but deliberately excluded from the verdict are listed in
    /// `coverage.non_stream_lists`. The Kotlin twin reflects `StreamBatch` the same way.
    func testDeclaredStreamsMatchOracleManifest() throws {
        let oracle = try loadOracle()
        let declared = Mirror(reflecting: Streams()).children.compactMap { child -> String? in
            guard let label = child.label, child.value as? [Any] != nil else { return nil }
            return Self.snakeCased(label)
        }
        XCTAssertEqual(Set(declared),
                       Set(oracle.coverage.streams).union(oracle.coverage.nonStreamLists),
                       "Streams declares array fields the oracle does not account for (or vice versa) , "
                       + "add the new stream to coverage.streams and to every batch's counts")
    }

    /// `sleepState` -> `sleep_state`. Digits never take a separator, so `spo2` stays `spo2`.
    private static func snakeCased(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch.isUppercase { out.append("_"); out.append(Character(ch.lowercased())) } else { out.append(ch) }
        }
        return out
    }

    /// The Swift and Android copies of the oracle MUST be byte-identical, so neither platform can edit
    /// its fixture without the other. Compares the bundled Swift resource against the Android source
    /// copy (located relative to this test file). Skips gracefully if the Android tree isn't present
    /// (e.g. a Swift-only checkout) rather than failing for the wrong reason.
    func testOracleCopiesAreIdentical() throws {
        let swiftURL = try XCTUnwrap(Bundle.module.url(forResource: "decoder_oracle", withExtension: "json"))
        let swiftData = try Data(contentsOf: swiftURL)

        // .../Packages/WhoopProtocol/Tests/WhoopProtocolTests/DecoderOracleTests.swift -> repo root
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here
            .deletingLastPathComponent()  // WhoopProtocolTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // WhoopProtocol
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo root
        let androidURL = repoRoot
            .appendingPathComponent("android/app/src/test/resources/decoder_oracle.json")

        guard FileManager.default.fileExists(atPath: androidURL.path) else {
            throw XCTSkip("android oracle copy not present at \(androidURL.path)")
        }
        let androidData = try Data(contentsOf: androidURL)
        XCTAssertEqual(swiftData, androidData,
                       "decoder_oracle.json copies differ , keep the Swift and Android copies in lockstep")
    }
}
