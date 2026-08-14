package com.noop.ui

import com.noop.data.AppleDaily
import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the Today Weight + Steps tile fallback logic (issues #107, #150). The Calories tile
 * reads straight off DailyMetric, so the pure logic worth pinning is the two tiles with an imported
 * fallback source:
 *   - [latestWeightKg] picks the most-recent non-null body weight across the two Apple-side sources.
 *   - [weightTile] prefers that weight, else falls back to the SI profile weight with an honest
 *     "from profile" caption, always formatted through the unit toggle.
 *   - [stepsForDay] resolves the selected day's imported Apple Health / Health Connect step total —
 *     the Steps tile's fallback when the strap (e.g. a WHOOP 4.0) didn't bank an on-device count.
 */
class TodayMetricTilesTest {

    private fun appleDay(day: String, weightKg: Double?) =
        AppleDaily(deviceId = "apple-health", day = day, weightKg = weightKg)

    private fun stepsDay(deviceId: String, day: String, steps: Int?) =
        AppleDaily(deviceId = deviceId, day = day, steps = steps)

    // MARK: latestWeightKg

    @Test
    fun latestWeight_nullWhenNoSourceHasWeight() {
        val apple = listOf(appleDay("2026-01-01", null), appleDay("2026-01-02", null))
        assertNull(latestWeightKg(apple, emptyList()))
    }

    @Test
    fun latestWeight_picksTheMostRecentDay() {
        val apple = listOf(
            appleDay("2026-01-01", 80.0),
            appleDay("2026-01-05", 78.5),
            appleDay("2026-01-03", 79.0),
        )
        assertEquals(78.5, latestWeightKg(apple, emptyList())!!, 1e-9)
    }

    @Test
    fun latestWeight_skipsNullWeightDaysEvenWhenNewer() {
        // A newer day with no weight must not blank out an older real reading.
        val apple = listOf(appleDay("2026-01-02", 81.0), appleDay("2026-01-09", null))
        assertEquals(81.0, latestWeightKg(apple, emptyList())!!, 1e-9)
    }

    @Test
    fun latestWeight_unionsBothSources_mostRecentWins() {
        val apple = listOf(appleDay("2026-01-04", 80.0))
        val healthConnect = listOf(
            AppleDaily(deviceId = "health-connect", day = "2026-01-06", weightKg = 77.0),
        )
        assertEquals(77.0, latestWeightKg(apple, healthConnect)!!, 1e-9)
    }

    // MARK: weightTile

    @Test
    fun weightTile_usesLatestReading_metric() {
        val t = weightTile(latestWeightKg = 74.5, profileWeightKg = 90.0, system = UnitSystem.METRIC)
        assertEquals("74.5 kg", t.value)
        assertEquals("latest", t.caption)
    }

    @Test
    fun weightTile_usesLatestReading_imperial() {
        val t = weightTile(latestWeightKg = 100.0, profileWeightKg = 90.0, system = UnitSystem.IMPERIAL)
        // 100 kg * 2.20462 = 220.462 lb
        assertEquals("220.5 lb", t.value)
        assertEquals("latest", t.caption)
    }

    @Test
    fun weightTile_fallsBackToProfile_withHonestCaption() {
        val t = weightTile(latestWeightKg = null, profileWeightKg = 75.0, system = UnitSystem.METRIC)
        assertEquals("75.0 kg", t.value)
        assertEquals("from profile", t.caption)
    }

    @Test
    fun weightTile_profileFallbackRespectsImperial() {
        val t = weightTile(latestWeightKg = null, profileWeightKg = 75.0, system = UnitSystem.IMPERIAL)
        // 75 kg * 2.20462 = 165.3465 lb
        assertEquals("165.3 lb", t.value)
        assertEquals("from profile", t.caption)
    }

    // MARK: stepsForDay — Today Steps-tile fallback to imported Apple Health / Health Connect (#150)

    @Test
    fun stepsForDay_nullWhenNeitherSourceCoversTheDay() {
        val apple = listOf(stepsDay("apple-health", "2026-01-01", 8000))
        assertNull(stepsForDay(apple, emptyList(), "2026-01-02"))
    }

    @Test
    fun stepsForDay_returnsImportedStepsForTheSelectedDay() {
        val apple = listOf(
            stepsDay("apple-health", "2026-01-01", 8000),
            stepsDay("apple-health", "2026-01-02", 11200),
        )
        assertEquals(11200, stepsForDay(apple, emptyList(), "2026-01-02"))
    }

    @Test
    fun stepsForDay_ignoresNullStepRowsForTheDay() {
        // A row exists for the day but carries no step count → treated as absent, not zero.
        val apple = listOf(stepsDay("apple-health", "2026-01-03", null))
        assertNull(stepsForDay(apple, emptyList(), "2026-01-03"))
    }

    @Test
    fun stepsForDay_unionsBothSources_takesTheLargerForTheDay() {
        // Both Apple Health and Health Connect can report the same day; take the larger (most complete)
        // rather than summing, so we never double-count overlapping sources.
        val apple = listOf(stepsDay("apple-health", "2026-01-04", 6000))
        val hc = listOf(stepsDay("health-connect", "2026-01-04", 9500))
        assertEquals(9500, stepsForDay(apple, hc, "2026-01-04"))
    }

    // MARK: buildingHint — the unscored Effort/Rest "it's coming" caption, today-only (#527)

    @Test
    fun buildingHint_rest_today_isTheWearItTonightCopy() {
        assertEquals("Building, wear it tonight", buildingHint(KeyMetric.REST, isToday = true))
    }

    @Test
    fun buildingHint_effort_today_isTheMovesAsYouDoCopy() {
        assertEquals("Building, moves as you do", buildingHint(KeyMetric.EFFORT, isToday = true))
    }

    @Test
    fun buildingHint_pastDay_isNull_soAnUnscoredOldDayStaysABareDash() {
        // Honesty: a navigated past day with no score is missing data, not mid-calibration.
        assertNull(buildingHint(KeyMetric.REST, isToday = false))
        assertNull(buildingHint(KeyMetric.EFFORT, isToday = false))
    }

    // MARK: buildingHint — H10 extension to Charge / Blood Oxygen / Steps cold-start captions

    @Test
    fun buildingHint_charge_today_isTheWearItTonightCopy() {
        // H10: a cold-start Charge (no score, not calibrating, nothing carried) reads "building", not blank.
        assertEquals("Building, wear it tonight", buildingHint(KeyMetric.CHARGE, isToday = true))
    }

    @Test
    fun buildingHint_bloodOxygen_today_buildsLikeTheOtherOvernightVitals() {
        // H10: the overnight SpO₂ fills in from sleep, like Rest.
        assertEquals("Building, wear it tonight", buildingHint(KeyMetric.BLOOD_OXYGEN, isToday = true))
    }

    @Test
    fun buildingHint_steps_today_movesAsYouDo() {
        // H10: on-device steps accrue across the day, like Effort.
        assertEquals("Building, moves as you do", buildingHint(KeyMetric.STEPS, isToday = true))
    }

    @Test
    fun buildingHint_h10Metrics_pastDay_isNull_soAnUnscoredOldDayStaysABareDash() {
        // Honesty: a navigated past day with no value is missing data, not mid-calibration.
        for (m in listOf(KeyMetric.CHARGE, KeyMetric.BLOOD_OXYGEN, KeyMetric.STEPS)) {
            assertNull(buildingHint(m, isToday = false))
        }
    }

    @Test
    fun buildingHint_stillNull_forMetricsWithNoHonestColdStartCopy() {
        // HRV / Resting HR / Respiratory / Weight / Calories carry their own treatment; no generic hint.
        for (m in listOf(KeyMetric.HRV, KeyMetric.RESTING_HR, KeyMetric.RESPIRATORY, KeyMetric.WEIGHT, KeyMetric.CALORIES)) {
            assertNull(buildingHint(m, isToday = true))
        }
    }

    @Test
    fun buildingHint_copy_hasNoEmDash() {
        // House style: user-facing strings carry no em-dashes (the #1 AI tell).
        for (m in listOf(KeyMetric.REST, KeyMetric.EFFORT, KeyMetric.CHARGE, KeyMetric.BLOOD_OXYGEN, KeyMetric.STEPS)) {
            val hint = buildingHint(m, isToday = true)!!
            assert(!hint.contains('—')) { "buildingHint($m) must not contain an em-dash: $hint" }
        }
    }

    // MARK: restStageLowConfidence — H9. Surfaces the core ScoreConfidence rule: a high-efficiency night
    // whose deep+REM share is implausibly low is flagged low-confidence STAGING (a likely staging miss),
    // shown as a small "Estimated" badge on the Rest tile rather than faked stages. efficiency is the
    // engine's 0..1 fraction; restorative = deep+REM minutes. Never fabricated — reads only banked figures.

    private fun sleepDay(
        day: String = "2026-06-19",
        totalSleepMin: Double?,
        efficiency: Double?,
        deepMin: Double?,
        remMin: Double?,
    ) = DailyMetric(
        deviceId = "my-whoop", day = day,
        totalSleepMin = totalSleepMin, efficiency = efficiency, deepMin = deepMin, remMin = remMin,
    )

    @Test
    fun restStageLowConfidence_false_whenDayIsNull() {
        assertFalse(restStageLowConfidence(null))
    }

    @Test
    fun restStageLowConfidence_false_whenNoEfficiencyOrDuration() {
        // No banked sleep figures → nothing to judge; the badge must stand down (not assume low-confidence).
        assertFalse(restStageLowConfidence(sleepDay(totalSleepMin = null, efficiency = 0.9, deepMin = 30.0, remMin = 30.0)))
        assertFalse(restStageLowConfidence(sleepDay(totalSleepMin = 480.0, efficiency = null, deepMin = 30.0, remMin = 30.0)))
    }

    @Test
    fun restStageLowConfidence_false_forAHealthyWellStructuredNight() {
        // ~45% deep+REM on a high-efficiency night is a normal adult night — SOLID, no badge.
        val d = sleepDay(totalSleepMin = 480.0, efficiency = 0.92, deepMin = 110.0, remMin = 105.0)
        assertFalse(restStageLowConfidence(d))
    }

    @Test
    fun restStageLowConfidence_true_forHighEfficiencyButNearZeroRestorative() {
        // 0.95 efficiency (>= 0.85) yet only ~4% deep+REM (< 10%) → the H9 staging-miss flag fires.
        val d = sleepDay(totalSleepMin = 480.0, efficiency = 0.95, deepMin = 10.0, remMin = 10.0)
        assertTrue(restStageLowConfidence(d))
    }

    @Test
    fun restStageLowConfidence_false_forLowEfficiencyNightWithLowRestorative() {
        // A fragmented (low-efficiency) night legitimately carries less deep/REM, so the floor does NOT
        // apply — we don't flag a genuinely poor night as a staging miss.
        val d = sleepDay(totalSleepMin = 360.0, efficiency = 0.70, deepMin = 8.0, remMin = 8.0)
        assertFalse(restStageLowConfidence(d))
    }

    @Test
    fun restStageLowConfidence_false_whenNoStagedSleepAtAll() {
        // No deep AND no REM → the base tier isn't SOLID (it's a sparse, unstaged night with its own
        // honest treatment), so the H9 "stages estimated" badge must not appear.
        val d = sleepDay(totalSleepMin = 420.0, efficiency = 0.95, deepMin = 0.0, remMin = 0.0)
        assertFalse(restStageLowConfidence(d))
    }

    // MARK: lastScoredRecoveryDay — the #543 carry-over selector that keeps the WHOLE recovery side
    // populated at the logical-day rollover (Charge ring + HRV / resting-HR / respiratory / SpO₂ tiles +
    // Synthesis / Contributors / Readiness), instead of blanking to "No Data" while live HR ticks. This
    // pins the GATE + SELECTION shared by all those read-outs. Mirrors the iOS TodayCarryOverTests.

    private fun recDay(
        day: String,
        recovery: Double?,
        hrv: Double? = null,
        rhr: Int? = null,
        spo2: Double? = null,
        resp: Double? = null,
    ) = DailyMetric(
        deviceId = "my-whoop", day = day, recovery = recovery,
        avgHrv = hrv, restingHr = rhr, spo2Pct = spo2, respRateBpm = resp,
    )

    @Test
    fun lastScoredRecoveryDay_carriesTheFreshestScoredPriorDay_whenTodayUnscoredAndPastCalibration() {
        val days = listOf(
            recDay("2026-06-17", 60.0),
            recDay("2026-06-18", 72.0),
            recDay("2026-06-19", null), // today, not scored yet
        )
        val carried = lastScoredRecoveryDay(
            days, selectedDayKey = "2026-06-19",
            isToday = true, todayScored = false, isCalibrating = false,
        )
        assertEquals("2026-06-18", carried?.day)
        assertEquals(72.0, carried?.recovery)
    }

    @Test
    fun lastScoredRecoveryDay_nothingCarried_whenTodayIsAlreadyScored() {
        val days = listOf(recDay("2026-06-18", 72.0), recDay("2026-06-19", 55.0))
        assertNull(
            lastScoredRecoveryDay(
                days, selectedDayKey = "2026-06-19",
                isToday = true, todayScored = true, isCalibrating = false,
            ),
        )
    }

    @Test
    fun lastScoredRecoveryDay_nothingCarried_whileCalibrating() {
        // Calibration owns its own "N of 4" Charge copy — the carry-over must stand down.
        val days = listOf(recDay("2026-06-18", 72.0), recDay("2026-06-19", null))
        assertNull(
            lastScoredRecoveryDay(
                days, selectedDayKey = "2026-06-19",
                isToday = true, todayScored = false, isCalibrating = true,
            ),
        )
    }

    @Test
    fun lastScoredRecoveryDay_nothingCarried_onANavigatedPastDay() {
        // A navigated past day with no score is missing data, not a rollover — never carry.
        val days = listOf(recDay("2026-06-17", 60.0), recDay("2026-06-18", 72.0))
        assertNull(
            lastScoredRecoveryDay(
                days, selectedDayKey = "2026-06-18",
                isToday = false, todayScored = false, isCalibrating = false,
            ),
        )
    }

    @Test
    fun lastScoredRecoveryDay_excludesTodaysOwnKey_soItNeverEchoesToday() {
        // Today carries vitals but no recovery — it must NOT be chosen (we'd echo today as "last night").
        val days = listOf(
            recDay("2026-06-18", 72.0),
            recDay("2026-06-19", null, hrv = 40.0),
        )
        val carried = lastScoredRecoveryDay(
            days, selectedDayKey = "2026-06-19",
            isToday = true, todayScored = false, isCalibrating = false,
        )
        assertEquals("2026-06-18", carried?.day)
    }

    @Test
    fun lastScoredRecoveryDay_null_whenNoPriorDayWasEverScored() {
        // A genuinely-never-scored history carries nothing — the tiles honestly stay "No Data".
        val days = listOf(recDay("2026-06-18", null), recDay("2026-06-19", null))
        assertNull(
            lastScoredRecoveryDay(
                days, selectedDayKey = "2026-06-19",
                isToday = true, todayScored = false, isCalibrating = false,
            ),
        )
    }

    @Test
    fun lastScoredRecoveryDay_carriedRow_keepsItsOwnMissingMetricsAsNull_neverFabricated() {
        // A metric the carried night genuinely lacks (e.g. a BLE-only night with no SpO₂) stays null on
        // the carried row, so the SpO₂ tile still resolves to "No Data" rather than a fabricated number.
        val days = listOf(
            recDay("2026-06-18", 72.0, hrv = 55.0, rhr = 50, spo2 = null, resp = 14.2),
            recDay("2026-06-19", null),
        )
        val carried = lastScoredRecoveryDay(
            days, selectedDayKey = "2026-06-19",
            isToday = true, todayScored = false, isCalibrating = false,
        )
        assertEquals(55.0, carried?.avgHrv)
        assertEquals(50, carried?.restingHr)
        assertNull(carried?.spo2Pct)
        assertEquals(14.2, carried?.respRateBpm)
    }

    // MARK: #547 carry-over future-day guard — a stray FUTURE-dated row (a bad strap clock wrote a day
    // past "today") must NEVER be picked as "last night"; that's exactly how #547's Today header read
    // "12 Jul". Belt-and-suspenders alongside the ingest gate + heal.

    @Test
    fun lastScoredRecoveryDay_neverCarriesAFutureDatedRow_547() {
        // A bad-clock row dated AFTER today sits at the end of the oldest→newest list; without the
        // day <= today filter, lastOrNull would pick it and surface "Last night · <future date>".
        val days = listOf(
            recDay("2026-06-18", 72.0),     // the real freshest scored prior day
            recDay("2026-07-12", 90.0),     // future-dated pollution (#547 "12 Jul")
        )
        val carried = lastScoredRecoveryDay(
            days, selectedDayKey = "2026-06-19",
            isToday = true, todayScored = false, isCalibrating = false,
            today = "2026-06-19",
        )
        assertEquals("2026-06-18", carried?.day)   // the future row is skipped
        assertEquals(72.0, carried?.recovery)
    }

    @Test
    fun lastScoredRecoveryDay_carriesTodayBoundaryDay_inclusive_547() {
        // A row dated exactly "today" (e.g. the local calendar day at a just-after-midnight rollover) is
        // NOT future — the <= today bound keeps it eligible so a legitimate carry-over is not dropped.
        val days = listOf(
            recDay("2026-06-18", 60.0),
            recDay("2026-06-19", 72.0),     // == today; eligible (it isn't the selected/unscored key)
        )
        val carried = lastScoredRecoveryDay(
            days, selectedDayKey = "2026-06-20",   // today's still-null logical key
            isToday = true, todayScored = false, isCalibrating = false,
            today = "2026-06-19",
        )
        assertEquals("2026-06-19", carried?.day)
        assertEquals(72.0, carried?.recovery)
    }

    // MARK: lastVitalsRow — the recovery-INDEPENDENT vitals carry (#543 follow-up). HRV / resting-HR /
    // respiratory exist without a recovery score, so this selector must carry the freshest STRICTLY-PRIOR
    // night that has ANY of them, NOT the freshest recovery-SCORED night. This is what keeps the overnight
    // HRV / Resting HR / Respiratory card in step with the (already-correct) per-field Key-Metrics tile
    // when a post-update re-analysis nulls last night's recovery while preserving its real vitals.

    @Test
    fun lastVitalsRow_keepsLastNightsOwnVitals_whenItsRecoveryWasNulled_documentsWholeRowBug() {
        // Post-update re-analysis nulled last night's RECOVERY but PRESERVED its real avgHrv/restingHr; an
        // older day was recovery-scored. The recovery-gated whole-row carry (lastScoredRecoveryDay) selects
        // that OLDER day, so a whole-row `carriedDay ?: day` read would discard last night's own 41 ms/61 bpm
        // — the tile-vs-card mismatch. The per-field read (today-first, else lastVitalsRow) keeps them.
        val days = listOf(
            recDay("2026-06-17", 65.0, hrv = 55.0, rhr = 50),   // older, recovery-scored
            recDay("2026-06-18", null, hrv = 41.0, rhr = 61),   // last night: recovery nulled, vitals intact
        )
        // The whole-row carry documents the bug: it picks the OLDER scored day, not last night.
        val scored = lastScoredRecoveryDay(
            days, selectedDayKey = "2026-06-19",
            isToday = true, todayScored = false, isCalibrating = false,
            today = "2026-06-19",
        )
        assertEquals("2026-06-17", scored?.day)

        // The vitals carry keeps last night's OWN preserved values, so the per-field read is correct.
        val vitals = lastVitalsRow(days, todayKey = "2026-06-19")
        assertEquals("2026-06-18", vitals?.day)
        assertEquals(41.0, vitals?.avgHrv)
        assertEquals(61, vitals?.restingHr)

        // The per-field read the card now uses (today has no row yet → carry): last night's own vitals.
        val today: DailyMetric? = null
        assertEquals(41.0, today?.avgHrv ?: vitals?.avgHrv)
        assertEquals(61, today?.restingHr ?: vitals?.restingHr)
    }

    @Test
    fun lastVitalsRow_carriesVitals_evenWhenNoPriorNightWasEverRecoveryScored() {
        // Prior night has real vitals but its recovery is null, and today is empty. The recovery-gated
        // selector carries NOTHING (nothing was scored), yet the vitals must still carry so the card doesn't
        // blank while the tile shows a value.
        val days = listOf(
            recDay("2026-06-18", null, hrv = 44.0, rhr = 58),   // vitals present, recovery never scored
            recDay("2026-06-19", null),                          // today, empty
        )
        val scored = lastScoredRecoveryDay(
            days, selectedDayKey = "2026-06-19",
            isToday = true, todayScored = false, isCalibrating = false,
            today = "2026-06-19",
        )
        assertNull(scored)

        val vitals = lastVitalsRow(days, todayKey = "2026-06-19")
        assertEquals("2026-06-18", vitals?.day)
        assertEquals(44.0, vitals?.avgHrv)
        assertEquals(58, vitals?.restingHr)
    }

    @Test
    fun lastVitalsRow_neverCarriesAFutureDatedRow() {
        // Belt-and-suspenders (mirrors the #547 guard on lastScoredRecoveryDay): a bad-clock row dated far in
        // the future sits at the end of the oldest→newest list; the `day < todayKey` bound skips it so it can
        // never surface as "last night".
        val days = listOf(
            recDay("2026-06-18", 72.0, hrv = 50.0, rhr = 55),   // the real freshest prior vitals
            recDay("2999-01-01", null, hrv = 99.0, rhr = 99),   // future-dated pollution
        )
        val vitals = lastVitalsRow(days, todayKey = "2026-06-19")
        assertEquals("2026-06-18", vitals?.day)
        assertEquals(50.0, vitals?.avgHrv)
        assertEquals(55, vitals?.restingHr)
    }

    // MARK: lastSpo2Row / lastSkinTempRow — the PER-FIELD carries for the two fields lastVitalsRow's
    // predicate does NOT check. The on-device engine writes spo2Pct = null (only raw spo2Red/spo2Ir), so
    // every computed "-noop" row lacks a percentage; only imported rows carry one. A whole-row carry lands
    // on a row with null spo2Pct/skinTempDevC and the Blood Oxygen / Skin Temp cards read "No Data" even
    // though an imported row holds a real reading. Mirrors iOS VitalSourceResolution's per-field pick.

    private fun fieldDay(
        day: String,
        hrv: Double? = null,
        spo2: Double? = null,
        skinTemp: Double? = null,
        resp: Double? = null,
    ) = DailyMetric(deviceId = "my-whoop", day = day, avgHrv = hrv, spo2Pct = spo2, skinTempDevC = skinTemp,
                    respRateBpm = resp)

    @Test
    fun lastSpo2Row_skipsANewerVitalsRowWithNullSpo2_documentsTheWholeRowBug() {
        // Last night's computed row has vitals but NO spo2Pct (engine-written null); an older imported row
        // has a real 96%. lastVitalsRow picks last night (correct for HRV) — the SpO₂ field must NOT ride
        // that row, it must resolve independently to the imported reading.
        val days = listOf(
            fieldDay("2026-06-17", spo2 = 96.0),                 // imported, real reading
            fieldDay("2026-06-18", hrv = 41.0, spo2 = null),     // computed row: vitals yes, SpO₂ null
        )
        assertEquals("2026-06-18", lastVitalsRow(days, todayKey = "2026-06-19")?.day)
        val spo2 = lastSpo2Row(days, todayKey = "2026-06-19")
        assertEquals("2026-06-17", spo2?.day)
        assertEquals(96.0, spo2?.spo2Pct)
    }

    @Test
    fun lastRespRow_carriesARECENTReading_whenTheNewestVitalsNightLacksResp() {
        // #1331: respiratory needs a longer clean sleep R-R segment than HRV, so last night can carry HRV
        // but no breaths/min. lastVitalsRow picks last night (right for HRV); respiratory resolves per-field
        // to the last night that HAD a reading — but only within the vitalCarryDays window.
        val days = listOf(
            fieldDay("2026-08-11", resp = 20.0),                 // 3 days back: within the 7-day carry window
            fieldDay("2026-08-13", hrv = 65.0, resp = null),     // last night: HRV yes, respiratory null
        )
        assertEquals("2026-08-13", lastVitalsRow(days, todayKey = "2026-08-14")?.day)
        val resp = lastRespRow(days, todayKey = "2026-08-14")
        assertEquals("2026-08-11", resp?.day)
        assertEquals(20.0, resp?.respRateBpm)
    }

    @Test
    fun lastRespRow_returnsNull_whenTheLastReadingIsStale_soNoStaleNumberIsShownAsCurrent() {
        // The reported #1331 case: respiratory last computed weeks ago (here 23 days). A nightly vital that
        // old must NOT be carried as the current card value — a silent stale number reads as a live
        // measurement (the "Respiratory 15.6 a fortnight later" bug). Beyond vitalCarryDays => "No Data".
        val days = listOf(
            fieldDay("2026-07-22", resp = 20.0),                 // 23 days back — beyond the 7-day window
            fieldDay("2026-08-13", hrv = 65.0, resp = null),     // recent HRV-only night
        )
        assertEquals("2026-08-13", lastVitalsRow(days, todayKey = "2026-08-14")?.day)
        assertNull(lastRespRow(days, todayKey = "2026-08-14"))
    }

    @Test
    fun lastSpo2Row_null_whenNoPriorRowEverHadAReading_staysHonestNoData() {
        val days = listOf(fieldDay("2026-06-18", hrv = 41.0))
        assertNull(lastSpo2Row(days, todayKey = "2026-06-19"))
    }

    @Test
    fun lastSpo2Row_neverCarriesAFutureDatedRow() {
        val days = listOf(
            fieldDay("2026-06-17", spo2 = 96.0),
            fieldDay("2999-01-01", spo2 = 99.0),                 // future-dated pollution
        )
        assertEquals("2026-06-17", lastSpo2Row(days, todayKey = "2026-06-19")?.day)
    }

    @Test
    fun lastSkinTempRow_resolvesIndependently_ofVitalsAndSpo2() {
        // Skin temp lives on yet another row than SpO₂ — each field carries from its own freshest source.
        val days = listOf(
            fieldDay("2026-06-16", skinTemp = 0.4),
            fieldDay("2026-06-17", spo2 = 96.0),
            fieldDay("2026-06-18", hrv = 41.0),
        )
        val skin = lastSkinTempRow(days, todayKey = "2026-06-19")
        assertEquals("2026-06-16", skin?.day)
        assertEquals(0.4, skin?.skinTempDevC)
    }

    @Test
    fun lastSkinTempRow_neverCarriesAFutureDatedRow() {
        val days = listOf(
            fieldDay("2026-06-16", skinTemp = 0.4),
            fieldDay("2999-01-01", skinTemp = 2.1),
        )
        assertEquals("2026-06-16", lastSkinTempRow(days, todayKey = "2026-06-19")?.day)
    }
}
