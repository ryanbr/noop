package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import android.content.Context
import androidx.compose.foundation.border
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.data.DailyMetric
import com.noop.data.JournalEntry
import com.noop.data.WorkoutRow
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.temporal.ChronoUnit
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.sqrt

// MARK: - Insights
//
// The "interrogate what affects what" screen, ported from the macOS InsightsView.
// Two halves:
//
//  1. BEHAVIOUR EFFECTS, split logged journal answers (the days each behaviour WAS
//     logged "yes" vs NOT) and compare a chosen outcome metric (Charge / HRV /
//     Rest / RHR) between the two groups. Ranked by effect size (Cohen's d), with
//     significant effects first. Each card carries a plain-English sentence, the
//     with/without means, group counts, a significance pill, and the magnitude word.
//     Tint is sign-aware: a behaviour that moves the outcome the "good" way (respecting
//     higherIsBetter) reads positive/green, the "bad" way reads critical/red.
//
//  2. METRIC RELATIONSHIPS, a curated set of Pearson correlations between daily series
//     (HRV ↔ charge, rest ↔ charge, RHR ↔ charge, charge → next-day charge),
//     each rendered as a one-line insight with r and a plain-English reading.
//
// Data note vs macOS: the Swift app computes these via the StrandAnalytics package
// (BehaviorInsights / CorrelationEngine) over a metricSeries store. On Android the
// analytics package isn't ported, and the guaranteed outcome source is the cached
// DailyMetric rows (vm.recentDays). So the outcome series here are read straight off
// those rows (recovery / avgHrv / sleep-efficiency / restingHr) and the simple, honest
// math (group means + Cohen's d, Pearson r) is computed inline below. No fabricated
// values: a behaviour or relationship only appears when there is real overlapping data.

// MARK: - Outcome (segmented selection)

/** One interrogable outcome metric: how to read it off a DailyMetric, its label,
 *  units, and whether higher is the "good" direction (drives sign-aware tint). */
private enum class Outcome(
    val label: String,
    val outcomeName: String,
    val higherIsBetter: Boolean,
    /** The Bevel colour world the outcome belongs to, drives the card wash so the
     *  Behaviour Effects section sits in one world (Charge→green, HRV/Rest→indigo,
     *  RHR→Stress teal), mirroring the Swift Outcome.domain. */
    val domain: DomainTheme,
    val pick: (DailyMetric) -> Double?,
    val format: (Double) -> String,
) {
    Recovery(
        label = uiString(R.string.l10n_insights_screen_charge_d4e1aee4), outcomeName = "Charge", higherIsBetter = true, domain = DomainTheme.Charge,
        pick = { it.recovery }, format = { "${it.roundToInt()}%" },
    ),
    Hrv(
        label = "HRV", outcomeName = "HRV", higherIsBetter = true, domain = DomainTheme.Rest,
        pick = { it.avgHrv }, format = { "${it.roundToInt()} ms" },
    ),
    Sleep(
        label = uiString(R.string.l10n_insights_screen_rest_b79e5f48), outcomeName = "Rest", higherIsBetter = true, domain = DomainTheme.Rest,
        pick = { it.efficiency }, format = { "${it.roundToInt()}%" },
    ),
    Rhr(
        label = uiString(R.string.l10n_insights_screen_rhr_04edf9b3), outcomeName = "Resting HR", higherIsBetter = false, domain = DomainTheme.Stress,
        pick = { it.restingHr?.toDouble() }, format = { "${it.roundToInt()} bpm" },
    ),
}

// MARK: - Computed shapes (plain data, no analytics package dependency)

/** One behaviour's effect on the selected outcome: with/without means, counts,
 *  Cohen's d and a crude significance flag. */
private data class BehaviorEffect(
    val behavior: String,
    val meanWith: Double,
    val meanWithout: Double,
    val nWith: Int,
    val nWithout: Int,
    val cohensD: Double,
) {
    val delta: Double get() = meanWith - meanWithout
    /** Crude significance: a non-trivial effect with enough days on both sides.
     *  Honest stand-in for a t-test, |d| ≥ 0.5 ("moderate") with ≥3 days each side. */
    val significant: Boolean get() = abs(cohensD) >= 0.5 && nWith >= 3 && nWithout >= 3
}

/** A curated metric relationship plus its computed Pearson correlation. */
private data class Relationship(
    val id: String,
    val title: String,
    val blurb: String,
    val r: Double,
    val n: Int,
) {
    /** Crude significance flag for |r| with n pairs (rough p < 0.05 threshold). */
    val significant: Boolean get() = n >= 4 && abs(r) >= significanceThreshold(n)
}

/** The fully-computed insight inputs for the current data, recomputed off recentDays. */
private data class InsightModel(
    /** behaviour question → set of days it was answered "yes". */
    val behaviours: Map<String, Set<String>>,
    /** day → value, per outcome. */
    val outcomeByDay: Map<Outcome, Map<String, Double>>,
    /** ordered (day, value) per outcome for correlations. */
    val seriesByOutcome: Map<Outcome, List<Pair<String, Double>>>,
    /**
     * #322: numeric journal item (question) → [day: value]. A numeric series is the same
     * Map<String, Double> shape EffectRanker.rank's `outcomeByDay` takes, so a numeric journal item
     * ("caffeine mg", "alcohol units") is a first-class series the ranker can consume like any metric
     * outcome (dose-response lands in the v5 hub). Empty for a yes/no-only journal.
     */
    val numericJournalSeries: Map<String, Map<String, Double>> = emptyMap(),
)

// MARK: - Screen

/**
 * Insights, behaviour effects + metric relationships over cached history.
 *
 * Loads the journal (all days) and the per-day outcome series from `vm.recentDays`,
 * then presents the ranked behaviour effects for the selected outcome and the curated
 * Pearson relationships. Empty/sparse states explain what's missing rather than faking
 * numbers, matching the macOS data-display contract.
 */
@Composable
fun InsightsScreen(vm: AppViewModel, onOpenInsightsHub: () -> Unit = {}) {
    val days by vm.recentDays.collectAsStateWithLifecycle()

    // Journal answers (all history): imported "my-whoop" rows UNIONED with native "noop-journal"
    // rows (native wins per (day, question)). Keyed on journalSeq so the logging card's saves and
    // clears refresh the effects immediately; re-loaded too when the cached days change underneath.
    var behaviours by remember { mutableStateOf<Map<String, Set<String>>>(emptyMap()) }
    // #322: numeric journal item (question) -> [day: value]. A numeric journal series is a daily series
    // the effect ranker consumes exactly like a metric series (EffectRanker.effect already takes a
    // Map<String, Double> outcome), so "caffeine mg" / "alcohol units" can rank as a numeric outcome.
    var numericJournalSeries by remember { mutableStateOf<Map<String, Map<String, Double>>>(emptyMap()) }
    var journalLoaded by remember { mutableStateOf(false) }
    var journalSeq by remember { mutableStateOf(0) }
    var dayOffset by remember { mutableStateOf(0L) }
    // #656: honour a day the Today journal widget deep-linked to (tapping a bar opens the journal at THAT
    // day). Consumed once on arrival, then cleared so it doesn't re-apply on the next recomposition.
    val pendingJournalDay by vm.pendingJournalDayOffset.collectAsStateWithLifecycle()
    androidx.compose.runtime.LaunchedEffect(pendingJournalDay) {
        pendingJournalDay?.let { dayOffset = it; vm.requestJournalDay(null) }
    }
    var importedQuestions by remember { mutableStateOf<List<String>>(emptyList()) }
    var dayAnswers by remember { mutableStateOf<Map<String, Boolean>>(emptyMap()) }
    // #322: the selected day's native numeric values (question -> value), drives the numeric fields.
    var dayNumeric by remember { mutableStateOf<Map<String, Double>>(emptyMap()) }
    var preFilledFromYesterday by remember { mutableStateOf(false) }
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    // #322: the v2 catalog (rename + numeric type + group + order), folding the legacy custom/hidden
    // arrays on first run. Held in state so edits (rename/regroup/convert/add/remove) recompose.
    var catalogItems by remember { mutableStateOf(loadJournalCatalogItems(ctx)) }

    // #860 item 4: today's local calendar-day key. The journal day chips ("Today"/"Yesterday"/"Tomorrow")
    // are relative to the CURRENT date, but the answers (`dayAnswers`) and the resolved key are derived from
    // `LocalDate.now()` only inside the load effect below, which re-keys on `journalSeq`/`dayOffset`. A day
    // can pass with the screen alive and no save (the app simply backgrounded overnight), leaving the
    // previous day's answers pinned under "Today" instead of the new day starting blank. We re-stamp this on
    // every lifecycle RESUME, and fold it into the load effect's keys, so the moment the date rolls over the
    // journal reloads for the new day and prior answers move to their real date. iOS parity in InsightsView.
    var currentDayKey by remember { mutableStateOf(LocalDate.now().toString()) }
    val lifecycleOwner = androidx.lifecycle.compose.LocalLifecycleOwner.current
    androidx.compose.runtime.DisposableEffect(lifecycleOwner) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_RESUME) {
                val key = LocalDate.now().toString()
                if (key != currentDayKey) currentDayKey = key
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    androidx.compose.runtime.LaunchedEffect(journalSeq, dayOffset, currentDayKey) {
        val imported = vm.repo.journal("my-whoop", "0000-01-01", "9999-12-31")
        val native = vm.repo.journal(JOURNAL_DEVICE_ID, "0000-01-01", "9999-12-31")
        val entries = mergeJournalEntries(imported, native)
        val byBehaviour = mutableMapOf<String, MutableSet<String>>()
        // #322: a numeric log writes answeredYes=true too, so a numeric item lands in the with/without
        // split here unchanged; its per-day value is captured separately for a numeric series the effect
        // ranker can consume like any metric outcome (dose-response lands in the v5 hub). Additive.
        val numericByBehaviour = mutableMapOf<String, MutableMap<String, Double>>()
        for (e in entries) {
            if (e.answeredYes) byBehaviour.getOrPut(e.question) { mutableSetOf() }.add(e.day)
            e.numericValue?.let { v -> numericByBehaviour.getOrPut(e.question) { mutableMapOf() }[e.day] = v }
        }
        behaviours = byBehaviour.mapValues { it.value.toSet() }
        numericJournalSeries = numericByBehaviour.mapValues { it.value.toMap() }
        importedQuestions = imported.map { it.question }.distinct()
        val key = journalDayKey(dayOffset)
        var answers = native.filter { it.day == key }.associate { it.question to it.answeredYes }
        // #322: the selected day's numeric values (native-only; imported WHOOP rows carry none).
        dayNumeric = native.filter { it.day == key && it.numericValue != null }
            .associate { it.question to it.numericValue!! }
        // Pre-fill from last night when opening today's journal with no entries yet, makes
        // recurring patterns (e.g. no alcohol, read before bed) one tap to confirm instead of re-enter.
        if (answers.isEmpty() && dayOffset == 0L) {
            val yesterdayAnswers = native
                .filter { it.day == journalDayKey(1L) }
                .associate { it.question to it.answeredYes }
            if (yesterdayAnswers.isNotEmpty()) {
                // Upsert real rows for today so the effects engine counts the day as logged
                // and onClear can delete the row it finds. Without this the chips looked
                // pre-filled but no row existed, so "confirm" persisted nothing and
                // "clear" tried to delete a phantom.
                vm.repo.upsertJournal(yesterdayAnswers.map { (q, yes) ->
                    JournalEntry(JOURNAL_DEVICE_ID, key, q, yes)
                })
                answers = yesterdayAnswers
                preFilledFromYesterday = true
            } else {
                preFilledFromYesterday = false
            }
        } else {
            preFilledFromYesterday = false
        }
        dayAnswers = answers
        journalLoaded = true
    }

    // Selected outcome metric for the behaviour-effects half.
    var outcome by remember { mutableStateOf(Outcome.Recovery) }

    // --- Personal-experiment state (LOCAL ONLY, SharedPreferences, parity with the
    //     Swift @AppStorage keys). `experimentSeq` bumps after a save so the snapshot
    //     and compliance refresh immediately, matching the journal card's pattern. ---
    var experimentSeq by remember { mutableStateOf(0) }
    var experimentBehaviour by remember { mutableStateOf(loadExperimentString(ctx, EXP_BEHAVIOUR)) }
    var experimentOutcomeName by remember { mutableStateOf(loadExperimentString(ctx, EXP_OUTCOME)) }
    var experimentStartedDay by remember { mutableStateOf(loadExperimentString(ctx, EXP_STARTED)) }
    var experimentDurationDays by remember { mutableStateOf(loadExperimentInt(ctx, EXP_DURATION, ExperimentLength.TwoWeeks.days)) }
    var experimentBaselineDays by remember { mutableStateOf(loadExperimentInt(ctx, EXP_BASELINE, ExperimentLength.TwoWeeks.days)) }

    // Build outcome day-maps + ordered series off the cached daily metrics. Cheap and
    // recomputed only when `days` changes (not on every recomposition).
    val model = remember(days, behaviours, numericJournalSeries) { buildModel(days, behaviours, numericJournalSeries) }

    // Ranked behaviour effects for the current outcome (recomputed when outcome/data change).
    val ranked = remember(model, outcome) { rankEffects(model, outcome) }
    // Curated relationships (independent of the selected outcome).
    val relationships = remember(model) { computeRelationships(model) }

    // --- Activity Cost (#439): the engine is pure + unit-tested; shape its inputs HERE. ---
    // Load the sessions (ALL sources, dismissed-filtered) the same way the Workouts screen does, then
    // build [sport: Set<localDayKey>] + [localDayKey: Charge] and rank the per-sport recovery cost.
    val workouts by vm.workouts.collectAsStateWithLifecycle()
    androidx.compose.runtime.LaunchedEffect(Unit) { vm.loadWorkouts() }
    val activityCosts = remember(workouts, days) { computeActivityCosts(workouts, days) }

    // PERF (#707): migrate to the lazy scaffold so only on-screen sections compose + get
    // accessibility-walked. Each eager child becomes its own `item { }`, INCLUDING the standalone
    // `Spacer(sectionGap - 20)` separators, which are real Column children that already sat inside the
    // eager `spacedBy(20.dp)`; a LazyColumn with the same `spacedBy(20.dp)` flanks each item identically,
    // so the rendered spacing is byte-for-byte unchanged. Conditional sections use `if (cond) { item {} }`
    // (never `item { if (cond) }`) so a hidden section emits NO item, an unconditional empty item would
    // otherwise insert a 0-height row that the 20dp arrangement flanks, shifting layout. The one
    // composable-only block (`run { … remember(snapshot) … }`) moves inside its `item { }` (which is
    // @Composable). Order is preserved exactly.
    // LIQUID SKY BACKDROP (the pilot pattern — LiquidScreenSky.kt): the static time-of-day liquid sky
    // settles into the theme canvas behind the header + the first cards (and bleeds full-width up behind the
    // status bar via the scaffold's topBackground plumbing), top-aligned, so the analysis cards float OVER
    // the sky on the flat surface below. The Android equivalent of the iOS
    // `ScreenScaffold(topBackground: liquidScaffoldSky())`; reuses the shared LiquidScreenSky() slot verbatim.
    // Insights has no day-cycle gate of its own, so the sky is always drawn (matching the liquid explorer).
    // Day-cycle sky + sky-behind-cards: the SAME two Appearance gates every other screen honours.
    // (This screen previously drew the sky unconditionally - it now matches Today/Trends/Sleep,
    // including turning OFF with the day-cycle setting.) Read once; SharedPreferences isn't reactive.
    val skyCtx = androidx.compose.ui.platform.LocalContext.current
    val showDayCycleBackground = remember { NoopPrefs.showDayCycleBackground(skyCtx) }
    val skyBehindCards = remember { NoopPrefs.skyBehindCards(skyCtx) }
    LazyScreenScaffold(
        title = uiString(R.string.l10n_insights_screen_insights_b4510362),
        subtitle = "Interrogate what affects what.",
        topBackground = screenBackdropSlot(showDayCycleBackground, skyBehindCards),
        // Sky-behind-cards fills the viewport so the transparent cards reveal the sky the whole way
        // down (Today / Trends / Sleep / metric-detail parity - same two prefs, same two behaviours).
        fullBleedBackground = screenBackdropFullBleed(showDayCycleBackground, skyBehindCards),
    ) {

        // --- "What moves you" deep-link into the v5 Insights Hub (ranked, lag-aware ranked-effect feed +
        //     personal alcohol/caffeine dose-response). The honest in-Insights entry point; the hub is its
        //     own destination too. Mirrors the Swift InsightsView.whatMovesYouLink. ---
        item { WhatMovesYouLink(onOpen = onOpenInsightsHub) }

        item { Spacer(Modifier.height(Metrics.sectionGap - 20.dp)) }

        // --- Native journal logging (always reachable, the account-free way in) ---
        if (preFilledFromYesterday) {
            item {
            Text(
                uiString(R.string.l10n_insights_screen_pre_filled_from_last_night_tap_ce81097c),
                style = NoopType.footnote,
                color = Palette.textTertiary,
                modifier = Modifier.fillMaxWidth(),
            )
            }
        }
        item {
        // Persist a mutated catalog list and refresh state (the pure edit helpers never touch the
        // canonical key, so a rename/regroup/convert keeps history joined; #322).
        fun applyCatalog(next: List<JournalCatalogItem>) {
            saveJournalCatalogItems(ctx, next)
            catalogItems = next
        }
        JournalLogCard(
            items = resolveJournalItems(importedQuestions, catalogItems, includeHidden = false),
            answers = dayAnswers,
            numericAnswers = dayNumeric,
            dayOffset = dayOffset,
            onDayOffset = { dayOffset = it },
            onAnswer = { q, yes ->
                scope.launch {
                    vm.repo.upsertJournal(
                        listOf(JournalEntry(JOURNAL_DEVICE_ID, journalDayKey(dayOffset), q, yes)),
                    )
                    journalSeq++
                }
            },
            onNumeric = { q, value ->
                scope.launch {
                    // A numeric log writes answeredYes=true AND the value (#322), so the effects engine
                    // counts the day as logged and the with/without split is unchanged.
                    vm.repo.upsertJournal(
                        listOf(JournalEntry(JOURNAL_DEVICE_ID, journalDayKey(dayOffset), q,
                            answeredYes = true, numericValue = value)),
                    )
                    journalSeq++
                }
            },
            onClear = { q ->
                scope.launch {
                    vm.repo.deleteJournalEntry(JOURNAL_DEVICE_ID, journalDayKey(dayOffset), q)
                    journalSeq++
                }
            },
            onAddCustom = { q, kind, group -> applyCatalog(addCustomJournalItem(catalogItems, q, kind, group)) },
            onRename = { q, name -> applyCatalog(renameJournalItem(catalogItems, q, name)) },
            onSetGroup = { q, group -> applyCatalog(setJournalItemGroup(catalogItems, q, group)) },
            onSetKind = { q, kind -> applyCatalog(setJournalItemKind(catalogItems, q, kind)) },
            onRemoveQuestion = { q -> applyCatalog(removeJournalItem(catalogItems, q)) },
            onRestoreQuestion = { q -> applyCatalog(restoreJournalItem(catalogItems, q)) },
        )
        }

        item { Spacer(Modifier.height(Metrics.sectionGap - 20.dp)) }

        // --- Mind: daily mood check-in + mood ↔ body correlations (Swift Mind-lane
        //     mirror; storage contract + footnote shared verbatim across platforms) ---
        item { MindSection(vm) }

        item { Spacer(Modifier.height(Metrics.sectionGap - 20.dp)) }

        // --- Caffeine window (#526), log an intake + a rough on-device "still active"
        //     hint. Self-contained (owns its own SharedPreferences state). Opt-in: shows
        //     nothing until the user logs one. Twin of macOS CaffeineLogCard. ---
        item { CaffeineLogCard() }

        item { Spacer(Modifier.height(Metrics.sectionGap - 20.dp)) }

        // --- Personal experiment (LOCAL ONLY n-of-1 protocol) ------------------
        item {
        run {
            // Candidates are gated to behaviours the user actually has data for, 
            // logged journal questions ∪ imported wording, minus hidden, NOT the
            // starter catalog (triage fix a/b). Empty → real empty-state guard.
            // Hidden canonicals come from the v2 catalog now (#322), same triage-fix semantics.
            val hiddenQuestions = catalogItems.filter { it.hidden }.map { it.canonical }
            val candidates = experimentCandidates(behaviours, importedQuestions, hiddenQuestions, experimentBehaviour)
            val expOutcome = Outcome.entries.firstOrNull { it.outcomeName == experimentOutcomeName } ?: Outcome.Recovery
            val resolvedBehaviour = resolveExperimentBehaviour(candidates, experimentBehaviour)
            val snapshot = remember(model, behaviours, experimentStartedDay, experimentOutcomeName, experimentDurationDays, experimentBaselineDays, experimentSeq) {
                buildExperimentSnapshot(
                    model = model,
                    behaviours = behaviours,
                    startedDay = experimentStartedDay,
                    outcome = expOutcome,
                    behaviour = resolvedBehaviour,
                    durationDays = experimentDurationDays,
                    baselineDays = experimentBaselineDays,
                )
            }

            ExperimentSection(
                snapshot = snapshot,
                candidates = candidates,
                resolvedBehaviour = resolvedBehaviour,
                outcome = expOutcome,
                length = ExperimentLength.fromDays(experimentDurationDays),
                onBehaviour = {
                    experimentBehaviour = it
                    saveExperimentString(ctx, EXP_BEHAVIOUR, it)
                },
                onOutcome = {
                    experimentOutcomeName = it.outcomeName
                    saveExperimentString(ctx, EXP_OUTCOME, it.outcomeName)
                },
                onLength = {
                    experimentDurationDays = it.days
                    saveExperimentInt(ctx, EXP_DURATION, it.days)
                },
                onStart = {
                    val behaviour = resolvedBehaviour
                    if (behaviour != null) {
                        experimentBehaviour = behaviour
                        saveExperimentString(ctx, EXP_BEHAVIOUR, behaviour)
                        experimentBaselineDays = experimentDurationDays
                        saveExperimentInt(ctx, EXP_BASELINE, experimentDurationDays)
                        val today = journalDayKey(0L)
                        experimentStartedDay = today
                        saveExperimentString(ctx, EXP_STARTED, today)
                    }
                },
                onEnd = {
                    experimentStartedDay = ""
                    saveExperimentString(ctx, EXP_STARTED, "")
                },
                onMark = { answeredYes ->
                    val behaviour = snapshot?.behavior
                    if (behaviour != null) {
                        scope.launch {
                            vm.repo.upsertJournal(
                                listOf(JournalEntry(JOURNAL_DEVICE_ID, journalDayKey(0L), behaviour, answeredYes)),
                            )
                            journalSeq++       // refresh behaviours map (logged-today, compliance)
                            experimentSeq++    // refresh the snapshot
                        }
                    }
                },
            )
        }
        }

        item { Spacer(Modifier.height(Metrics.sectionGap - 20.dp)) }

        // --- Behaviour effects -------------------------------------------------
        // (Always emits one of three branches → one unconditional item, never empty.)
        item {
        if (!journalLoaded) {
            NoopCard {
                Text(
                    uiString(R.string.l10n_insights_screen_reading_your_journal_and_outcomes_4a59af69),
                    style = NoopType.subhead,
                    color = Palette.textTertiary,
                )
            }
        } else if (behaviours.isEmpty()) {
            // No journal yet, explain, without dead-ending on a paid export.
            DataPendingNote(
                title = uiString(R.string.l10n_insights_screen_insights_read_your_journal_and_outcomes_6ec8aaf9),
                body = "Log behaviours above. After a few days of answers, NOOP ranks how each " +
                    "one moves your recovery, HRV and sleep. Importing a WHOOP export (which " +
                    "includes its journal) backfills history instantly.",
            )
        } else {
            BehaviourSection(
                outcome = outcome,
                onOutcome = { outcome = it },
                ranked = ranked,
            )
        }
        }

        item { Spacer(Modifier.height(Metrics.sectionGap - 20.dp)) }

        // --- Activity Cost (what each activity costs your recovery) ------------
        item { ActivityCostSection(activityCosts) }

        item { Spacer(Modifier.height(Metrics.sectionGap - 20.dp)) }

        // --- Metric relationships ---------------------------------------------
        item { RelationshipsSection(relationships) }
    }
}

// MARK: - "What moves you" deep-link
//
// A single NoopCard row into the v5 Insights Hub, the ranked, lag-aware "which of your habits actually
// move your Charge" feed plus the personal alcohol/caffeine dose-response. Charge-world wash (chargeColor
// tint), an accent auto_awesome glyph in a soft rounded chip, a short lag-aware blurb, and a trailing
// chevron. One combined accessibility label so screen readers announce it as a single link. Mirrors the
// Swift InsightsView.whatMovesYouLink.

@Composable
private fun WhatMovesYouLink(onOpen: () -> Unit) {
    // liquidPress: the tappable card settles inward on press (the iOS LiquidPressStyle feel). The SAME
    // interactionSource drives the clickable + the press, and indication is nulled so only the liquid
    // settle reads (no ripple). Same onOpen nav + same combined accessibility label.
    val interaction = remember { MutableInteractionSource() }
    NoopCard(
        tint = Palette.chargeColor,
        modifier = Modifier
            .clickable(interactionSource = interaction, indication = null, onClick = onOpen)
            .liquidPress(interaction)
            .semantics {
                contentDescription =
                    uiString(R.string.l10n_insights_screen_what_moves_you_ranked_patterns_in_7d89e628)
            },
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(30.dp)
                    .clip(RoundedCornerShape(9.dp))
                    .background(Palette.accent.copy(alpha = 0.14f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Filled.AutoAwesome,
                    contentDescription = null,
                    tint = Palette.accent,
                    modifier = Modifier.size(16.dp),
                )
            }
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                // WHOOP tappable-card title: UPPERCASE tracked WHITE label + a trailing "›" chevron
                // glyph (mirrors the iOS "WHAT MOVES YOU ›" overline). The descriptive line sits beneath.
                Overline("What moves you ›", color = Palette.textPrimary)
                Text(
                    uiString(R.string.l10n_insights_screen_ranked_lag_aware_which_of_your_e0e91b39),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
            Icon(
                Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = Palette.accent,
                modifier = Modifier.size(14.dp),
            )
        }
    }
}

// MARK: - Activity Cost section (#439)
//
// "What each activity costs your recovery": one ranked NoopCard per sport that cleared the engine's
// minSessions gate, each carrying next-morning Charge vs rest baseline, days-to-baseline, the sample
// count + confidence pill, and the engine's plain-English sentence. Sign-aware tint: a positive cost
// (recovery dipped) reads warm/critical, a recovery-POSITIVE delta reads green. Mirrors the Swift
// InsightsView.activityCostSection exactly.

/**
 * Shape the [ActivityCostEngine] inputs from the loaded sessions + cached daily metrics, then rank.
 * [workouts] → [sport: Set<localDayKey>] (displaySport collapses detected/"Activity" into one bucket
 * and de-camelCases WHOOP names; manual/imported labels pass through), keyed by the LOCAL calendar
 * day the session STARTED via the SAME AnalyticsEngine.dayString path [DailyMetric.day] uses, so the
 * engine's D+1 next-morning alignment is honest. [days] → [localDayKey: Charge] off DailyMetric.recovery.
 */
internal fun computeActivityCosts(
    workouts: List<WorkoutRow>,
    days: List<DailyMetric>,
): List<com.noop.analytics.ActivityCost> {
    // Single "now" offset for every session, the SAME tz-offset basis IntelligenceEngine.kt uses to
    // key DailyMetric.day (getOffset(now)/1000 applied across the run), via the SAME
    // AnalyticsEngine.dayString(ts, offsetSec) path, so the engine's D+1 next-morning lookups align
    // byte-for-byte with the recovery keys (and match the Swift TimeZone.current.secondsFromGMT path).
    val offsetSec = java.util.TimeZone.getDefault().getOffset(System.currentTimeMillis()) / 1_000L
    val activityDaysBySport = HashMap<String, MutableSet<String>>()
    for (w in workouts) {
        val sport = WorkoutEditing.displaySport(w.sport)
        if (sport.isEmpty()) continue
        val day = com.noop.analytics.AnalyticsEngine.dayString(w.startTs, offsetSec)
        activityDaysBySport.getOrPut(sport) { mutableSetOf() }.add(day)
    }
    val recoveryByDay = HashMap<String, Double>()
    for (d in days) {
        d.recovery?.let { recoveryByDay[d.day] = it }
    }
    return com.noop.analytics.ActivityCostEngine.evaluate(
        activityDaysBySport = activityDaysBySport.mapValues { it.value.toSet() },
        recoveryByDay = recoveryByDay,
    )
}

@Composable
private fun ActivityCostSection(costs: List<com.noop.analytics.ActivityCost>) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Activity Cost", overline = "What each activity costs your recovery")
        if (costs.isEmpty()) {
            NoopCard {
                Text(
                    uiString(R.string.l10n_insights_screen_tag_a_few_sessions_of_the_97927401),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
            }
        } else {
            // Fade + rise the ranked cost cards in sequence (mirrors iOS .staggeredAppear(index:)).
            costs.forEachIndexed { i, cost ->
                Box(modifier = Modifier.staggeredAppear(i)) { ActivityCostCard(cost) }
            }
        }
    }
}

@Composable
private fun ActivityCostCard(cost: com.noop.analytics.ActivityCost) {
    // Sign-aware accent: a POSITIVE delta means the next morning sat BELOW baseline (it cost you) →
    // warm/critical; a negative delta means you woke higher → green. Near-zero reads neutral gold so
    // "barely moves" doesn't shout either way.
    val costing = cost.delta >= com.noop.analytics.ActivityCostEngine.barelyMovesPoints
    val lifting = cost.delta <= -com.noop.analytics.ActivityCostEngine.barelyMovesPoints
    val accent: Color = when {
        costing -> Palette.statusCritical
        lifting -> Palette.statusPositive
        else -> Palette.chargeColor
    }
    val solid = cost.confidence == com.noop.analytics.ScoreConfidence.SOLID
    val pointsLabel = (if (cost.delta >= 0) "−" else "+") + abs(cost.delta).roundToInt()

    NoopCard(tint = accent) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    sportIcon(cost.sport),
                    contentDescription = null,
                    tint = accent,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    cost.sport,
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                StatePill(
                    if (solid) "SOLID" else "BUILDING",
                    tone = if (solid) StrandTone.Positive else StrandTone.Accent,
                    showsDot = false,
                )
            }
            Text(cost.sentence(), style = NoopType.subhead, color = Palette.textSecondary)
            // 2×2 StatTile grid so tile heights stay uniform on phone widths (matches SummarySection).
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                StatTile(
                    modifier = Modifier.weight(1f),
                    label = uiString(R.string.l10n_insights_screen_next_morning_61d1ea83),
                    value = "${cost.meanNextMorning.roundToInt()}",
                    caption = "Charge · $pointsLabel pts",
                    accent = accent,
                )
                StatTile(
                    modifier = Modifier.weight(1f),
                    label = uiString(R.string.l10n_insights_screen_rest_baseline_b3ac52a5),
                    value = "${cost.baselineMean.roundToInt()}",
                    caption = "untouched days",
                    accent = Palette.textPrimary,
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                StatTile(
                    modifier = Modifier.weight(1f),
                    label = uiString(R.string.l10n_insights_screen_bounce_back_be2d66a4),
                    value = cost.daysToBaseline?.let { "${it}d" } ?: "—",
                    caption = if (cost.daysToBaseline != null) "to baseline" else "not within 7d",
                    accent = Palette.chargeColor,
                )
                StatTile(
                    modifier = Modifier.weight(1f),
                    label = uiString(R.string.l10n_insights_screen_sessions_e11e37a9),
                    value = "${cost.n}",
                    caption = if (solid) "solid" else "building",
                    accent = Palette.textPrimary,
                )
            }
        }
    }
}

// MARK: - Behaviour effects section

@Composable
private fun BehaviourSection(
    outcome: Outcome,
    onOutcome: (Outcome) -> Unit,
    ranked: List<BehaviorEffect>,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(modifier = Modifier.weight(1f)) {
                SectionHeader(
                    "Behaviour Effects",
                    overline = "What moves your ${outcome.outcomeName.lowercase(Locale.US)}",
                )
            }
            SegmentedPillControl(
                items = Outcome.entries.toList(),
                selection = outcome,
                label = { it.label },
                onSelect = onOutcome,
            )
        }

        if (ranked.isEmpty()) {
            NoopCard {
                Text(
                    uiString(R.string.l10n_insights_screen_not_enough_overlap_between_your_journal_0ebdd7a2) +
                        "${outcome.outcomeName.lowercase(Locale.US)} to measure an effect yet. " +
                        "Keep logging. Effects need days both with and without each behaviour.",
                    style = NoopType.subhead,
                    color = Palette.textTertiary,
                )
            }
        } else {
            // Fade + rise the ranked cards in sequence (mirrors iOS .staggeredAppear(index:)).
            ranked.forEachIndexed { i, e ->
                Box(modifier = Modifier.staggeredAppear(i)) { EffectCard(e, outcome) }
            }
        }
    }
}

/** One behaviour-effect card: sentence + with/without StatTiles + significance pill. */
@Composable
private fun EffectCard(e: BehaviorEffect, outcome: Outcome) {
    // Sign-aware tint: did this behaviour move the outcome the GOOD way?
    val movedGood: Boolean? = when {
        e.delta == 0.0 -> null
        else -> (e.delta > 0) == outcome.higherIsBetter
    }
    val tone: StrandTone = when (movedGood) {
        null -> StrandTone.Neutral
        true -> StrandTone.Positive
        false -> if (e.significant) StrandTone.Critical else StrandTone.Warning
    }
    val tintColor = tone.color
    val arrow = if (e.delta > 0) "↑" else if (e.delta < 0) "↓" else "→"
    val deltaText = "$arrow ${String.format(Locale.US, "%.1f", abs(e.delta))}"
    val sentence = effectSentence(e, outcome)

    // The card wash reads as the OUTCOME's colour world (so the whole Behaviour Effects
    // section sits in one world), while the dot / StatTile accents stay sign-aware.
    NoopCard(tint = outcome.domain.color) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {

            // Header: behaviour name (tinted dot) + significance pill.
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Row(
                    modifier = Modifier.weight(1f),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Box(
                        modifier = Modifier
                            .size(8.dp)
                            .clip(CircleShape)
                            .drawBehind { drawCircle(tintColor) },
                    )
                    Text(
                        e.behavior,
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                StatePill(
                    if (e.significant) "SIGNIFICANT" else "EXPLORATORY",
                    tone = if (e.significant) StrandTone.Positive else StrandTone.Neutral,
                    showsDot = false,
                )
            }

            // Plain-English sentence.
            Text(sentence, style = NoopType.body, color = Palette.textSecondary)

            // With / without means as uniform StatTiles.
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                StatTile(
                    modifier = Modifier.weight(1f),
                    label = uiString(R.string.l10n_insights_screen_with_564f8c6e),
                    value = outcome.format(e.meanWith),
                    caption = "n = ${e.nWith}",
                    accent = tintColor,
                    delta = deltaText,
                    deltaColor = tintColor,
                )
                StatTile(
                    modifier = Modifier.weight(1f),
                    label = uiString(R.string.l10n_insights_screen_without_cb735356),
                    value = outcome.format(e.meanWithout),
                    caption = "n = ${e.nWithout}",
                    accent = Palette.textPrimary,
                )
            }

            HorizontalDivider(color = Palette.hairline)

            // Effect-size footer: Cohen's d + magnitude word.
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Overline("Effect size", modifier = Modifier.weight(1f))
                Text(
                    String.format(Locale.US, "d = %.2f", e.cohensD),
                    style = NoopType.captionNumber,
                    color = tintColor,
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    effectMagnitudeWord(e.cohensD),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
            }
        }
    }
}

// MARK: - Personal experiment section
//
// A LOCAL-ONLY n-of-1 protocol mirroring the Swift InsightsView experiment section:
// pick ONE behaviour you actually log, one outcome, and a short window, then compare
// the outcome on days you logged the behaviour (the intervention) against your
// behaviour-ABSENT days before the start (the baseline). The absent-day baseline
// matches the with/without model used by Behaviour Effects above, so "Baseline" vs
// "Intervention" is an honest present-vs-absent contrast, not a raw pre/post window.
// Nothing leaves the device: state is SharedPreferences and "Mark done" writes a
// normal journal answer.

/** One experiment window length (and the matching baseline span). */
private enum class ExperimentLength(val days: Int, val label: String) {
    OneWeek(7, "7d"),
    TwoWeeks(14, "14d"),
    FourWeeks(28, "28d");

    companion object {
        fun fromDays(d: Int): ExperimentLength = entries.firstOrNull { it.days == d } ?: TwoWeeks
    }
}

/** A snapshot of the running experiment, computed off the cached outcome day-maps. */
private data class ExperimentSnapshot(
    val behavior: String,
    val outcome: Outcome,
    val startDay: String,
    val durationDays: Int,
    val daysElapsed: Int,
    val baselineMean: Double?,
    val baselineCount: Int,
    val interventionMean: Double?,
    val interventionCount: Int,
    val loggedToday: Boolean,
    /** 0…100 percent. */
    val compliance: Double,
    val confidence: ExperimentConfidence,
) {
    val progress: Float get() = (daysElapsed.toFloat() / durationDays.coerceAtLeast(1)).coerceIn(0f, 1f)
    val phaseLabel: String get() =
        if (daysElapsed >= durationDays) "COMPLETE" else "DAY $daysElapsed/$durationDays"
    val phaseTone: StrandTone get() =
        if (daysElapsed >= durationDays) StrandTone.Positive else StrandTone.Accent
    val delta: Double? get() {
        val i = interventionMean ?: return null
        val b = baselineMean ?: return null
        return i - b
    }
    val deltaCaption: String get() =
        if (delta == null) "needs baseline + logged days" else "vs behaviour-free baseline"
}

private data class ExperimentConfidence(val label: String, val tone: StrandTone)

@Composable
private fun ExperimentSection(
    snapshot: ExperimentSnapshot?,
    candidates: List<String>,
    resolvedBehaviour: String?,
    outcome: Outcome,
    length: ExperimentLength,
    onBehaviour: (String) -> Unit,
    onOutcome: (Outcome) -> Unit,
    onLength: (ExperimentLength) -> Unit,
    onStart: () -> Unit,
    onEnd: () -> Unit,
    onMark: (Boolean) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader(
            "Personal Experiment",
            overline = "N-of-1 protocol",
            trailing = snapshot?.phaseLabel ?: "Setup",
        )
        NoopCard {
            if (snapshot != null) {
                ActiveExperimentCard(snapshot, onMark = onMark, onEnd = onEnd)
            } else {
                ExperimentSetupCard(
                    candidates = candidates,
                    resolvedBehaviour = resolvedBehaviour,
                    outcome = outcome,
                    length = length,
                    onBehaviour = onBehaviour,
                    onOutcome = onOutcome,
                    onLength = onLength,
                    onStart = onStart,
                )
            }
        }
    }
}

@Composable
private fun ExperimentSetupCard(
    candidates: List<String>,
    resolvedBehaviour: String?,
    outcome: Outcome,
    length: ExperimentLength,
    onBehaviour: (String) -> Unit,
    onOutcome: (Outcome) -> Unit,
    onLength: (ExperimentLength) -> Unit,
    onStart: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.Top,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(uiString(R.string.l10n_insights_screen_run_a_clean_personal_test_4da69781), style = NoopType.headline, color = Palette.textPrimary)
                Spacer(Modifier.height(4.dp))
                Text(
                    uiString(R.string.l10n_insights_screen_pick_one_behaviour_you_log_one_bd34090e) +
                        "compares the days you log the behaviour against your behaviour-free " +
                        "days before the start.",
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
            }
            Spacer(Modifier.width(12.dp))
            StatePill("LOCAL ONLY", tone = StrandTone.Neutral, showsDot = false)
        }

        if (candidates.isEmpty()) {
            Text(
                uiString(R.string.l10n_insights_screen_log_at_least_one_behaviour_above_cf7c65a6),
                style = NoopType.subhead,
                color = Palette.textTertiary,
            )
        } else {
            ExperimentField("Behaviour") {
                ExperimentBehaviourPicker(
                    candidates = candidates,
                    selection = resolvedBehaviour ?: candidates.first(),
                    onSelect = onBehaviour,
                )
            }
            ExperimentField("Outcome") {
                SegmentedPillControl(
                    items = Outcome.entries.toList(),
                    selection = outcome,
                    label = { it.label },
                    onSelect = onOutcome,
                )
            }
            ExperimentField("Window") {
                SegmentedPillControl(
                    items = ExperimentLength.entries.toList(),
                    selection = length,
                    label = { it.label },
                    onSelect = onLength,
                )
            }

            // Unified button system (mirrors iOS NoopButton("Start experiment", flask, .primary, fullWidth)).
            NoopButton(
                text = uiString(R.string.l10n_insights_screen_start_experiment_45a4b379),
                leadingIcon = Icons.Filled.Science,
                kind = NoopButtonKind.Primary,
                fullWidth = true,
                enabled = resolvedBehaviour != null,
                onClick = onStart,
                modifier = Modifier.semantics { contentDescription = uiString(R.string.l10n_insights_screen_start_experiment_45a4b379) },
            )
        }
    }
}

@Composable
private fun ActiveExperimentCard(
    snapshot: ExperimentSnapshot,
    onMark: (Boolean) -> Unit,
    onEnd: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.Top,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    snapshot.behavior,
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    uiString(R.string.l10n_insights_screen_started_snapshot_startday_testing_snapshot_outcome_1839ef40, snapshot.startDay, snapshot.outcome.outcomeName.lowercase(Locale.US)),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
            Spacer(Modifier.width(12.dp))
            StatePill(
                snapshot.phaseLabel,
                tone = snapshot.phaseTone,
                pulsing = snapshot.daysElapsed < snapshot.durationDays,
            )
        }

        Text(
            experimentReading(snapshot),
            style = NoopType.body,
            color = Palette.textSecondary,
        )

        // Baseline / Intervention / Change / Compliance measures.
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            ExperimentMeasure(
                modifier = Modifier.weight(1f),
                label = uiString(R.string.l10n_insights_screen_baseline_e6ab7982),
                value = snapshot.baselineMean?.let { snapshot.outcome.format(it) } ?: "—",
                caption = "${snapshot.baselineCount} days without it",
                tint = Palette.textSecondary,
            )
            ExperimentMeasure(
                modifier = Modifier.weight(1f),
                label = uiString(R.string.l10n_insights_screen_intervention_e9b90c40),
                value = snapshot.interventionMean?.let { snapshot.outcome.format(it) } ?: "—",
                caption = "${snapshot.interventionCount} logged days",
                tint = Palette.accent,
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            ExperimentMeasure(
                modifier = Modifier.weight(1f),
                label = uiString(R.string.l10n_insights_screen_change_64fbd995),
                value = formatExperimentDelta(snapshot.delta, snapshot.outcome),
                caption = snapshot.deltaCaption,
                tint = experimentDeltaColor(snapshot),
            )
            ExperimentMeasure(
                modifier = Modifier.weight(1f),
                label = uiString(R.string.l10n_insights_screen_compliance_68f0ae49),
                value = "${snapshot.compliance.roundToInt()}%",
                caption = if (snapshot.loggedToday) "logged today" else "not logged today",
                tint = if (snapshot.loggedToday) Palette.statusPositive else Palette.statusWarning,
            )
        }

        // Progress bar + day count + confidence pill.
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            // LiquidTube: a genuine SINGLE-value goal bar (day N of the window), so it liquid-fills to
            // `snapshot.progress` in the accent tint. Static (animated = false) — a scrolling explorer must
            // not carry a live Canvas clock. Same fraction, same tint, same accessibility label as the
            // hand-drawn track it replaces.
            LiquidTube(
                frac = snapshot.progress.toDouble(),
                tint = Palette.accent,
                height = 6.dp,
                animated = false,
                modifier = Modifier
                    .fillMaxWidth()
                    .semantics {
                        contentDescription =
                            uiString(R.string.l10n_insights_screen_experiment_progress_snapshot_dayselapsed_of_snapshot_ff62b228, snapshot.daysElapsed, snapshot.durationDays)
                    },
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    uiString(R.string.l10n_insights_screen_snapshot_dayselapsed_of_snapshot_durationdays_days_9a611f12, snapshot.daysElapsed, snapshot.durationDays),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                    modifier = Modifier.weight(1f),
                )
                StatePill(snapshot.confidence.label, tone = snapshot.confidence.tone, showsDot = false)
            }
        }

        // Mark done / Skip / End, all routed through the unified NoopButton (mirrors iOS
        // NoopButtonStyle(.primary / .secondary / .destructive) with leading icons).
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            NoopButton(
                text = uiString(R.string.l10n_insights_screen_mark_done_0911cce7),
                leadingIcon = Icons.Filled.CheckCircle,
                kind = NoopButtonKind.Primary,
                enabled = !snapshot.loggedToday,
                onClick = { onMark(true) },
                modifier = Modifier
                    .weight(1f)
                    .semantics { contentDescription = uiString(R.string.l10n_insights_screen_mark_done_today_471eb94a) },
            )
            NoopButton(
                text = uiString(R.string.l10n_insights_screen_skip_3da47453),
                leadingIcon = Icons.Filled.Close,
                kind = NoopButtonKind.Secondary,
                onClick = { onMark(false) },
                modifier = Modifier
                    .weight(1f)
                    .semantics { contentDescription = uiString(R.string.l10n_insights_screen_skip_today_ed6a16a5) },
            )
            NoopButton(
                text = uiString(R.string.l10n_insights_screen_end_a2bb9d34),
                leadingIcon = Icons.Filled.Stop,
                kind = NoopButtonKind.Destructive,
                onClick = onEnd,
                modifier = Modifier.semantics { contentDescription = uiString(R.string.l10n_insights_screen_end_experiment_0ed6d57f) },
            )
        }
    }
}

/** A labelled inset well wrapping one setup control. */
@Composable
private fun ExperimentField(title: String, content: @Composable () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(Palette.surfaceInset)
            .border(1.dp, Palette.hairline, RoundedCornerShape(8.dp))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Overline(title, color = Palette.textTertiary)
        content()
    }
}

/** One inset measure cell: label, big number, caption. */
@Composable
private fun ExperimentMeasure(
    label: String,
    value: String,
    caption: String,
    tint: Color,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .heightIn(min = 92.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(Palette.surfaceInset)
            .border(1.dp, Palette.hairline, RoundedCornerShape(8.dp))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(label, style = NoopType.caption, color = Palette.textTertiary, maxLines = 1)
        Text(
            value,
            style = NoopType.number(22f),
            color = tint,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(caption, style = NoopType.footnote, color = Palette.textTertiary, maxLines = 2)
    }
}

/** A menu-style behaviour picker (mirrors the Swift Picker(.menu) style). */
@Composable
private fun ExperimentBehaviourPicker(
    candidates: List<String>,
    selection: String,
    onSelect: (String) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    // liquidPress on the tappable picker row (same interactionSource on the clickable + press; indication
    // nulled so only the liquid settle reads). Same expand-on-tap + same accessibility label.
    val interaction = remember { MutableInteractionSource() }
    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(6.dp))
                .background(Palette.surfaceBase)
                .border(1.dp, Palette.hairline, RoundedCornerShape(6.dp))
                .clickable(interactionSource = interaction, indication = null) { expanded = true }
                .liquidPress(interaction)
                .padding(horizontal = 12.dp, vertical = 8.dp)
                .semantics { contentDescription = uiString(R.string.l10n_insights_screen_experiment_behaviour_selection_bcb29b58, selection) },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                selection,
                style = NoopType.subhead,
                color = Palette.textPrimary,
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text("▾", style = NoopType.subhead, color = Palette.textTertiary)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            candidates.forEach { q ->
                DropdownMenuItem(
                    text = { Text(q, style = NoopType.subhead, color = Palette.textPrimary) },
                    onClick = {
                        onSelect(q)
                        expanded = false
                    },
                )
            }
        }
    }
}

// MARK: - Experiment computation (mirrors Swift activeExperimentSnapshot)

/**
 * Behaviours the user actually has data for: distinct logged journal questions
 * (`behaviours.keys`) ∪ imported-export questions, minus the catalog's hidden set.
 * Triage fix (a)/(b): we do NOT route this through `mergeJournalCatalog`, which would
 * inject the whole starter catalog (and re-surface hidden behaviours), so only
 * behaviours with real history are eligible, and the empty-state guard is real.
 */
private fun experimentCandidates(
    behaviours: Map<String, Set<String>>,
    importedQuestions: List<String>,
    hidden: List<String>,
    saved: String,
): List<String> {
    val hiddenSet = hidden.map { it.trim().lowercase(Locale.US) }.toHashSet()
    val savedTrim = saved.trim()
    val raw = behaviours.keys.sorted() + importedQuestions +
        (if (savedTrim.isEmpty()) emptyList() else listOf(savedTrim))
    val seen = HashSet<String>()
    val out = mutableListOf<String>()
    for (q in raw) {
        val t = q.trim()
        val key = t.lowercase(Locale.US)
        if (t.isNotEmpty() && key !in hiddenSet && seen.add(key)) out.add(t)
    }
    return out
}

/** The saved behaviour if still eligible, else the first candidate (or null when empty). */
private fun resolveExperimentBehaviour(candidates: List<String>, saved: String): String? {
    val savedTrim = saved.trim()
    if (savedTrim.isNotEmpty() && candidates.contains(savedTrim)) return savedTrim
    return candidates.firstOrNull()
}

private fun buildExperimentSnapshot(
    model: InsightModel,
    behaviours: Map<String, Set<String>>,
    startedDay: String,
    outcome: Outcome,
    behaviour: String?,
    durationDays: Int,
    baselineDays: Int,
): ExperimentSnapshot? {
    if (startedDay.isEmpty() || behaviour == null) return null

    val today = journalDayKey(0L)
    val duration = durationDays.coerceAtLeast(1)
    val outcomeDays = model.outcomeByDay[outcome] ?: emptyMap()
    val loggedDays = behaviours[behaviour] ?: emptySet()

    // Baseline = behaviour-ABSENT days BEFORE the start (with/without model, matching
    // Behaviour Effects). Restricting to absent days is triage fix (c): "Baseline" vs
    // "Intervention" is an honest present-vs-absent contrast, not a raw pre/post window.
    val baselineKeys = outcomeDays.keys
        .filter { it < startedDay && it !in loggedDays }
        .sorted()
        .takeLast(baselineDays.coerceAtLeast(1))
    // Intervention = the first `duration` outcome days from the start where the
    // behaviour WAS logged.
    val interventionWindow = outcomeDays.keys
        .filter { it >= startedDay && it <= today }
        .sorted()
        .take(duration)
    val interventionKeys = interventionWindow.filter { it in loggedDays }

    val baselineValues = baselineKeys.mapNotNull { outcomeDays[it] }
    val interventionValues = interventionKeys.mapNotNull { outcomeDays[it] }
    val daysElapsed = (dayDistance(startedDay, today) + 1).coerceIn(1, duration)
    val complianceFraction = interventionKeys.size.toDouble() / daysElapsed.coerceAtLeast(1)
    val confidence = experimentConfidence(baselineValues.size, interventionValues.size, complianceFraction)

    return ExperimentSnapshot(
        behavior = behaviour,
        outcome = outcome,
        startDay = startedDay,
        durationDays = duration,
        daysElapsed = daysElapsed,
        baselineMean = mean(baselineValues),
        baselineCount = baselineValues.size,
        interventionMean = mean(interventionValues),
        interventionCount = interventionValues.size,
        loggedToday = today in loggedDays,
        compliance = complianceFraction * 100,
        confidence = confidence,
    )
}

private fun experimentConfidence(
    baselineCount: Int,
    interventionCount: Int,
    compliance: Double,
): ExperimentConfidence {
    val paired = minOf(baselineCount, interventionCount)
    return when {
        paired >= 10 && compliance >= 0.65 -> ExperimentConfidence("STRONGER SIGNAL", StrandTone.Positive)
        paired >= 5 -> ExperimentConfidence("EARLY SIGNAL", StrandTone.Accent)
        else -> ExperimentConfidence("LOW SIGNAL", StrandTone.Warning)
    }
}

private fun experimentReading(s: ExperimentSnapshot): String {
    val delta = s.delta
        ?: return "Collect a few logged intervention days before reading the effect. " +
            "Baseline and imported metrics stay in place."
    val absStr = formatExperimentDelta(abs(delta), s.outcome, includeSign = false)
    if (abs(delta) < 0.05) {
        return "${s.outcome.outcomeName} is flat against baseline on logged intervention days."
    }
    val movedGood = if (s.outcome.higherIsBetter) delta > 0 else delta < 0
    return "${s.outcome.outcomeName} is $absStr ${if (movedGood) "better" else "worse"} " +
        "than baseline on days you logged this behaviour."
}

private fun experimentDeltaColor(s: ExperimentSnapshot): Color {
    val delta = s.delta
    if (delta == null || abs(delta) < 0.05) return Palette.textTertiary
    val movedGood = if (s.outcome.higherIsBetter) delta > 0 else delta < 0
    return if (movedGood) Palette.statusPositive else Palette.statusCritical
}

private fun formatExperimentDelta(delta: Double?, outcome: Outcome, includeSign: Boolean = true): String {
    if (delta == null) return "—"
    val prefix = if (!includeSign) "" else if (delta > 0) "+" else if (delta < 0) "−" else ""
    val v = abs(delta).roundToInt()
    return when (outcome) {
        Outcome.Recovery, Outcome.Sleep -> "$prefix$v%"
        Outcome.Hrv -> "$prefix$v ms"
        Outcome.Rhr -> "$prefix$v bpm"
    }
}

/** Whole-day distance between two yyyy-MM-dd keys (0 if either is unparseable). */
private fun dayDistance(start: String, end: String): Int {
    return try {
        ChronoUnit.DAYS.between(LocalDate.parse(start), LocalDate.parse(end)).toInt()
    } catch (_: Exception) {
        0
    }
}

private fun mean(values: List<Double>): Double? =
    if (values.isEmpty()) null else values.sum() / values.size

// MARK: - Experiment persistence (SharedPreferences, parity with Swift @AppStorage keys)

private const val EXP_PREFS = "noop_prefs"
private const val EXP_BEHAVIOUR = "noop.experiment.behaviour"
private const val EXP_OUTCOME = "noop.experiment.outcome"
private const val EXP_STARTED = "noop.experiment.startedDay"
private const val EXP_DURATION = "noop.experiment.durationDays"
private const val EXP_BASELINE = "noop.experiment.baselineDays"

private fun loadExperimentString(context: Context, key: String): String =
    context.getSharedPreferences(EXP_PREFS, Context.MODE_PRIVATE).getString(key, "") ?: ""

private fun saveExperimentString(context: Context, key: String, value: String) {
    context.getSharedPreferences(EXP_PREFS, Context.MODE_PRIVATE).edit().putString(key, value).apply()
}

private fun loadExperimentInt(context: Context, key: String, default: Int): Int =
    context.getSharedPreferences(EXP_PREFS, Context.MODE_PRIVATE).getInt(key, default)

private fun saveExperimentInt(context: Context, key: String, value: Int) {
    context.getSharedPreferences(EXP_PREFS, Context.MODE_PRIVATE).edit().putInt(key, value).apply()
}

// MARK: - Metric relationships section

@Composable
private fun RelationshipsSection(rels: List<Relationship>) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Metric Relationships", overline = "Pearson r")

        if (rels.isEmpty()) {
            NoopCard {
                Text(
                    uiString(R.string.l10n_insights_screen_not_enough_overlapping_history_to_correlate_a552dbd4),
                    style = NoopType.subhead,
                    color = Palette.textTertiary,
                )
            }
        } else {
            // Every curated relationship terminates in Charge, so the card sits in the
            // Charge (green) colour world via a faint wash.
            NoopCard(tint = DomainTheme.Charge.color) {
                Column {
                    rels.forEachIndexed { idx, rel ->
                        RelationshipRow(rel)
                        if (idx < rels.size - 1) {
                            HorizontalDivider(color = Palette.hairline)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun RelationshipRow(rel: Relationship) {
    val strength = correlationColor(rel.r)
    val sentence = relationshipSentence(rel)

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 11.dp)
            .clearAndSetSemantics { contentDescription = sentence },
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                rel.title,
                style = NoopType.headline,
                color = Palette.textPrimary,
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                String.format(Locale.US, "r = %+.2f", rel.r),
                style = NoopType.number(16f),
                color = strength,
            )
            StatePill(
                if (rel.significant) "p < 0.05" else "n.s.",
                tone = if (rel.significant) StrandTone.Accent else StrandTone.Neutral,
                showsDot = false,
            )
        }

        // r bar, centred zero, fills left (negative) / right (positive) by |r|.
        RBar(r = rel.r, color = strength)

        Text(sentence, style = NoopType.subhead, color = Palette.textSecondary)
        Text(rel.blurb, style = NoopType.footnote, color = Palette.textTertiary)
    }
}

/**
 * A centred correlation bar: a faint inset track with a centre tick at zero, and a
 * coloured fill that grows left (negative r) or right (positive r) proportional to |r|.
 * Mirrors the macOS RBar (minus the desktop hover tooltip, the exact r value is already
 * printed beside the title, so the bar is never an unexplained coloured shape on phone).
 */
@Composable
private fun RBar(r: Double, color: Color) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(8.dp)
            .clip(CircleShape)
            .drawBehind {
                val half = size.width / 2f
                val mag = (abs(r).coerceAtMost(1.0)).toFloat() * half
                // Inset track.
                drawLine(
                    color = Palette.surfaceInset,
                    start = Offset(size.height / 2f, size.height / 2f),
                    end = Offset(size.width - size.height / 2f, size.height / 2f),
                    strokeWidth = size.height,
                    cap = StrokeCap.Round,
                )
                // Centre tick.
                drawLine(
                    color = Palette.hairlineStrong,
                    start = Offset(half, 0f),
                    end = Offset(half, size.height),
                    strokeWidth = 1f,
                )
                // Value fill from centre outward.
                if (mag > 0f) {
                    val start = if (r >= 0) Offset(half, size.height / 2f)
                    else Offset(half - mag, size.height / 2f)
                    val end = if (r >= 0) Offset(half + mag, size.height / 2f)
                    else Offset(half, size.height / 2f)
                    drawLine(
                        color = color,
                        start = start,
                        end = end,
                        strokeWidth = size.height,
                        cap = StrokeCap.Round,
                    )
                }
            },
    )
}

// MARK: - Model building + math (simple, honest, no external analytics)

/** Build the per-outcome day maps + ordered series from cached daily metrics. */
private fun buildModel(
    days: List<DailyMetric>,
    behaviours: Map<String, Set<String>>,
    numericJournalSeries: Map<String, Map<String, Double>> = emptyMap(),
): InsightModel {
    val outcomeByDay = mutableMapOf<Outcome, Map<String, Double>>()
    val seriesByOutcome = mutableMapOf<Outcome, List<Pair<String, Double>>>()
    for (o in Outcome.entries) {
        // Oldest → newest; one value per day (DailyMetric PK is (deviceId, day)).
        val series = days.mapNotNull { d -> o.pick(d)?.let { d.day to it } }
        seriesByOutcome[o] = series
        outcomeByDay[o] = series.toMap()
    }
    return InsightModel(behaviours, outcomeByDay, seriesByOutcome, numericJournalSeries)
}

/** Rank behaviour effects for one outcome by |Cohen's d|, significant first. */
private fun rankEffects(model: InsightModel, outcome: Outcome): List<BehaviorEffect> {
    val outcomeDays = model.outcomeByDay[outcome] ?: emptyMap()
    if (outcomeDays.isEmpty()) return emptyList()

    val effects = model.behaviours.mapNotNull { (behaviour, yesDays) ->
        val with = mutableListOf<Double>()
        val without = mutableListOf<Double>()
        for ((day, value) in outcomeDays) {
            if (day in yesDays) with.add(value) else without.add(value)
        }
        // Need both groups to compare; require ≥2 each so a mean/SD is meaningful.
        if (with.size < 2 || without.size < 2) return@mapNotNull null
        BehaviorEffect(
            behavior = behaviour,
            meanWith = with.average(),
            meanWithout = without.average(),
            nWith = with.size,
            nWithout = without.size,
            cohensD = cohensD(with, without),
        )
    }
    return effects.sortedWith(
        compareByDescending<BehaviorEffect> { it.significant }
            .thenByDescending { abs(it.cohensD) },
    )
}

/** The curated metric relationships, computed via Pearson r over aligned day pairs. */
private fun computeRelationships(model: InsightModel): List<Relationship> {
    fun series(o: Outcome) = model.seriesByOutcome[o] ?: emptyList()
    val out = mutableListOf<Relationship>()

    pearsonAligned(series(Outcome.Hrv), series(Outcome.Recovery))?.let { (r, n) ->
        out.add(
            Relationship(
                "hrv-rec", "HRV ↔ Charge",
                "Heart-rate variability as the engine behind your charge score.", r, n,
            ),
        )
    }
    pearsonAligned(series(Outcome.Sleep), series(Outcome.Recovery))?.let { (r, n) ->
        out.add(
            Relationship(
                "sleep-rec", "Rest ↔ Charge",
                "How closely a good night tracks next-morning charge.", r, n,
            ),
        )
    }
    pearsonAligned(series(Outcome.Rhr), series(Outcome.Recovery))?.let { (r, n) ->
        out.add(
            Relationship(
                "rhr-rec", "Resting HR ↔ Charge",
                "A lower resting heart rate usually means a higher charge.", r, n,
            ),
        )
    }
    pearsonLagged(series(Outcome.Recovery), lagDays = 1)?.let { (r, n) ->
        out.add(
            Relationship(
                "rec-lag", "Charge → Next-day charge",
                "How much one day's charge carries into the next.", r, n,
            ),
        )
    }

    return out
}

// MARK: - Statistics (pooled-SD Cohen's d, Pearson r)

/** Cohen's d using pooled standard deviation. 0 when either side lacks spread. */
private fun cohensD(a: List<Double>, b: List<Double>): Double {
    if (a.size < 2 || b.size < 2) return 0.0
    val ma = a.average()
    val mb = b.average()
    val va = variance(a, ma)
    val vb = variance(b, mb)
    val pooled = sqrt(((a.size - 1) * va + (b.size - 1) * vb) / (a.size + b.size - 2).toDouble())
    if (pooled <= 0.0 || !pooled.isFinite()) return 0.0
    return (ma - mb) / pooled
}

/** Sample variance (n-1 denominator) about a known mean. */
private fun variance(xs: List<Double>, mean: Double): Double {
    if (xs.size < 2) return 0.0
    val ss = xs.sumOf { val d = it - mean; d * d }
    return ss / (xs.size - 1).toDouble()
}

/** Pearson r over two (day,value) series aligned on shared days. Returns (r, n) or
 *  null if fewer than 3 overlapping pairs or no variance. */
private fun pearsonAligned(
    xs: List<Pair<String, Double>>,
    ys: List<Pair<String, Double>>,
): Pair<Double, Int>? {
    val ym = ys.toMap()
    val pairs = xs.mapNotNull { (day, x) -> ym[day]?.let { x to it } }
    return pearson(pairs)
}

/** Pearson r of a series against itself shifted forward by [lagDays] days.
 *  Uses index offset on the ordered series (days are oldest → newest). */
private fun pearsonLagged(series: List<Pair<String, Double>>, lagDays: Int): Pair<Double, Int>? {
    if (series.size <= lagDays) return null
    val pairs = (0 until series.size - lagDays).map { i ->
        series[i].second to series[i + lagDays].second
    }
    return pearson(pairs)
}

/** Pearson correlation of paired samples. Null with <3 pairs or no variance. */
private fun pearson(pairs: List<Pair<Double, Double>>): Pair<Double, Int>? {
    val n = pairs.size
    if (n < 3) return null
    val mx = pairs.sumOf { it.first } / n
    val my = pairs.sumOf { it.second } / n
    var sxy = 0.0
    var sxx = 0.0
    var syy = 0.0
    for ((x, y) in pairs) {
        val dx = x - mx
        val dy = y - my
        sxy += dx * dy
        sxx += dx * dx
        syy += dy * dy
    }
    val denom = sqrt(sxx * syy)
    if (denom <= 0.0 || !denom.isFinite()) return null
    return (sxy / denom).coerceIn(-1.0, 1.0) to n
}

/** Rough |r| threshold for "p < 0.05" at n pairs (critical r for a two-tailed test,
 *  approximated by 2 / sqrt(n), a standard rule-of-thumb). Honest, not exact. */
private fun significanceThreshold(n: Int): Double =
    if (n < 4) 1.1 else (2.0 / sqrt(n.toDouble())).coerceAtMost(1.0)

// MARK: - Text + colour helpers

private fun effectSentence(e: BehaviorEffect, outcome: Outcome): String {
    val dir = when {
        e.delta > 0 -> "higher"
        e.delta < 0 -> "lower"
        else -> "no different"
    }
    val name = outcome.outcomeName.lowercase(Locale.US)
    if (e.delta == 0.0) {
        return "On days you logged ${e.behavior.lowercase(Locale.US)}, your $name was no different."
    }
    val withStr = outcome.format(e.meanWith)
    val withoutStr = outcome.format(e.meanWithout)
    return "On days you logged ${e.behavior.lowercase(Locale.US)}, your $name averaged " +
        "$withStr, $dir than the $withoutStr on days you didn't."
}

private fun effectMagnitudeWord(d: Double): String {
    val m = abs(d)
    return when {
        m < 0.2 -> "negligible"
        m < 0.5 -> "small"
        m < 0.8 -> "moderate"
        else -> "large"
    }
}

private fun strengthWord(r: Double): String {
    val m = abs(r)
    return when {
        m < 0.1 -> "No"
        m < 0.3 -> "A weak"
        m < 0.5 -> "A moderate"
        m < 0.7 -> "A strong"
        else -> "A very strong"
    }
}

private fun relationshipSentence(rel: Relationship): String {
    val dir = if (rel.r > 0) "positive" else if (rel.r < 0) "negative" else "flat"
    return "${strengthWord(rel.r)} $dir relationship " +
        "(r = ${String.format(Locale.US, "%.2f", rel.r)}, n = ${rel.n})."
}

/** Tint a correlation by strength, keyed on the recovery gradient so strong positive
 *  reads mint and strong negative reads red. Maps r∈[-1,1] → 0…1 of the scale. */
private fun correlationColor(r: Double): Color =
    Palette.sample(Palette.recoveryStops, ((r + 1.0) / 2.0).toFloat())
