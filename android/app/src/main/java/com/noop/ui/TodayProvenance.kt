package com.noop.ui

import androidx.annotation.StringRes
import androidx.compose.ui.graphics.Color
import com.noop.R
import com.noop.analytics.FusionSource
import com.noop.analytics.ReadinessEngine
import com.noop.ble.WhoopBleClient
import com.noop.data.WhoopRepository
import com.noop.data.Vo2MaxEstimator

/**
 * The Today provenance label for the day's REAL merge winner, extends the existing By-Day badge
 * vocabulary consistently. NOOP-computed reads "On-device" (the spec's wording for the By-Day badge,
 * versus the FusedRecord screen's terser "NOOP"), an imported strap day reads "Whoop", and a phone
 * aggregate reads "Apple Health" / "Health Connect". Null when no source owns the day (nothing to
 * stamp). Mirrors the Swift `provenanceBadgeLabel`.
 */
internal fun dayOwnerSource(deviceId: String?): FusionSource? = when {
    deviceId == null -> null
    deviceId.endsWith("-noop") -> FusionSource.NOOP_COMPUTED
    deviceId == WhoopRepository.APPLE_HEALTH_SOURCE -> FusionSource.APPLE_HEALTH
    deviceId == WhoopRepository.HEALTH_CONNECT_SOURCE -> FusionSource.HEALTH_CONNECT
    // The merged Today rows carry the imported strap deviceId ("my-whoop") on days a real WHOOP import
    // covers, and the "-noop" sibling otherwise; any other strap deviceId is still an imported strap day.
    else -> FusionSource.WHOOP_IMPORT
}

internal sealed interface DisplayText {
    data class Resource(@StringRes val id: Int, val args: List<Any> = emptyList()) : DisplayText
    data class Dynamic(val value: String) : DisplayText
}

internal fun provenanceBadgeLabel(owner: FusionSource?): DisplayText? = when (owner) {
    FusionSource.NOOP_COMPUTED -> DisplayText.Resource(R.string.today_source_on_device)
    FusionSource.WHOOP_IMPORT -> DisplayText.Resource(R.string.today_source_whoop)
    FusionSource.APPLE_HEALTH -> DisplayText.Resource(R.string.today_source_apple_health)
    FusionSource.HEALTH_CONNECT -> DisplayText.Resource(R.string.today_source_health_connect)
    FusionSource.XIAOMI_BAND -> DisplayText.Resource(R.string.today_source_mi_band)
    FusionSource.NUTRITION_CSV -> DisplayText.Resource(R.string.today_source_nutrition)
    FusionSource.LOCAL_CACHE -> DisplayText.Resource(R.string.today_source_cached)
    null -> null
}

/**
 * PURE mapper (unit-tested), a RAW resolver source id (as returned by [WhoopRepository.resolvedSeries]'s
 * winning point, e.g. "my-whoop", "my-whoop-noop", "apple-health") onto the spec's provenance labels,
 * given the strap's real [deviceId]. ANY NOOP-computed strap sibling (a "-noop"-suffixed id, not just the
 * active strap's) reads "On-device" - matching by suffix rather than "$deviceId-noop" so a computed row
 * from a non-active strap can't fall through to [FusionSource.NOOP_COMPUTED]'s raw "NOOP" displayName
 * (the internal id must never surface); the imported strap source ([deviceId], normally "my-whoop") reads
 * "Whoop"; the Apple-Health source reads "Apple Health". Any other real source (Health Connect, Mi Band,
 * nutrition) keeps its [FusionSource.displayName], still the genuine merge winner, never a blanket claim.
 * Mirrors the Swift `provenanceDisplayLabel` EXACTLY. This is the PER-METRIC mapper the Today rings use;
 * the day-level [dayOwnerSource]/[provenanceBadgeLabel] pair stays for the legacy By-Day vocabulary.
 */
internal fun provenanceDisplayLabel(
    rawSource: String,
    deviceId: String = WhoopRepository.WHOOP_SOURCE,
): DisplayText {
    if (rawSource.startsWith(VO2_MAX_ATTRIBUTION_PREFIX)) {
        val raw = rawSource.removePrefix(VO2_MAX_ATTRIBUTION_PREFIX)
        return DisplayText.Resource(vo2MaxAttributionLabelRes(Vo2MaxEstimator.fromProvenanceId(raw)))
    }
    // #103/queue-11a follow-up: the spo2 candidate-fallback rows in the vital-detail readings table
    // (see [SPO2_CANDIDATE_ATTRIBUTION_SOURCE]) must read "strap estimate (unverified)" — the SAME
    // string every other candidate-fallback surface uses — never a device name, which would
    // misrepresent an unvalidated estimate as a calibrated reading in this table's Source column.
    if (rawSource == SPO2_CANDIDATE_ATTRIBUTION_SOURCE) {
        return DisplayText.Resource(R.string.spo2_strap_estimate_caption)
    }
    if (rawSource.endsWith("-noop")) return DisplayText.Resource(R.string.today_source_on_device)
    if (rawSource == deviceId || rawSource == WhoopRepository.WHOOP_SOURCE) return DisplayText.Resource(R.string.today_source_whoop)
    if (rawSource == WhoopRepository.APPLE_HEALTH_SOURCE) return DisplayText.Resource(R.string.today_source_apple_health)
    // Fall back to the FusionSource display name for any other known source; else the raw id verbatim.
    return FusionSource.entries.firstOrNull { it.id == rawSource }
        ?.let { source -> provenanceBadgeLabel(source) }
        ?: DisplayText.Dynamic(rawSource)
}

@StringRes
internal fun vo2MaxAttributionLabelRes(estimator: Vo2MaxEstimator?): Int = when (estimator) {
    Vo2MaxEstimator.NES -> R.string.vo2max_method_nes
    Vo2MaxEstimator.UTH -> R.string.vo2max_method_uth
    null -> R.string.vo2max_method_unknown
}

/** Today uses the audience-facing sensor name for Apple Health scores, matching the Swift Today lane. */
internal fun todayProvenanceChipLabel(
    rawSource: String,
    deviceId: String = WhoopRepository.WHOOP_SOURCE,
): DisplayText = if (rawSource == WhoopRepository.APPLE_HEALTH_SOURCE) {
    DisplayText.Resource(R.string.today_source_apple_watch)
} else {
    provenanceDisplayLabel(rawSource, deviceId)
}

/** The sensor/import provider whose inputs produced a Today score. */
internal data class ScoreInputProvider(val sourceId: String, val brand: String? = null)

/** Provider-facing hero wording. Registered brands cover live devices; stable import ids cover imports. */
internal fun todayScoreProviderLabel(provider: ScoreInputProvider): DisplayText {
    val source = provider.sourceId.lowercase()
    return when (source) {
        WhoopRepository.APPLE_HEALTH_SOURCE -> DisplayText.Resource(R.string.today_source_apple_watch)
        WhoopRepository.HEALTH_CONNECT_SOURCE -> DisplayText.Resource(R.string.today_source_health_connect)
        "oura-import", "oura-api" -> DisplayText.Resource(R.string.today_source_oura)
        "fitbit-import" -> DisplayText.Resource(R.string.today_source_fitbit)
        "garmin-import" -> DisplayText.Resource(R.string.today_source_garmin)
        "xiaomi-band" -> DisplayText.Resource(R.string.today_source_mi_band)
        WhoopRepository.ACTIVITY_FILE_SOURCE -> DisplayText.Resource(R.string.today_source_workout_files)
        else -> {
            val brand = provider.brand?.trim().orEmpty()
            when {
                brand.equals(FusionSource.WHOOP_IMPORT.displayName, ignoreCase = true) -> DisplayText.Resource(R.string.today_source_whoop)
                brand.isNotEmpty() -> DisplayText.Dynamic(brand)
                source == WhoopRepository.WHOOP_SOURCE -> DisplayText.Resource(R.string.today_source_whoop)
                else -> FusionSource.entries.firstOrNull { it.id == provider.sourceId }
                    ?.let { provenanceBadgeLabel(it) }
                    ?: DisplayText.Dynamic(provider.sourceId)
            }
        }
    }
}

/**
 * One compact provider label for the score hero. Providers arrive in Charge / Effort / Rest order;
 * identical display names collapse and mixed winners are capped at two so the badge stays readable.
 * Mirrors LiquidTodayView.heroSourceLabel value-for-value.
 */
internal fun heroSourceLabel(
    providers: List<ScoreInputProvider>,
): List<DisplayText> {
    val labels = LinkedHashSet<DisplayText>()
    for (provider in providers) {
        labels.add(todayScoreProviderLabel(provider))
        if (labels.size == 2) break
    }
    return labels.toList()
}

/**
 * Source label for the three visible hero scores. Today can show a carried Charge from the previous
 * scored night while today's recovery is still absent (#543); in that state the selected-day
 * "recovery" provider is also absent, so use the carried night's resolved recovery provider instead of
 * letting the card badge omit or misrepresent the visible Charge (#390).
 */
internal fun scoreHeroSourceLabel(
    providerByMetric: Map<String, ScoreInputProvider>,
    carriedRecoveryProvider: ScoreInputProvider?,
    usesCarriedRecovery: Boolean,
): List<DisplayText> {
    val recoveryProvider = providerByMetric["recovery"]
        ?: if (usesCarriedRecovery) carriedRecoveryProvider else null
    return heroSourceLabel(
        providers = listOfNotNull(
            recoveryProvider,
            providerByMetric["strain"],
            providerByMetric["sleep_performance"],
        ),
    )
}

/**
 * Today pull-to-sync mirrors the BLE client's manual-sync guard, so the gesture never starts a sync while
 * disconnected, still bonding, or already offloading. Kept pure for the UI-specific contract test.
 *
 * [historyReady] is the second half of that mirror and was missing. `canRequestSync` checks `bonded`,
 * which on a 5/MG is set by the live-HR path — true on a strap that has never completed a handshake. So
 * the gesture was offered, accepted, and then refused by `beginBackfill`'s own `connectHandshakeDone`
 * gate with nothing shown: a control that ran and did nothing, reported four times as "refresh doesn't
 * work". It was working; it was silent.
 *
 * Adding the client's OWN precondition cannot disable a sync that would have run, because
 * `beginBackfill` already requires exactly this flag before it will request an offload. The gesture now
 * goes away precisely when the sync would have been declined anyway — including on a WHOOP 4.0 whose
 * bond has not landed yet, which a strap-family check would have missed.
 */
internal fun todayPullToSyncEnabled(
    connected: Boolean,
    bonded: Boolean,
    backfilling: Boolean,
    historyReady: Boolean,
): Boolean = WhoopBleClient.canRequestSync(connected, bonded, backfilling) && historyReady

/** The tint for a per-metric provenance badge, keyed on the resolved LABEL, gold for Whoop, cyan for
 *  Apple Health, the positive status hue for on-device (and anything else). Matches the Data Sources
 *  footer + the Swift `provenanceTint` so the same source reads the same colour on Today. */
internal fun provenanceLabelTint(label: DisplayText): Color = when ((label as? DisplayText.Resource)?.id) {
    R.string.today_source_whoop -> Palette.accent
    R.string.today_source_apple_health -> Palette.metricCyan
    R.string.today_source_health_connect -> Palette.metricPurple
    else -> Palette.statusPositive
}

/**
 * S4 (#205): the one-word readiness read kept on the hero (Push / Maintain / Rest) now the full Readiness
 * card folded into the Charge-ring tap. PURE mapping of the existing [ReadinessEngine.Level]; INSUFFICIENT
 * returns null (the hero then shows no word, matching the old card hiding itself). Byte-identical twin of
 * the Swift TodayView.readinessWord.
 */
@StringRes
internal fun readinessWord(level: ReadinessEngine.Level): Int? = when (level) {
    ReadinessEngine.Level.PRIMED -> R.string.today_readiness_push
    ReadinessEngine.Level.BALANCED -> R.string.today_readiness_maintain
    ReadinessEngine.Level.STRAINED -> R.string.today_readiness_rest
    ReadinessEngine.Level.RUNDOWN -> R.string.today_readiness_rest
    ReadinessEngine.Level.INSUFFICIENT -> null
}

/**
 * S5: the collapsed Data Sources footer summary, "Synced from: WHOOP, Apple Watch", listing only sources
 * with data (Apple Health reads as "Apple Watch", the device the audience knows), or "No sources yet".
 * PURE + unit-tested. Twin of the Swift TodayView.syncedFromSummary, plus the Android-only
 * hasHealthConnect source - Health Connect is named for what it is, never folded under "Apple Watch"
 * (issue #176).
 */
internal fun syncedFromSummary(hasWhoop: Boolean, hasApple: Boolean, hasHealthConnect: Boolean = false, hasXiaomi: Boolean): List<DisplayText> {
    val names = buildList {
        if (hasWhoop) add(DisplayText.Resource(R.string.today_source_whoop))
        if (hasApple) add(DisplayText.Resource(R.string.today_source_apple_watch))
        if (hasHealthConnect) add(DisplayText.Resource(R.string.today_source_health_connect))
        if (hasXiaomi) add(DisplayText.Resource(R.string.today_source_mi_band))
    }
    return names
}
