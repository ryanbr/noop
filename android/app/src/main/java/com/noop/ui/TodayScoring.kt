package com.noop.ui

import com.noop.analytics.BaselineState
import com.noop.analytics.Baselines
import com.noop.analytics.ChargeDriver
import com.noop.analytics.RecoveryDrivers
import com.noop.analytics.RestScorer
import com.noop.analytics.ScoreConfidence
import com.noop.data.DailyMetric
import java.time.LocalDate
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale

/**
 * The recovery baseline's real seed count while it still cold-starts, the honest "calibrating N of
 * <seed>" progress shown in place of "No Data"; null once recovery exists or the baseline has crossed
 * the seed gate. N is the HRV baseline's `nValid` from folding the SAME day-keyed, epoch-aware history
 * the recovery engine folds ([Baselines.foldHistory] with [hrvBaselineEpoch]), NOT a looser per-night
 * bounds count.
 *
 * The old count advanced on every in-range night, including nights the engine's fold DROPS after a
 * manual "Recalibrate HRV baseline" (each night dated before the epoch is discarded, not skip-and-held).
 * A genuinely-calibrating user who had >= seed old in-range nights therefore read `count >= seed -> null`,
 * and the Today score side fell through to [ScoreState.NeedsStrap] while the post-recalibration baseline
 * was still seeding (Bug B, #393 follow-up). `nValid` is the exact count Baselines.computeStatus gates
 * CALIBRATING on, so N now tracks the baseline the Charge ring rides and can never over-state it.
 * [days] is oldest->newest (same order the engine folds). Pure + unit-tested (RecoveryCalibrationTest).
 * (PR #85)
 */
internal fun recoveryCalibrationNights(
    days: List<DailyMetric>,
    hasRecovery: Boolean,
    hrvBaselineEpoch: Double,
    seed: Int = Baselines.minNightsSeed,
): Int? {
    if (hasRecovery) return null
    val n = Baselines.foldHistory(
        days.map { it.avgHrv }, days.map { it.day }, Baselines.hrvCfg, hrvBaselineEpoch,
    ).nValid
    // Include 0: a brand-new user (no banked nights) reads "Calibrating, 0 of N" on Charge, not a
    // bare "No data" that looks broken (#335). Caller gates past days to null; >= seed -> null.
    return n.takeIf { it in 0 until seed }
}

/**
 * The ordered "What shaped it" Charge driver rows for [displayDay], rebuilt PURELY from the visible
 * [days] history (the same in-memory rows the dashboard already shows, imports win field-by-field in
 * the merge), so no engine round-trip is needed and the bars match the Charge ring's own inputs. Folds
 * the whole history (oldest first) into the four-plus-one personal baselines with [Baselines.foldHistory]
 * (byte-identical to the engine's whole-history fold when no manual Recalibrate epoch is set, the common
 * case), then defers to [RecoveryDrivers.chargeDrivers], which scores each row against the SAME inputs
 * [RestScorer] reads through the Today recovery path. Empty when the displayed day can't score
 * (cold-start / missing input), so the section hides rather than faking rows. Mirrors the iOS
 * chargeDrivers wiring.
 */
internal fun recoveryChargeDrivers(
    days: List<DailyMetric>,
    displayDay: DailyMetric?,
): List<ChargeDriver> {
    val day = displayDay ?: return emptyList()
    val hrv = day.avgHrv ?: return emptyList()
    val rhr = day.restingHr?.toDouble() ?: return emptyList()

    // Whole-history fold (oldest first), exactly as the engine seeds baselines2.
    val ordered = days.sortedBy { it.day }
    val hrvBase = Baselines.foldHistory(ordered.map { it.avgHrv }, Baselines.hrvCfg)
    if (!hrvBase.usable) return emptyList()
    val rhrBase = Baselines.foldHistory(ordered.map { it.restingHr?.toDouble() }, Baselines.restingHRCfg)
    val respBase = Baselines.foldHistory(ordered.map { it.respRateBpm }, Baselines.respCfg).takeIf { it.usable }

    // sleepPerf: the Rest COMPOSITE (/100) when stages exist, else raw efficiency, the SAME derivation
    // recomputeRecovery uses, so the Sleep driver scores against the headline's own input.
    val sleepPerf = RestScorer.restFromDaily(day)?.let { it / 100.0 } ?: day.efficiency

    return RecoveryDrivers.chargeDrivers(
        hrv = hrv,
        rhr = rhr,
        resp = day.respRateBpm,
        hrvBaseline = hrvBase,
        rhrBaseline = rhrBase,
        respBaseline = respBase,
        sleepPerf = sleepPerf,
        skinTempDev = day.skinTempDevC,
    )
}

/**
 * The Charge (recovery) [ScoreConfidence] tier for [displayDay] against the HRV baseline folded from
 * [days], surfaced as the confidence dot + tier tag under the "What shaped it" rows. SURFACED, never
 * recomputed differently: it calls [ScoreConfidence.forCharge] with the SAME folded HRV baseline the
 * drivers scored against. Mirrors the iOS surfacing of the existing ScoreConfidence on the recovery screen.
 */
internal fun chargeConfidenceTier(
    days: List<DailyMetric>,
    displayDay: DailyMetric?,
): ScoreConfidence {
    val hrvBase: BaselineState =
        Baselines.foldHistory(days.sortedBy { it.day }.map { it.avgHrv }, Baselines.hrvCfg)
    return ScoreConfidence.forCharge(displayDay?.recovery, hrvBase)
}

/**
 * The most recent fully-SCORED recovery day to carry over on TODAY while tonight's recovery hasn't been
 * scored yet (#543), the ONE prior row every recovery-derived read-out (Charge ring, HRV / resting-HR /
 * respiratory / SpO2 tiles, Synthesis, Contributors, Readiness) carries over from at the rollover. Pure +
 * unit-tested (TodayMetricTilesTest). [days] is oldest->newest; the chosen row is the last with a non-null
 * recovery that isn't today's (still-null) [selectedDayKey]. Returns null unless it's today, today itself
 * isn't scored, and we're not mid-calibration (calibration owns its own copy), so past days / a scored
 * today / a calibrating today carry nothing and live behaviour is unchanged. Mirrors iOS.
 */
internal fun lastScoredRecoveryDay(
    days: List<DailyMetric>,
    selectedDayKey: String,
    isToday: Boolean,
    todayScored: Boolean,
    isCalibrating: Boolean,
    // #547 carry-over guard: the local "today" key ("yyyy-MM-dd"). A stray FUTURE-dated row (a bad strap
    // clock wrote a day past today) must NEVER be picked as "last night", that's how #547's Today header
    // read "12 Jul". Cheap belt-and-suspenders alongside the ingest gate + heal: filter candidates to
    // day <= today so even a future row that slipped through can't surface here. ISO date keys sort
    // chronologically, so a plain string compare is correct. Defaulted to MAX so an un-updated call site
    // keeps the prior behaviour; the Today call site passes the real local today.
    today: String = "9999-12-31",
): DailyMetric? {
    if (!isToday || todayScored || isCalibrating) return null
    return days.lastOrNull { it.recovery != null && it.day != selectedDayKey && it.day <= today }
}

/** A prior day's Charge carried over on TODAY (value + "Last night · <date>" caption) while tonight's
 *  recovery hasn't been scored yet (#543). Mirrors the iOS lastScoredCharge tuple. */
internal data class LastCharge(val value: Double, val caption: String)

/** "d MMM" for a stored `yyyy-MM-dd` day key, used by the carried-over Charge caption (#543). Parses
 *  the key and falls back to the raw key so the caption is never empty. Mirrors iOS lastChargeDateFmt. */
internal fun lastChargeDateLabel(dayKey: String): String =
    runCatching {
        LocalDate.parse(dayKey).format(DateTimeFormatter.ofPattern("d MMM", Locale.US))
    }.getOrDefault(dayKey)

/** Carry-over recency cap (#779): the "Last night" framing only holds when the carried scored day is
 *  within this many days of today. Mirrors iOS TodayView.carryFreshnessDays. */
internal const val CARRY_FRESHNESS_DAYS = 2L

/** True when the carried scored day is OLDER than the freshness cap (#779), which drives the "Latest
 *  sleep" relabel. Pure + unit-testable. Both keys are "yyyy-MM-dd"; an unparseable key (or non-positive gap)
 *  reads as fresh so we never over-claim staleness. [today] is today's key (carry-over is today-only),
 *  defaulted to the device's current date for the composable call sites. Mirrors iOS isCarryStale. */
internal fun isCarryStale(priorDayKey: String, today: String = LocalDate.now().toString()): Boolean =
    runCatching {
        ChronoUnit.DAYS.between(LocalDate.parse(priorDayKey), LocalDate.parse(today)) > CARRY_FRESHNESS_DAYS
    }.getOrDefault(false)

/** #977 - HONEST Rest resolution for the selected day. Today's own scored Rest wins; otherwise, ONLY on
 *  today, tail-fall-back to the last scored night, but ONLY when that night is within the carry-freshness
 *  window ([isCarryStale] == false). A live 5.0 whose sleep never scores (no overnight gravity => no
 *  `sleep_performance` point ever written) used to pin Rest to a weeks-old scored night while Charge kept
 *  advancing; gating the tail-fallback lets the Rest ring fall through to its needs-a-tracked-night state
 *  instead of freezing on a stale number. The legitimate morning carry of last night's Rest (before today
 *  scores) is preserved unchanged. Pure + unit-testable. Mirrors iOS TodayView.freshRestScore. */
internal fun freshRestScore(
    todayValue: Double?, lastDay: String?, lastValue: Double?,
    isTodaySelected: Boolean, today: String = LocalDate.now().toString(),
): Double? {
    if (todayValue != null) return todayValue
    if (!isTodaySelected || lastDay == null || lastValue == null) return null
    return if (isCarryStale(lastDay, today)) null else lastValue
}

/** The carried recovery caption stamp, keyed on that scored day's own date and its recency. Within the
 *  freshness cap it reads "Last night · <date>"; once the carried day is older than the cap (#779) it reads
 *  "Latest sleep · <date>" so a weeks-old import is never surfaced as "Last night". Shared by every carried
 *  recovery read-out so the prior-day provenance reads identically. Mirrors iOS carriedCaption. */
internal fun carriedCaption(priorDayKey: String, today: String = LocalDate.now().toString()): String {
    val prefix = if (isCarryStale(priorDayKey, today)) "Latest sleep" else "Last night"
    return "$prefix · ${lastChargeDateLabel(priorDayKey)}"
}

// Explainability layer, COMPONENTS 2, 3, 4 (spec: 2026-06-20-sleep-guidance-explainability.md)
//
// "No bare number without a STATE, a REASON, and a NEXT STEP." Every uncertain or derived read-out on
// Today gets a clear state, a plain-English reason and a next step, and we NEVER fabricate a number:
// calibrating / needs-strap show NO value, carried values are always stamped with their date, and the
// provenance badge reflects the REAL per-day merge winner. The copy here is VERBATIM and must match the
// Swift today lane word-for-word (ScoreState / RecordingState). No em-dashes anywhere.

/**
 * The honest state of one score/tile on Today, one state per score, never a bare blank. Derived from
 * baseline readiness + data presence + the #543 carry-over, so a tile that has no own value for the day
 * still says WHY and WHAT to do, and shows no fabricated number. Mirrors Swift `ScoreState` 1:1 (same
 * three cases, same [title] / [detail] copy). [Scored] carries the real value the tile renders normally;
 * the other three are the no-own-number states this layer explains.
 */
sealed class ScoreState {
    /** Today's own value exists, the tile renders the number as usual; this layer adds nothing. */
    data class Scored(val value: Double) : ScoreState()

    /** Baselines still cold-start: [nightsRemaining] more nights of wear until scores get personal.
     *  Shows NO number (calibrating never fakes a value). */
    data class Calibrating(val nightsRemaining: Int) : ScoreState()

    /** A prior scored day shown before tonight is scored (#543 carry-over), stamped with [dateLabel]
     *  ("d MMM") so the prior read is never passed off as today's. [stale] is true when that day is older
     *  than the freshness cap (#779): the carry is still shown so the recovery side isn't a bare blank, but
     *  it's relabelled "Latest sleep" so a weeks-old import is never passed off as "Last night". */
    data class CarriedLastNight(val dateLabel: String, val stale: Boolean = false) : ScoreState()

    /** No data for today at all, strap not worn / not connected / not synced. Shows NO number. */
    object NeedsStrap : ScoreState()

    /** The status title shown in the tile's state slot. VERBATIM, mirror Swift exactly. */
    val title: String
        get() = when (this) {
            is Scored -> ""
            is Calibrating -> "Calibrating"
            is CarriedLastNight -> if (stale) "Latest sleep · $dateLabel" else "Last night · $dateLabel"
            NeedsStrap -> "Needs the strap"
        }

    /**
     * #731: names WHY the countdown restarted when the user tapped "Recalibrate baseline".
     *
     * The count alone is not enough. A reporter sat at "Calibrating, 3 of 4 nights" with 15 valid HRV
     * nights on file and tapped Recalibrate again — which discards every earlier night and resets the
     * count to 0. Two weeks of that and Charge could never return. Seeing the countdown without knowing
     * their own tap caused it makes re-tapping the natural move; naming the cause breaks the loop.
     *
     * A separate whole sentence, not a fragment stitched onto the countdown. Returns null when no
     * recalibration is set, so the card is unchanged for every user who never tapped it. Pure.
     * Twin of Swift `ChargeBreakdownFormat.calibrationRestartCause`.
     */
    companion object {
        /** The recalibration epoch (seconds) as a short display day ("19 Jul"), or null when none is
         *  set. Pure - the caller reads the pref. Twin of Swift
         *  `ChargeBreakdownFormat.recalibrationDay(epoch:)`; uses the same "d MMM" pattern as the
         *  sibling day formatter in this file. (#731) */
        fun recalibrationDay(epochSeconds: Long): String? {
            if (epochSeconds <= 0L) return null
            return Instant.ofEpochSecond(epochSeconds)
                .atZone(ZoneId.systemDefault())
                .toLocalDate()
                .format(DateTimeFormatter.ofPattern("d MMM", Locale.US))
        }

        fun calibrationRestartCause(recalibratedOn: String?): String? {
            if (recalibratedOn.isNullOrEmpty()) return null
            return "Restarted when you recalibrated on $recalibratedOn — no need to tap it again."
        }
    }

    /** The one-line plain-English what-to-do. VERBATIM, mirror Swift exactly. The night(s) plural in
     *  the calibrating copy follows [nightsRemaining]. */
    val detail: String
        get() = when (this) {
            is Scored -> ""
            is Calibrating -> {
                val nights = if (nightsRemaining == 1) "night" else "nights"
                "Building your baseline. About $nightsRemaining more $nights until your scores are personal."
            }
            is CarriedLastNight ->
                // A fresh post-rollover carry tells you tonight's score is on its way; a stale carry (an
                // older import, #779) instead explains the number is from that earlier session, not today.
                if (stale) "This is your last scored session. Wear the strap overnight for a fresh score."
                else "Tonight's lands after you sleep with the strap on."
            NeedsStrap -> "No data for today. Was your strap worn and connected overnight?"
        }
}

/**
 * Resolve the honest [ScoreState] for the Today score side from the same signals the tiles already use,
 * so the explainer is the EXACT truth on screen (never a separate guess). Pure + unit-tested. Order of
 * precedence mirrors the tile waterfall:
 *   1. [todayRecovery] present                -> [ScoreState.Scored] (the tile shows its real number);
 *   2. mid-calibration ([calibratingNights])  -> [ScoreState.Calibrating] (N more nights, no number);
 *   3. a prior scored day to carry (#543)     -> [ScoreState.CarriedLastNight] (stamped with its date);
 *   4. otherwise                              -> [ScoreState.NeedsStrap] (no data, no number).
 * Mirrors Swift `scoreStateForToday`.
 */
internal fun scoreStateForToday(
    todayRecovery: Double?,
    calibratingNights: Int?,
    carriedDay: DailyMetric?,
    seed: Int = Baselines.minNightsSeed,
    today: String = LocalDate.now().toString(),
): ScoreState = when {
    todayRecovery != null -> ScoreState.Scored(todayRecovery)
    // "About N more nights" = the seed gate minus the nights banked so far, floored at 1 (zero would read
    // as "ready" when it isn't). Calibrating never fakes a value.
    calibratingNights != null -> ScoreState.Calibrating((seed - calibratingNights).coerceAtLeast(1))
    // #779: a carry older than the freshness cap is still shown (not a bare blank) but relabelled to
    // "Latest sleep" so a weeks-old import is never passed off as "Last night".
    carriedDay != null -> ScoreState.CarriedLastNight(lastChargeDateLabel(carriedDay.day), isCarryStale(carriedDay.day, today))
    else -> ScoreState.NeedsStrap
}

/**
 * The honest live-recording state of the strap, for the Today/Live chip. Derived from the BLE connection
 * + last-sync timestamp so people always know it's working, or know it isn't and why. Mirrors Swift
 * `RecordingState` 1:1 (same three cases, same [title] / [detail] copy, same [tone]).
 */
sealed class RecordingState {
    /** The strap is connected and saving data live. */
    object Recording : RecordingState()

    /** Not live now, but synced [minutesAgo] minutes ago, an honest "how fresh is it". */
    data class LastSynced(val minutesAgo: Long) : RecordingState()

    /** No connection and nothing recent to fall back on. */
    object NotRecording : RecordingState()

    /** #580, a connected WHOOP 5/MG streaming live HR fine, but its firmware hands over no history
     *  offload yet. NOT the WHOOP-4 "not recording" failure: the link is live, history sync is just
     *  experimental on 5.0. Surfaced from `LiveState.historySyncExperimental`, overriding the resolver. */
    object HistoryExperimental : RecordingState()

    /** #612, connected with no live HR AND no evidence data is actually flowing — either this is the
     *  strap's first-ever pairing (never once synced) or a WHOOP-4/generic strap whose last several
     *  offloads all came back empty ([LiveState.sustainedEmptyOffload]). Distinct from [NotRecording]:
     *  the link genuinely IS up, so claiming "Strap not connected" would be false. */
    object ConnectedNoData : RecordingState()

    /** The chip's status word. VERBATIM, mirror Swift exactly. */
    val title: String
        get() = when (this) {
            Recording -> "Recording"
            is LastSynced -> "Last synced ${minutesAgo}m ago"
            NotRecording -> "Not recording"
            HistoryExperimental -> "Connected"
            ConnectedNoData -> "Connected"
        }

    /** The chip's one-line detail. VERBATIM, mirror Swift exactly. */
    val detail: String
        get() = when (this) {
            Recording -> "Your strap is connected and saving data."
            is LastSynced -> "Reconnect to pull the latest."
            NotRecording -> "Strap not connected. Tap to connect."
            HistoryExperimental -> "History sync is experimental on 5.0."
            ConnectedNoData -> "No live heart rate or synced history yet this session."
        }

    /** Chip hue: live recording reads positive (gold/green dot), a stale-but-recent sync reads neutral,
     *  not-recording reads critical so a dropped link is obvious; the 5.0 experimental-history state and
     *  the connected-no-data state are both connected so they read accent, not critical. */
    val tone: StrandTone
        get() = when (this) {
            Recording -> StrandTone.Positive
            is LastSynced -> StrandTone.Neutral
            NotRecording -> StrandTone.Critical
            HistoryExperimental -> StrandTone.Accent
            ConnectedNoData -> StrandTone.Accent
        }
}

/**
 * Resolve the honest [RecordingState] from the live BLE state + last-sync timestamp. Pure + unit-tested.
 *   - connected AND a live HR is streaming  -> [RecordingState.Recording] (it really is saving data);
 *   - connected, no live HR, AND (never synced OR [sustainedEmptyOffload]) -> [RecordingState.ConnectedNoData]
 *                                              (#612 — the link IS up, so "not connected" would be false);
 *   - else a [lastSyncAtSec] this session    -> [RecordingState.LastSynced] (minutes since, clamped >= 0,
 *                                              ROUNDED UP so a 30s-old sync reads "1m ago" not "0m ago");
 *   - else                                   -> [RecordingState.NotRecording].
 * "Recording" requires BOTH a connection AND a live heart-rate sample so a bonded-but-silent link can't
 * claim it's saving data. [nowSec] is unix seconds (injected so the math is testable). Mirrors Swift
 * `RecordingState.resolve`.
 */
internal fun recordingStateFor(
    connected: Boolean,
    liveHeartRate: Int?,
    lastSyncAtSec: Long?,
    nowSec: Long,
    sustainedEmptyOffload: Boolean = false,
): RecordingState = when {
    connected && liveHeartRate != null -> RecordingState.Recording
    connected && liveHeartRate == null && (lastSyncAtSec == null || sustainedEmptyOffload) ->
        RecordingState.ConnectedNoData
    lastSyncAtSec != null -> {
        // Clamp at 0 (a sync stamped slightly in the future from strap-clock skew can't read negative)
        // then ROUND UP so a 30-second-old sync reads "1m ago", never "0m ago", matches the Swift
        // `RecordingState.resolve` ceil. ceil(secs / 60) == (secs + 59) / 60 for non-negative longs.
        val secs = (nowSec - lastSyncAtSec).coerceAtLeast(0L)
        RecordingState.LastSynced((secs + 59L) / 60L)
    }
    else -> RecordingState.NotRecording
}

/** #245: the sync-status state the Today top bar's `SyncStatusChip` composable renders. Mirrors Swift
 *  `SyncChipState` 1:1 (same four cases, same priority order) so the twin can't drift on WHEN to show
 *  what. THREE non-hidden states so the ABSENCE of active syncing reads as "caught up", not "missing
 *  indicator": actively offloading -> [Syncing]; idle with a known last-sync -> [Synced]; a 5/MG whose
 *  history sync is experimental (live-connected, no completed offload yet) -> [ExperimentalLive].
 *  [Hidden] only on a true cold start (the building-scores note owns that case). Previously this
 *  priority order lived inline inside the `@Composable`, where it could not be unit-tested. */
sealed class SyncChipState {
    data class Syncing(val chunks: Int) : SyncChipState()
    data class Synced(val agoText: String) : SyncChipState()
    object ExperimentalLive : SyncChipState()
    object Hidden : SyncChipState()

    companion object {
        /** Pure + unit-tested. Mirrors Swift `SyncChipState.resolve` exactly: backfilling wins over a
         *  known last-sync, which wins over the 5/MG experimental fallback.
         *
         *  [nowSec] (unix seconds) and [nowLabel] (the already-translated "now" word) are PARAMETERS
         *  rather than things this function reaches for, which is what keeps "pure" true. Resolving the
         *  word in here instead cost the twin its own test: it goes through `NoopApplication`, which
         *  throws `IllegalStateException: NoopApplication is not attached` under a plain JVM unit test —
         *  these run without Robolectric, so no Application is ever attached. Only the `< 60s` branch of
         *  [shortSyncAgo] wants a word, so the failure was invisible until a case landed in it. Same
         *  injected-clock style as [recordingStateFor] just above.
         *
         *  Swift's twin keeps both inside its own `shortAgo` and is fine there — XCTest runs against a
         *  real bundle, so `String(localized:)` resolves. The two SIGNATURES therefore differ on purpose;
         *  the decision they encode does not. Don't "restore parity" by moving the lookup back in here. */
        fun resolve(
            backfilling: Boolean,
            chunks: Int,
            lastSyncAtSec: Long?,
            historySyncExperimental: Boolean,
            nowSec: Long,
            nowLabel: String,
        ): SyncChipState = when {
            backfilling -> Syncing(chunks)
            lastSyncAtSec != null -> Synced(shortSyncAgo(lastSyncAtSec, nowSec, nowLabel))
            historySyncExperimental -> ExperimentalLive
            else -> Hidden
        }
    }
}

/** Compact relative age for the header chip ("now" / "Nm" / "Nh" / "Nd") from a unix-SECONDS timestamp —
 *  deliberately terse. "now" is the only word in here (the rest is digits + a unit letter), so it's the
 *  only piece that needs a catalog entry to translate; it arrives as [nowLabel], resolved by the
 *  composable that owns the chip, so the bucketing stays framework-free. [nowSec] is unix seconds,
 *  injected for the same reason. Mirrors the iOS `SyncChipState.shortAgo`. */
internal fun shortSyncAgo(unixSec: Long, nowSec: Long, nowLabel: String): String {
    val secs = (nowSec - unixSec).coerceAtLeast(0)
    return when {
        secs < 60 -> nowLabel
        secs < 3600 -> "${secs / 60}m"
        secs < 86_400 -> "${secs / 3600}h"
        else -> "${secs / 86_400}d"
    }
}

/** Whether this night's sleep staging is low-confidence, using the core [ScoreConfidence] rule. */
internal fun restStageLowConfidence(d: DailyMetric?): Boolean {
    val asleepMin = d?.totalSleepMin ?: return false
    val efficiency = d.efficiency ?: return false
    val restorativeMin = (d.deepMin ?: 0.0) + (d.remMin ?: 0.0)
    val hasStaged = restorativeMin > 0.0
    if (ScoreConfidence.forRest(hasSession = true, hasStagedSleep = hasStaged) != ScoreConfidence.SOLID) {
        return false
    }
    return ScoreConfidence.forRest(
        hasSession = true,
        hasStagedSleep = hasStaged,
        asleepSeconds = asleepMin * 60.0,
        restorativeSeconds = restorativeMin * 60.0,
        efficiency = efficiency,
    ) == ScoreConfidence.BUILDING
}

/** Short "it's coming, not broken" caption for an unscored tile on today only. */
internal fun buildingHint(metric: KeyMetric, isToday: Boolean): String? {
    if (!isToday) return null
    return when (metric) {
        KeyMetric.REST -> "Building, wear it tonight"
        KeyMetric.EFFORT -> "Building, moves as you do"
        KeyMetric.CHARGE -> "Building, wear it tonight"
        KeyMetric.BLOOD_OXYGEN -> "Building, wear it tonight"
        KeyMetric.STEPS -> "Building, moves as you do"
        else -> null
    }
}
