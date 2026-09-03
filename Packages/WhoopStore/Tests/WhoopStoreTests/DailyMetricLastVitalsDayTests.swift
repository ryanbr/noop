import XCTest
@testable import WhoopStore

/// The recovery-INDEPENDENT overnight-vitals carry behind the v8 Today rollover fix. After the 04:00
/// logical-day rollover, before tonight's sleep is scored, today's row has no HRV / resting-HR /
/// respiratory yet, so the recovery-vitals read-outs must fall back to the last night that recorded them
/// instead of rendering "–". Unlike the whole-row Charge carry (`Repository.widgetAnchor` /
/// `TodayView.lastScoredRecoveryDay`), this selector does NOT gate on the prior night's recovery — a night
/// with real HRV/RHR but a null recovery is a valid vitals source. It only supplies the FALLBACK; the call
/// sites read each vital today-first, so today's own value always wins and the selector never overrides it.
final class DailyMetricLastVitalsDayTests: XCTestCase {

    /// A day row with optional recovery + vitals — mirrors the classic carry-over test's helper.
    private func day(_ key: String, recovery: Double? = nil,
                     hrv: Double? = nil, rhr: Int? = nil, resp: Double? = nil) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: recovery,
                    strain: nil, exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil, respRateBpm: resp)
    }

    // MARK: everyday rollover

    func testCarriesYesterdaysVitals_whenTodayHasNoneYet() {
        // The post-04:00 state: yesterday scored with vitals, today's row exists but is empty. The carry
        // must return yesterday so HRV/RHR/Resp keep reading instead of blanking to "–".
        let days = [day("2026-06-17", recovery: 60, hrv: 50, rhr: 54, resp: 14.0),
                    day("2026-06-18", recovery: 72, hrv: 58, rhr: 51, resp: 13.5),
                    day("2026-06-19")]   // today, no vitals yet
        let carried = DailyMetric.lastVitalsDay(days: days, todayKey: "2026-06-19")
        XCTAssertEqual(carried?.day, "2026-06-18", "must carry the freshest prior day that has vitals")
        XCTAssertEqual(carried?.avgHrv, 58)
        XCTAssertEqual(carried?.restingHr, 51)
        XCTAssertEqual(carried?.respRateBpm, 13.5)
    }

    // MARK: recovery-INDEPENDENT — the sub-case the whole-row Charge carry got wrong

    func testCarriesLastNightsOwnVitals_evenWhenItsRecoveryIsNull() {
        // Last night recorded real HRV/RHR but its recovery came back null (BLE-only night, or scoring not
        // finished). The whole-row `lastScoredRecoveryDay` carry (gated on `recovery != nil`) would SKIP it
        // and reach back to the older scored day; this recovery-independent selector keeps last night's own
        // values. Combined with the call site's per-field today-first read, last night wins over the older
        // day — never the reverse.
        let days = [day("2026-06-16", recovery: 65, hrv: 44, rhr: 60, resp: 15.0),   // older, scored
                    day("2026-06-18", recovery: nil, hrv: 59, rhr: 50, resp: 13.2),  // last night: vitals, null recovery
                    day("2026-06-19")]   // today, no vitals yet
        let carried = DailyMetric.lastVitalsDay(days: days, todayKey: "2026-06-19")
        XCTAssertEqual(carried?.day, "2026-06-18",
                       "a night with vitals but null recovery must still be the vitals source, not skipped")
        XCTAssertEqual(carried?.avgHrv, 59, "keeps last night's OWN HRV, not the older scored day's 44")
        XCTAssertEqual(carried?.restingHr, 50)
    }

    func testSelectsRowWithAnyOneVital_notRequiringAllThree() {
        // A night that recorded only respiratory (no HRV/RHR) is still a valid source — the OR gate means
        // any single vital qualifies the row.
        let days = [day("2026-06-18", recovery: nil, hrv: nil, rhr: nil, resp: 14.4),
                    day("2026-06-19")]
        let carried = DailyMetric.lastVitalsDay(days: days, todayKey: "2026-06-19")
        XCTAssertEqual(carried?.day, "2026-06-18")
        XCTAssertEqual(carried?.respRateBpm, 14.4)
    }

    func testNil_whenNoPriorDayHasAnyVital() {
        // A history where no prior day recorded a single vital carries nothing — the tiles honestly show "–".
        let days = [day("2026-06-18", recovery: 70),   // scored, but no vitals fields
                    day("2026-06-19")]
        XCTAssertNil(DailyMetric.lastVitalsDay(days: days, todayKey: "2026-06-19"))
    }

    // MARK: today-exclusion + future-day guard

    func testExcludesTodaysOwnRow_soItNeverEchoesToday() {
        // Today's row has partial vitals but the `< todayKey` bound excludes it, so the carry is the prior
        // day — the call site reads today's own field first anyway; the carry is strictly the fallback.
        let days = [day("2026-06-18", recovery: 72, hrv: 55, rhr: 52),
                    day("2026-06-19", hrv: 40)]   // today: a partial vital, still "today"
        let carried = DailyMetric.lastVitalsDay(days: days, todayKey: "2026-06-19")
        XCTAssertEqual(carried?.day, "2026-06-18", "the carry must be a strictly-prior day, never today's own row")
    }

    func testNeverSelectsAFutureDatedRow() {
        // A bad-clock strap can leave a future-dated row with vitals. The `< todayKey` bound must keep it
        // out so it can never surface as "last night's" vitals.
        let days = [day("2026-06-17", recovery: 60, hrv: 50, rhr: 54),
                    day("2026-06-18", recovery: 72, hrv: 58, rhr: 51),
                    day("2026-06-19"),                       // today, no vitals yet
                    day("2999-01-01", recovery: 80, hrv: 99, rhr: 40)]   // STRAY FUTURE row
        let carried = DailyMetric.lastVitalsDay(days: days, todayKey: "2026-06-19")
        XCTAssertEqual(carried?.day, "2026-06-18", "a future-dated row must never be carried as last night's vitals")
        XCTAssertEqual(carried?.avgHrv, 58)
    }

    func testNil_whenOnlyFutureRowsHaveVitals() {
        // If the only rows with vitals are future-dated, the carry honestly returns nil rather than reaching
        // forward in time.
        let days = [day("2026-06-19"),                              // today, no vitals
                    day("2999-01-01", recovery: 80, hrv: 99, rhr: 40)]
        XCTAssertNil(DailyMetric.lastVitalsDay(days: days, todayKey: "2026-06-19"))
    }

    // MARK: lastSpo2Day / lastSkinTempDay — the PER-FIELD carries for the two fields lastVitalsDay's
    // predicate does NOT check. The on-device engine writes spo2Pct = nil (only raw spo2Red/spo2Ir), so
    // every computed "-noop" row lacks a percentage; only imported rows carry one. A whole-row carry lands
    // on a row with null spo2Pct/skinTempDevC and the Blood Oxygen / Skin Temp cards read "No Data" even
    // though an imported row holds a real reading. Byte-twins of the Android lastSpo2Row / lastSkinTempRow.

    /// A day row carrying only the fields these per-field selectors read — mirrors the Android `fieldDay`.
    private func fieldDay(_ key: String, hrv: Double? = nil,
                          spo2: Double? = nil, skinTemp: Double? = nil) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: hrv, recovery: nil,
                    strain: nil, exerciseCount: nil, spo2Pct: spo2, skinTempDevC: skinTemp, respRateBpm: nil)
    }

    func testLastSpo2Day_skipsANewerVitalsRowWithNullSpo2_documentsTheWholeRowBug() {
        // Last night's computed row has vitals but NO spo2Pct (engine-written nil); an older imported row
        // has a real 96%. lastVitalsDay picks last night (correct for HRV) — the SpO₂ field must NOT ride
        // that row, it must resolve independently to the imported reading.
        let days = [fieldDay("2026-06-17", spo2: 96),               // imported, real reading
                    fieldDay("2026-06-18", hrv: 41, spo2: nil)]     // computed row: vitals yes, SpO₂ nil
        XCTAssertEqual(DailyMetric.lastVitalsDay(days: days, todayKey: "2026-06-19")?.day, "2026-06-18")
        let spo2 = DailyMetric.lastSpo2Day(days: days, todayKey: "2026-06-19")
        XCTAssertEqual(spo2?.day, "2026-06-17")
        XCTAssertEqual(spo2?.spo2Pct, 96)
    }

    func testLastSpo2Day_nil_whenNoPriorRowEverHadAReading_staysHonestNoData() {
        let days = [fieldDay("2026-06-18", hrv: 41)]
        XCTAssertNil(DailyMetric.lastSpo2Day(days: days, todayKey: "2026-06-19"))
    }

    func testLastSpo2Day_neverCarriesAFutureDatedRow() {
        let days = [fieldDay("2026-06-17", spo2: 96),
                    fieldDay("2999-01-01", spo2: 99)]              // future-dated pollution
        XCTAssertEqual(DailyMetric.lastSpo2Day(days: days, todayKey: "2026-06-19")?.day, "2026-06-17")
    }

    func testLastSkinTempDay_resolvesIndependently_ofVitalsAndSpo2() {
        // Skin temp lives on yet another row than SpO₂ — each field carries from its own freshest source.
        let days = [fieldDay("2026-06-16", skinTemp: 0.4),
                    fieldDay("2026-06-17", spo2: 96),
                    fieldDay("2026-06-18", hrv: 41)]
        let skin = DailyMetric.lastSkinTempDay(days: days, todayKey: "2026-06-19")
        XCTAssertEqual(skin?.day, "2026-06-16")
        XCTAssertEqual(skin?.skinTempDevC, 0.4)
    }

    func testLastSkinTempDay_neverCarriesAFutureDatedRow() {
        let days = [fieldDay("2026-06-16", skinTemp: 0.4),
                    fieldDay("2999-01-01", skinTemp: 2.1)]
        XCTAssertEqual(DailyMetric.lastSkinTempDay(days: days, todayKey: "2026-06-19")?.day, "2026-06-16")
    }

    // MARK: PER-FIELD HRV / resting HR — the OR predicate's blind spot (#1842)

    /// The reported shape: the freshest row carries respiratory ONLY, so the OR predicate selects it and its
    /// nil `avgHrv` renders "—" on the card while a tile carrying a different row shows a number on the same
    /// screen. Pins the BUG as well as the fix, so a future simplification back onto `lastVitalsDay` fails
    /// here rather than in the field.
    func testSharedPredicateSelectsARowWithNoHrv_perFieldDoesNot() {
        let days = [day("2026-09-01", hrv: 35, rhr: 58),
                    day("2026-09-02", resp: 14.2),
                    day("2026-09-03")]   // today, nothing yet
        let shared = DailyMetric.lastVitalsDay(days: days, todayKey: "2026-09-03")
        XCTAssertEqual(shared?.day, "2026-09-02", "the OR predicate takes the respiratory-only row")
        XCTAssertNil(shared?.avgHrv, "...and that row has no HRV — the blank the card was rendering")

        XCTAssertEqual(DailyMetric.lastHrvDay(days: days, todayKey: "2026-09-03")?.avgHrv, 35)
        XCTAssertEqual(DailyMetric.lastRestingHrDay(days: days, todayKey: "2026-09-03")?.restingHr, 58)
    }

    /// Freshest wins when several prior rows carry the field.
    func testPerFieldCarriesTheFreshestRowHoldingTheField() {
        let days = [day("2026-09-01", hrv: 30, rhr: 62),
                    day("2026-09-02", hrv: 41, rhr: 55),
                    day("2026-09-03")]
        XCTAssertEqual(DailyMetric.lastHrvDay(days: days, todayKey: "2026-09-03")?.avgHrv, 41)
        XCTAssertEqual(DailyMetric.lastRestingHrDay(days: days, todayKey: "2026-09-03")?.restingHr, 55)
    }

    /// Same future-clock bound as every sibling: strictly prior to today's key, so today's own still-forming
    /// row and a bad-clock strap's future-dated row can never be carried as "last night's".
    func testPerFieldNeverCarriesTodayOrLater() {
        let days = [day("2026-09-03", hrv: 44, rhr: 50), day("2026-09-04", hrv: 45, rhr: 49)]
        XCTAssertNil(DailyMetric.lastHrvDay(days: days, todayKey: "2026-09-03"))
        XCTAssertNil(DailyMetric.lastRestingHrDay(days: days, todayKey: "2026-09-03"))
    }

    /// Nothing anywhere stays "—": the carry must never invent a value.
    func testPerFieldCarriesNothingWhenNoRowHasTheField() {
        let days = [day("2026-09-01", resp: 15.0), day("2026-09-02", resp: 14.0)]
        XCTAssertNil(DailyMetric.lastHrvDay(days: days, todayKey: "2026-09-03"))
        XCTAssertNil(DailyMetric.lastRestingHrDay(days: days, todayKey: "2026-09-03"))
    }


    // MARK: skin-temp reading row — EITHER number, one night (#1844)

    private func skinDay(_ key: String, abs: Double? = nil, dev: Double? = nil) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
                    strain: nil, exerciseCount: nil, spo2Pct: nil, skinTempDevC: dev,
                    respRateBpm: nil, skinTempC: abs)
    }

    /// The calibrating night the deviation-only selector skipped: a real temperature, no deviation yet.
    func testFindsANightWithOnlyAnAbsolute() {
        let days = [skinDay("2026-09-01", dev: -0.3), skinDay("2026-09-02", abs: 34.1)]
        XCTAssertEqual(DailyMetric.lastSkinTempReadingDay(days: days, todayKey: "2026-09-03")?.day, "2026-09-02")
        // The deviation-only row reaches back past it, which is what left the card empty.
        XCTAssertEqual(DailyMetric.lastSkinTempDay(days: days, todayKey: "2026-09-03")?.day, "2026-09-01")
    }

    /// Both numbers come off ONE row, so an absolute is never paired with another night's deviation.
    func testBothSkinNumbersComeFromOneNight() {
        let days = [skinDay("2026-09-01", abs: 33.0, dev: -0.9), skinDay("2026-09-02", abs: 34.1, dev: 0.2)]
        let row = DailyMetric.lastSkinTempReadingDay(days: days, todayKey: "2026-09-03")
        XCTAssertEqual(row?.skinTempC, 34.1)
        XCTAssertEqual(row?.skinTempDevC, 0.2)
    }

    /// Same future-clock bound as every sibling carry.
    func testSkinReadingRowNeverCarriesTodayOrLater() {
        let days = [skinDay("2026-09-03", abs: 34.0), skinDay("2026-09-04", abs: 34.2)]
        XCTAssertNil(DailyMetric.lastSkinTempReadingDay(days: days, todayKey: "2026-09-03"))
    }

    /// A row with neither number is not a reading.
    func testSkinRowsWithNeitherNumberAreSkipped() {
        let days = [skinDay("2026-09-01", abs: 33.5), skinDay("2026-09-02")]
        XCTAssertEqual(DailyMetric.lastSkinTempReadingDay(days: days, todayKey: "2026-09-03")?.day, "2026-09-01")
    }

}
