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
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// MARK: - Palette — the "Bevel" re-skin (mirrors StrandDesign/Palette.swift)
//
// A premium dark theme built on a deep BLUE-BLACK canvas (NOT pure black) with
// per-domain accent "colour worlds" (Charge = green, Effort = amber, Rest = indigo,
// Stress = teal). NOOP green stays the dominant brand anchor.
//
// PUBLIC API IS FROZEN: every token NAME below is depended on by screens across the
// app, so the names never change — only the VALUES were re-themed to Bevel. New
// Bevel tokens (domain worlds, gradient pairs, glows, scenic background colours,
// card fills) are ADDED at the end of the object; nothing existing was removed or
// renamed. Hex values mirror the macOS/iOS StrandPalette so all three platforms
// share one visual language.

object Palette {

    // Surfaces — deep blue-black canvas, tinted frosted cards (NOT pure black).
    val surfaceBase = Color(0xFF080A11)    // deep blue-black canvas
    val surfaceRaised = Color(0xFF141826)  // frosted card fill
    val surfaceOverlay = Color(0xFF1A1F30) // popovers / sheets / tooltips
    val surfaceInset = Color(0xFF0E1019)   // wells / chart insets / segmented track
    val hairline = Color(0xFF262B3C)       // soft blue-grey 1px border (≈ white 6%)
    val hairlineStrong = Color(0xFF363D52) // hover / emphasis border

    // Text — cool off-white scale on the blue-black.
    val textPrimary = Color(0xFFF2F4FA)
    val textSecondary = Color(0xFFA6ADC0)
    val textTertiary = Color(0xFF737A8E)

    // Glow — ambient bloom behind heroes / charts.
    val glowAmbient = Color(0xFF1C2A4A)

    // Accent — NOOP green brand anchor (chrome + the Charge world).
    val accent = Color(0xFF2BCF8E)       // brand health green
    val accentHover = Color(0xFF4DEBA8)
    val accentMuted = Color(0xFF12281F)  // dark-green tint (selected rows)
    val focusRing = Color(0xFF2BCF8E)
    const val disabledOpacity = 0.45f

    // Recovery / Charge gradient — the green "Charge" colour world.
    // 0.00 coral → 0.30 amber → 0.55 gold → 0.78 green → 1.00 mint.
    val recovery000 = Color(0xFFFF5C7A) // depleted — coral
    val recovery030 = Color(0xFFFFB23E) // low — amber
    val recovery055 = Color(0xFFE8D14B) // moderate — gold
    val recovery078 = Color(0xFF1D9E75) // primed — deep green
    val recovery100 = Color(0xFF5DFFB0) // peak — bright mint

    /** Ordered gradient stops (position 0..1 → color) for the recovery scale. */
    val recoveryStops: List<Pair<Float, Color>> = listOf(
        0.00f to recovery000,
        0.30f to recovery030,
        0.55f to recovery055,
        0.78f to recovery078,
        1.00f to recovery100,
    )

    // Strain / Effort ramp — the amber "Effort" colour world.
    // Deep ember → warm gold → bright amber → hot amber peak.
    val strain000 = Color(0xFFB9740F) // deep ember
    val strain033 = Color(0xFFE89020) // warm gold
    val strain066 = Color(0xFFFFA836) // bright amber
    val strain100 = Color(0xFFFFC861) // hot amber peak

    val strainStops: List<Pair<Float, Color>> = listOf(
        0.00f to strain000,
        0.33f to strain033,
        0.66f to strain066,
        1.00f to strain100,
    )

    // Sleep stages — the indigo / periwinkle "Rest" colour world.
    val sleepAwake = Color(0xFFFF6F8B) // rose (out of bed)
    val sleepLight = Color(0xFF8E97E0) // periwinkle
    val sleepDeep = Color(0xFF5A63C7)  // indigo
    val sleepREM = Color(0xFFB4BDFF)   // pale periwinkle (glows)

    // HR zones — cool→warm ramp tuned to the Bevel worlds.
    val zone1 = Color(0xFF5AA8E0) // easy — blue
    val zone2 = Color(0xFF3ED1A0) // green
    val zone3 = Color(0xFFE8D14B) // gold
    val zone4 = Color(0xFFFFA836) // amber
    val zone5 = Color(0xFFFF6F8B) // max — rose

    /** HR zones indexed 1..5; index 0 mirrors zone1 for convenience. */
    val hrZones: List<Color> = listOf(zone1, zone1, zone2, zone3, zone4, zone5)

    // Status — never reused as recovery colors.
    val statusPositive = Color(0xFF2BCF8E)
    val statusWarning = Color(0xFFFFB23E)
    val statusCritical = Color(0xFFFF5C7A)

    // Per-metric accents — HRV / SpO₂ / energy / risk, on-brand for Bevel.
    val metricCyan = Color(0xFF46C8FF)   // SpO₂ / steps / Apple Health
    val metricPurple = Color(0xFFB4BDFF) // HRV (shares the Rest world)
    val metricAmber = Color(0xFFFFC861)  // calories (shares the Effort world)
    val metricRose = Color(0xFFFF6F8B)   // risk / heart rate / low recovery

    // MARK: - Bevel domain "colour worlds" (NEW)
    //
    // Each daily score owns a two-stop accent gradient (deep → bright) plus a glow.
    // These drive the layered gauges, frosted-card tints and scenic heroes. Charge
    // re-uses the brand green; Effort the amber ramp; Rest the indigo/periwinkle.

    // Charge (recovery) — green world.
    val chargeColor = Color(0xFF2BCF8E)
    val chargeDeep = Color(0xFF1D9E75)
    val chargeBright = Color(0xFF5DFFB0)
    val chargeGlow = Color(0xFF2BCF8E)

    // Effort (strain) — amber world.
    val effortColor = Color(0xFFFFA836)
    val effortDeep = Color(0xFFB9740F)
    val effortBright = Color(0xFFFFC861)
    val effortGlow = Color(0xFFFFA836)

    // Rest (sleep) — indigo / periwinkle world.
    val restColor = Color(0xFF7E88E0)
    val restDeep = Color(0xFF5A63C7)
    val restBright = Color(0xFFB4BDFF)
    val restGlow = Color(0xFF8E97E0)

    // Stress — teal world (used by StressScreen's accents).
    val stressColor = Color(0xFF3FB8B0)
    val stressDeep = Color(0xFF1F7E78)
    val stressBright = Color(0xFF6FE0D6)
    val stressGlow = Color(0xFF3FB8B0)

    /** Deep → bright accent pairs (gauge stroke + diagonal card wash) per domain. */
    val chargeGradientStops: List<Pair<Float, Color>> = listOf(0.0f to chargeDeep, 1.0f to chargeBright)
    val effortGradientStops: List<Pair<Float, Color>> = listOf(0.0f to effortDeep, 1.0f to effortBright)
    val restGradientStops: List<Pair<Float, Color>> = listOf(0.0f to restDeep, 1.0f to restBright)
    val stressGradientStops: List<Pair<Float, Color>> = listOf(0.0f to stressDeep, 1.0f to stressBright)

    // MARK: Scenic background (NEW) — detail-screen hero gradient + starfield.
    // Radial canvas: warm-lit center → deep edge. Used by ScenicHeroBackground.
    val scenicCenter = Color(0xFF0B0D14)
    val scenicEdge = Color(0xFF07080D)
    val scenicStar = Color(0xFFC9D2F0)

    /** Frosted-card tint endpoints (a subtle dark fill the accent wash sits over). */
    val cardFillTop = Color(0xFF161A26)
    val cardFillBottom = Color(0xFF101219)

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

// MARK: - DomainTheme (NEW — Bevel per-domain colour worlds)
//
// Maps a daily-score domain (Charge / Effort / Rest / Stress) to its accent
// "colour world": a primary colour, a deep→bright gradient for gauge strokes and
// card washes, and a glow colour for blooms / end-cap halos. Every Bevel surface
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
    val cardRadius = 18.dp   // Bevel continuous radius (18–22dp)
    val cornerXs = 2.dp
    val cornerSm = 12.dp
    val cornerBadge = 6.dp
    val cornerPill = 50.dp
    val cardPadding = 16.dp
    val gap = 12.dp           // gap between cards
    val sectionGap = 28.dp    // gap between sections
    val screenPadding = 24.dp
    val tileHeight = 104.dp   // every metric tile is this tall
    val chartHeight = 220.dp
    val divider = 1.dp
    val compactChartHeight = chartHeight - 90.dp
    val selectorTopUp = sectionGap - 20.dp
    val iconButton = 36.dp
    val iconSmall = 18.dp
    val selectorPadding = 10.dp
    val selectorSpacing = 8.dp
    val sparkWidthWide = 64.dp
    val sparkWidth = 58.dp
    val sparkHeight = 22.dp
    val stageStripHeight = 34.dp
    val trendStripHeight = 120.dp
    val sparklineHeight = 28.dp
    val segmentBarHeight = 18.dp
    val legendSwatch = 9.dp
    val legendLineWidth = 14.dp
    val legendLineHeight = 3.dp
    val progressHeight = 10.dp
}

// MARK: - Typography (ported from StrandDesign/Typography.swift §9.2)
//
// SF Pro on macOS; on Android we use the platform default (Roboto/system) with
// the same sizes/weights. Numeric/live styles request tabular-ish alignment via
// medium/semibold weights; Compose has no monospacedDigit toggle, so live values
// use Monospace where exact non-reflow alignment is load-bearing.

object NoopType {
    private val sans = FontFamily.Default
    private val monoFamily = FontFamily.Monospace

    /** Display 64–80 / Semibold — the recovery ring number. */
    fun display(size: Float = 72f) = TextStyle(
        fontFamily = sans, fontWeight = FontWeight.SemiBold, fontSize = size.sp,
    )

    val title1 = TextStyle(fontFamily = sans, fontWeight = FontWeight.Bold, fontSize = 28.sp)
    val title2 = TextStyle(fontFamily = sans, fontWeight = FontWeight.SemiBold, fontSize = 22.sp)
    val headline = TextStyle(fontFamily = sans, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
    val body = TextStyle(fontFamily = sans, fontWeight = FontWeight.Normal, fontSize = 15.sp)
    val subhead = TextStyle(fontFamily = sans, fontWeight = FontWeight.Normal, fontSize = 13.sp)
    val caption = TextStyle(fontFamily = sans, fontWeight = FontWeight.Normal, fontSize = 12.sp)
    val footnote = TextStyle(fontFamily = sans, fontWeight = FontWeight.Normal, fontSize = 11.sp)

    /** Overline 11 / Semibold, +0.8 tracking, ALL-CAPS at use site. */
    val overline = TextStyle(
        fontFamily = sans, fontWeight = FontWeight.SemiBold, fontSize = 11.sp,
        letterSpacing = 0.8.sp,
    )

    /** Mono 13 — raw / log views. */
    val mono = TextStyle(fontFamily = monoFamily, fontWeight = FontWeight.Normal, fontSize = 13.sp)

    /** A numeric style at an arbitrary size (Monospace so live values don't reflow). */
    fun number(size: Float, weight: FontWeight = FontWeight.SemiBold) = TextStyle(
        fontFamily = monoFamily, fontWeight = weight, fontSize = size.sp,
    )

    fun mono(size: Float, weight: FontWeight = FontWeight.Normal) = TextStyle(
        fontFamily = monoFamily, fontWeight = weight, fontSize = size.sp,
    )

    val bodyNumber = TextStyle(fontFamily = monoFamily, fontWeight = FontWeight.Normal, fontSize = 15.sp)
    val captionNumber = TextStyle(fontFamily = monoFamily, fontWeight = FontWeight.Medium, fontSize = 12.sp)
    val metricInline = number(15f)
    val chartValue = number(18f)
    val chartValueLarge = number(22f)
    val tileValue = number(24f)
    val tileValueLarge = number(26f)

    const val overlineTracking = 0.8f
}

// MARK: - Material3 bridge

private val NoopColorScheme = darkColorScheme(
    primary = Palette.accent,
    onPrimary = Palette.surfaceBase,
    primaryContainer = Palette.accentMuted,
    onPrimaryContainer = Palette.accentHover,
    secondary = Palette.metricPurple,
    onSecondary = Palette.surfaceBase,
    background = Palette.surfaceBase,
    onBackground = Palette.textPrimary,
    surface = Palette.surfaceRaised,
    onSurface = Palette.textPrimary,
    surfaceVariant = Palette.surfaceOverlay,
    onSurfaceVariant = Palette.textSecondary,
    outline = Palette.hairline,
    outlineVariant = Palette.hairlineStrong,
    error = Palette.statusCritical,
    onError = Palette.surfaceBase,
)

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
 * NoopTheme — dark, instrument-grade. Always dark regardless of system setting
 * (the design system is dark-only), but `isSystemInDarkTheme` is read so the
 * status-bar contract is satisfied on devices that key off it.
 */
@Composable
fun NoopTheme(content: @Composable () -> Unit) {
    // The design system is dark-only; we always apply the dark scheme regardless of
    // the system setting. `isSystemInDarkTheme` is referenced so status-bar tooling
    // that keys off it stays satisfied.
    isSystemInDarkTheme()
    MaterialTheme(
        colorScheme = NoopColorScheme,
        typography = NoopMaterialTypography,
        shapes = NoopShapes,
        content = content,
    )
}
