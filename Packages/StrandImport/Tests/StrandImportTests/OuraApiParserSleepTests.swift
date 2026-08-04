import XCTest
@testable import StrandImport

final class OuraApiParserSleepTests: XCTestCase {
    func testParsesPeriodWithHypnogramAndFoldsDay() throws {
        let docs: [[String: Any]] = [[
            "id": "s1", "day": "2026-01-02",
            "bedtime_start": "2026-01-01T23:00:00+00:00",
            "bedtime_end": "2026-01-02T06:00:00+00:00",
            "total_sleep_duration": 24000, "deep_sleep_duration": 6000,
            "light_sleep_duration": 12000, "rem_sleep_duration": 6000, "awake_time": 1200,
            "efficiency": 92, "average_heart_rate": 55, "lowest_heart_rate": 48,
            "average_hrv": 65, "average_breath": 14.2,
            "sleep_phase_5_min": "1234",
            "movement_30_sec": "1212",
            "heart_rate": ["interval": 300, "timestamp": "2026-01-01T23:00:00+00:00",
                           "items": [60, 58, NSNull(), 57]]
        ]]
        let (periods, days) = OuraApiParser.parseSleep(docs)
        XCTAssertEqual(periods.count, 1)
        let p = try XCTUnwrap(periods.first)
        XCTAssertEqual(p.session.totalSleepMin, 400)              // 24000s ÷ 60
        XCTAssertEqual(p.session.lowestHr, 48)
        XCTAssertEqual(p.session.avgHrvMs, 65)
        XCTAssertEqual(p.session.stages.map(\.stage), ["deep", "light", "rem", "wake"])
        XCTAssertEqual(p.movement30s, [1, 2, 1, 2])
        XCTAssertEqual(p.hr.map(\.bpm), [60, 58, 57])            // null sample dropped
        // ts = bedtime_start epoch + i*interval, using the ORIGINAL items index (the null at i=2 is
        // skipped, so the 3rd kept sample is i=3, i.e. epoch + 900, not epoch + 600).
        let bedtimeStart = try XCTUnwrap(WhoopTime.parseISOWithOffset("2026-01-01T23:00:00+00:00"))
        let ts0 = Int(bedtimeStart.timeIntervalSince1970)
        XCTAssertEqual(p.hr.map(\.ts), [ts0, ts0 + 300, ts0 + 900])
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.day, "2026-01-02")
        XCTAssertEqual(days.first?.totalSleepMin, 400)
        XCTAssertEqual(days.first?.restingHr, 48)                // lowestHr ≈ resting fallback
        XCTAssertEqual(days.first?.respRateBpm, 14.2)            // average_breath folded onto the day rollup
    }

    func testSkipsPeriodWithInvalidSpan() {
        let (periods, _) = OuraApiParser.parseSleep([["bedtime_start": "nope", "bedtime_end": "nope"]])
        XCTAssertTrue(periods.isEmpty)
    }

    func testSkipsDeletedPeriodEntirely() throws {
        // A user-removed night (`type == "deleted"`) must neither become a session nor compete for
        // the day's rollup — same rule as OuraExportParser's CSV side (#862). The deleted doc here
        // would otherwise WIN the day on duration.
        let docs: [[String: Any]] = [
            ["id": "dead", "day": "2026-01-02", "type": "deleted",
             "bedtime_start": "2026-01-01T22:00:00+00:00",
             "bedtime_end": "2026-01-02T07:00:00+00:00",
             "total_sleep_duration": 30000, "lowest_heart_rate": 44, "efficiency": 95],
            ["id": "real", "day": "2026-01-02", "type": "long_sleep",
             "bedtime_start": "2026-01-02T00:00:00+00:00",
             "bedtime_end": "2026-01-02T06:00:00+00:00",
             "total_sleep_duration": 19800, "lowest_heart_rate": 50, "efficiency": 90],
        ]
        let (periods, days) = OuraApiParser.parseSleep(docs)
        XCTAssertEqual(periods.count, 1)
        XCTAssertEqual(try XCTUnwrap(periods.first).session.lowestHr, 50)
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.totalSleepMin, 330)             // 19800s ÷ 60, from the real night
        XCTAssertEqual(days.first?.restingHr, 50)
    }

    func testSampleSeriesSkipsFiniteButHugeValuesWithoutCrashing() throws {
        // Both `ts` and `bpm` in sampleSeries are Double->Int casts; a finite-but-huge value for EITHER
        // (a crafted `interval` or a crafted `items` element) must be skipped, never trap Int(...).

        // A huge `interval` blows the 2nd sample's ts (t0 + 1*interval) past Int range; the 1st sample's
        // ts (t0 + 0*interval == t0) stays in range and must still be kept.
        let hugeIntervalDocs: [[String: Any]] = [[
            "day": "2026-01-02",
            "bedtime_start": "2026-01-01T23:00:00+00:00",
            "bedtime_end": "2026-01-02T06:00:00+00:00",
            "heart_rate": ["interval": 1e300, "timestamp": "2026-01-01T23:00:00+00:00",
                           "items": [60, 58]]
        ]]
        let (hugeIntervalPeriods, _) = OuraApiParser.parseSleep(hugeIntervalDocs)
        let hugeIntervalPeriod = try XCTUnwrap(hugeIntervalPeriods.first)
        XCTAssertEqual(hugeIntervalPeriod.hr.map(\.bpm), [60])

        // A huge `items` element (bpm itself) must be skipped even with a perfectly normal interval/ts.
        let hugeItemDocs: [[String: Any]] = [[
            "day": "2026-01-02",
            "bedtime_start": "2026-01-01T23:00:00+00:00",
            "bedtime_end": "2026-01-02T06:00:00+00:00",
            "heart_rate": ["interval": 300, "timestamp": "2026-01-01T23:00:00+00:00",
                           "items": [60, 1e300, 58]]
        ]]
        let (hugeItemPeriods, _) = OuraApiParser.parseSleep(hugeItemDocs)
        let hugeItemPeriod = try XCTUnwrap(hugeItemPeriods.first)
        XCTAssertEqual(hugeItemPeriod.hr.map(\.bpm), [60, 58])
    }

    // MARK: - Daily rollup main-session selection (audit: first-write-wins let a nap/fragment beat the
    // real night on 36 real days, incl. two 90+ bpm daily restingHr spikes from a wake-dominated micro-
    // session). The rollup must pick the `long_sleep` session regardless of doc order, never mix fields
    // from two different sessions, and still fall back honestly when no long_sleep exists that day.

    func testDailyRollupPrefersLongSleepOverEarlierFragment() throws {
        // A 2-min fragment is listed BEFORE the real night's long_sleep session, same day. First-write-wins
        // would let the fragment's near-zero duration and its own (spiked) restingHr win the day.
        let docs: [[String: Any]] = [
            [
                "day": "2026-02-01", "type": "short_sleep",
                "bedtime_start": "2026-02-01T04:00:00+00:00",
                "bedtime_end": "2026-02-01T04:02:00+00:00",
                "total_sleep_duration": 120, "lowest_heart_rate": 92,
            ],
            [
                "day": "2026-02-01", "type": "long_sleep",
                "bedtime_start": "2026-01-31T23:00:00+00:00",
                "bedtime_end": "2026-02-01T07:00:00+00:00",
                "total_sleep_duration": 27_000, "lowest_heart_rate": 57,
            ],
        ]
        let (periods, days) = OuraApiParser.parseSleep(docs)
        XCTAssertEqual(periods.count, 2)          // both sessions still show up as Sleep-tab periods
        XCTAssertEqual(days.count, 1)
        let day = try XCTUnwrap(days.first)
        XCTAssertEqual(day.totalSleepMin, 450)    // 27000s ÷ 60 — the long_sleep's duration, not the fragment's
        XCTAssertEqual(day.restingHr, 57)         // the long_sleep's lowestHr, not the fragment's 92
    }

    func testDailyRollupPrefersLongSleepRegardlessOfOrder() throws {
        // Same fixture, long_sleep listed FIRST — the fix must not depend on doc order either way.
        let docs: [[String: Any]] = [
            [
                "day": "2026-02-01", "type": "long_sleep",
                "bedtime_start": "2026-01-31T23:00:00+00:00",
                "bedtime_end": "2026-02-01T07:00:00+00:00",
                "total_sleep_duration": 27_000, "lowest_heart_rate": 57,
            ],
            [
                "day": "2026-02-01", "type": "short_sleep",
                "bedtime_start": "2026-02-01T04:00:00+00:00",
                "bedtime_end": "2026-02-01T04:02:00+00:00",
                "total_sleep_duration": 120, "lowest_heart_rate": 92,
            ],
        ]
        let (_, days) = OuraApiParser.parseSleep(docs)
        let day = try XCTUnwrap(days.first)
        XCTAssertEqual(day.totalSleepMin, 450)
        XCTAssertEqual(day.restingHr, 57)
    }

    func testDailyRollupKeepsFragmentValuesWhenNoLongSleepThatDay() throws {
        // A fragment-only day (a nap with no main night recorded) keeps the fragment's own values —
        // honest, not zeroed or dropped.
        let docs: [[String: Any]] = [[
            "day": "2026-02-02", "type": "short_sleep",
            "bedtime_start": "2026-02-02T13:00:00+00:00",
            "bedtime_end": "2026-02-02T13:20:00+00:00",
            "total_sleep_duration": 900, "lowest_heart_rate": 64,
        ]]
        let (_, days) = OuraApiParser.parseSleep(docs)
        let day = try XCTUnwrap(days.first)
        XCTAssertEqual(day.totalSleepMin, 15)     // 900s ÷ 60 — the only session that day
        XCTAssertEqual(day.restingHr, 64)
    }

    func testDailyRollupPicksLongerOfTwoLongSleeps() throws {
        // Equal rank (both long_sleep) → the longer total_sleep_duration wins, not doc order.
        let docs: [[String: Any]] = [
            [
                "day": "2026-02-03", "type": "long_sleep",
                "bedtime_start": "2026-02-02T22:00:00+00:00",
                "bedtime_end": "2026-02-03T02:00:00+00:00",
                "total_sleep_duration": 12_000, "lowest_heart_rate": 60,
            ],
            [
                "day": "2026-02-03", "type": "long_sleep",
                "bedtime_start": "2026-02-03T03:00:00+00:00",
                "bedtime_end": "2026-02-03T07:00:00+00:00",
                "total_sleep_duration": 13_000, "lowest_heart_rate": 55,
            ],
        ]
        let (_, days) = OuraApiParser.parseSleep(docs)
        let day = try XCTUnwrap(days.first)
        XCTAssertEqual(day.totalSleepMin, 13_000 / 60.0)
        XCTAssertEqual(day.restingHr, 55)
    }

    /// Oura's `efficiency` is a 0-100 integer percent. NOOP's own sleep pipeline stores
    /// sleepSession.efficiency / dailyMetric.efficiency as a 0-1 FRACTION everywhere else it's
    /// written (StrandAnalytics: asleep ÷ in-bed), so the importer must normalize at the parse
    /// boundary rather than passing Oura's native percent straight through — both the individual
    /// session and the day rollup it folds onto.
    func testEfficiencyIsNormalizedToZeroToOneFraction() throws {
        let docs: [[String: Any]] = [[
            "day": "2026-03-01",
            "bedtime_start": "2026-02-28T23:00:00+00:00",
            "bedtime_end": "2026-03-01T07:00:00+00:00",
            "total_sleep_duration": 27_000, "efficiency": 92,
        ]]
        let (periods, days) = OuraApiParser.parseSleep(docs)
        let p = try XCTUnwrap(periods.first)
        XCTAssertEqual(p.session.efficiencyPct, 0.92)
        XCTAssertEqual(days.first?.efficiencyPct, 0.92)
    }
}
