import XCTest
@testable import WhoopStore

/// Pins the export's generation-selection rule. These run under `swift test` with no app, no strap and
/// no CoreBluetooth, which matters because the caller (`TestBundleAssembler`) is app-target Swift that
/// no default CI job compiles — this is the only automated cover the rule has.
final class OuraSidecarGenerationsTests: XCTestCase {

    private let kinds = ["raw", "cva-ppg", "motion", "activity"]

    // MARK: - classify

    func testClassifyLiveFileIsGenerationZero() {
        let hit = OuraSidecarGenerations.classify(filename: "oura-raw-AABB.jsonl", kinds: kinds)
        XCTAssertEqual(hit?.kind, "raw")
        XCTAssertEqual(hit?.generation, 0)
    }

    func testClassifyRolledGenerations() {
        for n in 1...8 {
            let hit = OuraSidecarGenerations.classify(filename: "oura-raw-AABB.jsonl.\(n)", kinds: kinds)
            XCTAssertEqual(hit?.kind, "raw")
            XCTAssertEqual(hit?.generation, n, "generation \(n)")
        }
        // Multi-digit, so the ring is not silently capped at nine.
        XCTAssertEqual(OuraSidecarGenerations.classify(filename: "oura-raw-AABB.jsonl.12",
                                                       kinds: kinds)?.generation, 12)
    }

    func testClassifyRejectsNonRingShapes() {
        // Not a JSONL sidecar, a non-numeric suffix, a trailing dot, and no ring id at all.
        for bad in ["oura-raw.txt", "oura-raw-AABB.jsonl.bak", "oura-raw-AABB.jsonl.",
                    "oura-raw-AABB.jsonl.1a", "raw-capture.jsonl", "whoop.sqlite", "oura-raw.jsonl"] {
            XCTAssertNil(OuraSidecarGenerations.classify(filename: bad, kinds: kinds), bad)
        }
        // A kind we do not collect.
        XCTAssertNil(OuraSidecarGenerations.classify(filename: "oura-unknown-AABB.jsonl", kinds: kinds))
    }

    func testEntryNameDropsRingId() {
        XCTAssertEqual(OuraSidecarGenerations.entryName(kind: "raw"), "oura-raw.jsonl")
    }

    // MARK: - mergePlan ordering (the actual defect)

    /// THE REGRESSION TEST. Under the old largest-wins rule this exact input shipped `gen 2` alone —
    /// the fattest file — and the newest capture never left the device. The plan must now END with the
    /// live file, because the cap keeps the TAIL.
    func testMergePlanEndsWithTheNewestFileEvenWhenAnOlderGenerationIsFarLarger() {
        let plan = OuraSidecarGenerations.mergePlan(
            files: [("oura-raw-AABB.jsonl", 100),          // live: this morning's drain, small
                    ("oura-raw-AABB.jsonl.1", 500),
                    ("oura-raw-AABB.jsonl.2", 9_000)],     // yesterday's backfill, the old winner
            kinds: kinds, ceilingBytes: 1_000_000)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].entryName, "oura-raw.jsonl")
        XCTAssertEqual(plan[0].files, ["oura-raw-AABB.jsonl.2",
                                       "oura-raw-AABB.jsonl.1",
                                       "oura-raw-AABB.jsonl"])
        XCTAssertEqual(plan[0].files.last, "oura-raw-AABB.jsonl", "newest must be last")
    }

    func testMergePlanIsIndependentOfInputOrder() {
        let forward: [(name: String, bytes: Int)] = [("oura-raw-A.jsonl", 1), ("oura-raw-A.jsonl.1", 2),
                                                     ("oura-raw-A.jsonl.2", 3)]
        let a = OuraSidecarGenerations.mergePlan(files: forward, kinds: kinds, ceilingBytes: 1_000)
        let b = OuraSidecarGenerations.mergePlan(files: forward.reversed(), kinds: kinds, ceilingBytes: 1_000)
        XCTAssertEqual(a, b)
    }

    func testMergePlanOrdersEntriesByKindsNotByDiscovery() {
        let plan = OuraSidecarGenerations.mergePlan(
            files: [("oura-motion-A.jsonl", 1), ("oura-raw-A.jsonl", 1), ("oura-cva-ppg-A.jsonl", 1)],
            kinds: kinds, ceilingBytes: 1_000)
        XCTAssertEqual(plan.map(\.entryName), ["oura-raw.jsonl", "oura-cva-ppg.jsonl", "oura-motion.jsonl"])
    }

    func testMergePlanSkipsKindsWithNoFiles() {
        let plan = OuraSidecarGenerations.mergePlan(files: [("oura-raw-A.jsonl", 1)],
                                                    kinds: kinds, ceilingBytes: 1_000)
        XCTAssertEqual(plan.map(\.entryName), ["oura-raw.jsonl"])
    }

    // MARK: - mergePlan ceiling

    /// The ceiling is a READ bound. The file that crosses it is kept, so the run spanning the boundary
    /// is never half-read; everything strictly older is left on the device.
    func testMergePlanStopsAtCeilingButIncludesTheCrossingFile() {
        let plan = OuraSidecarGenerations.mergePlan(
            files: [("oura-raw-A.jsonl", 60),      // newest
                    ("oura-raw-A.jsonl.1", 60),    // crosses the 100 ceiling -> included
                    ("oura-raw-A.jsonl.2", 60)],   // older -> dropped
            kinds: kinds, ceilingBytes: 100)
        XCTAssertEqual(plan[0].files, ["oura-raw-A.jsonl.1", "oura-raw-A.jsonl"])
    }

    /// A single file at or over the ceiling reads exactly as it did before this change — one file, the
    /// newest — so the memory profile never regresses against largest-wins.
    func testMergePlanKeepsOnlyTheNewestWhenItAlreadyFillsTheCeiling() {
        let plan = OuraSidecarGenerations.mergePlan(
            files: [("oura-raw-A.jsonl", 500), ("oura-raw-A.jsonl.1", 500)],
            kinds: kinds, ceilingBytes: 100)
        XCTAssertEqual(plan[0].files, ["oura-raw-A.jsonl"])
    }

    /// Shipping nothing would be strictly worse than shipping the newest tail, so a degenerate ceiling
    /// still yields one file rather than an empty plan.
    func testMergePlanWithNonPositiveCeilingStillShipsTheNewestFile() {
        for ceiling in [0, -1] {
            let plan = OuraSidecarGenerations.mergePlan(
                files: [("oura-raw-A.jsonl", 10), ("oura-raw-A.jsonl.1", 10)],
                kinds: kinds, ceilingBytes: ceiling)
            XCTAssertEqual(plan[0].files, ["oura-raw-A.jsonl"], "ceiling \(ceiling)")
        }
    }

    func testMergePlanNeverReturnsAnEmptyFileList() {
        let plan = OuraSidecarGenerations.mergePlan(
            files: [("oura-raw-A.jsonl", 0)], kinds: kinds, ceilingBytes: 1_000)
        XCTAssertEqual(plan[0].files, ["oura-raw-A.jsonl"])
    }

    func testMergePlanIgnoresUnrelatedFiles() {
        let plan = OuraSidecarGenerations.mergePlan(
            files: [("raw-capture.jsonl", 10), ("whoop.sqlite", 10), ("oura-raw-A.jsonl", 10)],
            kinds: kinds, ceilingBytes: 1_000)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].files, ["oura-raw-A.jsonl"])
    }

    /// Two rings that wrote the same kind collide on generation. The tie must break deterministically
    /// rather than by directory order, or the bundle listing changes between exports.
    func testMergePlanBreaksSameGenerationTiesOnFilename() {
        let plan = OuraSidecarGenerations.mergePlan(
            files: [("oura-raw-BBBB.jsonl", 10), ("oura-raw-AAAA.jsonl", 10)],
            kinds: kinds, ceilingBytes: 1_000)
        // Newest-first sorts A before B; reversed for concatenation, B lands last.
        XCTAssertEqual(plan[0].files, ["oura-raw-BBBB.jsonl", "oura-raw-AAAA.jsonl"])
    }
}
