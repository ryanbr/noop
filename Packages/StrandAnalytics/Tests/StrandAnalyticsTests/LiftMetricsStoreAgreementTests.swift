import XCTest
import GRDB
import WhoopStore
@testable import StrandAnalytics

/// The per-muscle set count is computed TWICE, by two different pieces of code, and both are shown
/// to the user:
///
///   * `WhoopStore.liftSetCounts` — SQL, feeds the Lift Log hub's "last 7 days" card;
///   * `LiftMetrics.muscleCounts` — in memory, feeds a finished session's detail sheet.
///
/// It is the load-bearing figure of the whole feature — the one the reference doses are compared
/// against — so the two disagreeing would mean two screens reporting different numbers for the same
/// sets, with nothing to notice. They are pinned against each other here rather than each being
/// pinned to its own expectation, because agreeing with a literal is not the same as agreeing with
/// each other.
///
/// This test exists because they DID differ: the in-memory version excluded a muscle listed both as
/// primary and secondary, and the SQL version did not. Nothing showed it, because the write path
/// strips the primary on the way in — so the divergence was invisible until some future writer
/// forgot to. The malformed row below is written with raw SQL precisely because the public API
/// cannot produce one.
final class LiftMetricsStoreAgreementTests: XCTestCase {

    private let day = 1_700_000_000

    /// Insert sets through raw SQL so the row shapes are exactly what is asked for, including the
    /// one the public API would clean up.
    private func store(_ rows: [(primary: String?, secondary: String, warmup: Int)],
                       reps: [Int] = []) async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        let writer = store.registryWriter
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO liftSession (id, deviceId, startTs, endTs, sport, programId, programName,
                                         sessionRpe, note)
                VALUES ('s1', 'dev', ?, ?, 'Strength Training', NULL, NULL, NULL, NULL)
                """, arguments: [self.day, self.day + 3600])
            for (i, r) in rows.enumerated() {
                try db.execute(sql: """
                    INSERT INTO liftSet (id, deviceId, sessionId, ord, exercise, primaryMuscle,
                                         secondaryMuscles, setIndex, weightKg, reps, rpe, isWarmup,
                                         startTs, endTs, restSec, note)
                    VALUES (?, 'dev', 's1', ?, 'Exercise', ?, ?, 1, 60, ?, NULL, ?, NULL, NULL, NULL, NULL)
                    """, arguments: ["set-\(i)", i, r.primary, r.secondary,
                                    reps.indices.contains(i) ? reps[i] : 10, r.warmup])
            }
        }
        return store
    }

    /// The same rows, as `LiftMetrics` would receive them from the store.
    private func rows(_ store: WhoopStore) async throws -> [LiftSetRow] {
        try await store.liftSets(sessionId: "s1")
    }

    private func assertAgree(_ store: WhoopStore,
                             file: StaticString = #filePath, line: UInt = #line) async throws {
        let sql = try await store.liftSetCounts(deviceId: "dev", fromTs: day - 1, toTs: day + 1)
        let memory = LiftMetrics.muscleCounts(try await rows(store))
        XCTAssertEqual(sql.direct, memory.direct, "direct counts diverged", file: file, line: line)
        XCTAssertEqual(sql.indirect, memory.indirect, "indirect counts diverged", file: file, line: line)
        XCTAssertEqual(sql.fractional, memory.fractional, "fractional counts diverged", file: file, line: line)
    }

    /// The ordinary shape: a primary and two distinct secondaries.
    func testBothImplementationsAgreeOnAWellFormedSet() async throws {
        let store = try await store([(primary: "chest", secondary: "frontDelts,triceps", warmup: 0)])
        try await assertAgree(store)

        let counts = try await store.liftSetCounts(deviceId: "dev", fromTs: day - 1, toTs: day + 1)
        XCTAssertEqual(counts.fractional[.chest], LiftMuscle.directSetCredit)
        XCTAssertEqual(counts.fractional[.triceps], LiftMuscle.indirectSetCredit)
    }

    /// THE ONE THAT WAS BROKEN. A row that lists its own primary among the secondaries must be
    /// credited once, as direct, by BOTH — not 1.0 by one screen and 1.5 by the other.
    func testBothImplementationsAgreeWhenARowListsItsPrimaryAsASecondary() async throws {
        let store = try await store([(primary: "chest", secondary: "chest,triceps", warmup: 0)])
        try await assertAgree(store)

        let counts = try await store.liftSetCounts(deviceId: "dev", fromTs: day - 1, toTs: day + 1)
        XCTAssertEqual(counts.direct[.chest], 1)
        XCTAssertNil(counts.indirect[.chest], "the primary must not also be counted as indirect")
        XCTAssertEqual(counts.fractional[.chest], LiftMuscle.directSetCredit,
                       "1.0, never 1.5 — the same muscle cannot be worked twice by one set")
    }

    /// Warm-ups are excluded on both sides. They are excluded from volume and the per-muscle counts
    /// by design, so a difference here would inflate the figure the doses are compared against.
    func testBothImplementationsAgreeThatWarmUpsDoNotCount() async throws {
        let store = try await store([
            (primary: "quads", secondary: "glutes", warmup: 1),
            (primary: "quads", secondary: "glutes", warmup: 0),
        ])
        try await assertAgree(store)

        let counts = try await store.liftSetCounts(deviceId: "dev", fromTs: day - 1, toTs: day + 1)
        XCTAssertEqual(counts.direct[.quads], 1, "only the working set counts")
    }

    /// An unclassified set contributes nothing rather than defaulting into a bucket.
    func testBothImplementationsAgreeOnAnUnclassifiedSet() async throws {
        let store = try await store([(primary: nil, secondary: "", warmup: 0)])
        try await assertAgree(store)

        let counts = try await store.liftSetCounts(deviceId: "dev", fromTs: day - 1, toTs: day + 1)
        XCTAssertTrue(counts.fractional.isEmpty, "no muscle was named, so no muscle is credited")
    }

    /// A token no longer in the vocabulary is ignored by both rather than crashing or counting.
    func testBothImplementationsAgreeOnAnUnknownToken() async throws {
        let store = try await store([(primary: "shoulders", secondary: "pecs,triceps", warmup: 0)])
        try await assertAgree(store)

        let counts = try await store.liftSetCounts(deviceId: "dev", fromTs: day - 1, toTs: day + 1)
        XCTAssertEqual(counts.indirect[.triceps], 1, "the recognisable half still counts")
        XCTAssertTrue(counts.direct.isEmpty)
    }

    /// A set saved at zero reps was never performed, and neither implementation counts it. The rule is
    /// exactly `reps != 0` on both sides, so a nonsensical negative count still counts in both rather
    /// than in one: an SQL `reps > 0` would drop it where `LiftMetrics.isPerformed` keeps it.
    func testBothImplementationsAgreeThatASetWithZeroRepsDoesNotCount() async throws {
        let store = try await store([
            (primary: "chest", secondary: "triceps", warmup: 0),
            (primary: "chest", secondary: "triceps", warmup: 0),
            (primary: "chest", secondary: "triceps", warmup: 0),
        ], reps: [0, 10, -1])
        try await assertAgree(store)

        let counts = try await store.liftSetCounts(deviceId: "dev", fromTs: day - 1, toTs: day + 1)
        XCTAssertEqual(counts.direct[.chest], 2, "the zero-rep set is the only one left out")
        XCTAssertEqual(counts.indirect[.triceps], 2)
    }
}
