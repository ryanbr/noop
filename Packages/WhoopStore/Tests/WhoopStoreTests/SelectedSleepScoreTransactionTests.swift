import XCTest
@testable import WhoopStore

final class SelectedSleepScoreTransactionTests: XCTestCase {
    private let source = "my-whoop-noop"
    private let day = "2021-06-15"

    private func sleep(_ start: Int, _ end: Int, edited: Bool = false) -> CachedSleepSession {
        CachedSleepSession(startTs: start, endTs: end, efficiency: 0.9, restingHr: 50, avgHrv: 60,
            stagesJSON: "[{\"start\":\(start),\"end\":\(end),\"stage\":\"deep\"}]", userEdited: edited)
    }

    private func daily(_ recovery: Double) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: 420, efficiency: 0.9, deepMin: 420, remMin: 0, lightMin: 0,
            disturbances: 0, restingHr: 50, avgHrv: 60, recovery: recovery, strain: 10, exerciseCount: 0)
    }

    private func commit(_ store: WhoopStore, sleeps: [CachedSleepSession], recovery: Double = 70) async throws {
        try await store.persistComputedScores(dailyMetrics: [daily(recovery)],
            metricPoints: [.init(day: day, key: "sleep_performance", value: 80)],
            provenance: [.init(day: day, key: "recovery", sourceId: "active-strap")],
            deviceId: source, from: day, to: day, sleepSessions: sleeps)
    }

    func testMissingOldNightBanksWithScoresAndPreservesOtherSourcesAndRows() async throws {
        let store = try await WhoopStore.inMemory()
        let selected = sleep(1_623_711_600, 1_623_736_800)
        let neighboring = sleep(selected.startTs - 86400, selected.endTs - 86400)
        let manual = sleep(selected.endTs + 3600, selected.endTs + 7200, edited: true)
        _ = try await store.upsertSleepSessions([neighboring, manual], deviceId: source)
        _ = try await store.upsertSleepSessions([selected], deviceId: "my-whoop")
        let before = try await store.sleepSessions(deviceId: source, from: 0, to: 2_000_000_000, limit: 100)
        let imported = try await store.sleepSessions(deviceId: "my-whoop", from: 0, to: 2_000_000_000, limit: 100)
        try await commit(store, sleeps: [selected])
        let after = try await store.sleepSessions(deviceId: source, from: 0, to: 2_000_000_000, limit: 100)
        XCTAssertEqual(after.filter { $0.startTs != selected.startTs }, before)
        let afterImported = try await store.sleepSessions(deviceId: "my-whoop", from: 0, to: 2_000_000_000, limit: 100)
        XCTAssertEqual(afterImported, imported)
        XCTAssertEqual(after.first { $0.startTs == selected.startTs }?.endTs, selected.endTs)
        let scores = try await store.dailyMetrics(deviceId: source, from: day, to: day)
        let provenance = try await store.scoreInputSource(deviceId: source, day: day, key: "recovery")
        XCTAssertEqual(scores.first?.totalSleepMin, 420)
        XCTAssertEqual(provenance, "active-strap")
    }

    func testIncompleteDetectedNightRefreshesWithoutChangingStableKey() async throws {
        let store = try await WhoopStore.inMemory()
        let complete = sleep(1_623_711_600, 1_623_736_800)
        _ = try await store.upsertSleepSessions([sleep(complete.startTs, complete.startTs + 5400)], deviceId: source)
        try await commit(store, sleeps: [complete])
        let rows = try await store.sleepSessions(deviceId: source, from: 0, to: 2_000_000_000, limit: 100)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.endTs, complete.endTs)
        XCTAssertEqual(rows.first?.stagesJSON, complete.stagesJSON)
    }

    func testFailedDailyWriteRollsBackSleepAndProvenanceTogether() async throws {
        let store = try await WhoopStore.inMemory()
        try await commit(store, sleeps: [], recovery: 10)
        try await store.syncWrite { db in
            try db.execute(sql: """
                CREATE TRIGGER refuse_selected_day BEFORE INSERT ON dailyMetric
                WHEN NEW.day = '2021-06-15' BEGIN SELECT RAISE(ABORT, 'test write failure'); END
                """)
        }
        do { try await commit(store, sleeps: [sleep(1_623_711_600, 1_623_736_800)], recovery: 70); XCTFail("write must fail") }
        catch { }
        let rows = try await store.sleepSessions(deviceId: source, from: 0, to: 2_000_000_000, limit: 100)
        let scores = try await store.dailyMetrics(deviceId: source, from: day, to: day)
        let provenance = try await store.scoreInputSource(deviceId: source, day: day, key: "recovery")
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(scores.first?.recovery, 10)
        XCTAssertEqual(provenance, "active-strap")
    }

    func testSelectedCleanupRejectsImportedDeviceAndRollsBackWrites() async throws {
        let store = try await WhoopStore.inMemory()
        let imported = "my-whoop"
        let old = sleep(1_623_711_540, 1_623_733_200)
        let fresh = sleep(1_623_711_600, 1_623_736_800)
        _ = try await store.upsertSleepSessions([old], deviceId: imported)
        try await store.persistComputedScores(dailyMetrics: [daily(10)],
            metricPoints: [.init(day: day, key: "sleep_performance", value: 20)],
            provenance: [.init(day: day, key: "recovery", sourceId: "original-source")],
            deviceId: imported, from: day, to: day)
        do {
            try await store.persistComputedScores(dailyMetrics: [daily(70)],
                metricPoints: [.init(day: day, key: "sleep_performance", value: 80)],
                provenance: [.init(day: day, key: "recovery", sourceId: "replacement-source")],
                deviceId: imported, from: day, to: day, sleepSessions: [fresh],
                selectedSleepBounds: 1_623_715_200...1_623_801_599)
            XCTFail("selected cleanup must reject an imported device")
        } catch {
            XCTAssertEqual((error as NSError).domain, "WhoopStore.selectedSleepScope")
            XCTAssertEqual((error as NSError).code, 2)
        }
        let rows = try await store.sleepSessions(deviceId: imported, from: 0, to: 2_000_000_000, limit: 100)
        let scores = try await store.dailyMetrics(deviceId: imported, from: day, to: day)
        let points = try await store.metricSeries(deviceId: imported, key: "sleep_performance", from: day, to: day)
        let provenance = try await store.scoreInputSource(deviceId: imported, day: day, key: "recovery")
        XCTAssertEqual(rows.map(\.startTs), [old.startTs])
        XCTAssertEqual(scores.first?.recovery, 10)
        XCTAssertEqual(points.first?.value, 20)
        XCTAssertEqual(provenance, "original-source")
    }

    func testCancelledSelectedWriteBanksNothing() async throws {
        let store = try await WhoopStore.inMemory()
        var finish: AsyncStream<Void>.Continuation!
        let gate = AsyncStream<Void> { finish = $0 }
        let task = Task {
            for await _ in gate { }
            try await commit(store, sleeps: [sleep(1_623_711_600, 1_623_736_800)])
        }
        task.cancel()
        finish.finish()
        do { try await task.value; XCTFail("cancellation must propagate") }
        catch is CancellationError { }
        let rows = try await store.sleepSessions(deviceId: source, from: 0, to: 2_000_000_000, limit: 100)
        let scores = try await store.dailyMetrics(deviceId: source, from: day, to: day)
        XCTAssertTrue(rows.isEmpty)
        XCTAssertTrue(scores.isEmpty)
    }
    func testDependentUpdatePreservesOtherFieldsAndCommitsProvenanceAtomically() async throws {
        let store = try await WhoopStore.inMemory()
        let next = "2021-06-16"
        let neighbor = DailyMetric(day: next, totalSleepMin: 360, efficiency: 0.8, deepMin: 90,
            remMin: 90, lightMin: 180, disturbances: 2, restingHr: 55, avgHrv: 40,
            recovery: 10, strain: 8, exerciseCount: 1)
        _ = try await store.upsertDailyMetrics([neighbor], deviceId: source)
        try await store.persistComputedScores(dailyMetrics: [daily(70)], metricPoints: [], provenance: [],
            deviceId: source, from: day, to: day, sleepSessions: [sleep(1_623_711_600, 1_623_736_800)],
            dependentRecoveryUpdates: [.init(day: next, recovery: 60, skinTempDevC: 0.2, sourceId: "active-strap")])
        let after = try await store.dailyMetrics(deviceId: source, from: next, to: next)
        XCTAssertEqual(after.first?.totalSleepMin, neighbor.totalSleepMin)
        XCTAssertEqual(after.first?.strain, neighbor.strain)
        XCTAssertEqual(after.first?.recovery, 60)
        let provenance = try await store.scoreInputSource(deviceId: source, day: next, key: "recovery")
        XCTAssertEqual(provenance, "active-strap")
        try await store.syncWrite { db in
            try db.execute(sql: "CREATE TRIGGER refuse_dependent BEFORE UPDATE ON dailyMetric WHEN NEW.day = '2021-06-16' BEGIN SELECT RAISE(ABORT, 'dependent failure'); END")
        }
        do {
            try await store.persistComputedScores(dailyMetrics: [daily(90)], metricPoints: [], provenance: [],
                deviceId: source, from: day, to: day, sleepSessions: [sleep(1_623_711_600, 1_623_740_400)],
                dependentRecoveryUpdates: [.init(day: next, recovery: nil, skinTempDevC: nil)])
            XCTFail("dependent failure must roll back selected day and sleep")
        } catch { }
        let primary = try await store.dailyMetrics(deviceId: source, from: day, to: day)
        let sleeps = try await store.sleepSessions(deviceId: source, from: 0, to: 2_000_000_000, limit: 100)
        XCTAssertEqual(primary.first?.recovery, 70)
        XCTAssertEqual(sleeps.first?.endTs, 1_623_736_800)
    }

    func testDetailsAndShiftedDuplicateCleanupCommitTogether() async throws {
        let store = try await WhoopStore.inMemory()
        let fresh = sleep(1_623_711_600, 1_623_736_800)
        let old = sleep(fresh.startTs - 60, fresh.endTs - 3600)
        let neighbor = sleep(fresh.startTs - 86400, fresh.endTs - 86400)
        _ = try await store.upsertSleepSessions([old, neighbor], deviceId: source)
        func write() async throws {
            try await store.persistComputedScores(dailyMetrics: [daily(70)], metricPoints: [], provenance: [],
                deviceId: source, from: day, to: day, sleepSessions: [fresh],
                sleepMotion: [fresh.startTs: [0.1, 0.2]], sleepStates: [fresh.startTs: [1, 2]],
                selectedSleepBounds: 1_623_715_200...1_623_801_599)
        }
        try await store.syncWrite { db in
            try db.execute(sql: "CREATE TRIGGER refuse_details BEFORE UPDATE OF motionJSON ON sleepSession BEGIN SELECT RAISE(ABORT, 'detail failure'); END")
        }
        do { try await write(); XCTFail("detail failure must roll back selected sleep and day") } catch { }
        let before = try await store.sleepSessions(deviceId: source, from: 0, to: 2_000_000_000, limit: 100)
        XCTAssertEqual(Set(before.map(\.startTs)), Set([old.startTs, neighbor.startTs]))
        let dailyBefore = try await store.dailyMetrics(deviceId: source, from: day, to: day)
        XCTAssertTrue(dailyBefore.isEmpty)
        try await store.syncWrite { db in try db.execute(sql: "DROP TRIGGER refuse_details") }
        try await write()
        let after = try await store.sleepSessions(deviceId: source, from: 0, to: 2_000_000_000, limit: 100)
        XCTAssertEqual(Set(after.map(\.startTs)), Set([fresh.startTs, neighbor.startTs]))
        let motion = try await store.sessionMotion(deviceId: source, sessionStart: fresh.startTs)
        let states = try await store.sessionSleepState(deviceId: source, sessionStart: fresh.startTs)
        XCTAssertEqual(motion, [0.1, 0.2]); XCTAssertEqual(states, [1, 2])
    }

    func testSelectedWriteDoesNotBankNeighboringContextMarkersOrTags() async throws {
        let store = try await WhoopStore.inMemory()
        let prior = "2021-06-14"
        let key = "day_cycle_onset_ts"
        let neighbor = MetricPoint(day: prior, key: key, value: 123)
        try await store.persistMetricSeriesWithProvenance(points: [neighbor],
            provenance: [.init(day: prior, key: key, sourceId: "prior-source")], deviceId: source)
        try await store.persistComputedScores(dailyMetrics: [daily(70)],
            metricPoints: [.init(day: prior, key: key, value: 999), .init(day: day, key: key, value: 456)],
            provenance: [.init(day: prior, key: key, sourceId: "wrong-source")],
            deviceId: source, from: day, to: day, replaceMetricKeys: [key],
            additionalMetricPoints: [.init(deviceId: source, point: .init(day: prior, key: key, value: 777))], sleepSessions: [],
            selectedSleepBounds: 1_623_715_200...1_623_801_599)
        let rows = try await store.metricSeries(deviceId: source, key: key, from: prior, to: prior)
        let tag = try await store.scoreInputSource(deviceId: source, day: prior, key: key)
        XCTAssertEqual(rows.first?.value, 123); XCTAssertEqual(tag, "prior-source")
    }

}
