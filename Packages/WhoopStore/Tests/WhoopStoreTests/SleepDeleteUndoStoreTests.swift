import XCTest
@testable import WhoopStore

/// #65 undo, the DB half. The Repository (app target, unrunnable headless) resolves the owning
/// namespace and drives these store calls; these tests pin the store-level guarantees the undo relies
/// on: (a) a deleted row restores VERBATIM into whichever namespace owned it, (b) restoring a
/// `userEdited` night preserves the flag so the next analyze pass does NOT re-score it as a detected
/// twin (HAZARD 2), and (c) the delete + restore never leaks into the OTHER namespace. Paired with
/// `DismissedSleepSpansTests` (the tombstone-lift half) this covers the whole undo path.
final class SleepDeleteUndoStoreTests: XCTestCase {

    private let computed = "my-whoop-noop"
    private let imported = "my-whoop"

    /// The same session as it reads back from `deviceId`. `sleepSessions` stamps the device it read the
    /// row from, and a hand-built session carries no provenance, so a whole-value expectation has to
    /// state it. The write takes its device from the `upsertSleepSessions` argument, never from this
    /// field, so a session's `deviceId` is an output of the read and not an input to the write.
    private func readBack(_ s: CachedSleepSession, from deviceId: String) -> CachedSleepSession {
        CachedSleepSession(startTs: s.startTs, endTs: s.endTs, efficiency: s.efficiency,
                           restingHr: s.restingHr, avgHrv: s.avgHrv, stagesJSON: s.stagesJSON,
                           userEdited: s.userEdited, startTsAdjusted: s.startTsAdjusted,
                           stagingSparse: s.stagingSparse, deviceId: deviceId)
    }

    private func session(start: Int, end: Int, edited: Bool = false, stages: String? = "[]",
                         startAdjusted: Int? = nil) -> CachedSleepSession {
        CachedSleepSession(startTs: start, endTs: end, efficiency: 0.9, restingHr: 50,
                           avgHrv: 60, stagesJSON: stages, userEdited: edited,
                           startTsAdjusted: startAdjusted)
    }

    // MARK: - Restore into the ORIGINAL namespace (HAZARD 2)

    func testUndoRestoresComputedRowIntoComputedNamespaceOnly() async throws {
        let store = try await WhoopStore.inMemory()
        let row = session(start: 1000, end: 5000)
        try await store.upsertSleepSessions([row], deviceId: computed)

        // Delete (the delete half of deleteSleepSession) resolves computed-first.
        let deleted = try await store.deleteSleepSession(deviceId: computed, startTs: 1000)
        XCTAssertEqual(deleted, 1)

        // Undo restores the snapshot into the SAME (computed) namespace.
        _ = try await store.upsertSleepSessions([row], deviceId: computed)

        let computedRows = try await store.sleepSessions(deviceId: computed, from: 0, to: 100_000, limit: 100)
        let importedRows = try await store.sleepSessions(deviceId: imported, from: 0, to: 100_000, limit: 100)
        XCTAssertEqual(computedRows, [readBack(row, from: computed)], "restored verbatim into computed")
        XCTAssertTrue(importedRows.isEmpty, "undo never leaks into the imported namespace")
    }

    func testUndoRestoresImportedRowIntoImportedNamespaceOnly() async throws {
        let store = try await WhoopStore.inMemory()
        let row = session(start: 2000, end: 8000)
        try await store.upsertSleepSessions([row], deviceId: imported)

        // The delete resolves computed-first (0 rows), then falls back to imported.
        let computedDeleted = try await store.deleteSleepSession(deviceId: computed, startTs: 2000)
        XCTAssertEqual(computedDeleted, 0, "no computed row owns this night")
        let importedDeleted = try await store.deleteSleepSession(deviceId: imported, startTs: 2000)
        XCTAssertEqual(importedDeleted, 1)

        // Undo restores into imported, NOT computed (the bug the brief guards against).
        _ = try await store.upsertSleepSessions([row], deviceId: imported)

        let computedRows = try await store.sleepSessions(deviceId: computed, from: 0, to: 100_000, limit: 100)
        let importedRows = try await store.sleepSessions(deviceId: imported, from: 0, to: 100_000, limit: 100)
        XCTAssertEqual(importedRows, [readBack(row, from: imported)], "restored verbatim into imported")
        XCTAssertTrue(computedRows.isEmpty, "an imported night must never resurrect as a computed twin")
    }

    // MARK: - userEdited preserved on restore (HAZARD 2)

    func testUndoRestoresUserEditedNightWithFlagIntact() async throws {
        let store = try await WhoopStore.inMemory()
        // A hand-corrected night: userEdited, an adjusted onset, custom stages.
        let edited = session(start: 3000, end: 9000, edited: true,
                             stages: "[{\"start\":3200,\"end\":9000,\"stage\":\"deep\"}]",
                             startAdjusted: 3200)
        try await store.upsertSleepSessions([edited], deviceId: computed)

        _ = try await store.deleteSleepSession(deviceId: computed, startTs: 3000)
        // Undo re-inserts the snapshot verbatim.
        _ = try await store.upsertSleepSessions([edited], deviceId: computed)

        let rows = try await store.sleepSessions(deviceId: computed, from: 0, to: 100_000, limit: 100)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].userEdited, "the correction flag survives undo so analyze won't re-detect a twin")
        XCTAssertEqual(rows[0].startTsAdjusted, 3200)
        XCTAssertEqual(rows[0].endTs, 9000)
        XCTAssertEqual(rows[0].stagesJSON, edited.stagesJSON)
    }

    // MARK: - motion + band-state survive undo (Deep Timeline tracks; Android parity)

    /// A `userEdited` night is never re-detected, so `analyzeRecent` won't re-persist its Deep Timeline
    /// motion + Band Sleep State tracks after an undo. The Repository snapshot therefore captures
    /// `motionJSON`/`sleepStateJSON` at delete time and re-persists them after the restore-upsert. This
    /// pins the store half of that path: the two per-epoch series must round-trip through
    /// delete → upsert → re-persist intact (the bug was they came back NULL, diverging from Android).
    func testUndoRestoresUserEditedNightMotionAndBandStateTracks() async throws {
        let store = try await WhoopStore.inMemory()
        let edited = session(start: 4000, end: 10_000, edited: true)
        try await store.upsertSleepSessions([edited], deviceId: computed)

        // Populate the per-epoch tracks the Deep Timeline reads.
        let motion: [Double] = [0.1, 0.9, 0.3, 0.0, 1.2]
        let bandState: [Int] = [0, 1, 2, 3, 1]
        _ = try await store.persistSessionMotion(deviceId: computed, sessionStart: 4000, motionEpochs: motion)
        _ = try await store.persistSessionSleepState(deviceId: computed, sessionStart: 4000, states: bandState)

        // Snapshot the tracks BEFORE deleting (what ownedSleepRowSnapshot now captures).
        let snapMotion = try await store.sessionMotion(deviceId: computed, sessionStart: 4000)
        let snapState = try await store.sessionSleepState(deviceId: computed, sessionStart: 4000)
        XCTAssertEqual(snapMotion, motion)
        XCTAssertEqual(snapState, bandState)

        // Delete drops the row AND its per-epoch columns. (Hoist awaited reads: XCTAssert autoclosures
        // can't await.)
        _ = try await store.deleteSleepSession(deviceId: computed, startTs: 4000)
        let motionAfterDelete = try await store.sessionMotion(deviceId: computed, sessionStart: 4000)
        let stateAfterDelete = try await store.sessionSleepState(deviceId: computed, sessionStart: 4000)
        XCTAssertNil(motionAfterDelete, "delete removes the motion track with the row")
        XCTAssertNil(stateAfterDelete)

        // Undo: restore the row, THEN re-persist the captured tracks (the fixed undo order).
        _ = try await store.upsertSleepSessions([edited], deviceId: computed)
        _ = try await store.persistSessionMotion(deviceId: computed, sessionStart: 4000,
                                                 motionEpochs: snapMotion ?? [])
        _ = try await store.persistSessionSleepState(deviceId: computed, sessionStart: 4000,
                                                     states: snapState ?? [])

        // Both Deep Timeline tracks are back, byte-for-byte (no silent loss like the pre-fix path).
        let motionAfterUndo = try await store.sessionMotion(deviceId: computed, sessionStart: 4000)
        let stateAfterUndo = try await store.sessionSleepState(deviceId: computed, sessionStart: 4000)
        XCTAssertEqual(motionAfterUndo, motion, "the Deep Timeline motion track survives undo")
        XCTAssertEqual(stateAfterUndo, bandState, "the Band Sleep State track survives undo")
    }
}
