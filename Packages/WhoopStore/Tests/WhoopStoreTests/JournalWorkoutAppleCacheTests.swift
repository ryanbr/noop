import XCTest
import GRDB
@testable import WhoopStore

final class JournalWorkoutAppleCacheTests: XCTestCase {

    // MARK: - migration (v8 creates the three tables with the right PKs)

    func testV8CreatesTables() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("journal"))
        XCTAssertTrue(tables.contains("workout"))
        XCTAssertTrue(tables.contains("appleDaily"))

        let journalPK = try await store.primaryKeyColumns("journal")
        XCTAssertEqual(journalPK, ["deviceId", "day", "question"])
        let workoutPK = try await store.primaryKeyColumns("workout")
        XCTAssertEqual(workoutPK, ["deviceId", "startTs", "sport"])
        let applePK = try await store.primaryKeyColumns("appleDaily")
        XCTAssertEqual(applePK, ["deviceId", "day"])
    }

    func testExistingTablesStillPresentAfterV8() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["device", "hrSample", "rrInterval", "event", "battery", "rawBatch",
                  "sleepSession", "dailyMetric"] {
            XCTAssertTrue(tables.contains(t), "v8 must not drop \(t)")
        }
    }

    // MARK: - journal

    func testJournalUpsertReadAndIdempotency() async throws {
        let store = try await WhoopStore.inMemory()
        let e = JournalEntry(day: "2026-05-23", question: "Did you drink alcohol?",
                             answeredYes: true, notes: "two beers")
        try await store.upsertJournal([e], deviceId: "devA")

        var rows = try await store.journalEntries(deviceId: "devA", from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0], e)

        // Re-upsert same natural key with changed values → no duplicate, value updated.
        let e2 = JournalEntry(day: "2026-05-23", question: "Did you drink alcohol?",
                              answeredYes: false, notes: nil)
        try await store.upsertJournal([e2], deviceId: "devA")
        rows = try await store.journalEntries(deviceId: "devA", from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(rows.count, 1, "same (deviceId,day,question) must not duplicate")
        XCTAssertEqual(rows[0].answeredYes, false)
        XCTAssertNil(rows[0].notes)
    }

    func testDeleteJournalTouchesOnlyTheNamedSource() async throws {
        // The native logging card clears under "noop-journal" only, an identical
        // (day, question) imported under "my-whoop" must survive the clear.
        let store = try await WhoopStore.inMemory()
        let e = JournalEntry(day: "2026-06-09", question: "Any alcohol?", answeredYes: true, notes: nil)
        try await store.upsertJournal([e], deviceId: "my-whoop")
        try await store.upsertJournal([e], deviceId: "noop-journal")

        let n = try await store.deleteJournal(deviceId: "noop-journal", day: "2026-06-09",
                                              question: "Any alcohol?")
        XCTAssertEqual(n, 1)
        let imported = try await store.journalEntries(deviceId: "my-whoop",
                                                      from: "2026-06-01", to: "2026-06-30")
        XCTAssertEqual(imported.count, 1, "imported row must be untouched")
        let native = try await store.journalEntries(deviceId: "noop-journal",
                                                    from: "2026-06-01", to: "2026-06-30")
        XCTAssertEqual(native.count, 0)
    }

    func testJournalDistinctQuestionsCoexist() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertJournal([
            JournalEntry(day: "2026-05-23", question: "Caffeine?", answeredYes: true, notes: nil),
            JournalEntry(day: "2026-05-23", question: "Alcohol?", answeredYes: false, notes: nil),
        ], deviceId: "devA")
        let rows = try await store.journalEntries(deviceId: "devA", from: "2026-05-23", to: "2026-05-23")
        XCTAssertEqual(rows.map { $0.question }, ["Alcohol?", "Caffeine?"]) // question ASC
    }

    func testJournalDayRangeAndDeviceFilter() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertJournal([
            JournalEntry(day: "2026-05-01", question: "Q", answeredYes: true, notes: nil),
            JournalEntry(day: "2026-05-20", question: "Q", answeredYes: true, notes: nil),
        ], deviceId: "devA")
        try await store.upsertJournal([
            JournalEntry(day: "2026-05-20", question: "Q", answeredYes: false, notes: nil),
        ], deviceId: "devB")
        let rows = try await store.journalEntries(deviceId: "devA", from: "2026-05-10", to: "2026-05-31")
        XCTAssertEqual(rows.map { $0.day }, ["2026-05-20"])
        XCTAssertEqual(rows[0].answeredYes, true, "must not bleed devB's row")
    }

    func testUpsertJournalReturnsChangeCount() async throws {
        let store = try await WhoopStore.inMemory()
        let n = try await store.upsertJournal([
            JournalEntry(day: "2026-05-01", question: "A", answeredYes: true, notes: nil),
            JournalEntry(day: "2026-05-01", question: "B", answeredYes: false, notes: nil),
        ], deviceId: "devA")
        XCTAssertEqual(n, 2)
    }

    // MARK: - journal numeric value (#322 / v20)

    func testV20AddsNumericValueColumn() async throws {
        // The v20 migration must add `numericValue` to the journal table (additive, nullable).
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "journal")
        XCTAssertTrue(cols.contains("numericValue"), "v20 must add journal.numericValue")
        // The PK is unchanged (still natural key), so existing history keys the same way.
        let pk = try await store.primaryKeyColumns("journal")
        XCTAssertEqual(pk, ["deviceId", "day", "question"])
    }

    func testJournalNumericValueRoundTrips() async throws {
        // A numeric log stores answeredYes=true AND the value; both survive the round-trip.
        let store = try await WhoopStore.inMemory()
        let e = JournalEntry(day: "2026-06-20", question: "Caffeine (mg)",
                             answeredYes: true, notes: nil, numericValue: 180)
        try await store.upsertJournal([e], deviceId: "noop-journal")
        let rows = try await store.journalEntries(deviceId: "noop-journal",
                                                  from: "2026-06-01", to: "2026-06-30")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].numericValue, 180)
        XCTAssertTrue(rows[0].answeredYes, "a numeric log is also a yes for the with/without split")
    }

    func testJournalPlainAnswerHasNilNumericValue() async throws {
        // A plain yes/no answer (and every legacy/imported row) reads back numericValue == nil.
        let store = try await WhoopStore.inMemory()
        try await store.upsertJournal(
            [JournalEntry(day: "2026-06-20", question: "Alcohol?", answeredYes: false, notes: nil)],
            deviceId: "noop-journal")
        let rows = try await store.journalEntries(deviceId: "noop-journal",
                                                  from: "2026-06-20", to: "2026-06-20")
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].numericValue, "a plain answer carries no numeric reading")
    }

    func testJournalNumericValueUpdatesOnConflict() async throws {
        // Re-logging the same (day, question) with a new value updates in place (no duplicate),
        // and clearing the value (nil) round-trips as nil.
        let store = try await WhoopStore.inMemory()
        let day = "2026-06-21", q = "Water (L)"
        try await store.upsertJournal(
            [JournalEntry(day: day, question: q, answeredYes: true, notes: nil, numericValue: 2)],
            deviceId: "noop-journal")
        try await store.upsertJournal(
            [JournalEntry(day: day, question: q, answeredYes: true, notes: nil, numericValue: 3.5)],
            deviceId: "noop-journal")
        var rows = try await store.journalEntries(deviceId: "noop-journal", from: day, to: day)
        XCTAssertEqual(rows.count, 1, "same natural key must not duplicate")
        XCTAssertEqual(rows[0].numericValue, 3.5)
        // Overwrite with a plain answer → numericValue clears to nil.
        try await store.upsertJournal(
            [JournalEntry(day: day, question: q, answeredYes: false, notes: nil)],
            deviceId: "noop-journal")
        rows = try await store.journalEntries(deviceId: "noop-journal", from: day, to: day)
        XCTAssertNil(rows[0].numericValue)
    }

    // MARK: - workout

    func testWorkoutUpsertReadAndIdempotency() async throws {
        let store = try await WhoopStore.inMemory()
        let w = WorkoutRow(startTs: 1_000, endTs: 4_600, sport: "run", source: "apple",
                           durationS: 3600, energyKcal: 520.5, avgHr: 148, maxHr: 176,
                           strain: 12.4, distanceM: 8000, zonesJSON: "{\"z1\":10,\"z2\":40}",
                           notes: "easy", steps: nil)
        try await store.upsertWorkouts([w], deviceId: "devA")

        var rows = try await store.workouts(deviceId: "devA", from: 0, to: 100_000, limit: 100)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0], w)

        // Re-upsert same natural key with updated values → no duplicate, value updated.
        let w2 = WorkoutRow(startTs: 1_000, endTs: 5_000, sport: "run", source: "whoop",
                            durationS: 4000, energyKcal: 600, avgHr: 150, maxHr: 180,
                            strain: 14.0, distanceM: 9000, zonesJSON: nil, notes: nil, steps: nil)
        try await store.upsertWorkouts([w2], deviceId: "devA")
        rows = try await store.workouts(deviceId: "devA", from: 0, to: 100_000, limit: 100)
        XCTAssertEqual(rows.count, 1, "same (deviceId,startTs,sport) must not duplicate")
        XCTAssertEqual(rows[0], w2)
        XCTAssertNil(rows[0].zonesJSON)
        XCTAssertNil(rows[0].notes)
    }

    func testWorkoutDistinctSportSameStartCoexist() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertWorkouts([
            WorkoutRow(startTs: 1_000, endTs: 2_000, sport: "run", source: "apple",
                       durationS: nil, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                       distanceM: nil, zonesJSON: nil, notes: nil, steps: nil),
            WorkoutRow(startTs: 1_000, endTs: 2_000, sport: "cycle", source: "apple",
                       durationS: nil, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                       distanceM: nil, zonesJSON: nil, notes: nil, steps: nil),
        ], deviceId: "devA")
        let rows = try await store.workouts(deviceId: "devA", from: 0, to: 100_000, limit: 100)
        XCTAssertEqual(rows.count, 2, "same startTs but different sport are distinct rows")
    }

    // MARK: - #1058 per-session steps: a second activity file for a day ADDS, and re-import is idempotent

    func testWorkoutStepsRoundTrip() async throws {
        let store = try await WhoopStore.inMemory()
        let w = WorkoutRow(startTs: 1_000, endTs: 4_600, sport: "run", source: "activity-file",
                           durationS: nil, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                           distanceM: nil, zonesJSON: nil, notes: nil, steps: 3_000)
        try await store.upsertWorkouts([w], deviceId: "activity-file")
        let rows = try await store.workouts(deviceId: "activity-file", from: 0, to: 100_000, limit: 100)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].steps, 3_000)
    }

    func testSumWorkoutStepsAddsAcrossSameDaySessionsAndIsIdempotent() async throws {
        // The #1058 repro: two walks on one day. Before the fix, the second file's whole-day upsert
        // clobbered the first's step count; now each session carries its steps and the day total is
        // their SUM — and re-importing a file leaves that total unchanged.
        let store = try await WhoopStore.inMemory()
        let morning = WorkoutRow(startTs: 10_000, endTs: 12_000, sport: "walk", source: "activity-file",
                                 durationS: nil, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                                 distanceM: nil, zonesJSON: nil, notes: nil, steps: 3_000)
        let evening = WorkoutRow(startTs: 60_000, endTs: 63_000, sport: "walk", source: "activity-file",
                                 durationS: nil, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                                 distanceM: nil, zonesJSON: nil, notes: nil, steps: 8_834)

        try await store.upsertWorkouts([morning], deviceId: "activity-file")
        var total = try await store.sumWorkoutSteps(deviceId: "activity-file", from: 0, to: 86_400)
        XCTAssertEqual(total, 3_000, "one walk = its own steps")

        try await store.upsertWorkouts([evening], deviceId: "activity-file")
        total = try await store.sumWorkoutSteps(deviceId: "activity-file", from: 0, to: 86_400)
        XCTAssertEqual(total, 11_834, "second same-day walk ADDS, not overwrites")

        // Re-import the morning file (same startTs+sport) → its row is replaced, not duplicated.
        try await store.upsertWorkouts([morning], deviceId: "activity-file")
        total = try await store.sumWorkoutSteps(deviceId: "activity-file", from: 0, to: 86_400)
        XCTAssertEqual(total, 11_834, "re-importing a file must not double-count")
    }

    func testSumWorkoutStepsIgnoresSteplessSessionsAndOtherDaysAndSources() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertWorkouts([
            // a cycling session that day — no steps, must not affect the total or crash the SUM
            WorkoutRow(startTs: 20_000, endTs: 22_000, sport: "cycle", source: "activity-file",
                       durationS: nil, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                       distanceM: nil, zonesJSON: nil, notes: nil, steps: nil),
            WorkoutRow(startTs: 30_000, endTs: 32_000, sport: "walk", source: "activity-file",
                       durationS: nil, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                       distanceM: nil, zonesJSON: nil, notes: nil, steps: 5_000),
            // next day — outside the range
            WorkoutRow(startTs: 90_000, endTs: 92_000, sport: "walk", source: "activity-file",
                       durationS: nil, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                       distanceM: nil, zonesJSON: nil, notes: nil, steps: 9_999),
        ], deviceId: "activity-file")
        // a different source with steps that day — must not bleed into the activity-file total
        try await store.upsertWorkouts([
            WorkoutRow(startTs: 40_000, endTs: 42_000, sport: "walk", source: "apple",
                       durationS: nil, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                       distanceM: nil, zonesJSON: nil, notes: nil, steps: 7_777),
        ], deviceId: "apple-health")

        let total = try await store.sumWorkoutSteps(deviceId: "activity-file", from: 0, to: 86_400)
        XCTAssertEqual(total, 5_000, "only same-source, same-day, step-bearing sessions count")
    }

    func testWorkoutNullableMetricsRoundTripAsNil() async throws {
        let store = try await WhoopStore.inMemory()
        let w = WorkoutRow(startTs: 50, endTs: 60, sport: "yoga", source: "apple",
                           durationS: nil, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                           distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
        try await store.upsertWorkouts([w], deviceId: "devA")
        let rows = try await store.workouts(deviceId: "devA", from: 0, to: 100, limit: 10)
        XCTAssertEqual(rows.count, 1)
        let r = try XCTUnwrap(rows.first)
        XCTAssertNil(r.durationS); XCTAssertNil(r.energyKcal); XCTAssertNil(r.avgHr)
        XCTAssertNil(r.maxHr); XCTAssertNil(r.strain); XCTAssertNil(r.distanceM)
        XCTAssertNil(r.zonesJSON); XCTAssertNil(r.notes)
    }

    func testWorkoutRangeAndLimit() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertWorkouts([
            WorkoutRow(startTs: 100, endTs: 200, sport: "run", source: "a", durationS: nil,
                       energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
                       zonesJSON: nil, notes: nil, steps: nil),
            WorkoutRow(startTs: 500, endTs: 600, sport: "run", source: "a", durationS: nil,
                       energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
                       zonesJSON: nil, notes: nil, steps: nil),
            WorkoutRow(startTs: 900, endTs: 1000, sport: "run", source: "a", durationS: nil,
                       energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
                       zonesJSON: nil, notes: nil, steps: nil),
        ], deviceId: "devA")
        let ranged = try await store.workouts(deviceId: "devA", from: 400, to: 1000, limit: 100)
        XCTAssertEqual(ranged.map { $0.startTs }, [500, 900])
        let limited = try await store.workouts(deviceId: "devA", from: 0, to: 100_000, limit: 1)
        XCTAssertEqual(limited.map { $0.startTs }, [100], "limit honoured, oldest first")
    }

    func testDeleteWorkoutsBySportAndRange() async throws {
        // Pins deleteWorkouts (detected-workout idempotency, port of WhoopDao.deleteWorkoutsBySport):
        // deletes only the matching (deviceId, sport, startTs-range) rows, leaving other sports,
        // other devices and out-of-range rows untouched.
        let store = try await WhoopStore.inMemory()
        func row(_ ts: Int, _ sport: String) -> WorkoutRow {
            WorkoutRow(startTs: ts, endTs: ts + 600, sport: sport, source: "devA-noop",
                       durationS: 600, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                       distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
        }
        try await store.upsertWorkouts([row(1_000, "detected"), row(2_000, "detected"),
                                        row(1_500, "run")], deviceId: "devA-noop")
        try await store.upsertWorkouts([row(1_200, "detected")], deviceId: "devA")

        let n = try await store.deleteWorkouts(deviceId: "devA-noop", sport: "detected",
                                               from: 0, to: 1_800)
        XCTAssertEqual(n, 1, "only the in-range detected row of the computed source")
        let left = try await store.workouts(deviceId: "devA-noop", from: 0, to: 10_000, limit: 100)
        XCTAssertEqual(left.map { $0.startTs }.sorted(), [1_500, 2_000])
        let other = try await store.workouts(deviceId: "devA", from: 0, to: 10_000, limit: 100)
        XCTAssertEqual(other.count, 1, "other device untouched")
    }

    // MARK: - appleDaily

    func testAppleDailyUpsertReadAndIdempotency() async throws {
        let store = try await WhoopStore.inMemory()
        let a = AppleDaily(day: "2026-05-23", steps: 9123, activeKcal: 540.2, basalKcal: 1600.0,
                           vo2max: 48.5, avgHr: 62, maxHr: 171, walkingHr: 98, weightKg: 78.4)
        try await store.upsertAppleDaily([a], deviceId: "devA")

        var rows = try await store.appleDaily(deviceId: "devA", from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0], a)

        // Re-upsert same day with new values → no duplicate, value updated.
        let a2 = AppleDaily(day: "2026-05-23", steps: 10000, activeKcal: 600, basalKcal: 1620,
                            vo2max: 49.0, avgHr: 60, maxHr: 175, walkingHr: 95, weightKg: 78.0)
        try await store.upsertAppleDaily([a2], deviceId: "devA")
        rows = try await store.appleDaily(deviceId: "devA", from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(rows.count, 1, "same (deviceId,day) must not duplicate")
        XCTAssertEqual(rows[0], a2)
    }

    func testAppleDailyNullableMetricsRoundTripAsNil() async throws {
        let store = try await WhoopStore.inMemory()
        let a = AppleDaily(day: "2026-05-25", steps: nil, activeKcal: nil, basalKcal: nil,
                           vo2max: nil, avgHr: nil, maxHr: nil, walkingHr: nil, weightKg: nil)
        try await store.upsertAppleDaily([a], deviceId: "devA")
        let rows = try await store.appleDaily(deviceId: "devA", from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(rows.count, 1)
        let r = try XCTUnwrap(rows.first)
        XCTAssertNil(r.steps); XCTAssertNil(r.activeKcal); XCTAssertNil(r.basalKcal)
        XCTAssertNil(r.vo2max); XCTAssertNil(r.avgHr); XCTAssertNil(r.maxHr)
        XCTAssertNil(r.walkingHr); XCTAssertNil(r.weightKg)
    }

    func testAppleDailyDayRangeFilter() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertAppleDaily([
            AppleDaily(day: "2026-05-01", steps: 1, activeKcal: nil, basalKcal: nil, vo2max: nil,
                       avgHr: nil, maxHr: nil, walkingHr: nil, weightKg: nil),
            AppleDaily(day: "2026-05-20", steps: 2, activeKcal: nil, basalKcal: nil, vo2max: nil,
                       avgHr: nil, maxHr: nil, walkingHr: nil, weightKg: nil),
        ], deviceId: "devA")
        let rows = try await store.appleDaily(deviceId: "devA", from: "2026-05-10", to: "2026-05-31")
        XCTAssertEqual(rows.map { $0.day }, ["2026-05-20"])
    }
}
