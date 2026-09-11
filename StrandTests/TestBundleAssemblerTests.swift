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

    func testCapLeavesUndersizedBundleUntouched() {
        let entries = [FileExport.BundleEntry(name: "report.txt", data: Data("tiny".utf8))]
        let (capped, truncated) = TestBundleAssembler.capEntries(entries, capBytes: 20 * 1024 * 1024)
        XCTAssertFalse(truncated)
        XCTAssertEqual(capped, entries)
    }

    // MARK: - Oura diagnostics attachment (#Test-Centre Oura sidecars)

    func testNormalizedOuraEntryNameDropsRingId() {
        // The three sidecars normalize to id-free names; the ring UUID is gone from the filename.
        XCTAssertEqual(TestBundleAssembler.normalizedOuraEntryName(
            forFile: "oura-raw-5C4C0BF8-2DF6-1B3A-18D0-3DF0B3590148.jsonl"), "oura-raw.jsonl")
        XCTAssertEqual(TestBundleAssembler.normalizedOuraEntryName(
            forFile: "oura-ibihr-5C4C0BF8-2DF6-1B3A-18D0-3DF0B3590148.jsonl"), "oura-ibihr.jsonl")
        XCTAssertEqual(TestBundleAssembler.normalizedOuraEntryName(
            forFile: "oura-activity-oura-5C4C0BF8.jsonl"), "oura-activity.jsonl")
        // Non-sidecar files are ignored.
        XCTAssertNil(TestBundleAssembler.normalizedOuraEntryName(forFile: "raw-capture.jsonl"))
        XCTAssertNil(TestBundleAssembler.normalizedOuraEntryName(forFile: "whoop.sqlite"))
        XCTAssertNil(TestBundleAssembler.normalizedOuraEntryName(forFile: "oura-raw.txt"))
    }

    func testNormalizedOuraNamesAreAllTrimmable() {
        // Every normalized sidecar name must be in the cap's trimmable set, else a big night's dump could
        // blow the 20 MB cap instead of being tail-trimmed.
        for kind in ["raw", "ibihr", "activity"] {
            XCTAssertTrue(TestBundleAssembler.trimmableNames.contains("oura-\(kind).jsonl"))
        }
    }

    func testCapSharesBudgetAcrossOuraAndRawCaptureKeepingTails() {
        // report.txt kept whole; raw-capture + oura-ibihr together blow the cap → BOTH trimmed to a
        // proportional tail, bundle stays under cap, and each keeps its most-recent byte.
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
        // Bigger stream gets the bigger share (raw was 3× ibi).
        XCTAssertGreaterThan(cappedRaw.data.count, cappedIbi.data.count)
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
}
