package com.noop.ui

import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.Easing
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import android.app.Activity
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// MARK: - Palette — the "Titanium & Gold" re-skin (mirrors StrandDesign/Palette.swift)
//
// A premium dark theme built on a deep NAVY canvas (NOT pure black) with per-domain
// accent "colour worlds": Charge/recovery = GOLD, Effort/strain = amber, Rest/sleep =
// blue, HRV = teal, high stress = burnt orange. Gold is the dominant brand anchor —
// no greens anywhere.
//
// PUBLIC API IS FROZEN: every token NAME below is depended on by screens across the
// app, so the names never change — only the VALUES were re-themed to Titanium & Gold.
// New tokens (gold/titanium ramps + their gradients) are ADDED at the end of the
// object; nothing existing was removed or renamed. Hex values mirror the macOS/iOS
// StrandPalette so all three platforms share one visual language.

object Palette {

    // The active scheme's tokens — snapshot state, so a flip re-resolves every read below (in
    // composables AND Canvas DrawScopes) with no call-site changes. Set by NoopTheme.
    internal var active by mutableStateOf(DarkTokens)
    /** True when the light scheme is active (surface code uses this for the per-scheme idiom). */
    val isLight: Boolean get() = active === LightTokens

    // Chart style — when CLASSIC, the DATA accessors below return the throwback red→green ramps
    // (light/dark tuned). Reads ChartStylePrefs.style (snapshot state) so a flip re-colours live.
    val isClassic: Boolean get() = ChartStylePrefs.style == ChartStyle.CLASSIC
    private val classic: ClassicRamp get() = if (isLight) ClassicLight else ClassicDark

    // Surfaces.
    val surfaceBase get() = active.surfaceBase
    val surfaceRaised get() = active.surfaceRaised
    val surfaceOverlay get() = active.surfaceOverlay
    val surfaceInset get() = active.surfaceInset
    val hairline get() = active.hairline
    val hairlineStrong get() = active.hairlineStrong

    // Text.
    val textPrimary get() = active.textPrimary
    val textSecondary get() = active.textSecondary
    val textTertiary get() = active.textTertiary

    // #1160/#1161: the Liquid hero card surface, now theme-aware — near-black in dark, frosted white in
    // light so the hero fits in with the other cards; the border flips with it. The hero's own text uses
    // the flip-able text* tokens now (readable on either fill).
    val heroFill get() = active.heroFill
    val heroBorder get() = active.heroBorder
    // Light-on-dark text for a GENUINELY-always-dark surface (twin of StrandPalette.onDarkSecondary). The
    // theme-aware hero no longer uses this; kept for any always-dark chrome.
    val onDarkSecondary = Color(0xFFC8CFD8)

    // Glow.
    val glowAmbient get() = active.glowAmbient

    // Accent — user-selectable chrome anchor (mint default / WHOOP blue / custom). Chrome ONLY; the
    // recovery/strain/sleep DATA worlds are never themed by this. Reads AccentPrefs snapshot state so a
    // change is live. Twin of macOS StrandPalette.accent* branching on AccentColor.
    val accent get() = when (AccentPrefs.color) {
        AccentColor.MINT -> active.accent
        AccentColor.WHOOP_BLUE -> if (isLight) Color(0xFF234F9E) else Color(0xFF60A0E0)
        AccentColor.CUSTOM -> AccentColor.parseHex(AccentPrefs.customHex, active.accent)
    }
    val accentHover get() = when (AccentPrefs.color) {
        AccentColor.MINT -> active.accentHover
        AccentColor.WHOOP_BLUE -> if (isLight) Color(0xFF3A6FC0) else Color(0xFF8FBEEC)
        AccentColor.CUSTOM -> AccentColor.lighten(AccentPrefs.customHex)
    }
    val accentMuted get() = when (AccentPrefs.color) {
        AccentColor.MINT -> active.accentMuted
        AccentColor.WHOOP_BLUE -> (if (isLight) Color(0xFF234F9E) else Color(0xFF60A0E0)).copy(alpha = 0.18f)
        AccentColor.CUSTOM -> AccentColor.parseHex(AccentPrefs.customHex, active.accent).copy(alpha = 0.18f)
    }
    val focusRing get() = if (AccentPrefs.color == AccentColor.MINT) active.focusRing else accent
    const val disabledOpacity = 0.45f

    // Recovery / Charge gradient.
    val recovery000 get() = active.recovery000
    val recovery030 get() = active.recovery030
    val recovery055 get() = active.recovery055
    val recovery078 get() = active.recovery078
    val recovery100 get() = active.recovery100

    /** Ordered gradient stops for the recovery scale (Titanium gold, or Classic red→green). */
    val recoveryStops: List<Pair<Float, Color>>
        get() = if (isClassic) classic.recovery
                else listOf(0.00f to recovery000, 0.30f to recovery030, 0.55f to recovery055, 0.78f to recovery078, 1.00f to recovery100)

    // Strain / Effort ramp.
    val strain000 get() = active.strain000
    val strain033 get() = active.strain033
    val strain066 get() = active.strain066
    val strain100 get() = active.strain100

    val strainStops: List<Pair<Float, Color>>
        get() = if (isClassic) classic.strain
                else listOf(0.00f to strain000, 0.33f to strain033, 0.66f to strain066, 1.00f to strain100)

    // Sleep stages (Classic adds a purple REM).
    val sleepAwake get() = if (isClassic) classic.sleepAwake else active.sleepAwake
    val sleepLight get() = if (isClassic) classic.sleepLight else active.sleepLight
    val sleepDeep get() = if (isClassic) classic.sleepDeep else active.sleepDeep
    val sleepREM get() = if (isClassic) classic.sleepREM else active.sleepREM

    // HR zones (Classic = grey→green→yellow→orange→red).
    val zone1 get() = if (isClassic) classic.zone1 else active.zone1
    val zone2 get() = if (isClassic) classic.zone2 else active.zone2
    val zone3 get() = if (isClassic) classic.zone3 else active.zone3
    val zone4 get() = if (isClassic) classic.zone4 else active.zone4
    val zone5 get() = if (isClassic) classic.zone5 else active.zone5

    /** HR zones indexed 1..5; index 0 mirrors zone1 for convenience. */
    val hrZones: List<Color> get() = listOf(zone1, zone1, zone2, zone3, zone4, zone5)

    // Status (Classic = green/amber/red).
    val statusPositive get() = if (isClassic) classic.statusPositive else active.statusPositive
    val statusWarning get() = if (isClassic) classic.statusWarning else active.statusWarning
    val statusCritical get() = if (isClassic) classic.statusCritical else active.statusCritical

    // Per-metric accents (Classic = purple HRV, red risk).
    val metricCyan get() = if (isClassic) classic.metricCyan else active.metricCyan
    val metricPurple get() = if (isClassic) classic.metricPurple else active.metricPurple
    val metricAmber get() = if (isClassic) classic.metricAmber else active.metricAmber
    val metricRose get() = if (isClassic) classic.metricRose else active.metricRose

    // Domain "colour worlds" (Classic: Charge green, Effort blue, Rest indigo, Stress amber).
    val chargeColor get() = if (isClassic) classic.chargeColor else active.chargeColor
    val chargeDeep get() = if (isClassic) classic.chargeDeep else active.chargeDeep
    val chargeBright get() = if (isClassic) classic.chargeBright else active.chargeBright
    val chargeGlow get() = if (isClassic) classic.chargeColor else active.chargeGlow

    val effortColor get() = if (isClassic) classic.effortColor else active.effortColor
    val effortDeep get() = if (isClassic) classic.effortDeep else active.effortDeep
    val effortBright get() = if (isClassic) classic.effortBright else active.effortBright
    val effortGlow get() = if (isClassic) classic.effortColor else active.effortGlow

    val restColor get() = if (isClassic) classic.restColor else active.restColor
    val restDeep get() = if (isClassic) classic.restDeep else active.restDeep
    val restBright get() = if (isClassic) classic.restBright else active.restBright
    val restGlow get() = if (isClassic) classic.restColor else active.restGlow

    val stressColor get() = if (isClassic) classic.stressColor else active.stressColor
    val stressDeep get() = if (isClassic) classic.stressDeep else active.stressDeep
    val stressBright get() = if (isClassic) classic.stressBright else active.stressBright
    val stressGlow get() = if (isClassic) classic.stressColor else active.stressGlow

    /** Deep → bright accent pairs (gauge stroke + diagonal card wash) per domain. */
    val chargeGradientStops: List<Pair<Float, Color>> get() = listOf(0.0f to chargeDeep, 1.0f to chargeBright)
    val effortGradientStops: List<Pair<Float, Color>> get() = listOf(0.0f to effortDeep, 1.0f to effortBright)
    val restGradientStops: List<Pair<Float, Color>> get() = listOf(0.0f to restDeep, 1.0f to restBright)
    // Stress ramp: Titanium calm-blue→gold→orange, or Classic green→amber→red.
    val stressGradientStops: List<Pair<Float, Color>>
        get() = if (isClassic) classic.stress else listOf(0.0f to stressDeep, 0.5f to stressColor, 1.0f to stressBright)

    // Scenic background.
    val scenicCenter get() = active.scenicCenter
    val scenicEdge get() = active.scenicEdge
    val scenicStar get() = active.scenicStar

    /** Frosted-card tint endpoints (the accent wash sits over them). */
    val cardFillTop get() = active.cardFillTop
    val cardFillBottom get() = active.cardFillBottom

    // Gold & Titanium ramps.
    val gold get() = active.gold
    val goldLight get() = active.goldLight
    val goldDeep get() = active.goldDeep
    val goldDeepText get() = active.goldDeepText
    val signalYellow get() = active.signalYellow

    /** Gold gradient stops (light → gold → deep) — buttons, ring fills, FAB (135–155°). */
    val goldGradient: List<Pair<Float, Color>> get() = listOf(0.0f to goldLight, 0.5f to gold, 1.0f to goldDeep)

    val titaniumTop get() = active.titaniumTop
    val titaniumMid get() = active.titaniumMid
    val titaniumLow get() = active.titaniumLow
    val titaniumDeep get() = active.titaniumDeep

    /** Titanium gradient stops (top → mid → low → deep) — tiles / avatars / icon (150°). */
    val titaniumGradient: List<Pair<Float, Color>>
        get() = listOf(0.0f to titaniumTop, 0.40f to titaniumMid, 0.75f to titaniumLow, 1.0f to titaniumDeep)

    /** Gauge-tip / sparkline-head core — white on dark, deep ink on light. */
    val tipCore get() = active.tipCore

    // MARK: - Sampling helpers (mirror StrandPalette.sample / recoveryColor)

    /** Linear-interpolate two colors in sRGB space (matches StrandPalette.interpolate). */
    private fun lerp(a: Color, b: Color, t: Float): Color {
        val tt = t.coerceIn(0f, 1f)
        return Color(
            red = a.red + (b.red - a.red) * tt,
            green = a.green + (b.green - a.green) * tt,
            blue = a.blue + (b.blue - a.blue) * tt,
            alpha = a.alpha + (b.alpha - a.alpha) * tt,
        )
    }

    /** Sample a set of (location, color) stops at a normalized position 0..1. */
    fun sample(stops: List<Pair<Float, Color>>, position: Float): Color {
        if (stops.isEmpty()) return Color.Transparent
        if (stops.size == 1) return stops.first().second
        val t = position.coerceIn(0f, 1f)
        var lower = stops.first()
        var upper = stops.last()
        for (i in 0 until stops.size - 1) {
            val a = stops[i]
            val b = stops[i + 1]
            if (t >= a.first && t <= b.first) {
                lower = a; upper = b; break
            }
        }
        val span = upper.first - lower.first
        val localT = if (span > 0f) (t - lower.first) / span else 0f
        return lerp(lower.second, upper.second, localT)
    }

    /** Sample the recovery gradient at a recovery score 0..100. */
    fun recoveryColor(score: Double): Color = sample(recoveryStops, (score / 100.0).toFloat())

    /** Sample the strain gradient at an Effort value on the 0..100 scale. */
    fun strainColor(strain: Double): Color = sample(strainStops, (strain / 100.0).toFloat())

    /**
     * Effort tint sampled by a 0..1 fraction (e.g. value/scaleMax), spreading the full ember→amber
     * ramp. Prefer this for gauge tips / value-tinted accents so a high Effort reads as bright amber
     * rather than ember. strainColor() stays for callers holding a 0..100 value.
     */
    fun effortTint(fraction: Double): Color = sample(strainStops, fraction.coerceIn(0.0, 1.0).toFloat())

    /** The state word for a recovery score, per spec §9.3. */
    fun recoveryState(score: Double): String = when {
        score < 25 -> "DEPLETED"
        score < 50 -> "LOW"
        score < 70 -> "MODERATE"
        score < 88 -> "PRIMED"
        else -> "PEAK"
    }

    /** HR-zone color for a 1..5 zone index (clamped). */
    fun hrZoneColor(zone: Int): Color = hrZones[zone.coerceIn(1, 5)]

    /** The signature recovery gradient as a horizontal sweep brush (for bars). */
    fun recoveryBrush(): Brush =
        Brush.horizontalGradient(*recoveryStops.toTypedArray())

    /** The strain ramp as a horizontal sweep brush. */
    fun strainBrush(): Brush =
        Brush.horizontalGradient(*strainStops.toTypedArray())
}

// MARK: - DomainTheme (NEW — Titanium & Gold per-domain colour worlds)
//
// Maps a daily-score domain (Charge / Effort / Rest / Stress) to its accent
// "colour world": a primary colour, a deep→bright gradient for gauge strokes and
// card washes, and a glow colour for blooms / end-cap halos. Every surface
// (layered gauge, frosted card tint, scenic hero) reads its colours from here so a
// screen only has to name its domain. Mirrors StrandDesign/DomainTheme.swift.

enum class DomainTheme {
    Charge,
    Effort,
    Rest,
    Stress;

    /** The dominant accent colour for the world. */
    val color: Color
        get() = when (this) {
            Charge -> Palette.chargeColor
            Effort -> Palette.effortColor
            Rest -> Palette.restColor
            Stress -> Palette.stressColor
        }

    /** The deep (low) end of the world's accent ramp. */
    val deep: Color
        get() = when (this) {
            Charge -> Palette.chargeDeep
            Effort -> Palette.effortDeep
            Rest -> Palette.restDeep
            Stress -> Palette.stressDeep
        }

    /** The bright (high) end of the world's accent ramp. */
    val bright: Color
        get() = when (this) {
            Charge -> Palette.chargeBright
            Effort -> Palette.effortBright
            Rest -> Palette.restBright
            Stress -> Palette.stressBright
        }

    /** The world's glow colour for blooms and gauge end-caps. */
    val glow: Color
        get() = when (this) {
            Charge -> Palette.chargeGlow
            Effort -> Palette.effortGlow
            Rest -> Palette.restGlow
            Stress -> Palette.stressGlow
        }

    /** Deep → bright gradient stops for gauge strokes and the diagonal card wash. */
    val gradientStops: List<Pair<Float, Color>>
        get() = when (this) {
            Charge -> Palette.chargeGradientStops
            Effort -> Palette.effortGradientStops
            Rest -> Palette.restGradientStops
            Stress -> Palette.stressGradientStops
        }

    /** The data gradient the world samples values along (Charge/Rest/Stress = recovery
     *  scale, Effort = strain ramp), used by sparklines and value-tinted strokes. */
    val dataStops: List<Pair<Float, Color>>
        get() = when (this) {
            Effort -> Palette.strainStops
            else -> Palette.recoveryStops
        }

    /** A short upper-case label for the world (CHARGE / EFFORT / REST / STRESS). */
    val label: String get() = name
}

// MARK: - Motion (ported from StrandDesign/Motion.swift §9.6)
//
// Physiological motion — breathe / pulse / flow, no cartoon bounce.

object Motion {
    // Durations (ms)
    const val durationFast = 180       // hover/press feedback
    const val durationStandard = 300   // card appear, fades
    const val durationSlow = 900       // ring arc, waveform ignite
    const val breathPeriodMs = 3200    // one breath cycle for ambient pulsing

    // Easings (Compose equivalents of the SwiftUI curves)
    val easeOut: Easing = LinearOutSlowInEasing
    val easeInOut: Easing = FastOutSlowInEasing
    val drawIn: Easing = LinearOutSlowInEasing
    val interactive: Easing = CubicBezierEasing(0.2f, 0.0f, 0.0f, 1.0f)
}

// MARK: - Shared UI tokens (ported Android-side from the StrandDesign contract)

object StrandAlpha {
    const val subtleLine = 0.60f
    const val selectedFill = 0.12f
    const val selectedBorder = 0.55f
    const val chartFillStrong = 0.28f
    const val chartFillSoft = 0.04f
    const val chartMarker = 0.35f
    const val chartShadow = 0.28f
    const val chartLabel = 0.95f
    const val unselectedBar = 0.88f
    const val warningFill = 0.12f
    const val warningBorder = 0.40f
}

// MARK: - Metrics (ported from StrandDesign/Components.swift NoopMetrics)

object Metrics {
    val space2 = 2.dp
    val space4 = 4.dp
    val space6 = 6.dp
    val space8 = 8.dp
    val space10 = 10.dp
    val space12 = 12.dp
    val space14 = 14.dp
    val space16 = 16.dp
    val space18 = 18.dp
    val space24 = 24.dp
    val sourceBadgeHeight = 18.dp
    val cardRadius = 18.dp   // Bevel continuous radius (18–22dp)
    val cornerXs = 2.dp
    val cornerSm = 12.dp
    val cornerBadge = 6.dp
    val cornerPill = 50.dp
    val cardPadding = 16.dp
    val gap = 12.dp           // gap between cards
    val sectionGap = 28.dp    // gap between sections
    // #765: the ONE inter-card vertical spacing for a screen's top-level scroll rows. Both ScreenScaffold
    // and LazyScreenScaffold use this for `spacedBy(...)`, so every Today/Explore card sits on the same
    // rhythm instead of a bare `20.dp` literal repeated per scaffold (and Today no longer injects ad-hoc
    // Spacer rows that broke that rhythm). One token = uniform, consistent gaps across the screens.
    val screenRowSpacing = 20.dp
    val screenPadding = 24.dp
    val tileHeight = 108.dp   // every metric tile is this tall
    val chartHeight = 220.dp
    val divider = 1.dp
    val compactChartHeight = chartHeight - 90.dp
    val selectorTopUp = sectionGap - screenRowSpacing
    val iconButton = 36.dp
    val iconSmall = 18.dp
    val selectorPadding = 10.dp
    val selectorSpacing = 8.dp
    val sparkWidthWide = 48.dp   // inline trend beside a tile value — kept compact so the value (which
                                 // shrinks to fit, #332) keeps enough room to stay legible at full size
    val sparkWidth = 58.dp
    val sparkHeight = 22.dp
    val stageStripHeight = 34.dp
    val motionStripHeight = 40.dp   // #407 — the subordinate movement/restlessness trace under the hypnogram
    // iOS #988 port — WHOOP-style per-stage sleep timeline rows (design 2026-07-10).
    val stageRowTrackHeight = 20.dp  // hatched night track + solid stage segments
    val stageRowCorner = 10.dp       // row background rounding
    val stageRowPadH = 10.dp         // row inner horizontal padding — MotionStrip/axis share it so epochs align
    val stageRowPadV = 8.dp          // row inner vertical padding
    val stageSegMinWidth = 2.dp      // width floor so a brief fragment reads as a block, not a hairline
    val stageSegCorner = 1.5.dp      // solid segment rounding
    val stageInsightHeight = 36.dp   // fixed insight slot height — selection never reflows the card
    val trendStripHeight = 120.dp
    val sparklineHeight = 28.dp
    val segmentBarHeight = 18.dp
    val legendSwatch = 9.dp
    val legendLineWidth = 14.dp
    val legendLineHeight = 3.dp
    val progressHeight = 10.dp
    val editorListMaxHeight = 390.dp
}

// MARK: - Typography (ported from StrandDesign/Typography.swift §9.2)
//
// Helvetica Neue on Apple; on Android we use a Helvetica-Neue FontFamily where one
// is bundled in res/font, else FontFamily.SansSerif as the documented substitute
// (no Helvetica asset is bundled, so the platform grotesque stands in) with the same
// sizes/weights. Numeric/live styles stay in the house sans and request TABULAR
// figures via fontFeatureSettings = "tnum" (mirroring iOS .monospacedDigit()) so live
// values don't reflow; Monospace is reserved for the `mono` raw/log style only.

object NoopType {
    // Helvetica Neue family — falls back to the platform grotesque (SansSerif) when
    // no res/font/helvetica_neue asset is bundled, per the v3 type spec.
    private val sans = FontFamily.SansSerif
    private val monoFamily = FontFamily.Monospace

    /** Display 64–80 / Bold — the recovery ring number. Tight tracking (≈ -0.04em),
     *  tabular figures so a changing value never reflows. Mirrors StrandFont.display. */
    fun display(size: Float = 72f) = TextStyle(
        fontFamily = sans, fontWeight = FontWeight.Bold, fontSize = size.sp,
        letterSpacing = displayTracking(size).sp, fontFeatureSettings = "tnum",
    )

    /** The tight tracking for big display numbers (≈ -0.04em). Already applied inside
     *  display(); exposed to mirror StrandFont.displayTracking. */
    fun displayTracking(size: Float = 72f): Float = -size * 0.04f

    val title1 = TextStyle(fontFamily = sans, fontWeight = FontWeight.Bold, fontSize = 28.sp)
    val title2 = TextStyle(fontFamily = sans, fontWeight = FontWeight.SemiBold, fontSize = 22.sp)
    val headline = TextStyle(fontFamily = sans, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
    val body = TextStyle(fontFamily = sans, fontWeight = FontWeight.Normal, fontSize = 15.sp)
    val subhead = TextStyle(fontFamily = sans, fontWeight = FontWeight.Normal, fontSize = 13.sp)
    val caption = TextStyle(fontFamily = sans, fontWeight = FontWeight.Normal, fontSize = 12.sp)
    val footnote = TextStyle(fontFamily = sans, fontWeight = FontWeight.Normal, fontSize = 11.sp)

    /** Overline 11 / Bold, +1.4 tracking, ALL-CAPS at use site. */
    val overline = TextStyle(
        fontFamily = sans, fontWeight = FontWeight.Bold, fontSize = 11.sp,
        letterSpacing = 1.4.sp,
    )

    /** Mono 13 — raw / log views. */
    val mono = TextStyle(fontFamily = monoFamily, fontWeight = FontWeight.Normal, fontSize = 13.sp)

    /** A numeric style at an arbitrary size — the house sans with TABULAR figures
     *  ('tnum') so live values don't reflow. Mirrors StrandFont.number. */
    fun number(size: Float, weight: FontWeight = FontWeight.SemiBold) = TextStyle(
        fontFamily = sans, fontWeight = weight, fontSize = size.sp, fontFeatureSettings = "tnum",
    )

    fun mono(size: Float, weight: FontWeight = FontWeight.Normal) = TextStyle(
        fontFamily = monoFamily, fontWeight = weight, fontSize = size.sp,
    )

    val bodyNumber = TextStyle(fontFamily = sans, fontWeight = FontWeight.Medium, fontSize = 15.sp, fontFeatureSettings = "tnum")
    val captionNumber = TextStyle(fontFamily = sans, fontWeight = FontWeight.Medium, fontSize = 12.sp, fontFeatureSettings = "tnum")
    val metricInline = number(15f)
    val chartValue = number(18f)
    val chartValueLarge = number(22f)
    val tileValue = number(24f)
    val tileValueLarge = number(26f)

    const val overlineTracking = 1.4f
}

// MARK: - Material3 bridge

/** Build the Material3 colour scheme from a token set. Dark/light differ only in the builder used
 *  (which sets sensible defaults for the slots we don't override); the NOOP surfaces are all driven
 *  by `Palette.*` directly, so this only feeds Material components (text fields, switches, etc.). */
private fun noopColorScheme(t: PaletteTokens, dark: Boolean): ColorScheme {
    val base = if (dark) darkColorScheme() else lightColorScheme()
    return base.copy(
        primary = t.accent,
        onPrimary = if (dark) t.surfaceBase else t.goldDeepText,
        primaryContainer = t.accentMuted,
        onPrimaryContainer = if (dark) t.accentHover else t.accent,
        secondary = t.metricPurple,
        onSecondary = if (dark) t.surfaceBase else Color(0xFFFFFFFF),
        background = t.surfaceBase,
        onBackground = t.textPrimary,
        surface = t.surfaceRaised,
        onSurface = t.textPrimary,
        surfaceVariant = t.surfaceOverlay,
        onSurfaceVariant = t.textSecondary,
        outline = t.hairline,
        outlineVariant = t.hairlineStrong,
        error = t.statusCritical,
        onError = if (dark) t.surfaceBase else Color(0xFFFFFFFF),
    )
}

private val NoopMaterialTypography = Typography(
    displayLarge = NoopType.display(72f),
    titleLarge = NoopType.title1,
    titleMedium = NoopType.title2,
    titleSmall = NoopType.headline,
    bodyLarge = NoopType.body,
    bodyMedium = NoopType.subhead,
    bodySmall = NoopType.caption,
    labelLarge = NoopType.headline,
    labelMedium = NoopType.caption,
    labelSmall = NoopType.overline,
)

private val NoopShapes = Shapes(
    extraSmall = RoundedCornerShape(8.dp),
    small = RoundedCornerShape(12.dp),
    medium = RoundedCornerShape(Metrics.cardRadius),
    large = RoundedCornerShape(20.dp),
    extraLarge = RoundedCornerShape(28.dp),
)

/**
 * NoopTheme — instrument-grade, now System / Light / Dark. The chosen mode (default System) drives
 * both `Palette.active` (so every `Palette.*` read re-resolves) and the Material scheme. The write to
 * `Palette.active` is guarded + idempotent, and happens before children compose, so there's no flash
 * and no recomposition loop (NoopTheme itself never reads `active`).
 */
@Composable
fun NoopTheme(content: @Composable () -> Unit) {
    val dark = when (AppearancePrefs.mode) {
        AppearanceMode.LIGHT -> false
        AppearanceMode.DARK -> true
        AppearanceMode.SYSTEM -> isSystemInDarkTheme()
    }
    val tokens = if (dark) DarkTokens else LightTokens
    if (Palette.active !== tokens) Palette.active = tokens

    // Status-/nav-bar icon appearance: light icons on the dark theme, dark icons on the warm-paper
    // light theme (otherwise the icons are invisible). Edge-to-edge keeps the bars transparent.
    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            (view.context as? Activity)?.window?.let { window ->
                val controller = WindowCompat.getInsetsController(window, view)
                controller.isAppearanceLightStatusBars = !dark
                controller.isAppearanceLightNavigationBars = !dark
            }
        }
    }

    MaterialTheme(
        colorScheme = noopColorScheme(tokens, dark),
        typography = NoopMaterialTypography,
        shapes = NoopShapes,
        content = content,
    )
}
