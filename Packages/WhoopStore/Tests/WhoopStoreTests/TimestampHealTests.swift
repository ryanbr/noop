import XCTest
import WhoopProtocol
@testable import WhoopStore

/// #547 — the one-time heal of a DB polluted by a bad-clock strap (pikapik). Before the ingest gate,
/// type-47 records were trusted verbatim, so a broken-clock WHOOP wrote raw rows + computed days dated to
/// scattered garbage (far-past, a bogus 2027, FUTURE dates). `healImplausibleTimestamps` purges those so a
/// rescore recomputes the real days cleanly. Mirrors the Android Room-cleanup tests: SAME bounds, SAME set.
final class TimestampHealTests: XCTestCase {

    // A deterministic "now" well above the 1.7B floor (≈ 2025-06). The heal's future bound = now + 1 day.
    private let now = 1_750_000_000
    private let todayKey = "2025-06-15"   // local day matching `now`; future = any day > this

    private func hr(_ ts: Int, _ bpm: Int) -> HRSample { HRSample(ts: ts, bpm: bpm) }

    func testPurgesImplausibleRawRowsKeepsGood() async throws {
        let store = try await WhoopStore.inMemory()
        // Good rows around "now"; garbage rows far-past, future, and the literal bogus 2027=1827642881.
        let good1 = now - 3600, good2 = now - 7200
        let farPast = 1_250_000_000          // < MIN_PLAUSIBLE_UNIX → drop
        let future = now + 30 * 86_400       // > now + FUTURE_MARGIN → drop
        let bogus2027 = 1_827_642_881        // > now + FUTURE_MARGIN → drop
        _ = try await store.insert(Streams(hr: [
            hr(good1, 55), hr(good2, 58),
            hr(farPast, 99), hr(future, 99), hr(bogus2027, 99),
        ]), deviceId: "dev1")

        let result = try await store.healImplausibleTimestamps(now: now, todayLocalDayKey: todayKey)
        XCTAssertEqual(result.rawRowsDeleted, 3, "the 3 garbage HR rows must be purged")
        XCTAssertTrue(result.didChange)

        let survivors = try await store.hrSamples(deviceId: "dev1", from: 0, to: Int.max, limit: 1000)
        XCTAssertEqual(survivors.map(\.ts).sorted(), [good2, good1].sorted())
    }

    /// The instrumentation streams landed AFTER this heal's table list and were never added to it, so a
    /// bad-clock strap's garbage-ts rows survived in them while every sibling stream was cleaned. They are
    /// keyed by the same `ts` from the same type-47 ingest path, so they get the same treatment.
    func testPurgesImplausibleRowsInTheInstrumentationStreamsToo() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        let good = now - 3600
        let farPast = 1_250_000_000
        let future = now + 30 * 86_400
        for ts in [good, farPast, future] {
            _ = try await store.insert(Streams(
                sleepState: [SleepStateSample(ts: ts, state: 2, rawByte: 0x20)],
                ppgWaveform: [PpgWaveformSample(ts: ts, samples: [1, 2, 3])],
                v18Aux: [V18AuxSample(ts: ts, statusWord: 7)]), deviceId: "dev1")
        }
        let before = try await store.v18AuxCountForTest()
        XCTAssertEqual(before, 3)

        _ = try await store.healImplausibleTimestamps(now: now, todayLocalDayKey: todayKey)

        // Only the plausible second survives, in every one of the three streams.
        let band = try await store.sleepStateSamples(deviceId: "dev1", from: 0, to: Int.max)
        let waveforms = try await store.ppgWaveformCountForTest()
        let aux = try await store.v18AuxSamples(deviceId: "dev1", from: 0, to: Int.max)
        XCTAssertEqual(band.map(\.ts), [good])
        XCTAssertEqual(waveforms, 1)
        XCTAssertEqual(aux.map(\.ts), [good])
    }

    func testPurgesFutureAndImplausibleComputedRows() async throws {
        let store = try await WhoopStore.inMemory()
        // dailyMetric rows: a real prior day, a FUTURE day, and an absurd far-past day.
        func day(_ d: String) -> DailyMetric {
            DailyMetric(day: d, totalSleepMin: 721, efficiency: nil, deepMin: nil, remMin: nil,
                        lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                        recovery: 0.5, strain: nil, exerciseCount: nil)
        }
        _ = try await store.upsertDailyMetrics([
            day("2025-06-14"),   // genuine prior day — keep
            day("2025-07-12"),   // FUTURE (> todayKey) — the "12 Jul" carry-over bug — drop
            day("2019-01-01"),   // far-past (< the 2023-11 floor day) — drop
        ], deviceId: "dev1-noop")
        // sleepSession rows keyed by startTs: one real, one future.
        _ = try await store.upsertSleepSessions([
            CachedSleepSession(startTs: now - 30_000, endTs: now - 1000, efficiency: nil,
                               restingHr: nil, avgHrv: nil, stagesJSON: nil),
            CachedSleepSession(startTs: now + 30 * 86_400, endTs: now + 30 * 86_400 + 1000,
                               efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil),
        ], deviceId: "dev1-noop")

        let result = try await store.healImplausibleTimestamps(now: now, todayLocalDayKey: todayKey)
        XCTAssertEqual(result.computedRowsDeleted, 3, "2 bad daily + 1 future sleep session")

        let days = try await store.dailyMetrics(deviceId: "dev1-noop", from: "1900-01-01", to: "2999-12-31")
        XCTAssertEqual(days.map(\.day), ["2025-06-14"], "only the genuine prior day survives")
        let sleeps = try await store.sleepSessions(deviceId: "dev1-noop", from: 0, to: Int.max, limit: 1000)
        XCTAssertEqual(sleeps.count, 1)
        XCTAssertEqual(sleeps[0].startTs, now - 30_000)
    }

    func testImportedHistoryBelowFloorSurvivesButComputedGarbageIsPurged() async throws {
        // The far-past floor must NOT touch IMPORTED rows (bare "my-whoop"): a WHOOP CSV export carries
        // real dates going back years. It STILL purges computed ("...-noop") rows below the floor, which
        // can only be bad-clock garbage. Regression for the import-history purge (v8.2.1).
        let store = try await WhoopStore.inMemory()
        func day(_ d: String) -> DailyMetric {
            DailyMetric(day: d, totalSleepMin: 400, efficiency: nil, deepMin: nil, remMin: nil,
                        lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                        recovery: 0.5, strain: nil, exerciseCount: nil)
        }
        // Imported history (bare device id) years before the 2023-11 floor — must survive.
        _ = try await store.upsertDailyMetrics([day("2018-03-04"), day("2020-11-20")], deviceId: "my-whoop")
        // A computed row below the floor — bad-clock garbage, must be purged.
        _ = try await store.upsertDailyMetrics([day("2019-01-01")], deviceId: "my-whoop-noop")
        let oldImportTs = 1_520_000_000   // 2018-03, below MIN_PLAUSIBLE_UNIX
        _ = try await store.upsertSleepSessions([
            CachedSleepSession(startTs: oldImportTs, endTs: oldImportTs + 20_000, efficiency: nil,
                               restingHr: nil, avgHrv: nil, stagesJSON: nil),
        ], deviceId: "my-whoop")
        _ = try await store.upsertSleepSessions([
            CachedSleepSession(startTs: oldImportTs, endTs: oldImportTs + 20_000, efficiency: nil,
                               restingHr: nil, avgHrv: nil, stagesJSON: nil),
        ], deviceId: "my-whoop-noop")

        let result = try await store.healImplausibleTimestamps(now: now, todayLocalDayKey: todayKey)
        XCTAssertEqual(result.computedRowsDeleted, 2, "only the computed daily + computed sleep below the floor")

        let imported = try await store.dailyMetrics(deviceId: "my-whoop", from: "1900-01-01", to: "2999-12-31")
        XCTAssertEqual(imported.map(\.day).sorted(), ["2018-03-04", "2020-11-20"], "imported history preserved")
        let computed = try await store.dailyMetrics(deviceId: "my-whoop-noop", from: "1900-01-01", to: "2999-12-31")
        XCTAssertTrue(computed.isEmpty, "computed pre-floor garbage purged")
        let importedSleeps = try await store.sleepSessions(deviceId: "my-whoop", from: 0, to: Int.max, limit: 1000)
        XCTAssertEqual(importedSleeps.count, 1, "imported sleep session preserved")
    }

    func testTodayItselfIsKept() async throws {
        // The future-day filter is strict `> todayKey`, so TODAY's own row (== todayKey) survives.
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertDailyMetrics([
            DailyMetric(day: todayKey, totalSleepMin: 400, efficiency: nil, deepMin: nil, remMin: nil,
                        lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                        recovery: 0.6, strain: nil, exerciseCount: nil),
        ], deviceId: "dev1-noop")
        let result = try await store.healImplausibleTimestamps(now: now, todayLocalDayKey: todayKey)
        XCTAssertEqual(result.computedRowsDeleted, 0)
        let days = try await store.dailyMetrics(deviceId: "dev1-noop", from: "1900-01-01", to: "2999-12-31")
        XCTAssertEqual(days.map(\.day), [todayKey])
    }

    func testHealIsIdempotentOnCleanDB() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(Streams(hr: [hr(now - 100, 60), hr(now - 200, 61)]), deviceId: "dev1")
        // First pass: nothing implausible → no change.
        let r1 = try await store.healImplausibleTimestamps(now: now, todayLocalDayKey: todayKey)
        XCTAssertFalse(r1.didChange)
        XCTAssertEqual(r1.rawRowsDeleted, 0)
        // Re-running is harmless and still a no-op.
        let r2 = try await store.healImplausibleTimestamps(now: now, todayLocalDayKey: todayKey)
        XCTAssertFalse(r2.didChange)
        let survivors = try await store.hrSamples(deviceId: "dev1", from: 0, to: Int.max, limit: 1000)
        XCTAssertEqual(survivors.count, 2, "good rows untouched across repeated heals")
    }

    func testBoundaryRowsExactlyOnEdgesAreKept() async throws {
        let store = try await WhoopStore.inMemory()
        let floor = MIN_PLAUSIBLE_UNIX            // exactly the floor — keep
        let ceiling = now + FUTURE_MARGIN          // exactly the ceiling — keep
        _ = try await store.insert(Streams(hr: [
            hr(floor, 50), hr(ceiling, 51),
            hr(floor - 1, 99), hr(ceiling + 1, 99),   // just outside — drop both
        ]), deviceId: "dev1")
        let result = try await store.healImplausibleTimestamps(now: now, todayLocalDayKey: todayKey)
        XCTAssertEqual(result.rawRowsDeleted, 2)
        let survivors = try await store.hrSamples(deviceId: "dev1", from: 0, to: Int.max, limit: 1000)
        XCTAssertEqual(survivors.map(\.ts).sorted(), [floor, ceiling])
    }
}
