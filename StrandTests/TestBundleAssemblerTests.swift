import XCTest
@testable import Strand

final class TestBundleAssemblerTests: XCTestCase {

    func testReScrubsEveryFileIncludingRawCapture() {
        // A serial that never went through the append(log:) sink, e.g. embedded in raw-capture console text.
        let rawWithSerial = "{\"console\":\"connected to WHOOP 4C1594026 ok\"}"
        let entries = [
            FileExport.BundleEntry(name: "report.txt", data: Data("clean line".utf8)),
            FileExport.BundleEntry(name: "raw-capture.jsonl", data: Data(rawWithSerial.utf8)),
        ]
        let scrubbed = TestBundleAssembler.redactEntries(entries)
        let raw = scrubbed.first { $0.name == "raw-capture.jsonl" }!
        let text = String(data: raw.data, encoding: .utf8)!
        XCTAssertFalse(text.contains("4C1594026"), "the injected serial must be scrubbed")
        XCTAssertTrue(text.contains("WHOOP <serial>"))
    }

    func testMetaJsonIsNotMangledButStillPasses() {
        // meta.json has no PII shapes, so it should pass through byte-identical.
        let json = Data("{\"schema\":1,\"redaction\":\"v2\"}".utf8)
        let scrubbed = TestBundleAssembler.redactEntries([FileExport.BundleEntry(name: "meta.json", data: json)])
        XCTAssertEqual(scrubbed.first!.data, json)
    }

    func testStampsRedactionV2() {
        XCTAssertEqual(TestBundleAssembler.redactionVersion, "v2")
    }

    func testCapTruncatesRawCaptureTailAndFlags() {
        // report.txt + meta.json are small; raw-capture blows the cap. We keep the most-recent tail.
        let small = FileExport.BundleEntry(name: "report.txt", data: Data("small".utf8))
        let oversized = String(repeating: "x", count: 40 * 1024 * 1024)  // 40 MB of raw-capture
        let entries = [small, FileExport.BundleEntry(name: "raw-capture.jsonl", data: Data(oversized.utf8))]

        let (capped, truncated) = TestBundleAssembler.capEntries(entries, capBytes: 20 * 1024 * 1024)
        XCTAssertTrue(truncated, "the bundle exceeded the cap so truncated must be true")
        let total = capped.reduce(0) { $0 + $1.data.count }
        XCTAssertLessThanOrEqual(total, 20 * 1024 * 1024)
        // report.txt is preserved in full; only raw-capture is trimmed.
        XCTAssertEqual(capped.first { $0.name == "report.txt" }?.data, small.data)
        let raw = capped.first { $0.name == "raw-capture.jsonl" }!
        XCTAssertLessThan(raw.data.count, oversized.utf8.count)
        // We keep the TAIL (most recent), so the last byte survives.
        XCTAssertEqual(raw.data.last, Data(oversized.utf8).last)
    }

    func testCapSnapsTrimmedTailToLineBoundary() {
        // A raw byte-count tail can (and in production did) land mid-record: a real export shipped
        // oura-cva-ppg.jsonl/oura-real-steps.jsonl/oura-motion.jsonl each with a corrupted first line.
        // Every trimmable name is newline-delimited JSONL, so the trimmed tail must always start at a
        // clean line boundary.
        let small = FileExport.BundleEntry(name: "report.txt", data: Data("small".utf8))
        let lines = (1...2000).map { "{\"n\":\($0),\"pad\":\"\(String(repeating: "x", count: 50))\"}" }
        let raw = FileExport.BundleEntry(name: "oura-raw.jsonl", data: Data(lines.joined(separator: "\n").utf8))
        // Force a mid-file trim at a cap unlikely to land exactly on a newline.
        let cap = raw.data.count / 2
        let (capped, truncated) = TestBundleAssembler.capEntries([small, raw], capBytes: cap)
        XCTAssertTrue(truncated)
        let cappedRaw = capped.first { $0.name == "oura-raw.jsonl" }!
        let text = String(data: cappedRaw.data, encoding: .utf8)!
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.hasPrefix("{"), "trimmed tail must start at a clean line boundary, got: \(text.prefix(30))")
        // Every kept line must still be valid JSON (no partial record survived).
        for line in text.split(separator: "\n") {
            XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                            "corrupted line survived trimming: \(line.prefix(30))")
        }
    }

    func testTrimToLineBoundaryHandlesNoNewline() {
        // A single-line (or already-empty) entry has nothing to snap to - returned unchanged, never worse.
        let noNewline = Data("no newline here".utf8)
        XCTAssertEqual(TestBundleAssembler.trimToLineBoundary(noNewline), noNewline)
        XCTAssertEqual(TestBundleAssembler.trimToLineBoundary(Data()), Data())
    }

    func testCapLeavesUndersizedBundleUntouched() {
        let entries = [FileExport.BundleEntry(name: "report.txt", data: Data("tiny".utf8))]
        let (capped, truncated) = TestBundleAssembler.capEntries(entries, capBytes: 20 * 1024 * 1024)
        XCTAssertFalse(truncated)
        XCTAssertEqual(capped, entries)
    }

    // MARK: - Oura diagnostics attachment (#Test-Centre Oura sidecars)

    func testNormalizedOuraEntryNameDropsRingId() {
        // All six sidecars normalize to id-free names; the ring UUID is gone from the filename.
        XCTAssertEqual(TestBundleAssembler.normalizedOuraEntryName(
            forFile: "oura-raw-5C4C0BF8-2DF6-1B3A-18D0-3DF0B3590148.jsonl"), "oura-raw.jsonl")
        XCTAssertEqual(TestBundleAssembler.normalizedOuraEntryName(
            forFile: "oura-ibihr-5C4C0BF8-2DF6-1B3A-18D0-3DF0B3590148.jsonl"), "oura-ibihr.jsonl")
        XCTAssertEqual(TestBundleAssembler.normalizedOuraEntryName(
            forFile: "oura-activity-oura-5C4C0BF8.jsonl"), "oura-activity.jsonl")
        // #Test-Centre follow-up: cva-ppg/motion/real-steps shipped writers (Strand/BLE/Oura*Dump.swift)
        // before the bundler knew their kind — regression coverage for that gap.
        XCTAssertEqual(TestBundleAssembler.normalizedOuraEntryName(
            forFile: "oura-cva-ppg-oura-2H3B2405003655.jsonl"), "oura-cva-ppg.jsonl")
        XCTAssertEqual(TestBundleAssembler.normalizedOuraEntryName(
            forFile: "oura-motion-oura-2H3B2405003655.jsonl"), "oura-motion.jsonl")
        XCTAssertEqual(TestBundleAssembler.normalizedOuraEntryName(
            forFile: "oura-real-steps-oura-2H3B2405003655.jsonl"), "oura-real-steps.jsonl")
        // Non-sidecar files are ignored.
        XCTAssertNil(TestBundleAssembler.normalizedOuraEntryName(forFile: "raw-capture.jsonl"))
        XCTAssertNil(TestBundleAssembler.normalizedOuraEntryName(forFile: "whoop.sqlite"))
        XCTAssertNil(TestBundleAssembler.normalizedOuraEntryName(forFile: "oura-raw.txt"))
    }

    /// A ROLLED GENERATION must normalize to the same entry name as the live file, so
    /// `ouraDiagnosticEntries` can MERGE the generations behind that one name (it used to choose the
    /// largest between them, which is why a morning export kept shipping the wrong session).
    /// Before this, `hasSuffix(".jsonl")` rejected every `.jsonl.<n>` and a morning export could only ever
    /// carry the live file — a 30-second session, while the night sat in a generation nothing looked at
    /// (measured 2026-08-10).
    func testRolledGenerationsNormalizeToTheSameEntryName() {
        for suffix in [".jsonl.1", ".jsonl.2", ".jsonl.8", ".jsonl.12"] {
            XCTAssertEqual(TestBundleAssembler.normalizedOuraEntryName(
                forFile: "oura-raw-oura-2H3B2405003655" + suffix), "oura-raw.jsonl", suffix)
        }
        XCTAssertEqual(TestBundleAssembler.normalizedOuraEntryName(
            forFile: "oura-cva-ppg-oura-2H3B2405003655.jsonl.3"), "oura-cva-ppg.jsonl")
        // A non-numeric or empty tail is NOT a generation — those are someone else's files, not ours.
        XCTAssertNil(TestBundleAssembler.normalizedOuraEntryName(
            forFile: "oura-raw-oura-2H3B2405003655.jsonl.bak"))
        XCTAssertNil(TestBundleAssembler.normalizedOuraEntryName(
            forFile: "oura-raw-oura-2H3B2405003655.jsonl."))
        XCTAssertNil(TestBundleAssembler.normalizedOuraEntryName(
            forFile: "oura-raw-oura-2H3B2405003655.jsonl.1.gz"))
    }

    func testNormalizedOuraNamesAreAllTrimmable() {
        // Every normalized sidecar name must be in the cap's trimmable set, else a big night's dump could
        // blow the 20 MB cap instead of being tail-trimmed.
        for kind in TestBundleAssembler.ouraSidecarKinds {
            XCTAssertTrue(TestBundleAssembler.trimmableNames.contains("oura-\(kind).jsonl"))
            XCTAssertTrue(TestBundleAssembler.ouraSidecarNames.contains("oura-\(kind).jsonl"))
        }
    }

    func testCapSharesBudgetAcrossOuraAndRawCaptureKeepingTails() {
        // report.txt kept whole; raw-capture + oura-ibihr together blow the cap → BOTH over their fair
        // share, so both are trimmed, the bundle stays under cap, and each keeps its most-recent byte.
        let small = FileExport.BundleEntry(name: "report.txt", data: Data("small".utf8))
        let raw = FileExport.BundleEntry(name: "raw-capture.jsonl",
                                         data: Data((String(repeating: "r", count: 30 * 1024 * 1024) + "R").utf8))
        let ibi = FileExport.BundleEntry(name: "oura-ibihr.jsonl",
                                         data: Data((String(repeating: "i", count: 10 * 1024 * 1024) + "I").utf8))
        let cap = 20 * 1024 * 1024
        let (capped, truncated) = TestBundleAssembler.capEntries([small, raw, ibi], capBytes: cap)
        XCTAssertTrue(truncated)
        XCTAssertLessThanOrEqual(capped.reduce(0) { $0 + $1.data.count }, cap)
        XCTAssertEqual(capped.first { $0.name == "report.txt" }?.data, small.data)          // whole
        let cappedRaw = capped.first { $0.name == "raw-capture.jsonl" }!
        let cappedIbi = capped.first { $0.name == "oura-ibihr.jsonl" }!
        XCTAssertLessThan(cappedRaw.data.count, raw.data.count)                             // trimmed
        XCTAssertLessThan(cappedIbi.data.count, ibi.data.count)                             // trimmed
        XCTAssertEqual(cappedRaw.data.last, raw.data.last)                                  // newest kept
        XCTAssertEqual(cappedIbi.data.last, ibi.data.last)
        // Both were over the fair share, so they land on it — within a byte of each other, NOT split 3:1
        // by size the way the old proportional rule would have.
        XCTAssertLessThanOrEqual(abs(cappedRaw.data.count - cappedIbi.data.count), 1)
    }

    /// The bug this allocation exists to prevent (measured on `noop-master-iOS-v9.3.1-260809-0716.zip`):
    /// proportional-to-size handed 53.9 % of the budget to a bulk sidecar dump and left the raw wire capture
    /// — the only sidecar a protocol fact can be re-derived from — with 1.9 %, i.e. 8 min of an 8.4 h night.
    /// Max-min fair keeps a modest stream WHOLE and takes the bytes off the stream that is merely bulky.
    /// (The bulky neighbour is modelled here as the CVA-PPG dump — the measured case was a SpO2 research
    /// sidecar that this branch does not carry; the allocation rule is kind-agnostic.)
    func testSmallHighValueSidecarSurvivesABulkyNeighbour() {
        let report = FileExport.BundleEntry(name: "report.txt", data: Data("small".utf8))
        // Mirrors the real shape: one 40 MB bulk dump beside a 2 MB wire capture, 20 MB of room.
        let bulk = FileExport.BundleEntry(name: "oura-cva-ppg.jsonl",
                                          data: Data(String(repeating: "s\n", count: 20 * 1024 * 1024).utf8))
        let raw = FileExport.BundleEntry(name: "oura-raw.jsonl",
                                         data: Data(String(repeating: "r\n", count: 1024 * 1024).utf8))
        let cap = 20 * 1024 * 1024
        let (capped, truncated) = TestBundleAssembler.capEntries([report, bulk, raw], capBytes: cap)
        XCTAssertTrue(truncated)
        XCTAssertLessThanOrEqual(capped.reduce(0) { $0 + $1.data.count }, cap)
        // The wire capture is under its ~10 MB fair share, so it ships WHOLE — not scaled down to ~9 % of
        // the budget the way size-proportional splitting would have left it.
        XCTAssertEqual(capped.first { $0.name == "oura-raw.jsonl" }?.data.count, raw.data.count)
        // Its surplus rolls forward: the bulk dump gets everything the raw capture did not need.
        let cappedBulk = capped.first { $0.name == "oura-cva-ppg.jsonl" }!
        XCTAssertLessThan(cappedBulk.data.count, bulk.data.count)
        XCTAssertGreaterThan(cappedBulk.data.count, cap - raw.data.count - 1024)
    }

    func testFairAllowancesIsWaterFillingAndNeverBreachesBudget() {
        // Classic water-filling: 1 fits whole, 10 takes its share of what is left, 30 takes the rest.
        let a = TestBundleAssembler.fairAllowances(
            sizes: [("big", 30), ("small", 1), ("mid", 10)], budget: 20)
        XCTAssertEqual(a["small"], 1)                                    // whole, under any share
        XCTAssertEqual(a["mid"], 9)                                      // (20-1)/2
        XCTAssertEqual(a["big"], 10)                                     // the remainder
        XCTAssertEqual(a.values.reduce(0, +), 20)                        // budget fully used
        // Input order must not change the answer.
        let b = TestBundleAssembler.fairAllowances(
            sizes: [("small", 1), ("mid", 10), ("big", 30)], budget: 20)
        XCTAssertEqual(a, b)
        // Everything fits: nobody is trimmed.
        XCTAssertEqual(TestBundleAssembler.fairAllowances(sizes: [("x", 3), ("y", 4)], budget: 100),
                       ["x": 3, "y": 4])
        // Degenerate budgets stay in range rather than going negative.
        XCTAssertEqual(TestBundleAssembler.fairAllowances(sizes: [("x", 5)], budget: 0), ["x": 0])
        XCTAssertEqual(TestBundleAssembler.fairAllowances(sizes: [], budget: 10), [:])
        // A single trimmable stream still gets the WHOLE remainder — the original behaviour, unchanged.
        XCTAssertEqual(TestBundleAssembler.fairAllowances(sizes: [("only", 999)], budget: 42), ["only": 42])
    }

    /// The redaction contract for the Oura sidecars (PR review, ryanbr): the ONLY PII in a raw line is the
    /// ring id, and redactEntries masks it to `<device>` — but ONLY because the producer writes it as a
    /// canonical dashed `uuidString`, the shape the dash-anchored UUID rule matches. This pins that contract
    /// against a representative line in the EXACT `OuraRawDumpLine.encode` shape (schema/deviceId/utc/iso/hex)
    /// so a future producer PR that emits a dashless or truncated id — which would leak the id verbatim —
    /// fails here instead of silently shipping the id in a bundle the user shares.
    func testRedactionMasksOuraRingIdButKeepsRawHexIntact() {
        let ringId = "5C4C0BF8-2DF6-1B3A-18D0-3DF0B3590148"
        // A long raw-byte run (>32 hex chars, no dashes/colons): the capture payload the scrub must NOT touch.
        // Broadening the UUID rule to dashless hex to "be safe" would shred exactly this field — which is why
        // the fix is a producer-format contract (this test), not a greedier regex.
        let hex = "0b3c1e00a1b2c3d4e5f60718293a4b5c6d7e8f90aabbccdd"
        let line = "{\"schema\":1,\"deviceId\":\"\(ringId)\",\"utc\":1752969600," +
                   "\"iso\":\"2026-07-19T00:00:00Z\",\"hex\":\"\(hex)\"}"
        let scrubbed = TestBundleAssembler.redactEntries(
            [FileExport.BundleEntry(name: "oura-raw.jsonl", data: Data(line.utf8))])
        let out = String(data: scrubbed.first!.data, encoding: .utf8)!
        // The ring id is masked to <device>, and the canonical id does not survive anywhere in the line…
        XCTAssertFalse(out.contains(ringId), "the ring UUID must not survive the scrub")
        XCTAssertTrue(out.contains("\"deviceId\":\"<device>\""), "the ring id must be masked to <device>")
        // …while the raw capture bytes pass through byte-for-byte (redaction must never corrupt the capture).
        XCTAssertTrue(out.contains("\"hex\":\"\(hex)\""), "the raw hex bytes must survive redaction intact")
    }

    /// 2026-09-11: the test above only proves the raw `hex` field survives for a payload that happens to
    /// avoid `redactHexDump`'s WHOOP-serial heuristic (its bytes never decode to a 9+ byte run of unbroken
    /// alnum ASCII starting with a letter). A real capture's `0x80` live-HR/IBI and `0x43`/`0x61` debug-text
    /// channels routinely produce exactly that shape by coincidence or by design (found 2026-09-11 in a
    /// user's #2075 attachment: 38 of 3112 `oura-raw.jsonl` lines had bytes silently replaced with `•` — not
    /// even valid hex — because they matched the WHOOP-serial shape this heuristic was built to catch on a
    /// console hex dump, e.g. "WHOOP 4C1594026"). This pins that `oura-raw.jsonl` is now exempt from that
    /// sweep while its `deviceId` is still masked.
    func testRawSidecarSurvivesTheWhoopSerialHeuristicFalsePositive() {
        let ringId = "5C4C0BF8-2DF6-1B3A-18D0-3DF0B3590148"
        // 0x43 op, header-ish non-alnum bytes, then an UNBROKEN 9-byte letter-led alnum run ("SN1234567") -
        // exactly what `redactHexDump` masks in a WHOOP console hex dump, coincidentally reachable by any
        // Oura frame whose bytes happen to fall in that ASCII range.
        let header = "e5a30000"
        let payload = Array("SN1234567".utf8).map { String(format: "%02x", $0) }.joined()
        let bodyLen = (header.count + payload.count) / 2
        let hex = "43" + String(format: "%02x", bodyLen) + header + payload
        let line = "{\"schema\":1,\"deviceId\":\"\(ringId)\",\"utc\":1,\"iso\":\"2026-09-11T00:00:00Z\",\"hex\":\"\(hex)\"}"
        let out = String(data: TestBundleAssembler.redactEntries(
            [FileExport.BundleEntry(name: "oura-raw.jsonl", data: Data(line.utf8))]).first!.data, encoding: .utf8)!
        XCTAssertTrue(out.contains("\"hex\":\"\(hex)\""),
                       "the debug-text frame must survive byte-for-byte, got: \(out)")
        XCTAssertFalse(out.contains(ringId), "the ring UUID must still be scrubbed")
        XCTAssertTrue(out.contains("\"deviceId\":\"<device>\""), "the ring id must still be masked to <device>")
        // A sibling non-raw sidecar (decoded fields, no hex blob) is unaffected by this exemption and still
        // rides the general `redactPii` sweep — the exemption is scoped to `raw` alone.
        let ibiLine = "{\"schema\":1,\"deviceId\":\"\(ringId)\",\"hr\":60}"
        let ibiOut = String(data: TestBundleAssembler.redactEntries(
            [FileExport.BundleEntry(name: "oura-ibihr.jsonl", data: Data(ibiLine.utf8))]).first!.data, encoding: .utf8)!
        XCTAssertFalse(ibiOut.contains(ringId))
    }

    /// #572 follow-up: the field-aware `deviceId` mask closes the gap the canonical-only contract left — a
    /// DASHLESS (or truncated) ring id, which the dash-anchored UUID rule can't match and would otherwise
    /// leak verbatim, is still masked to `<device>`, and the raw `hex` capture is STILL untouched (the mask
    /// is key-anchored to "deviceId", not a greedier hex rule that would shred it). This is the direction the
    /// earlier hardcoded contract test could not enforce.
    func testSidecarRedactionMasksDashlessRingIdAndKeepsHexIntact() {
        let dashless = "5C4C0BF82DF61B3A18D03DF0B3590148" // no dashes → redactPii's UUID rule cannot match it
        let hex = "0b3c1e00a1b2c3d4e5f60718293a4b5c6d7e8f90aabbccdd"
        let line = "{\"schema\":1,\"deviceId\":\"\(dashless)\",\"utc\":1,\"hex\":\"\(hex)\"}"
        let out = String(data: TestBundleAssembler.redactEntries(
            [FileExport.BundleEntry(name: "oura-ibihr.jsonl", data: Data(line.utf8))]).first!.data, encoding: .utf8)!
        XCTAssertFalse(out.contains(dashless), "a dashless ring id must not survive the scrub")
        XCTAssertTrue(out.contains("\"deviceId\":\"<device>\""), "the deviceId value must be masked to <device>")
        XCTAssertTrue(out.contains("\"hex\":\"\(hex)\""), "the raw hex bytes must survive redaction intact")
    }

    /// The field-aware mask is SCOPED to the Oura sidecars: it must NOT rewrite a non-PII logical `deviceId`
    /// (e.g. "my-whoop") in a non-sidecar entry, which would strip useful, non-sensitive context from the
    /// report body the user reviews.
    func testSidecarDeviceIdMaskDoesNotTouchNonSidecarEntries() {
        let line = "{\"deviceId\":\"my-whoop\",\"note\":\"hi\"}"
        let out = String(data: TestBundleAssembler.redactEntries(
            [FileExport.BundleEntry(name: "report.txt", data: Data(line.utf8))]).first!.data, encoding: .utf8)!
        XCTAssertTrue(out.contains("\"deviceId\":\"my-whoop\""), "a non-sidecar logical deviceId must be left readable")
    }

    // MARK: - generation merge (the capture-coverage defect)

    /// END-TO-END over real files on disk, reproducing the layout that broke the export on
    /// 2026-09-05: the live file holds the morning drain (small), while a rolled generation holds the
    /// previous day's post-reinstall backfill (large). Under the old largest-wins rule the bundle
    /// shipped the BACKFILL and the night's own drain never left the device — the shipped
    /// `oura-raw.jsonl` spanned `2026-09-04 10:58 → 12:03 UTC` against a night that ended that
    /// morning. The merged entry must now contain BOTH, with the morning drain LAST so the cap's
    /// keep-the-tail trim can never be the thing that drops it.
    func testOuraDiagnosticEntriesMergesGenerationsNewestLast() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oura-gen-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let morning = "{\"utc\":1788627494,\"iso\":\"2026-09-05T07:08:14Z\",\"hex\":\"5c08\"}\n"
        let backfill = String(repeating: "{\"utc\":1788519502,\"iso\":\"2026-09-04T10:58:22Z\"}\n",
                              count: 50)
        try morning.write(to: dir.appendingPathComponent("oura-raw-RING1.jsonl"),
                          atomically: true, encoding: .utf8)
        try backfill.write(to: dir.appendingPathComponent("oura-raw-RING1.jsonl.1"),
                           atomically: true, encoding: .utf8)

        let entries = TestBundleAssembler.ouraDiagnosticEntries(directory: dir)
        XCTAssertEqual(entries.map(\.name), ["oura-raw.jsonl"], "one entry, ring id dropped")
        let text = try XCTUnwrap(String(data: entries[0].data, encoding: .utf8))
        XCTAssertTrue(text.contains("2026-09-04T10:58:22Z"), "older generation must still be present")
        XCTAssertTrue(text.hasSuffix(morning), "the newest capture must be LAST — the cap keeps the tail")
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "2026-09-04T10:58:22Z")).lowerBound,
                          try XCTUnwrap(text.range(of: "2026-09-05T07:08:14Z")).lowerBound,
                          "chronological order")
    }

    /// A generation whose last write did not end in a newline must not splice its final record onto
    /// the next generation's first one — that would produce a line parsing as neither.
    func testOuraDiagnosticEntriesInsertsANewlineBetweenGenerations() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oura-gen-nl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "{\"a\":1}".write(to: dir.appendingPathComponent("oura-raw-R.jsonl.1"),   // NO trailing newline
                              atomically: true, encoding: .utf8)
        try "{\"b\":2}\n".write(to: dir.appendingPathComponent("oura-raw-R.jsonl"),
                                 atomically: true, encoding: .utf8)

        let entries = TestBundleAssembler.ouraDiagnosticEntries(directory: dir)
        let text = try XCTUnwrap(String(data: entries[0].data, encoding: .utf8))
        XCTAssertEqual(text, "{\"a\":1}\n{\"b\":2}\n")
        XCTAssertEqual(text.split(separator: "\n").count, 2, "two whole lines, nothing spliced")
    }

    /// Every merged line must survive the redact + cap pass the bundle actually applies, and the
    /// newest record must be the one that survives a cap far smaller than the merged size.
    func testMergedSidecarKeepsTheNewestRecordsUnderTheCap() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oura-gen-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try String(repeating: "{\"old\":1}\n", count: 4000)
            .write(to: dir.appendingPathComponent("oura-raw-R.jsonl.1"), atomically: true, encoding: .utf8)
        try String(repeating: "{\"new\":1}\n", count: 100)
            .write(to: dir.appendingPathComponent("oura-raw-R.jsonl"), atomically: true, encoding: .utf8)

        let merged = TestBundleAssembler.ouraDiagnosticEntries(directory: dir)
        let (capped, truncated) = TestBundleAssembler.capEntries(merged, capBytes: 2_000)
        XCTAssertTrue(truncated)
        let text = try XCTUnwrap(String(data: capped[0].data, encoding: .utf8))
        XCTAssertTrue(text.contains("{\"new\":1}"), "the newest records must survive the cap")
        // Every kept line must be whole — the front trim snaps to a line boundary, so the partial
        // record the raw byte-count tail would otherwise start on is dropped.
        for line in text.split(separator: "\n") {
            XCTAssertTrue(line.hasPrefix("{") && line.hasSuffix("}"), "no partial line: \(line)")
        }
    }

}
