package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.LocalDrink
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.analytics.HydrationGoal
import com.noop.analytics.HydrationStore
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

// MARK: - Hydration detail (MVP, opt-in, local-only) — LIQUID restyle
//
// Liquid finish (matching the liquid Today pilot — TodayScreen.kt / LiquidScreenSky.kt / LiquidPrimitives.kt):
// the day-of-sky settles behind the header (LiquidScreenSky, gated on the same showDayCycleBackground pref),
// the headline fill becomes a LiquidVessel (water in a vessel — the literal fit) with the litre figure
// counting up over it, the daily goal reads as a LiquidTube, and the quick-log controls are liquid-press
// tiles. Everything below stays crisp: the 7-day mini bars are a multi-bar chart (not a single value, so no
// tube), the flat cards keep the frosted surface. All data bindings, the pure HydrationGoal engine, and the
// local-only HydrationStore reads/writes are UNCHANGED — this is a restyle only. Mirrors the iOS HydrationView.

/** The reset accent blue (matches NoopButton's pinned iOS `StrandPalette.accent`: #234F9E / #60A0E0). */
private val hydrationAccent: Color
    @Composable get() = if (Palette.isLight) Color(0xFF234F9E) else Color(0xFF60A0E0)

// MARK: - Liquid hero tokens (shared with the liquid Today hero card)
//
// The frosted translucent near-black the hydration vessel floats on (mock rgba(13,14,20,.80)), so the vessel
// + the white count-up litre figure read crisp over the day-of-sky. Radius 26 + a white@0.11 hairline give
// the frosted-glass edge. Same numbers as the liquid Today heroCard (TodayScreen.kt LIQUID_HERO_*).
private val LIQUID_HERO_RADIUS = 26.dp

/** Upper bound (ml) for a single custom hydration log (#798) - a sane cap so a stray digit can't bank an
 *  absurd 50-litre day. A 3-litre container covers any realistic bottle/jug. Mirrors the iOS clamp. */
private const val MAX_CUSTOM_ML: Int = 3000

/** Parse a custom-amount field to a clamped whole-ml value in 1..[MAX_CUSTOM_ML], or null when the text
 *  isn't a usable positive number. Pure + side-effect-free so the dialog's confirm gate is unit-testable. */
internal fun parseCustomHydrationMl(text: String): Int? {
    val n = text.trim().toIntOrNull() ?: return null
    if (n <= 0) return null
    return n.coerceAtMost(MAX_CUSTOM_ML)
}

/**
 * The Hydration detail screen. The goal's effort bump uses today's Effort/strain (0..100) read from the
 * view-model's `today` row (null leaves the bump at 0). The screen reads/writes via [viewModel].repo;
 * the SharedPreferences-backed profile sex is read once. A log tap appends to the local-only day total
 * and refreshes the vessel + history.
 */
@Composable
fun HydrationScreen(viewModel: AppViewModel) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    val today by viewModel.today.collectAsStateWithLifecycle()
    val strain = today?.strain

    val sex = remember { ProfileStore.from(context).sex }
    val goalMl = remember(sex, strain) { HydrationGoal.dailyGoalMl(sex, strain) }

    // The liquid sky backdrop honours the SAME opt-out pref as the liquid Today (a user who turned the
    // day-cycle sky off gets the flat canvas here too). Mirrors iOS `showDayCycleBackground ? ... : nil`.
    val showDayCycleBackground = remember { NoopPrefs.showDayCycleBackground(context) }
    val skyBehindCards = remember { NoopPrefs.skyBehindCards(context) }

    // Today's running total + the per-day history, loaded off the gesture path and refreshed after a log.
    var totalMl by remember { mutableStateOf(0.0) }
    var history by remember { mutableStateOf<List<Pair<String, Double>>>(emptyList()) }
    // A simple reload key the log taps bump so the LaunchedEffect re-reads the store.
    var reloadTick by remember { mutableStateOf(0) }
    // #949: water imported from Health Connect. Already part of [totalMl]; read separately so the screen
    // can name where it came from rather than leaving an unexplained jump in the day figure.
    var importedMl by remember { mutableStateOf(0.0) }
    LaunchedEffect(reloadTick) {
        totalMl = runCatching { HydrationStore.total(viewModel.repo) }.getOrDefault(0.0)
        history = runCatching { HydrationStore.history(viewModel.repo, days = 7) }.getOrDefault(emptyList())
        importedMl = runCatching { HydrationStore.importedTotal(viewModel.repo) }.getOrDefault(0.0)
    }

    // #798 - the LAST amount logged this session, so the detail can offer a one-tap "Undo" that removes
    // exactly that container from the day total. The single-total schema can't address an individual log,
    // so undo subtracts the last known amount (clamped at 0 by the store). Reset to null after an undo so
    // the affordance only appears when there's something to take back. Not persisted - a relaunch shows
    // the day total but no pending undo, which is honest (you can still correct via the custom dialog).
    var lastLoggedMl by remember { mutableStateOf<Int?>(null) }
    // The custom-amount dialog (the "custom container size" - log any ml the quick buttons don't cover).
    var showCustom by remember { mutableStateOf(false) }

    val log: (Int) -> Unit = { amount ->
        scope.launch {
            runCatching { HydrationStore.log(viewModel.repo, amount) }
            if (amount > 0) lastLoggedMl = amount
            reloadTick += 1
        }
    }
    // Remove [amount] ml from the day total (the undo / delete-a-log path, #798). Clears the pending undo.
    val remove: (Int) -> Unit = { amount ->
        scope.launch {
            runCatching { HydrationStore.remove(viewModel.repo, amount) }
            lastLoggedMl = null
            reloadTick += 1
        }
    }

    val fraction = if (goalMl > 0) (totalMl / goalMl).toFloat() else 0f
    val accent = hydrationAccent

    // #798 - the custom-amount entry. Logs any whole-ml amount the Sip/Cup/Bottle quick buttons don't
    // cover (a bespoke container), clamped to a sane 1..MAX_CUSTOM_ML, then routed through the SAME
    // additive `log` path so it accumulates into the day total and refreshes the vessel + history.
    if (showCustom) {
        CustomAmountDialog(
            accent = accent,
            onDismiss = { showCustom = false },
            onConfirm = { ml ->
                showCustom = false
                log(ml)
            },
        )
    }

    // PERF (#707): lazy scaffold — each top-level section is one `item { }`. Order + spacing unchanged
    // (LazyColumn reproduces the eager `spacedBy(20.dp)`); only on-screen cards compose + are
    // accessibility-walked. All children are unconditional, so every wrap is a bare `item { }`.
    //
    // LIQUID: the day-of-sky sits behind the header via the scaffold's topBackground slot (the pilot
    // pattern — LiquidScreenSky.kt), replacing the classic flat canvas. Gated on the day-cycle pref, so an
    // opted-out user still gets the plain surface. Mirrors the liquid Today scaffold.
    LazyScreenScaffold(
        title = uiString(R.string.l10n_hydration_screen_hydration_bdfb040f),
        subtitle = "Your fluid intake today, on this phone only.",
        topBackground = screenBackdropSlot(showDayCycleBackground, skyBehindCards),
        // Sky-behind-cards fills the viewport so the transparent cards reveal the sky the whole way
        // down (Today / Trends / Sleep / metric-detail parity - same two prefs, same two behaviours).
        fullBleedBackground = screenBackdropFullBleed(showDayCycleBackground, skyBehindCards),
    ) {
        // HERO — the day's intake as a LiquidVessel (water in a vessel: the literal fit), with the litre
        // figure counting up over it, floating on the frosted translucent-black liquid hero card so it reads
        // crisp on the day-of-sky. The daily goal is a LiquidTube beneath. Same fraction math + accent +
        // litre values as the GlowRing this replaced. Mirrors the iOS liquid hero idiom (HeroScoreVessel).
        item {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(LIQUID_HERO_RADIUS))
                    .background(Palette.heroFill.copy(alpha = Palette.heroFill.alpha * CardAppearance.opacity))
                    .border(1.dp, Palette.heroBorder.copy(alpha = Palette.heroBorder.alpha * CardAppearance.opacity), RoundedCornerShape(LIQUID_HERO_RADIUS))
                    .padding(20.dp),
            ) {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        // The vessel fills to the goal fraction in the hydration accent. It runs LIVE (per-frame
                        // slosh + tilt) once anything is logged today; a fresh empty day poses it static so the
                        // launch isn't fighting a live canvas. Honours Reduce Motion internally.
                        LiquidVessel(
                            value = fraction.toDouble().coerceIn(0.0, 1.0),
                            tint = accent,
                            animated = totalMl > 0.0,
                            modifier = Modifier.size(184.dp),
                        )
                        // The litre count-up over the vessel — white, tabular, a soft shadow for legibility,
                        // hit-transparent (clearAndSetSemantics + no clickable) so a tap falls THROUGH to the
                        // vessel (LiquidVessel owns its own tap→splash+haptic). Mirrors the iOS HeroScoreCell.
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            modifier = Modifier.clearAndSetSemantics {},
                        ) {
                            CountUpText(
                                value = totalMl / 1000.0,
                                format = { String.format(Locale.US, "%.1f", it) },
                                style = NoopType.number(40f, weight = FontWeight.Bold).copy(
                                    shadow = Shadow(
                                        color = Color.Black.copy(alpha = 0.5f),
                                        offset = Offset(0f, 1f),
                                        blurRadius = 6f,
                                    ),
                                ),
                                color = Color.White,
                            )
                            Text(
                                String.format(Locale.US, "of %.1f L", goalMl / 1000.0),
                                style = NoopType.subhead,
                                color = Color.White.copy(alpha = 0.72f),
                            )
                        }
                    }
                    // DAILY GOAL — a genuine single-value progress bar, so it reads as a LiquidTube (static:
                    // it sits in a detail hero, not a live surface). Same goal fraction as the vessel.
                    LiquidTube(
                        frac = fraction.toDouble().coerceIn(0.0, 1.0),
                        tint = accent,
                        height = Metrics.progressHeight,
                        animated = false,
                        modifier = Modifier
                            .fillMaxWidth()
                            .semantics {
                                contentDescription =
                                    uiString(R.string.l10n_hydration_screen_kotlin_math_min_100_fraction_100_416d2889, kotlin.math.min(100, (fraction * 100).toInt()))
                            },
                    )
                    Text(
                        uiString(R.string.l10n_hydration_screen_kotlin_math_min_100_fraction_100_72f2dfde, kotlin.math.min(100, (fraction * 100).toInt())),
                        style = NoopType.footnote,
                        color = Color.White.copy(alpha = 0.6f),
                    )
                }
            }
        }

        // LOG TILES — Sip / Cup / Bottle, as liquid-press tiles (the log controls). Each owns its own
        // interactionSource wired to BOTH its clickable and liquidPress, so the whole tile settles inward on
        // press (the iOS LiquidPressStyle feel), routing the SAME `log(...)` amounts as before.
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                LiquidLogTile(
                    label = uiString(R.string.l10n_hydration_screen_sip_78cca3e8),
                    icon = Icons.Filled.WaterDrop,
                    accent = accent,
                    modifier = Modifier.weight(1f),
                ) { log(HydrationGoal.SIP_ML) }
                LiquidLogTile(
                    label = uiString(R.string.l10n_hydration_screen_cup_04b95071),
                    icon = Icons.Filled.LocalDrink,
                    accent = accent,
                    modifier = Modifier.weight(1f),
                ) { log(HydrationGoal.CUP_ML) }
                LiquidLogTile(
                    label = uiString(R.string.l10n_hydration_screen_bottle_3b8ac6c7),
                    icon = Icons.Filled.LocalDrink,
                    accent = accent,
                    modifier = Modifier.weight(1f),
                ) { log(HydrationGoal.BOTTLE_ML) }
            }
        }
        // #798 - "Custom" (a bespoke container size). Full-width secondary button under the quick-add tiles;
        // opens the custom-amount dialog so any ml the presets don't cover can be logged. (Kept as a
        // NoopButton — it carries its own press feedback and this is a secondary affordance, not a quick-log.)
        item {
            NoopButton(
                text = uiString(R.string.l10n_hydration_screen_custom_amount_f7219236),
                leadingIcon = Icons.Filled.Add,
                kind = NoopButtonKind.Secondary,
                modifier = Modifier.fillMaxWidth(),
            ) { showCustom = true }
        }
        item {
            Text(
                uiString(R.string.l10n_hydration_screen_sip_hydrationgoal_sip_ml_ml_cup_287647f5, HydrationGoal.SIP_ML, HydrationGoal.CUP_ML, HydrationGoal.BOTTLE_ML),
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }

        // 7-DAY HISTORY — flat mini bars, today on the right. Kept CRISP: this is a multi-bar mini chart
        // (one bar per day), not a single-value progress bar, so a tube would flatten it — leave it as-is.
        item {
            NoopCard(padding = 18.dp) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Overline("Last 7 days")
                    HydrationHistoryBars(history = history, goalMl = goalMl, accent = accent)
                }
            }
        }

        // TODAY'S TOTAL as a single read-out row (the MVP "logged entries" — the day total is the running
        // sum the store banks; per-tap rows aren't separately persisted, so we show the honest day figure).
        item {
            NoopCard(padding = 18.dp) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Overline("Today")
                    if (totalMl <= 0.0) {
                        Text(
                            uiString(R.string.l10n_hydration_screen_no_drinks_logged_yet_tap_sip_cc0d2f72),
                            style = NoopType.subhead,
                            color = Palette.textSecondary,
                        )
                    } else {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(
                                Icons.Filled.WaterDrop,
                                contentDescription = null,
                                tint = accent,
                                modifier = Modifier.size(18.dp),
                            )
                            Spacer(Modifier.width(10.dp))
                            Text(
                                uiString(R.string.l10n_hydration_screen_logged_today_0071a46c),
                                style = NoopType.subhead,
                                color = Palette.textPrimary,
                                modifier = Modifier.weight(1f),
                            )
                            Text(
                                uiString(R.string.l10n_hydration_screen_totalml_toint_ml_522b262a, totalMl.toInt()),
                                style = NoopType.headline.copy(fontWeight = FontWeight.SemiBold),
                                color = Palette.textPrimary,
                            )
                        }
                        // #949: name the imported share rather than folding it silently into the figure
                        // above — otherwise the day total moves on its own after a Health Connect import
                        // and nothing on screen accounts for it.
                        if (importedMl > 0.0) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Spacer(Modifier.width(28.dp))
                                Text(
                                    uiString(R.string.l10n_hydration_screen_from_health_connect_4ad037a3),
                                    style = NoopType.footnote,
                                    color = Palette.textSecondary,
                                    modifier = Modifier.weight(1f),
                                )
                                Text(
                                    uiString(R.string.l10n_hydration_screen_totalml_toint_ml_522b262a, importedMl.toInt()),
                                    style = NoopType.footnote,
                                    color = Palette.textSecondary,
                                )
                            }
                        }
                        // #798 - undo / correct affordances. "Undo last" appears once something has been logged
                        // this session and removes exactly that container from the day total. "Clear today" zeroes
                        // the day's total outright (the delete-everything correction). Both route through the
                        // store's clamped remove/set, so the total never goes negative.
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                            lastLoggedMl?.let { last ->
                                NoopButton(
                                    text = uiString(R.string.l10n_hydration_screen_undo_last_last_ml_330befc5, last),
                                    leadingIcon = Icons.AutoMirrored.Filled.Undo,
                                    kind = NoopButtonKind.Secondary,
                                    modifier = Modifier.weight(1f),
                                ) { remove(last) }
                            }
                            // #949: clears only what NOOP owns. Passing the COMBINED total here would ask
                            // the store to subtract imported water from the hand-logged row — the row it
                            // isn't in — and the button is offered only when there is something of ours
                            // to clear, so it never sits there doing visibly nothing on an import-only day.
                            val manualMl = (totalMl - importedMl).toInt()
                            if (manualMl > 0) {
                                NoopButton(
                                    text = uiString(R.string.l10n_hydration_screen_clear_today_1be870ea),
                                    leadingIcon = Icons.Filled.Delete,
                                    kind = NoopButtonKind.Secondary,
                                    modifier = Modifier.weight(1f),
                                ) { remove(manualMl) }
                            }
                        }
                    }
                }
            }
        }

        item {
            Text(
                uiString(R.string.l10n_hydration_screen_a_simple_goal_that_adjusts_to_723dc08a),
                style = NoopType.footnote,
                color = Palette.textTertiary,
                textAlign = TextAlign.Start,
            )
        }
    }
}

/**
 * One quick-log tile (Sip / Cup / Bottle) as a liquid-press control. The tile owns a single
 * [MutableInteractionSource] wired to BOTH its `clickable` and `Modifier.liquidPress`, so the whole tile
 * settles inward (0.975 scale / 0.86 alpha) on press — the iOS LiquidPressStyle feel — then fires [onLog].
 * A frosted card surface + an accent-tinted icon tile keep it on the liquid palette. Mirrors the iOS
 * hydration quick-add button.
 */
@Composable
private fun LiquidLogTile(
    label: String,
    icon: ImageVector,
    accent: Color,
    modifier: Modifier = Modifier,
    onLog: () -> Unit,
) {
    val interaction = remember { MutableInteractionSource() }
    Column(
        modifier = modifier
            .liquidPress(interaction)
            .clip(RoundedCornerShape(Metrics.cardRadius))
            .frostedCardSurface(cornerRadius = Metrics.cardRadius)
            .clickable(
                interactionSource = interaction,
                indication = null,
                onClickLabel = "Log $label",
                onClick = onLog,
            )
            .padding(vertical = 14.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(
            modifier = Modifier
                .size(34.dp)
                .clip(RoundedCornerShape(9.dp))
                .background(accent.copy(alpha = 0.14f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = accent, modifier = Modifier.size(17.dp))
        }
        Text(
            label,
            style = NoopType.headline.copy(fontWeight = FontWeight.SemiBold),
            color = Palette.textPrimary,
        )
    }
}

/**
 * The 7-day mini bar history: one flat rounded bar per day, height = day total ÷ goal (clamped to 1), with
 * the weekday initial beneath. Today's bar is the accent blue; prior days a muted accent. Empty days render
 * a faint track. Pure Compose Canvas + a row of labels (design-reset flat style, no gridlines/axes).
 */
@Composable
private fun HydrationHistoryBars(
    history: List<Pair<String, Double>>,
    goalMl: Int,
    accent: Color,
) {
    if (history.isEmpty()) {
        Text(uiString(R.string.l10n_hydration_screen_no_history_yet_933f417e), style = NoopType.footnote, color = Palette.textTertiary)
        return
    }
    val goal = goalMl.coerceAtLeast(1).toDouble()
    val track = Palette.textPrimary.copy(alpha = 0.10f)
    val priorBar = accent.copy(alpha = 0.45f)
    val lastIndex = history.lastIndex
    val maxMl = history.maxOf { it.second }
    // Scale the bars to the LARGER of the goal and the biggest day, so an over-goal day doesn't clip.
    val ceiling = kotlin.math.max(goal, maxMl).coerceAtLeast(1.0)

    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Canvas(modifier = Modifier.fillMaxWidth().height(96.dp)) {
            val n = history.size
            val gap = 10.dp.toPx()
            val barW = (size.width - gap * (n - 1)) / n
            val corner = 6.dp.toPx()
            history.forEachIndexed { i, (_, ml) ->
                val x = i * (barW + gap)
                // Track (full-height faint bar).
                drawRoundRectBar(x, 0f, barW, size.height, corner, track)
                val frac = (ml / ceiling).toFloat().coerceIn(0f, 1f)
                if (frac > 0f) {
                    val h = size.height * frac
                    val color = if (i == lastIndex) accent else priorBar
                    drawRoundRectBar(x, size.height - h, barW, h, corner, color)
                }
            }
        }
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            history.forEach { (dayKey, _) ->
                Text(
                    weekdayInitial(dayKey),
                    style = NoopType.overline.copy(letterSpacing = 0.2.sp),
                    color = Palette.textTertiary,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

/** Draw one rounded-rect bar via the Canvas draw scope (small helper so the bar loop stays readable). */
private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawRoundRectBar(
    x: Float,
    y: Float,
    w: Float,
    h: Float,
    corner: Float,
    color: Color,
) {
    drawRoundRect(
        color = color,
        topLeft = Offset(x, y),
        size = Size(w, h),
        cornerRadius = androidx.compose.ui.geometry.CornerRadius(corner, corner),
    )
}

/** The single-letter weekday for a yyyy-MM-dd key (M T W T F S S), or "·" when unparseable. */
private fun weekdayInitial(dayKey: String): String =
    runCatching {
        LocalDate.parse(dayKey).format(DateTimeFormatter.ofPattern("EEE", Locale.US)).take(1)
    }.getOrDefault("·")

/**
 * #798 - the custom-amount dialog. A single numeric ml field (the "custom container size") with a clamped
 * confirm: the Log button is disabled until the text parses to a positive whole-ml value (1..MAX_CUSTOM_ML
 * via [parseCustomHydrationMl]), and confirming hands the parsed amount back to the caller's additive log.
 * Tokens-only on the hydration-blue field; mirrors the iOS custom-amount sheet.
 */
@Composable
private fun CustomAmountDialog(
    accent: Color,
    onDismiss: () -> Unit,
    onConfirm: (Int) -> Unit,
) {
    var text by remember { mutableStateOf("") }
    val parsed = parseCustomHydrationMl(text)
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Filled.WaterDrop,
                    contentDescription = null,
                    tint = accent,
                    modifier = Modifier.size(20.dp),
                )
                Spacer(Modifier.width(10.dp))
                Text(uiString(R.string.l10n_hydration_screen_custom_amount_f7219236), style = NoopType.title2, color = Palette.textPrimary)
            }
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = text,
                    onValueChange = { new -> text = new.filter { it.isDigit() }.take(5) },
                    label = { Text(uiString(R.string.l10n_hydration_screen_millilitres_ml_0fb0d2a4), style = NoopType.footnote) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = Palette.textPrimary,
                        unfocusedTextColor = Palette.textPrimary,
                        cursorColor = accent,
                        focusedBorderColor = accent,
                        unfocusedBorderColor = Palette.hairline,
                        focusedLabelColor = accent,
                        unfocusedLabelColor = Palette.textSecondary,
                        focusedContainerColor = Palette.surfaceInset,
                        unfocusedContainerColor = Palette.surfaceInset,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    uiString(R.string.l10n_hydration_screen_enter_any_amount_from_1_to_a85a639e, MAX_CUSTOM_ML),
                    style = NoopType.footnote,
                    color = if (text.isNotEmpty() && parsed == null) Palette.statusWarning else Palette.textTertiary,
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { parsed?.let(onConfirm) }, enabled = parsed != null) {
                Text(uiString(R.string.l10n_hydration_screen_log_8bf95ea3), color = if (parsed != null) accent else Palette.textTertiary)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(uiString(R.string.l10n_hydration_screen_cancel_77dfd213), color = Palette.textSecondary)
            }
        },
    )
}
