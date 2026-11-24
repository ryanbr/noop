import XCTest
import Foundation
import WhoopStore
import StrandAnalytics
@testable import Strand

/// The Insights "Rest" outcome covers strap-only nights. Both Insights screens read the imported
/// `sleep_performance` series alone, so a Bluetooth-only wearer had no Rest effects, no Rest ↔ Charge
/// relationship and no Rest experiments, while Today and Trends showed a Rest score for the same nights.
/// Same fixture shape as the Kotlin `InsightsRestOutcomeTest`.
final class InsightsRestOutcomeTests: XCTestCase {

    private let canonical = "my-whoop"
    private let restKey = "sleep_performance"

    private func dayKey(_ daysAgo: Int) -> String {
        Repository.localDayKey(Date().addingTimeInterval(-Double(daysAgo) * 86_400))
    }

    private func daily(_ day: String, totalSleepMin: Double? = 450, efficiency: Double? = 0.92) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: totalSleepMin, efficiency: efficiency, deepMin: 90, remMin: 110,
                    lightMin: 250, disturbances: 2, restingHr: 52, avgHrv: 70, recovery: 60, strain: 8,
                    exerciseCount: 0)
    }

    @MainActor
    private func repository(active: String, store: WhoopStore) async -> Repository {
        let repo = Repository(deviceId: canonical)
        repo.setStoreForTesting(store)
        if active != canonical { repo.adoptActiveDeviceId(active) }
        await repo.refresh()
        return repo
    }

    /// Mixed history after a strap re-add: the import wins its night, a strap-only night resolves under the
    /// ACTIVE strap's computed sibling, a night with totals but no series point derives its composite, and a
    /// night with no sleep has no Rest rather than something else in its place.
    @MainActor
    func testMixedImportedAndStrapOnlyNightsAllHaveRest() async throws {
        let strap = "whoop-ABC123"
        let (imported, computed, derived, noSleep) = (dayKey(5), dayKey(4), dayKey(3), dayKey(2))
        let store = try await WhoopStore.inMemory()
        for id in [canonical, strap] { try await store.upsertDevice(id: id, mac: nil, name: "WHOOP") }

        try await store.upsertMetricSeries([MetricPoint(day: imported, key: restKey, value: 83)],
                                           deviceId: canonical)
        try await store.upsertMetricSeries([MetricPoint(day: imported, key: restKey, value: 70),
                                            MetricPoint(day: computed, key: restKey, value: 77)],
                                           deviceId: strap + "-noop")
        _ = try await store.upsertDailyMetrics([daily(imported)], deviceId: canonical)
        _ = try await store.upsertDailyMetrics(
            [daily(computed), daily(derived), daily(noSleep, totalSleepMin: nil, efficiency: nil)],
            deviceId: strap + "-noop")

        let repo = await repository(active: strap, store: store)
        let rest = await repo.insightsOutcomeDays(key: restKey, mergedDays: repo.days)

        let expectedDerived = try XCTUnwrap(AnalyticsEngine.Rest.composite(daily: daily(derived)))
        XCTAssertGreaterThan(expectedDerived, 1.5, "the derived Rest is on the 0–100 scale")
        XCTAssertEqual(rest, [imported: 83, computed: 77, derived: expectedDerived])
    }

    /// The other three outcomes keep their contract: imported series first, merged column for the rest.
    @MainActor
    func testOtherOutcomesAreUnchanged() async throws {
        let (seriesDay, columnDay) = (dayKey(4), dayKey(3))
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: canonical, mac: nil, name: "WHOOP")
        try await store.upsertMetricSeries([MetricPoint(day: seriesDay, key: "recovery", value: 88),
                                            MetricPoint(day: seriesDay, key: "hrv", value: 95),
                                            MetricPoint(day: seriesDay, key: "rhr", value: 47)],
                                           deviceId: canonical)
        _ = try await store.upsertDailyMetrics([daily(columnDay)], deviceId: canonical + "-noop")

        let repo = await repository(active: canonical, store: store)
        let recovery = await repo.insightsOutcomeDays(key: "recovery", mergedDays: repo.days)
        let hrv = await repo.insightsOutcomeDays(key: "hrv", mergedDays: repo.days)
        let rhr = await repo.insightsOutcomeDays(key: "rhr", mergedDays: repo.days)
        XCTAssertEqual(recovery, [seriesDay: 88, columnDay: 60])
        XCTAssertEqual(hrv, [seriesDay: 95, columnDay: 70])
        XCTAssertEqual(rhr, [seriesDay: 47, columnDay: 52])
    }

    /// End to end through the Hub for a strap-only wearer: a journal with no import behind it ranks a Rest
    /// effect, and the two group means are Rest points.
    @MainActor
    func testStrapOnlyJournalRanksARestEffect() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: canonical, mac: nil, name: "WHOOP")

        // Irregular yes days, so lag 0 is the best lag on its own; Rest sits 20 points lower on them (± 1 so
        // the two groups have variance). Same layout as the Kotlin test.
        let yesDays: Set<Int> = [1, 4, 5, 8, 11, 12, 13, 17, 18, 20]
        var points: [MetricPoint] = [], journal: [JournalEntry] = [], days: [DailyMetric] = []
        var yesCount = 0, noCount = 0
        for n in 1...20 {
            let key = dayKey(30 - n)
            let yes = yesDays.contains(n)
            let index = yes ? yesCount : noCount
            if yes { yesCount += 1 } else { noCount += 1 }
            points.append(MetricPoint(day: key, key: restKey,
                                      value: (yes ? 60 : 80) + (index % 2 == 0 ? 1 : -1)))
            journal.append(JournalEntry(day: key, question: "Alcohol", answeredYes: yes, notes: nil))
            days.append(daily(key))
        }
        try await store.upsertMetricSeries(points, deviceId: canonical + "-noop")
        _ = try await store.upsertDailyMetrics(days, deviceId: canonical + "-noop")
        _ = try await store.upsertJournal(journal, deviceId: Repository.journalDeviceId)

        let repo = await repository(active: canonical, store: store)
        let hub = InsightsHubViewModel()
        await hub.load(repo: repo)
        hub.rankFor(.sleep)

        XCTAssertEqual(hub.ranked.count, 1, "a strap-only journal must rank a Rest effect")
        let effect = try XCTUnwrap(hub.ranked.first).effect
        XCTAssertEqual(effect.meanWith, 60, accuracy: 1e-9)
        XCTAssertEqual(effect.meanWithout, 80, accuracy: 1e-9)
    }

    /// The Insights snapshot is reused until `refreshSeq` moves (#833), so it is only correct if a Rest
    /// change moves it. The engine derives Rest from the daily row it persists beside it, so a re-scored
    /// night changes the row; pin that the row change is what invalidates the snapshot.
    @MainActor
    func testARescoredNightInvalidatesTheInsightsSnapshot() async throws {
        let night = dayKey(2)
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: canonical, mac: nil, name: "WHOOP")
        let first = daily(night)
        _ = try await store.upsertDailyMetrics([first], deviceId: canonical + "-noop")

        let repo = await repository(active: canonical, store: store)
        let seq = repo.refreshSeq
        let before = await repo.insightsOutcomeDays(key: restKey, mergedDays: repo.days)
        XCTAssertEqual(before[night], AnalyticsEngine.Rest.composite(daily: first))

        let rescored = daily(night, totalSleepMin: 360)
        _ = try await store.upsertDailyMetrics([rescored], deviceId: canonical + "-noop")
        await repo.refresh()

        XCTAssertGreaterThan(repo.refreshSeq, seq, "a re-scored night must drop the cached Insights snapshot")
        let after = await repo.insightsOutcomeDays(key: restKey, mergedDays: repo.days)
        XCTAssertEqual(after[night], AnalyticsEngine.Rest.composite(daily: rescored))
        XCTAssertNotEqual(after[night], before[night])
    }

    /// InsightsView's load is private to the view, so its half is checked as source: both screens load their
    /// outcomes through the one shared read, and neither keeps an imported-only read beside it.
    func testBothInsightsScreensLoadThroughTheSharedRead() throws {
        let screens = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Strand/Screens")
        for name in ["InsightsView.swift", "InsightsHubView.swift"] {
            let source = try String(contentsOf: screens.appendingPathComponent(name), encoding: .utf8)
            XCTAssertEqual(source.components(separatedBy: "insightsOutcomeDays(key: key, mergedDays: mergedDays)").count - 1,
                           1, "\(name) must load its outcomes through insightsOutcomeDays")
            XCTAssertFalse(source.contains("series(key: key, source: \"my-whoop\")"),
                           "\(name) must not read an outcome from the imported series alone")
        }
    }
}
