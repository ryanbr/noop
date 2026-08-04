package com.noop.ui

import com.noop.analytics.AnalyticsEngine
import com.noop.analytics.SleepStageTotals
import com.noop.data.DailyMetric
import com.noop.data.SleepSession
import java.util.TimeZone

/**
 * Pick the night for the DAY [offset] stops back from the most recent (0 = latest). [navDays]
 * is grouped-by-calendar-day, newest first, so the chevrons step by DAY not by flat session
 * index — a WHOOP 4.0 user with a single detected night has exactly one stop (both arrows
 * correctly disabled) instead of arrows that move within naps/split blocks of one night and
 * appear stuck (#57/#59). Mirrors iOS SleepView.decodedNight(at:)/navDays.
 *
 * The day's REPRESENTATIVE session is its MAIN sleep block — the LONGEST block, preferring an
 * OVERNIGHT-anchored onset (#518). A day can hold an overnight AND an afternoon nap (both end on
 * the same calendar day, so both bucket here); the OLD `maxByOrNull { endTs }` picked the
 * latest-ending block, which is the afternoon nap — so the overnight vanished from the Sleep tab.
 * Picking the longest overnight block fixes it; the other blocks are carried as `napBlocks` for
 * the naps card. The day key tries UTC then local-tz attribution of the MAIN block's wake — imported
 * DailyMetric.day is local-tz while dayString is UTC, so a near-midnight-UTC wake needs the second
 * key; both derive from THIS night's endTs, never another night. (#160, #518)
 */
internal fun selectNight(
    navDays: List<List<SleepSession>>,
    days: List<DailyMetric>,
    offset: Int,
    // The LEARNED habitual midsleep the engine threaded into the daily total, so the hero, the naps split,
    // and the edit target pick the SAME block the analytics rollup did — for a shift/late sleeper too. null
    // = cold-start band. (#547)
    habitualMidsleepSec: Long? = null,
    // Per-epoch MOTION keyed by detected startTs (#407). The group's fragments' series are concatenated in
    // group order onto HeroNight.groupMotion. Empty/absent → honest empty state. Default empty so existing
    // callers/tests compile unchanged.
    motionByStart: Map<Long, List<Double>> = emptyMap(),
): HeroNight? {
    if (navDays.isEmpty()) return null
    val dayIdx = offset.coerceIn(0, navDays.size - 1)
    val blocks = navDays[dayIdx]
    val session = mainSleepBlock(blocks, habitualMidsleepSec) ?: return null
    // The day's MAIN sleep is the bridged main-night GROUP (#561): a briefly-interrupted / biphasic night's
    // sibling fragments belong to the night, NOT the naps card — only blocks OUTSIDE the group are naps.
    // `session` stays the single WINNING block (the durable-edit anchor at SleepTimeEditor), but the group
    // drives the naps split, the hero's summed stage minutes, and the full-night hypnogram, so the tab
    // matches AnalyticsEngine.analyzeDay instead of rendering phantom naps (#555). A single-block day is
    // byte-identical to the prior behaviour. (#518/#555/#561)
    val group = mainSleepGroup(blocks, habitualMidsleepSec)
    val groupStarts = group.map { it.startTs }.toHashSet()
    val napBlocks = blocks.filter { it.startTs !in groupStarts }
        .sortedBy { it.effectiveStartTs }
    // Drop a spurious leading pre-sleep awake stub from the hero's RECONSTRUCTION so the hypnogram and the
    // summed minutes start where the displayed bedtime (the main block's onset) does (#736). A night can
    // record a brief, all-awake pre-onset block (e.g. lying in bed before sleep); the gap-bridge folds it
    // into the group, so the chart drew sleep beginning before the labelled "Asleep" time. We only drop a
    // BRIEF, essentially-sleepless leading fragment that also sits before the main block, so a genuine first
    // sleep fragment of an interrupted/biphasic night is never lost. The stub still rides in `groupStarts`
    // above, so it is never mislabelled as a nap. `session` (the edit anchor) is already the main block, so
    // the bedtime label and the pencil were aligned — this aligns the chart to that same bedtime. (#736/#555)
    val onsetTsForHero = session.effectiveStartTs
    // #259: reference size for the "minor relative to the main block" stub test = the largest asleep span in
    // the group (≈ the main block). A genuine biphasic first sleep is comparable to it and is kept; only a
    // small stray lead carrying a few minutes of sleep is dropped, so the onset no longer jumps hours early.
    val groupRefAsleepMin = group.maxOfOrNull { frag ->
        decodedAsleepMinutes(frag.stagesJSON, frag.effectiveStartTs)
    } ?: 0.0
    val heroGroup = group.dropWhile {
        it.effectiveStartTs < onsetTsForHero && isPreOnsetAwakeStub(it, groupRefAsleepMin)
    }
    val utcKey = AnalyticsEngine.dayString(session.endTs)
    val localKey = localDayString(session.endTs)
    val dayKey = listOf(utcKey, localKey).firstOrNull { key ->
        days.any { it.day == key && (it.deepMin ?: 0.0) + (it.remMin ?: 0.0) + (it.lightMin ?: 0.0) > 0.0 }
    } ?: utcKey
    // Lay every fragment's persisted segments end-to-end so a biphasic night draws as one continuous
    // hypnogram, and SUM their stage minutes for the hero. Built from `heroGroup` (the group minus a leading
    // spurious stub, #736) so the chart and minutes start at the displayed bedtime. Null for a single-block
    // hero → prior behaviour.
    // #259: clamp each fragment's timeline to its effective onset too (matching the stage-minute clamp
    // and the iOS decodeSegments clamp), so the hypnogram starts where the edited bedtime does instead of
    // drawing pre-onset bars that contradict the clamped asleep total. No-op for non-edited nights.
    val groupSegmentsRaw = if (heroGroup.size > 1) {
        heroGroup.flatMap { parsePersistedSegments(SleepStageTotals.clampStagesToOnset(it.stagesJSON, it.effectiveStartTs)).orEmpty() }
            .sortedBy { it.start }
            .takeIf { it.size >= 2 }
    } else null
    // #364: draw each inter-fragment wake seam as an explicit wake segment in the full-night
    // hypnogram, so the merged night has no silent hole where the user was up — matching what the
    // Health Connect export now writes. TIMELINE only: the seam is deliberately NOT added to the
    // stage MINUTES (sumGroupStages) or groupInBedMin below — those keep the fragment-only
    // accounting (asleep ≤ in-bed, see the #561 comment), and iOS mergeDay applies the same split.
    val groupSegments = groupSegmentsRaw?.let { segs ->
        val seams = heroGroup.zipWithNext().mapNotNull { (prev, next) ->
            if (next.effectiveStartTs > prev.endTs)
                PersistedSegment(prev.endTs, next.effectiveStartTs, "wake") else null
        }
        (segs + seams).sortedBy { it.start }
    }
    val groupStages = if (heroGroup.size > 1) sumGroupStages(heroGroup) else null
    val segments = (groupSegmentsRaw ?: parsePersistedSegments(SleepStageTotals.clampStagesToOnset(session.stagesJSON, session.effectiveStartTs)))
        ?.map { seg -> seg.stage to ((seg.end - seg.start) / 60f) }
    // #407: lay the GROUP's per-epoch motion fragment-by-fragment in `heroGroup` order (the same order
    // `groupSegments` lays the stage timeline), reading the already-chosen group's stored series. The
    // detected key (`startTs`) is the motion store's key. A fragment with no series contributes nothing; if
    // NO fragment has one, `groupMotion` is empty → honest empty state.
    val groupMotion = heroGroup.flatMap { motionByStart[it.startTs].orEmpty() }
    // #736 parity: the displayed bedtime must match where the hypnogram starts. The chart is built from
    // heroGroup (first non-stub fragment onward), so label from THAT fragment's onset (mirrors Swift
    // nightOnsetTs / synth.startTs), closed by the group's latest wake. `session` stays the edit anchor only.
    val heroOnsetTs = heroGroup.firstOrNull()?.effectiveStartTs ?: session.effectiveStartTs
    val heroWakeTs = heroGroup.maxOfOrNull { it.endTs } ?: session.endTs
    // #561: whole-group time-in-bed (minutes) — fragment windows summed, gaps excluded — so the hero
    // subtitle matches the multi-fragment stage total it is shown with. Single-block days stay null.
    val groupInBedMin = if (heroGroup.size > 1) {
        heroGroup.sumOf { (it.endTs - it.effectiveStartTs).coerceAtLeast(0L) } / 60.0
    } else null
    return HeroNight(session, dayKey, segments, clockLabelFor(heroOnsetTs, heroWakeTs), napBlocks, groupStages,
        groupSegments, groupMotion, groupInBedMin, heroOnsetTs, heroWakeTs)
}

/**
 * The day's MAIN sleep block — the night people mean by "last night" — resolved by the SINGLE shared
 * selector ([SleepStageTotals.mainNightIndex]) the analytics rollup uses: the LEARNED-TIMING score
 * (asleep span + alignment bonus on each block's EFFECTIVE onset) rather than a re-derived overnight
 * gate, so the hero, the edit affordance, the analytics total, and the Sleep tab ALL resolve to the
 * identical block (the whole point of #525/#547). Scores on each block's EFFECTIVE onset (what the user
 * sees) and returns the owning session. This is the BARE single-block pick (the durable-edit anchor): the
 * HERO display and the nap split use [mainSleepGroup], which bridges the winner's adjacent fragments into
 * ONE night (#561) so a biphasic night isn't shown as phantom naps (#555). [habitualMidsleepSec] is the
 * SAME learned value the engine threads into the
 * persisted totals (loaded via `vm.repo.habitualMidsleepSec`), so a shift/late sleeper's hero and analytics
 * total resolve to the identical block; null keeps the cold-start overnight-band bonus, which matches a
 * cold-start engine run. Mirrors iOS SleepView.mainNightSession. (#518/#547)
 */
internal fun mainSleepBlock(blocks: List<SleepSession>, habitualMidsleepSec: Long? = null): SleepSession? {
    if (blocks.isEmpty()) return null
    val idx = SleepStageTotals.mainNightIndex(
        blocks.map { SleepStageTotals.NightBlock(it.effectiveStartTs, it.endTs) },
        uiTzOffsetSec(),
        habitualMidsleepSec,
    ) ?: return null
    return blocks[idx]
}

/**
 * The day's MAIN-night GROUP — the winning block PLUS any adjacent fragments bridged into it (a wake gap
 * shorter than [SleepStageTotals.gapBridgeMaxMin]), so a briefly-interrupted / biphasic night reads as ONE
 * continuous sleep exactly the way AnalyticsEngine.analyzeDay rolls it up for the daily total (#561). The
 * hero aggregates this whole group and ONLY blocks outside it are naps; without it the tab used the
 * un-bridged single-block pick and rendered the bridged siblings as phantom naps (#555). A night with no
 * bridgeable gap collapses to the single block [mainSleepBlock] picks. Returns ascending by effective
 * onset. Mirrors iOS SleepView.mainNightGroup. (#561/#555)
 */
internal fun mainSleepGroup(blocks: List<SleepSession>, habitualMidsleepSec: Long? = null): List<SleepSession> {
    val idx = SleepStageTotals.mainNightGroupIndices(
        blocks.map { SleepStageTotals.NightBlock(it.effectiveStartTs, it.endTs) },
        uiTzOffsetSec(),
        habitualMidsleepSec,
    ) ?: return emptyList()
    return idx.map { blocks[it] }.sortedBy { it.effectiveStartTs }
}

/**
 * Actual asleep minutes in blocks outside each day's canonical main-night group. The Sleep screen's
 * session union has already removed cross-namespace duplicates; this helper only applies the same
 * main-vs-nap classification the hero uses and decodes the persisted stage minutes. A stage-less nap
 * contributes nothing rather than substituting its in-bed window. Mirrors `SleepView.napSleepMinutesByDay`.
 */
internal fun napSleepMinutesByDay(
    sleeps: List<SleepSession>,
    habitualMidsleepSec: Long? = null,
): Map<String, Double> = sleeps
    .groupBy { localDayString(it.endTs) }
    .mapValues { (_, blocks) ->
        val mainStarts = mainSleepGroup(blocks, habitualMidsleepSec).mapTo(hashSetOf()) { it.startTs }
        blocks.asSequence()
            .filter { it.startTs !in mainStarts }
            .sumOf { decodedAsleepMinutes(it.stagesJSON, it.effectiveStartTs) }
    }

/**
 * The day's main-night bridged SPAN (onset -> wake), the same window [mainSleepGroup] bridges into one
 * continuous night. The ONE canonical bed/wake read every glance screen (Coupled, Today's HR band) should
 * show -- never a screen-local "freshest" or "longest single block" heuristic, which can silently disagree
 * with each other and with the Sleep tab hero on a night stored as more than one block (#294). null only
 * when `blocks` has nothing bridgeable. Mirrors iOS SleepView.mainNightSpan.
 */
internal fun mainSleepSpan(blocks: List<SleepSession>, habitualMidsleepSec: Long? = null): Pair<Long, Long>? {
    val group = mainSleepGroup(blocks, habitualMidsleepSec)
    val first = group.firstOrNull() ?: return null
    val last = group.lastOrNull() ?: return null
    return first.effectiveStartTs to last.endTs
}

/**
 * The trailing [limit] nights' bridged bed→wake SPANS — one per local calendar day of wake, grouped the
 * SAME way [navDays] groups the browsable day list (`localDayString(it.endTs)`), then resolved through
 * the SAME bridged selector ([mainSleepSpan]) the hero uses. Before this, [SleepConsistencyCard] iterated
 * raw sessions directly: a briefly-interrupted / biphasic night's night-tail fragment (bridged into the
 * hero's ONE night) still drew as its OWN low bar, got counted as an extra "night", and skewed the bed/wake
 * SD and consistency score (#699). A day whose only blocks are naps (no bridgeable main sleep) drops out via
 * `mapNotNull`, matching [mainSleepSpan]'s null. Ascending by day, oldest first (matches the prior
 * `sleeps.takeLast(limit)` ordering assumption).
 */
internal fun consistencyNightSpans(
    sleeps: List<SleepSession>,
    habitualMidsleepSec: Long? = null,
    limit: Int = 14,
): List<Pair<Long, Long>> =
    sleeps.groupBy { localDayString(it.endTs) }
        .toSortedMap()
        .values
        .mapNotNull { blocks -> mainSleepSpan(blocks.sortedBy { it.effectiveStartTs }, habitualMidsleepSec) }
        .takeLast(limit)

/** Longest a leading block can be and still be treated as a spurious pre-sleep awake stub (lying in bed
 *  before sleep). Generous (a few hours) because the reporter's stub ran 21:41 → 00:27 — ~2h45m of pre-sleep
 *  awake — so a tight cap missed it (#736). The real guard against swallowing a genuine first sleep fragment
 *  is [PRE_ONSET_STUB_ASLEEP_MAX_MIN]: a stub must be essentially SLEEPLESS. Mirrors iOS
 *  SleepView.preOnsetStubMaxMin. (#736) */
private const val PRE_ONSET_STUB_MAX_MIN = 240.0
/** Most asleep minutes a fragment can carry and still count as a (sleepless) pre-onset awake stub. A real
 *  first sleep fragment of a biphasic night carries far more. Mirrors iOS SleepView.preOnsetStubAsleepMaxMin.
 *  (#736) */
private const val PRE_ONSET_STUB_ASLEEP_MAX_MIN = 3.0
/** A leading pre-onset fragment that carries SOME sleep is still spurious when it is minor RELATIVE to the
 *  night's main block: its asleep minutes are below this fraction of the largest fragment's. A genuine
 *  biphasic first sleep is comparable in size to the main block (well above this), so it is never dropped;
 *  only a small stray lead (e.g. a brief early doze hours before the real sleep) is. This extends the
 *  essentially-sleepless [PRE_ONSET_STUB_ASLEEP_MAX_MIN] rule (#736), which missed a lead carrying a few
 *  minutes more than 3. Mirrors iOS SleepView.preOnsetStubMinorFrac. (#259) */
private const val PRE_ONSET_STUB_MINOR_FRAC = 0.15

/** Absolute floor (ASLEEP minutes) under the #259 relative "minor lead" test: a leading fragment that carries
 *  at least this much real sleep is a genuine first sleep — a real sleep episode — and is NEVER a spurious
 *  pre-onset lead, however large the main block is. Without it a long main sleep inflates the 15% relative bar
 *  (a 6 h night → ~54 min) so a genuine ~34-min first sleep was swallowed and the shown bedtime jumped hours
 *  late, hiding the real onset the bridged night (and the Health write-back) already spans. 20 min ≈ the
 *  shortest standalone sleep episode; below it a handful of asleep minutes beside a long night is a stray lead.
 *  Mirrors iOS SleepView.preOnsetStubMinorAsleepFloorMin. (#259 / bridged-night headline) */
internal const val PRE_ONSET_STUB_MINOR_ASLEEP_FLOOR_MIN = 20.0

/**
 * Asleep minutes decoded from a stored [stagesJSON] in EITHER of the two formats that exist in the DB:
 * on-device COMPUTED nights store a SEGMENT ARRAY `[{start,end,stage}]`; imported nights store a dict of
 * MINUTES `{light,deep,rem,awake}`. [parseSessionStages] already reads both; this additionally threads the
 * fragment's [effectiveStartTs] through [SleepStageTotals.clampStagesToOnset] so a segment array is trimmed to
 * the effective onset (the #259 pre-onset trim) exactly as the hero's stage totals trim it — a no-op for a
 * minute dict and for a segment array that already starts at its onset. The displayed-onset stub test reads
 * asleep minutes through this seam so a computed night's segment array is never counted as 0 asleep minutes.
 * Internal so the onset golden pins the DECODE PATH itself. Mirrors iOS SleepView.decodedAsleepMinutes.
 */
internal fun decodedAsleepMinutes(stagesJSON: String?, effectiveStartTs: Long): Double =
    parseSessionStages(SleepStageTotals.clampStagesToOnset(stagesJSON, effectiveStartTs))
        ?.let { it.light + it.deep + it.rem } ?: 0.0

/** A fragment is a spurious pre-onset awake stub when it is within the lie-in cap (<= [PRE_ONSET_STUB_MAX_MIN])
 *  and EITHER carries essentially no sleep (asleep minutes <= [PRE_ONSET_STUB_ASLEEP_MAX_MIN]) OR is minor
 *  relative to the night's main block ([refAsleepMin], the group's largest asleep span): asleep minutes below
 *  [PRE_ONSET_STUB_MINOR_FRAC] of it AND below the absolute [PRE_ONSET_STUB_MINOR_ASLEEP_FLOOR_MIN] real-sleep-
 *  episode floor. Used only to skip such a stub when it leads the main-night group, so the hero's hypnogram and
 *  minutes start at the displayed bedtime (the main block's onset) rather than before it. [refAsleepMin]
 *  defaults to 0 (relative test off) so existing callers/tests are byte-identical. Mirrors iOS
 *  SleepView.isPreOnsetAwakeStub. (#736 / #259) */
internal fun isPreOnsetAwakeStub(frag: SleepSession, refAsleepMin: Double = 0.0): Boolean {
    val spanMin = (frag.endTs - frag.effectiveStartTs) / 60.0
    if (spanMin > PRE_ONSET_STUB_MAX_MIN) return false
    val asleepMin = decodedAsleepMinutes(frag.stagesJSON, frag.effectiveStartTs)
    if (asleepMin <= PRE_ONSET_STUB_ASLEEP_MAX_MIN) return true
    // #259 relative "minor lead" test, floored: a real sleep episode (>= the floor) is never a stray lead, so
    // a long main block can't inflate the 15% bar past a genuine short first sleep. A genuine biphasic first
    // sleep is comparable in size, so it stays and its onset stands.
    return refAsleepMin > 0.0 &&
        asleepMin < PRE_ONSET_STUB_MINOR_FRAC * refAsleepMin &&
        asleepMin < PRE_ONSET_STUB_MINOR_ASLEEP_FLOOR_MIN
}

/** SUM the per-stage minutes across a bridged main-night group, so the hero's stage breakdown reflects the
 *  WHOLE night (#561) instead of one fragment (#555). The inter-fragment wake gap belongs to no fragment,
 *  so it is excluded exactly as AnalyticsEngine excludes it. Null if no fragment has parseable stages. */
private fun sumGroupStages(group: List<SleepSession>): StageMins? {
    var aw = 0.0; var li = 0.0; var dp = 0.0; var rm = 0.0; var any = false
    for (frag in group) {
        // #259: each fragment's stages trimmed to its effective onset before summing (see buildSleepModel).
        val s = parseSessionStages(SleepStageTotals.clampStagesToOnset(frag.stagesJSON, frag.effectiveStartTs)) ?: continue
        aw += s.awake; li += s.light; dp += s.deep; rm += s.rem; any = true
    }
    return if (any) StageMins(aw, li, dp, rm) else null
}

/** The device's current UTC offset (seconds east), evaluated per pick, fed to the selector's `offsetSec`
 *  so the timing test reads the user's clock via the SAME `offsetSec` math the engine uses
 *  ([SleepStageTotals.localSecOfDay]) instead of `Calendar.get(HOUR_OF_DAY)` — the duplicated, DST-fragile
 *  gate the audit flagged. Mirrors the engine's `TimeZone.getDefault().getOffset(...)`. (#547) */
internal fun uiTzOffsetSec(): Long =
    TimeZone.getDefault().getOffset(System.currentTimeMillis()) / 1000L
