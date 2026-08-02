package com.noop.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.Icon
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import com.noop.R

/**
 * Five-page modal Quick Launch: fixed-slot favourites followed by the four destination catalogues.
 * The caller owns the full-screen scrim, which prevents interaction with every view behind the panel.
 */
@OptIn(ExperimentalFoundationApi::class, ExperimentalMaterial3Api::class)
@Composable
internal fun QuickLaunchPanel(
    onDismiss: () -> Unit,
    onLaunch: (LaunchItem) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val prefs = remember(context) { NoopPrefs.of(context) }
    var slots by remember { mutableStateOf(QuickLaunchPrefs.read(prefs)) }
    var editing by remember { mutableStateOf(false) }
    var showPicker by remember { mutableStateOf(false) }
    var downwardDrag by remember { mutableFloatStateOf(0f) }
    val pagerState = rememberPagerState(pageCount = { QuickLaunchCatalog.pages.size + 1 })
    val fontScale = LocalDensity.current.fontScale
    val gridHeight = Metrics.quickLaunchGridMinHeight +
        Metrics.quickLaunchGridFontExpansion * (fontScale - 1f).coerceAtLeast(0f)

    LaunchedEffect(pagerState.currentPage) {
        if (pagerState.currentPage != 0) editing = false
    }

    fun updateSlots(next: List<String?>) {
        slots = QuickLaunchPrefs.normalize(next)
        QuickLaunchPrefs.write(prefs, slots)
    }

    Surface(
        color = Palette.surfaceRaised.copy(alpha = Metrics.quickLaunchGlassAlpha),
        contentColor = Palette.textPrimary,
        shape = RoundedCornerShape(Metrics.quickLaunchPanelRadius),
        tonalElevation = Metrics.quickLaunchGlassTonalElevation,
        shadowElevation = Metrics.quickLaunchGlassShadowElevation,
        modifier = modifier
            .fillMaxWidth()
            .widthIn(max = Metrics.quickLaunchPanelMaxWidth)
            .border(Metrics.divider, Palette.hairlineStrong, RoundedCornerShape(Metrics.quickLaunchPanelRadius))
            .graphicsLayer { translationY = downwardDrag },
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = Metrics.quickLaunchPanelHorizontalInset)
                .padding(top = Metrics.space8, bottom = Metrics.space14),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(Metrics.space18)
                    .pointerInput(Unit) {
                        detectVerticalDragGestures(
                            onVerticalDrag = { change, amount ->
                                change.consume()
                                downwardDrag = (downwardDrag + amount).coerceAtLeast(0f)
                            },
                            onDragCancel = { downwardDrag = 0f },
                            onDragEnd = {
                                if (downwardDrag >= Metrics.quickLaunchDismissDragDistance.toPx()) onDismiss()
                                downwardDrag = 0f
                            },
                        )
                    },
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    Modifier
                        .width(Metrics.quickLaunchDragHandleWidth)
                        .height(Metrics.quickLaunchDragHandleHeight)
                        .clip(CircleShape)
                        .background(Palette.hairlineStrong),
                )
            }

            QuickLaunchHeader(
                title = if (pagerState.currentPage == 0) {
                    stringResource(R.string.quick_launch_favourites)
                } else {
                    stringResource(QuickLaunchCatalog.pages[pagerState.currentPage - 1].titleRes)
                },
                showEditControls = pagerState.currentPage == 0 && editing,
                hasEmptySlot = slots.any { it == null },
                onAddOrChange = {
                    editing = false
                    showPicker = true
                },
                onCancel = { editing = false },
            )

            HorizontalPager(
                state = pagerState,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(gridHeight),
                userScrollEnabled = true,
            ) { page ->
                if (page == 0) {
                    FavouriteLaunchGrid(
                        slots = slots,
                        editing = editing,
                        onEditingChange = { editing = it },
                        onSlotsChange =(::updateSlots),
                        onChoose = { showPicker = true },
                        onLaunch = onLaunch,
                    )
                } else {
                    StaticLaunchGrid(
                        items = QuickLaunchCatalog.pages[page - 1].items,
                        onLaunch = onLaunch,
                    )
                }
            }

            PageDots(
                pageCount = QuickLaunchCatalog.pages.size + 1,
                currentPage = pagerState.currentPage,
                modifier = Modifier.align(Alignment.CenterHorizontally),
            )
        }
    }

    if (showPicker) {
        QuickLaunchPicker(
            slots = slots,
            onDismiss = { showPicker = false },
            onSlotsChange =(::updateSlots),
            onAdd = { item -> updateSlots(QuickLaunchPrefs.addFirstEmpty(slots, item.id)) },
            onReset = { updateSlots(QuickLaunchPrefs.defaultSlots) },
        )
    }
}

@Composable
private fun QuickLaunchHeader(
    title: String,
    showEditControls: Boolean,
    hasEmptySlot: Boolean,
    onAddOrChange: () -> Unit,
    onCancel: () -> Unit,
) {
    val modifier = Modifier
        .fillMaxWidth()
        .padding(vertical = Metrics.space4)
    val stacked = LocalDensity.current.fontScale >= Metrics.quickLaunchStackedHeaderFontScale
    if (showEditControls && stacked) {
        Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
            Text(title, style = NoopType.headline, color = Palette.textPrimary, textAlign = TextAlign.Center)
            QuickLaunchHeaderControls(
                hasEmptySlot = hasEmptySlot,
                onAddOrChange = onAddOrChange,
                onCancel = onCancel,
            )
        }
    } else {
        Box(modifier = modifier, contentAlignment = Alignment.Center) {
            Text(title, style = NoopType.headline, color = Palette.textPrimary, textAlign = TextAlign.Center)
            if (showEditControls) {
                QuickLaunchHeaderControls(
                    hasEmptySlot = hasEmptySlot,
                    onAddOrChange = onAddOrChange,
                    onCancel = onCancel,
                )
            }
        }
    }
}

@Composable
private fun QuickLaunchHeaderControls(
    hasEmptySlot: Boolean,
    onAddOrChange: () -> Unit,
    onCancel: () -> Unit,
) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        QuickLaunchHeaderChip(
            label = stringResource(
                if (hasEmptySlot) R.string.quick_launch_add else R.string.quick_launch_change,
            ),
            color = Palette.accent,
            onClick = onAddOrChange,
        )
        Spacer(Modifier.weight(1f))
        QuickLaunchHeaderChip(
            label = stringResource(R.string.quick_launch_cancel),
            color = Palette.textSecondary,
            onClick = onCancel,
        )
    }
}

@Composable
private fun QuickLaunchHeaderChip(label: String, color: androidx.compose.ui.graphics.Color, onClick: () -> Unit) {
    Surface(
        color = Palette.surfaceOverlay,
        contentColor = color,
        shape = CircleShape,
        border = androidx.compose.foundation.BorderStroke(Metrics.divider, Palette.hairlineStrong),
        modifier = Modifier
            .widthIn(min = Metrics.quickLaunchHeaderChipMinWidth)
            .clip(CircleShape)
            .clickable(role = Role.Button, onClick = onClick),
    ) {
        Text(
            label,
            style = NoopType.subhead,
            color = color,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = Metrics.space10, vertical = Metrics.space8),
        )
    }
}

@Composable
private fun StaticLaunchGrid(items: List<LaunchItem>, onLaunch: (LaunchItem) -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = Metrics.quickLaunchGridHorizontalPadding),
        verticalArrangement = Arrangement.SpaceEvenly,
    ) {
        repeat(3) { row ->
            Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically) {
                repeat(3) { column ->
                    val item = items.getOrNull(row * 3 + column)
                    Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                        if (item != null) LaunchTile(item = item, onClick = { onLaunch(item) })
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun LaunchTile(
    item: LaunchItem,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    onLongClick: (() -> Unit)? = null,
    iconModifier: Modifier = Modifier,
    iconOverlay: (@Composable BoxScope.() -> Unit)? = null,
) {
    val label = stringResource(item.titleRes)
    Column(
        modifier = modifier
            .widthIn(min = Metrics.quickLaunchIconCircle, max = Metrics.quickLaunchTileMaxWidth)
            .then(
                if (onLongClick == null) Modifier.clickable(role = Role.Button, onClick = onClick)
                else Modifier.combinedClickable(
                    role = Role.Button,
                    onClick = onClick,
                    onLongClick = onLongClick,
                    onLongClickLabel = stringResource(R.string.quick_launch_edit_favourites),
                )
            )
            .semantics { contentDescription = label }
            .padding(vertical = Metrics.space4),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Metrics.quickLaunchLabelGap),
    ) {
        Box(contentAlignment = Alignment.Center) {
            Surface(
                color = Palette.surfaceOverlay,
                shape = CircleShape,
                modifier = iconModifier.size(Metrics.quickLaunchIconCircle),
                border = androidx.compose.foundation.BorderStroke(Metrics.divider, Palette.hairline),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        item.icon,
                        contentDescription = null,
                        tint = Palette.accent,
                        modifier = Modifier.size(Metrics.quickLaunchIconGlyph),
                    )
                }
            }
            iconOverlay?.invoke(this)
        }
        Text(
            label,
            style = NoopType.footnote,
            color = Palette.textSecondary,
            textAlign = TextAlign.Center,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun PageDots(pageCount: Int, currentPage: Int, modifier: Modifier = Modifier) {
    Row(modifier = modifier.padding(top = Metrics.space6), horizontalArrangement = Arrangement.spacedBy(Metrics.space6)) {
        repeat(pageCount) { index ->
            Box(
                Modifier
                    .width(if (index == currentPage) Metrics.quickLaunchPageDotActiveWidth else Metrics.quickLaunchPageDot)
                    .height(Metrics.quickLaunchPageDot)
                    .clip(CircleShape)
                    .background(if (index == currentPage) Palette.accent else Palette.hairlineStrong),
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun QuickLaunchPicker(
    slots: List<String?>,
    onDismiss: () -> Unit,
    onSlotsChange: (List<String?>) -> Unit,
    onAdd: (LaunchItem) -> Unit,
    onReset: () -> Unit,
) {
    val fontScale = LocalDensity.current.fontScale
    val gridHeight = Metrics.quickLaunchGridMinHeight +
        Metrics.quickLaunchGridFontExpansion * (fontScale - 1f).coerceAtLeast(0f)
    val resetDescription = stringResource(R.string.quick_launch_reset_description)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceRaised,
        contentColor = Palette.textPrimary,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Metrics.cardPadding)
                .padding(bottom = Metrics.space24),
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                    Text(
                        stringResource(R.string.quick_launch_reset),
                        style = NoopType.body,
                        color = Palette.accent,
                        modifier = Modifier
                            .clip(RoundedCornerShape(Metrics.cornerSm))
                            .clickable(role = Role.Button, onClick = onReset)
                            .semantics { contentDescription = resetDescription }
                            .padding(Metrics.space8),
                    )
                }
                Text(
                    stringResource(R.string.quick_launch_edit_favourites),
                    style = NoopType.headline,
                    textAlign = TextAlign.Center,
                    maxLines = 2,
                    modifier = Modifier.weight(2f),
                )
                Box(Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) {
                    Text(
                        stringResource(R.string.quick_launch_done),
                        style = NoopType.body,
                        color = Palette.accent,
                        modifier = Modifier
                            .clip(RoundedCornerShape(Metrics.cornerSm))
                            .clickable(role = Role.Button, onClick = onDismiss)
                            .padding(Metrics.space8),
                    )
                }
            }
            Text(
                pluralStringResource(
                    R.plurals.quick_launch_slots,
                    slots.count { it != null },
                    slots.count { it != null },
                    QuickLaunchPrefs.SLOT_COUNT,
                ),
                style = NoopType.footnote,
                color = Palette.textTertiary,
                modifier = Modifier.padding(bottom = Metrics.space8),
            )
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(gridHeight),
            ) {
                FavouriteLaunchGrid(
                    slots = slots,
                    editing = true,
                    onEditingChange = {},
                    onSlotsChange = onSlotsChange,
                    onChoose = null,
                    onLaunch = {},
                )
            }
            QuickLaunchCatalog.pages.forEach { page ->
                val available = page.items.filterNot { it.id in slots }
                if (available.isNotEmpty()) {
                    Overline(stringResource(page.titleRes), color = Palette.textTertiary, modifier = Modifier.padding(top = Metrics.space12))
                    available.chunked(3).forEach { rowItems ->
                        Row(Modifier.fillMaxWidth()) {
                            repeat(3) { index ->
                                val item = rowItems.getOrNull(index)
                                Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                                    if (item != null) {
                                        val full = slots.none { it == null }
                                        LaunchTile(
                                            item = item,
                                            onClick = { if (!full) onAdd(item) },
                                            modifier = Modifier
                                                .alpha(if (full) Palette.disabledOpacity else 1f)
                                                .semantics { if (full) disabled() },
                                            iconOverlay = if (!full) {
                                                {
                                                    Icon(
                                                        Icons.Filled.Add,
                                                        contentDescription = stringResource(R.string.quick_launch_add_to_favourites, stringResource(item.titleRes)),
                                                        tint = Palette.textPrimary,
                                                        modifier = Modifier
                                                            .align(Alignment.BottomEnd)
                                                            .size(Metrics.iconSmall)
                                                            .clip(CircleShape)
                                                            .background(Palette.accent)
                                                            .padding(Metrics.space2),
                                                    )
                                                }
                                            } else null,
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
