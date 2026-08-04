package com.noop.ui

import com.noop.R
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.clickable

// MARK: - NoopButton — the unified button system (Design Reset, 2026-06-22)
//
// Compose port of StrandDesign/NoopButton.swift. One button, four kinds, no glow. Beauty comes
// from a crisp filled accent, honest surface fills, restrained spacing and a subtle press —
// never neon, bloom or a halo. Labels are sentence-case (never ALL CAPS), single line, with the
// optional leading icon as one unit, and degrade gracefully under Reduce Motion (the press scale
// drops; only the dim remains).
//
// NOTE ON COLOUR (Design Reset): the accent here is the WHOOP link/action BLUE, matching the
// iOS reset (`StrandPalette.accent` = #60A0E0 dark / #234F9E light, "gold killed 2026-06-22").
// The Android `Palette.accent` token still carries the pre-reset GOLD, so this file pins the
// reset blue locally rather than reading the stale token — keeping the hard "no gold" rule and
// the iOS values exactly. Label-on-fill is crisp white (iOS `goldDeepText` is #FFFFFF post-reset).

/** The four button roles. Colour + emphasis differ; geometry is identical across all four. */
enum class NoopButtonKind {
    /** Filled accent (blue), white label — the one primary action on a screen. */
    Primary,
    /** Raised-surface fill, primary-text label, hairline edge — secondary actions. */
    Secondary,
    /** No fill, accent label — low-emphasis / inline actions. */
    Tertiary,
    /** Filled critical (red), white label — destructive / irreversible actions. */
    Destructive,
}

// MARK: - Shared geometry (single source of truth for button shape)

private object NoopButtonMetrics {
    /** Standard control height (48). */
    val height = 48.dp
    /** Corner radius (14) — softer than a card, not a pill. */
    val cornerRadius = 14.dp
    /** Horizontal label inset. */
    val hPadding = 18.dp
    /** Spacing between a leading icon and the label. */
    val iconSpacing = 8.dp
    /** Apple's minimum touch target. */
    val minHitTarget = 44.dp
    /** Pressed scale (subtle 0.97). Reduce Motion collapses this to 1 (dim only). */
    const val pressedScale = 0.97f
    /** Pressed dim — a slight opacity drop, applied in BOTH motion modes. */
    const val pressedOpacity = 0.82f
    /** Disabled dim. */
    const val disabledOpacity = 0.4f
}

// MARK: - Design-reset accent (WHOOP blue) — pinned to the iOS values, never gold

/** The reset accent blue (iOS `StrandPalette.accent`: #234F9E light / #60A0E0 dark). */
private val noopAccentBlue: Color
    @Composable get() = if (Palette.isLight) Color(0xFF234F9E) else Color(0xFF60A0E0)

/** Crisp white label/icon on accent + critical fills (iOS `goldDeepText` = #FFFFFF post-reset). */
private val noopOnFill: Color = Color(0xFFFFFFFF)

/** Resolves a [NoopButtonKind] to its concrete fill / label / border tokens. */
private data class NoopButtonAppearance(
    val fill: Color?,     // null = no fill (tertiary)
    val label: Color,
    val border: Color?,   // null = no hairline edge
)

@Composable
private fun appearanceFor(kind: NoopButtonKind): NoopButtonAppearance = when (kind) {
    NoopButtonKind.Primary -> NoopButtonAppearance(
        fill = noopAccentBlue, label = noopOnFill, border = null,
    )
    NoopButtonKind.Secondary -> NoopButtonAppearance(
        fill = Palette.surfaceRaised, label = Palette.textPrimary, border = Palette.hairline,
    )
    NoopButtonKind.Tertiary -> NoopButtonAppearance(
        fill = null, label = noopAccentBlue, border = null,
    )
    NoopButtonKind.Destructive -> NoopButtonAppearance(
        fill = Palette.statusCritical, label = noopOnFill, border = null,
    )
}

// MARK: - NoopButton (the convenience view)

/**
 * The unified button. A sentence-case title, an optional leading icon, a [NoopButtonKind], an
 * optional [fullWidth], and an action. Crisp, flat, glow-free; subtle press; 44dp hit floor;
 * Reduce-Motion aware. Mirrors iOS `NoopButton`.
 *
 * ```
 * NoopButton(text = uiString(R.string.l10n_noop_button_save_changes_179359b3), leadingIcon = Icons.Filled.Check, kind = NoopButtonKind.Primary, fullWidth = true) {
 *     save()
 * }
 * ```
 *
 * @param text the sentence-case label (single line).
 * @param leadingIcon optional leading icon, 8dp before the label.
 * @param kind the button role (default Primary).
 * @param fullWidth stretch to the available width.
 * @param enabled when false the button dims and ignores taps.
 * @param onClick the tap action.
 */
@Composable
fun NoopButton(
    text: String,
    leadingIcon: ImageVector? = null,
    kind: NoopButtonKind = NoopButtonKind.Primary,
    fullWidth: Boolean = false,
    enabled: Boolean = true,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val reduced = rememberReduceMotion()
    val appearance = appearanceFor(kind)

    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()

    // Reduce Motion: no scale, dim only. Otherwise subtle scale + dim. Pressed dim applies in both.
    val targetScale = if (pressed && !reduced) NoopButtonMetrics.pressedScale else 1f
    val scale by animateFloatAsState(
        targetValue = targetScale,
        animationSpec = if (reduced) tween(0) else NoopMotion.value(),
        label = uiString(R.string.l10n_noop_button_noopbutton_scale_1bee88be),
    )
    val opacity = when {
        !enabled -> NoopButtonMetrics.disabledOpacity
        pressed -> NoopButtonMetrics.pressedOpacity
        else -> 1f
    }

    val shape = RoundedCornerShape(NoopButtonMetrics.cornerRadius)

    var box = modifier
        .graphicsLayer { scaleX = scale; scaleY = scale }
        .alpha(opacity)
        .let { if (fullWidth) it.fillMaxWidth() else it }
        .height(NoopButtonMetrics.height)
        .defaultMinSize(minHeight = NoopButtonMetrics.minHitTarget)
        .clip(shape)

    if (appearance.fill != null) box = box.background(appearance.fill, shape)
    if (appearance.border != null) box = box.border(BorderStroke(1.dp, appearance.border), shape)

    box = box
        .clickable(
            interactionSource = interaction,
            indication = null,
            enabled = enabled,
            role = Role.Button,
            onClick = onClick,
        )
        .padding(horizontal = NoopButtonMetrics.hPadding)

    Row(
        modifier = box,
        horizontalArrangement = Arrangement.spacedBy(
            NoopButtonMetrics.iconSpacing, Alignment.CenterHorizontally,
        ),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (leadingIcon != null) {
            Icon(
                imageVector = leadingIcon,
                contentDescription = null, // the text labels the button
                tint = appearance.label,
                modifier = Modifier.height(18.dp),
            )
        }
        Text(
            text = text,
            style = NoopType.headline.copy(
                fontWeight = FontWeight.SemiBold,
                letterSpacing = 0.2.sp, // a hair of openness on the semibold face (iOS tracking 0.2)
            ),
            color = appearance.label,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/**
 * The "an export is running" row: spinner plus a short status word, shown under a button that is
 * disabled while its work is in flight.
 *
 * Five call sites across Settings and Test Centre had this block copied verbatim, down to the 18.dp and
 * the 2.dp stroke, so a change to how a busy export reads meant editing it five times and the copies
 * could drift. The update-checker's inline spinner is deliberately NOT folded in here: it is a different
 * size, sits inside its button rather than under it, and says "Checking…".
 */
@Composable
fun NoopBusyRow() {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        CircularProgressIndicator(
            color = Palette.accent,
            strokeWidth = 2.dp,
            modifier = Modifier.size(18.dp),
        )
        Text(uiString(R.string.l10n_settings_screen_working_13b7bfca), style = NoopType.footnote, color = Palette.textSecondary)
    }
}
