package com.noop.ui

import com.noop.analytics.FusionSource
import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the Today explainability layer (spec: 2026-06-20-sleep-guidance-explainability.md):
 *   - COMPONENT 2 — [scoreStateForToday] + the [ScoreState] copy (calibrating / carried / needs-strap);
 *   - COMPONENT 3 — [recordingStateFor] + the [RecordingState] copy (recording / last-synced / not);
 *   - COMPONENT 4 — [dayOwnerSource] + [provenanceBadgeLabel] (the By-Day vocabulary) AND
 *                   [provenanceDisplayLabel] (the PER-METRIC ring badge — the REAL field-by-field winner).
 *
 * The COPY assertions are VERBATIM and must stay word-for-word identical to the Swift today lane. The
 * honesty rules are pinned directly: calibrating / needs-strap carry NO number, carried values are
 * stamped with their date, and the provenance label is the real winner (never a blanket "on-device").
 */
class TodayExplainabilityTest {

    private fun day(key: String, recovery: Double? = null, deviceId: String = "my-whoop") =
        DailyMetric(deviceId = deviceId, day = key, recovery = recovery)

    // ── COMPONENT 2 — score state ────────────────────────────────────────────────────────────────────

    @Test
    fun scoreState_scored_whenTodayHasRecovery() {
        val state = scoreStateForToday(todayRecovery = 72.0, calibratingNights = null, carriedDay = null)
        assertTrue(state is ScoreState.Scored)
        assertEquals(72.0, (state as ScoreState.Scored).value, 1e-9)
    }

    @Test
    fun scoreState_calibrating_takesPrecedenceAndShowsRemainingNights() {
        // 1 night banked, seed 4 → "about 3 more nights". No fabricated value.
        val state = scoreStateForToday(todayRecovery = null, calibratingNights = 1, carriedDay = null, seed = 4)
        assertEquals(ScoreState.Calibrating(3), state)
        assertEquals("Calibrating", state.title)
        assertEquals(
            "Building your baseline. About 3 more nights until your scores are personal.",
            state.detail,
        )
    }

    @Test
    fun scoreState_calibrating_singularNight_whenOneRemaining() {
        // 3 of 4 banked → exactly one more night → singular "night".
        val state = scoreStateForToday(todayRecovery = null, calibratingNights = 3, carriedDay = null, seed = 4)
        assertEquals(ScoreState.Calibrating(1), state)
        assertEquals(
            "Building your baseline. About 1 more night until your scores are personal.",
            state.detail,
        )
    }

    @Test
    fun scoreState_calibrating_flooredAtOne_neverZeroOrNegative() {
        // At/above the seed the count would be 0 or negative; floor at 1 so it never reads "ready".
        val state = scoreStateForToday(todayRecovery = null, calibratingNights = 4, carriedDay = null, seed = 4)
        assertEquals(ScoreState.Calibrating(1), state)
    }

    @Test
    fun scoreState_carriedLastNight_whenNotCalibratingAndPriorExists() {
        // A genuine post-rollover carry (yesterday's score) stays "Last night". An explicit `today` anchors
        // the recency check so the test is stable regardless of the real wall-clock date (#779).
        val prior = day("2026-01-14", recovery = 65.0)
        val state = scoreStateForToday(todayRecovery = null, calibratingNights = null, carriedDay = prior,
            today = "2026-01-15")
        assertEquals(ScoreState.CarriedLastNight("14 Jan", false), state)
        assertEquals("Last night · 14 Jan", state.title)
        assertEquals("Tonight's lands after you sleep with the strap on.", state.detail)
    }

    @Test
    fun scoreState_staleCarry_relabelsLatestSleep() {
        // #779: a weeks-old carry is still shown (not a bare blank) but relabelled so the number is never
        // passed off as "Last night".
        val prior = day("2026-01-14", recovery = 65.0)
        val state = scoreStateForToday(todayRecovery = null, calibratingNights = null, carriedDay = prior,
            today = "2026-02-11")
        assertEquals(ScoreState.CarriedLastNight("14 Jan", true), state)
        assertEquals("Latest sleep · 14 Jan", state.title)
        assertEquals("This is your last scored session. Wear the strap overnight for a fresh score.", state.detail)
    }

    @Test
    fun carriedCaption_capsLastNightToTwoDays() {
        // Within the cap → "Last night"; older → "Latest sleep". The cap is inclusive at 2 days. (#779)
        assertEquals(false, isCarryStale("2026-01-13", "2026-01-15"))
        assertEquals("Last night · 13 Jan", carriedCaption("2026-01-13", "2026-01-15"))
        assertEquals(true, isCarryStale("2026-01-12", "2026-01-15"))
        assertEquals("Latest sleep · 12 Jan", carriedCaption("2026-01-12", "2026-01-15"))
        // An unparseable key never reads stale (never over-claims).
        assertEquals(false, isCarryStale("not-a-date", "2026-01-15"))
    }

    @Test
    fun scoreState_needsStrap_whenNothingToShow() {
        val state = scoreStateForToday(todayRecovery = null, calibratingNights = null, carriedDay = null)
        assertEquals(ScoreState.NeedsStrap, state)
        assertEquals("Needs the strap", state.title)
        assertEquals("No data for today. Was your strap worn and connected overnight?", state.detail)
    }

    @Test
    fun scoreState_calibratingBeatsCarried_whenBothPresent() {
        // Calibration owns its own copy — it must win over a prior carried day.
        val prior = day("2026-01-14", recovery = 65.0)
        val state = scoreStateForToday(todayRecovery = null, calibratingNights = 2, carriedDay = prior, seed = 4)
        assertTrue(state is ScoreState.Calibrating)
    }

    @Test
    fun scoreState_calibratingAndNeedsStrap_carryNoNumber() {
        // Honesty: the no-own-value states have an empty value slot — the copy carries no figure.
        val calibrating = scoreStateForToday(todayRecovery = null, calibratingNights = 0, carriedDay = null, seed = 4)
        val needsStrap = scoreStateForToday(todayRecovery = null, calibratingNights = null, carriedDay = null)
        // No "%" or other number sneaks into the title.
        assertTrue(!calibrating.title.contains("%"))
        assertTrue(!needsStrap.title.contains("%"))
    }

    // ── COMPONENT 3 — recording state ────────────────────────────────────────────────────────────────

    @Test
    fun recording_whenConnectedAndLiveHr() {
        val state = recordingStateFor(connected = true, liveHeartRate = 58, lastSyncAtSec = null, nowSec = 1_000_000)
        assertEquals(RecordingState.Recording, state)
        assertEquals("Recording", state.title)
        assertEquals("Your strap is connected and saving data.", state.detail)
        assertEquals(StrandTone.Positive, state.tone)
    }

    @Test
    fun recording_notClaimed_whenConnectedButNoLiveHr() {
        // A bonded-but-silent link must not claim it's saving data.
        // #612: connected + no live HR + never synced (a strap's first-ever pairing) must not claim
        // "Not recording" either — the link genuinely IS up. Fixed from the prior `NotRecording` result,
        // which was the exact bug #612 reported.
        val state = recordingStateFor(connected = true, liveHeartRate = null, lastSyncAtSec = null, nowSec = 1_000_000)
        assertEquals(RecordingState.ConnectedNoData, state)
    }

    @Test
    fun connectedNoData_sustainedEmptyOffload_overridesAnOldLastSync() {
        // #612: an established strap (old but known last-sync) whose recent offloads are a SUSTAINED
        // empty streak reads "connected, no data" rather than a stale "Last synced 14d ago".
        val now = 10_000L
        val state = recordingStateFor(
            connected = true, liveHeartRate = null, lastSyncAtSec = now - 1_209_600, nowSec = now,
            sustainedEmptyOffload = true,
        )
        assertEquals(RecordingState.ConnectedNoData, state)
    }

    @Test
    fun connectedNoData_sustainedEmptyOffload_withoutConnection_isNotConnectedNoData() {
        // The `connected` gate still applies: a disconnected strap with a stale sustained-empty flag
        // (carried over from before the drop) must not read "Connected".
        val state = recordingStateFor(
            connected = false, liveHeartRate = null, lastSyncAtSec = null, nowSec = 10_000L,
            sustainedEmptyOffload = true,
        )
        assertEquals(RecordingState.NotRecording, state)
    }

    @Test
    fun lastSynced_minutesAgoFromTimestamp() {
        // Exactly 9 minutes ago = 540 s. ceil(540/60) == 9 (no rounding needed on a boundary).
        val now = 1_000_000L
        val state = recordingStateFor(connected = false, liveHeartRate = null, lastSyncAtSec = now - 540, nowSec = now)
        assertEquals(RecordingState.LastSynced(9), state)
        assertEquals("Last synced 9m ago", state.title)
        assertEquals("Reconnect to pull the latest.", state.detail)
        assertEquals(StrandTone.Neutral, state.tone)
    }

    @Test
    fun lastSynced_minutesRoundUP_30secondsReads1m() {
        // CANONICAL CONTRACT: minutesAgo = ceil((now - lastSync) / 60). A 30-second-old sync must read
        // "1m ago", NEVER "0m ago" (the old integer floor read 0 and looked stale-but-fresh). Mirrors
        // the Swift RecordingState.resolve ceil.
        val now = 1_000_000L
        val state = recordingStateFor(connected = false, liveHeartRate = null, lastSyncAtSec = now - 30, nowSec = now)
        assertEquals(RecordingState.LastSynced(1), state)
        assertEquals("Last synced 1m ago", state.title)
    }

    @Test
    fun lastSynced_minutesRoundUP_anyRemainderBumpsTheMinute() {
        // 8m 01s (481 s) must ceil to 9, not floor to 8 — any partial minute rounds UP.
        val now = 1_000_000L
        val state = recordingStateFor(connected = false, liveHeartRate = null, lastSyncAtSec = now - 481, nowSec = now)
        assertEquals(RecordingState.LastSynced(9), state)
        assertEquals("Last synced 9m ago", state.title)
        // 1 second ago still rounds up to a whole minute.
        val oneSecond = recordingStateFor(connected = false, liveHeartRate = null, lastSyncAtSec = now - 1, nowSec = now)
        assertEquals(RecordingState.LastSynced(1), oneSecond)
    }

    @Test
    fun lastSynced_exactlyNow_reads0m() {
        // A sync stamped at exactly `now` is 0 seconds old → ceil(0/60) == 0 → "0m ago" (not bumped to 1).
        val now = 1_000_000L
        val state = recordingStateFor(connected = false, liveHeartRate = null, lastSyncAtSec = now, nowSec = now)
        assertEquals(RecordingState.LastSynced(0), state)
        assertEquals("Last synced 0m ago", state.title)
    }

    @Test
    fun lastSynced_flooredAtZero_neverNegative() {
        // A clock skew (sync stamped slightly in the future) must not read a negative minute count: the
        // seconds clamp at 0 BEFORE the ceil, so a future stamp reads "0m ago", never a bumped "1m".
        val now = 1_000_000L
        val state = recordingStateFor(connected = false, liveHeartRate = null, lastSyncAtSec = now + 30, nowSec = now)
        assertEquals(RecordingState.LastSynced(0), state)
        assertEquals("Last synced 0m ago", state.title)
    }

    @Test
    fun notRecording_whenNoConnectionAndNoSync() {
        val state = recordingStateFor(connected = false, liveHeartRate = null, lastSyncAtSec = null, nowSec = 1_000_000)
        assertEquals(RecordingState.NotRecording, state)
        assertEquals("Not recording", state.title)
        assertEquals("Strap not connected. Tap to connect.", state.detail)
        assertEquals(StrandTone.Critical, state.tone)
    }

    // ── COMPONENT 4 — provenance ─────────────────────────────────────────────────────────────────────

    @Test
    fun dayOwner_noopComputedSibling_mapsToOnDevice() {
        assertEquals(FusionSource.NOOP_COMPUTED, dayOwnerSource("my-whoop-noop"))
        assertEquals("On-device", provenanceBadgeLabel(dayOwnerSource("my-whoop-noop")))
    }

    @Test
    fun dayOwner_importedStrap_mapsToWhoop() {
        assertEquals(FusionSource.WHOOP_IMPORT, dayOwnerSource("my-whoop"))
        assertEquals("Whoop", provenanceBadgeLabel(dayOwnerSource("my-whoop")))
    }

    @Test
    fun dayOwner_appleAndHealthConnect_keptSeparate() {
        assertEquals("Apple Health", provenanceBadgeLabel(dayOwnerSource("apple-health")))
        assertEquals("Health Connect", provenanceBadgeLabel(dayOwnerSource("health-connect")))
    }

    @Test
    fun dayOwner_nullDeviceId_givesNoBadge() {
        assertNull(dayOwnerSource(null))
        assertNull(provenanceBadgeLabel(null))
    }

    @Test
    fun provenanceLabel_isNeverBlanketOnDevice_forImports() {
        // Honesty: an imported source must NOT be relabelled "On-device".
        assertEquals("Whoop", provenanceBadgeLabel(FusionSource.WHOOP_IMPORT))
        assertEquals("Apple Health", provenanceBadgeLabel(FusionSource.APPLE_HEALTH))
    }

    // ── COMPONENT 4 — PER-METRIC provenance (provenanceDisplayLabel) ─────────────────────────────────────
    //
    // The Today rings each badge their OWN metric's real merge winner, resolved field-by-field per
    // WhoopRepository.mergeDaily (imported WHOOP > NOOP-computed > Apple Health). `provenanceDisplayLabel`
    // is the PURE raw-source-id → label mapper that the per-ring badge uses. It must mirror the Swift
    // `provenanceDisplayLabel(rawSource:deviceId:)` EXACTLY: the computed sibling reads "On-device", the
    // imported strap source reads "Whoop", Apple Health reads "Apple Health", and any OTHER source keeps
    // its FusionSource display name (never a blanket "on-device").

    @Test
    fun perMetric_computedSibling_readsOnDevice() {
        // The "$deviceId-noop" sibling is a score NOOP computed on THIS device from the raw strap stream.
        assertEquals("On-device", provenanceDisplayLabel("my-whoop-noop"))
    }

    @Test
    fun perMetric_importedStrap_readsWhoop() {
        // The imported strap source (the deviceId itself, normally "my-whoop") is a real WHOOP export.
        assertEquals("Whoop", provenanceDisplayLabel("my-whoop"))
    }

    @Test
    fun perMetric_importedMetricOnComputedDay_labelledHonestly() {
        // THE CONTRACT (Component 4): an imported metric winning field-by-field on an otherwise-computed
        // day must read its REAL source, never a blanket "On-device". So when the resolver returns the
        // import source for, say, "recovery" while the day's other fields are computed, the Charge badge
        // reads "Whoop" — and an Apple-Health-won metric reads "Apple Health" — not the day's deviceId.
        assertEquals("Whoop", provenanceDisplayLabel("my-whoop"))
        assertEquals("Apple Health", provenanceDisplayLabel("apple-health"))
    }

    @Test
    fun perMetric_appleHealth_readsAppleHealth() {
        assertEquals("Apple Health", provenanceDisplayLabel("apple-health"))
    }

    @Test
    fun perMetric_otherKnownSource_keepsFusionDisplayName() {
        // Any other real source keeps its FusionSource.displayName (the genuine winner), never blanketed.
        assertEquals("Health Connect", provenanceDisplayLabel("health-connect"))
        assertEquals("Mi Band", provenanceDisplayLabel("xiaomi-band"))
    }

    @Test
    fun perMetric_unknownSource_fallsBackToRawId() {
        // An unrecognised raw id falls through to itself verbatim rather than guessing a label.
        assertEquals("garmin-import", provenanceDisplayLabel("garmin-import"))
    }

    @Test
    fun perMetric_honoursACustomStrapDeviceId() {
        // The deviceId is parameterised (mirrors Swift's repo.deviceId): a custom strap id and its "-noop"
        // sibling still resolve to "Whoop" / "On-device", and the FIXED "my-whoop" import still reads "Whoop".
        assertEquals("On-device", provenanceDisplayLabel("strap-42-noop", deviceId = "strap-42"))
        assertEquals("Whoop", provenanceDisplayLabel("strap-42", deviceId = "strap-42"))
        assertEquals("Whoop", provenanceDisplayLabel("my-whoop", deviceId = "strap-42"))
    }

    @Test
    fun perMetric_crossStrapComputedSibling_stillReadsOnDevice() {
        // A "-noop" sibling banked under a DIFFERENT strap id (the user re-paired straps) is still a
        // score NOOP computed on-device. The resolver matches the "-noop" suffix, not the exact
        // "$deviceId-noop" — otherwise these rows would fall through to the raw id verbatim.
        assertEquals("On-device", provenanceDisplayLabel("whoop5-C0FF-noop", deviceId = "my-whoop"))
        assertEquals("On-device", provenanceDisplayLabel("my-whoop-noop", deviceId = "strap-42"))
    }

    @Test
    fun todayScoreProviderLabel_coversImportedAndRegisteredProviders() {
        assertEquals("Whoop", todayScoreProviderLabel(ScoreInputProvider("my-whoop", "WHOOP")))
        assertEquals("Apple Watch", todayScoreProviderLabel(ScoreInputProvider("apple-health")))
        assertEquals("Health Connect", todayScoreProviderLabel(ScoreInputProvider("health-connect")))
        assertEquals("Oura", todayScoreProviderLabel(ScoreInputProvider("oura-import")))
        assertEquals("Fitbit", todayScoreProviderLabel(ScoreInputProvider("fitbit-import")))
        assertEquals("Garmin", todayScoreProviderLabel(ScoreInputProvider("garmin-import")))
        assertEquals("Mi Band", todayScoreProviderLabel(ScoreInputProvider("xiaomi-band")))
        for (brand in com.noop.data.DeviceBrandCatalog.all.map { it.brand }) {
            assertEquals(brand, todayScoreProviderLabel(ScoreInputProvider("device-$brand", brand)))
        }
    }

    @Test
    fun todayScoreProviderLabel_unknownSourceDoesNotPretendToBeWhoop() {
        assertEquals("sensor-42", todayScoreProviderLabel(ScoreInputProvider("sensor-42")))
        assertEquals("not-a-whoop", todayScoreProviderLabel(ScoreInputProvider("not-a-whoop")))
    }

    @Test
    fun liquidHeroSourceLabel_deduplicatesOneProvider() {
        assertEquals(
            "Polar",
            heroSourceLabel(
                listOf(
                    ScoreInputProvider("polar-1", "Polar"),
                    ScoreInputProvider("polar-1", "Polar"),
                    ScoreInputProvider("polar-1", "Polar"),
                ),
            ),
        )
    }

    @Test
    fun liquidHeroSourceLabel_capsMixedProvidersAtTwoInScoreOrder() {
        assertEquals(
            "Whoop + Oura",
            heroSourceLabel(
                listOf(
                    ScoreInputProvider("my-whoop", "WHOOP"),
                    ScoreInputProvider("oura-import"),
                    ScoreInputProvider("health-connect"),
                ),
            ),
        )
    }

    @Test
    fun liquidHeroSourceLabel_usesAudienceFacingAppleWatchName() {
        assertEquals("Apple Watch", heroSourceLabel(listOf(ScoreInputProvider("apple-health"))))
    }

    @Test
    fun liquidHeroSourceLabel_hidesWhenNoScoreHasAResolvedSource() {
        assertNull(heroSourceLabel(emptyList()))
    }

    @Test
    fun liquidHeroSourceLabel_usesCarriedChargeSourceWhenTodayRecoveryIsAbsent() {
        assertEquals(
            "Whoop",
            scoreHeroSourceLabel(
                providerByMetric = emptyMap(),
                carriedRecoveryProvider = ScoreInputProvider("my-whoop", "WHOOP"),
                usesCarriedRecovery = true,
            ),
        )
    }

    @Test
    fun liquidHeroSourceLabel_keepsCurrentDayRecoveryAheadOfCarriedFallback() {
        assertEquals(
            "Oura",
            scoreHeroSourceLabel(
                providerByMetric = mapOf("recovery" to ScoreInputProvider("oura-import")),
                carriedRecoveryProvider = ScoreInputProvider("my-whoop", "WHOOP"),
                usesCarriedRecovery = true,
            ),
        )
    }

    @Test
    fun liquidHeroSourceLabel_ignoresCarriedSourceWhenChargeIsNotCarried() {
        assertNull(
            scoreHeroSourceLabel(
                providerByMetric = emptyMap(),
                carriedRecoveryProvider = ScoreInputProvider("my-whoop", "WHOOP"),
                usesCarriedRecovery = false,
            ),
        )
    }

    @Test
    fun pullToSync_onlyEnabledWhenConnectedBondedAndIdle() {
        assertTrue(todayPullToSyncEnabled(connected = true, bonded = true, backfilling = false))

        assertFalse(todayPullToSyncEnabled(connected = false, bonded = true, backfilling = false))
        assertFalse(todayPullToSyncEnabled(connected = true, bonded = false, backfilling = false))
        assertFalse(todayPullToSyncEnabled(connected = true, bonded = true, backfilling = true))
    }
}
