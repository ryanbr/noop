package com.noop.ui

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.VectorConverter
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.RemoveCircle
import androidx.compose.material3.Icon
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
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.zIndex
import com.noop.R
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlin.math.floor

/**
 * A true fixed-slot 3×3 favourites grid. In edit mode pointer input exists only on each visible icon
 * circle: nearby blank space can never acquire an invisible tile. The original tile itself follows the
 * pointer, while an occupied target previews in the origin slot; releasing swaps the two identities.
 */
@Composable
internal fun FavouriteLaunchGrid(
    slots: List<String?>,
    editing: Boolean,
    onEditingChange: (Boolean) -> Unit,
    onSlotsChange: (List<String?>) -> Unit,
    onChoose: (() -> Unit)?,
    onLaunch: (LaunchItem) -> Unit,
) {
    val normalized = QuickLaunchPrefs.normalize(slots)
    val density = LocalDensity.current
    val reduceMotion = rememberReduceMotion()
    var draggingIndex by remember { mutableStateOf<Int?>(null) }
    var hoverIndex by remember { mutableStateOf<Int?>(null) }
    var dragDelta by remember { mutableStateOf(Offset.Zero) }
    var dragPointerStart by remember { mutableStateOf(Offset.Zero) }
    var gridOriginInRoot by remember { mutableStateOf(Offset.Zero) }
    var settling by remember { mutableStateOf(false) }
    var settleJob by remember { mutableStateOf<Job?>(null) }
    val scope = rememberCoroutineScope()

    LaunchedEffect(editing) {
        if (!editing) {
            settleJob?.cancel()
            settleJob = null
            draggingIndex = null
            hoverIndex = null
            dragDelta = Offset.Zero
            dragPointerStart = Offset.Zero
            settling = false
        }
    }

    BoxWithConstraints(
        Modifier
            .fillMaxSize()
            .onGloballyPositioned { gridOriginInRoot = it.positionInRoot() },
    ) {
        val cellWidth = maxWidth / 3
        val cellHeight = maxHeight / 3
        val cellWidthPx = with(density) { cellWidth.toPx() }
        val cellHeightPx = with(density) { cellHeight.toPx() }
        val origin = draggingIndex

        fun targetFor(pointer: Offset): Int? {
            if (pointer.x < 0f || pointer.y < 0f ||
                pointer.x >= cellWidthPx * 3 || pointer.y >= cellHeightPx * 3
            ) return null
            val column = floor(pointer.x / cellWidthPx).toInt().coerceIn(0, 2)
            val row = floor(pointer.y / cellHeightPx).toInt().coerceIn(0, 2)
            return row * 3 + column
        }

        // Slot guides are separate from tiles, so empty positions stay visible and selectable without
        // enlarging any tile's drag hit region.
        repeat(QuickLaunchPrefs.SLOT_COUNT) { index ->
            val column = index % 3
            val row = index / 3
            Box(
                modifier = Modifier
                    .offset(x = cellWidth * column, y = cellHeight * row)
                    .size(width = cellWidth, height = cellHeight),
                contentAlignment = Alignment.Center,
            ) {
                val hoveringOccupiedTarget = origin != null && hoverIndex != null && hoverIndex != origin &&
                    normalized[hoverIndex!!] != null
                val showPlaceholder = normalized[index] == null ||
                    (index == origin && !hoveringOccupiedTarget) ||
                    (index == hoverIndex && origin != hoverIndex)
                if (editing && showPlaceholder) {
                    EmptyFavouriteSlot(
                        onChoose = if (normalized[index] == null) onChoose else null,
                        highlighted = draggingIndex != null && index == hoverIndex,
                    )
                }
            }
        }

        normalized.forEachIndexed { logicalIndex, id ->
            val item = id?.let(QuickLaunchCatalog.byId::get) ?: return@forEachIndexed
            val previewIndex = when {
                origin != null && hoverIndex == logicalIndex && logicalIndex != origin -> origin
                else -> logicalIndex
            }
            val column = previewIndex % 3
            val row = previewIndex / 3
            val isDragging = logicalIndex == origin
            val jiggle = rememberFavouriteJiggle(editing && !isDragging && !reduceMotion, logicalIndex)
            val liftScale by animateFloatAsState(
                targetValue = if (isDragging && !settling) NoopMotion.favouriteDragLiftScale else 1f,
                animationSpec = if (reduceMotion) tween(durationMillis = 0) else NoopMotion.card(),
                label = "favourite_drag_lift",
            )
            val removeDescription = stringResource(R.string.quick_launch_remove_from_favourites, stringResource(item.titleRes))
            val moveEarlierLabel = stringResource(R.string.quick_launch_move_earlier)
            val moveLaterLabel = stringResource(R.string.quick_launch_move_later)
            var iconOriginInRoot by remember(item.id) { mutableStateOf(Offset.Zero) }
            val reorderActions = if (!editing) {
                emptyList()
            } else {
                buildList {
                    if (logicalIndex > 0) {
                        add(CustomAccessibilityAction(moveEarlierLabel) {
                            onSlotsChange(QuickLaunchPrefs.swap(normalized, logicalIndex, logicalIndex - 1))
                            true
                        })
                    }
                    if (logicalIndex < QuickLaunchPrefs.SLOT_COUNT - 1) {
                        add(CustomAccessibilityAction(moveLaterLabel) {
                            onSlotsChange(QuickLaunchPrefs.swap(normalized, logicalIndex, logicalIndex + 1))
                            true
                        })
                    }
                }
            }

            Box(
                modifier = Modifier
                    .offset(x = cellWidth * column, y = cellHeight * row)
                    .size(width = cellWidth, height = cellHeight)
                    .graphicsLayer {
                        if (isDragging) {
                            translationX = dragDelta.x
                            translationY = dragDelta.y
                            scaleX = liftScale
                            scaleY = liftScale
                        }
                    }
                    .zIndex(if (isDragging) NoopMotion.favouriteDragZIndex else 1f),
                contentAlignment = Alignment.Center,
            ) {
                LaunchTile(
                    item = item,
                    modifier = Modifier.semantics { customActions = reorderActions },
                    onClick = { if (!editing) onLaunch(item) },
                    onLongClick = if (editing) null else ({ onEditingChange(true) }),
                    iconModifier = Modifier
                        .rotate(jiggle)
                        .onGloballyPositioned { iconOriginInRoot = it.positionInRoot() }
                        .then(
                            if (!editing) Modifier else Modifier.pointerInput(item.id, logicalIndex) {
                                detectDragGestures(
                                    onDragStart = { touchInCircle ->
                                        settleJob?.cancel()
                                        settling = false
                                        draggingIndex = logicalIndex
                                        hoverIndex = logicalIndex
                                        dragDelta = Offset.Zero
                                        dragPointerStart = iconOriginInRoot - gridOriginInRoot + touchInCircle
                                    },
                                    onDrag = { change, amount ->
                                        if (!settling) {
                                            change.consume()
                                            val next = dragDelta + amount
                                            dragDelta = next
                                            hoverIndex = targetFor(dragPointerStart + next)
                                        }
                                    },
                                    onDragCancel = {
                                        draggingIndex = null
                                        hoverIndex = null
                                        dragDelta = Offset.Zero
                                        dragPointerStart = Offset.Zero
                                    },
                                    onDragEnd = {
                                        val target = hoverIndex ?: logicalIndex
                                        if (reduceMotion) {
                                            if (target != logicalIndex) {
                                                onSlotsChange(QuickLaunchPrefs.swap(normalized, logicalIndex, target))
                                            }
                                            draggingIndex = null
                                            hoverIndex = null
                                            dragDelta = Offset.Zero
                                            dragPointerStart = Offset.Zero
                                        } else {
                                            val targetDelta = Offset(
                                                x = ((target % 3) - (logicalIndex % 3)) * cellWidthPx,
                                                y = ((target / 3) - (logicalIndex / 3)) * cellHeightPx,
                                            )
                                            settling = true
                                            settleJob = scope.launch {
                                                Animatable(dragDelta, Offset.VectorConverter)
                                                    .animateTo(targetDelta, NoopMotion.card()) {
                                                        dragDelta = value
                                                    }
                                                if (target != logicalIndex) {
                                                    onSlotsChange(QuickLaunchPrefs.swap(normalized, logicalIndex, target))
                                                }
                                                draggingIndex = null
                                                hoverIndex = null
                                                dragDelta = Offset.Zero
                                                dragPointerStart = Offset.Zero
                                                settling = false
                                                settleJob = null
                                            }
                                        }
                                    },
                                )
                            }
                        ),
                    iconOverlay = if (editing && !isDragging) {
                        {
                            Box(
                                modifier = Modifier
                                    .align(Alignment.TopStart)
                                    .offset(x = -Metrics.quickLaunchRemoveTarget / 4, y = -Metrics.quickLaunchRemoveTarget / 4)
                                    .size(Metrics.quickLaunchRemoveTarget)
                                    .clip(CircleShape)
                                    .clickable(role = Role.Button) {
                                        onSlotsChange(QuickLaunchPrefs.remove(normalized, logicalIndex))
                                    }
                                    .semantics { contentDescription = removeDescription },
                                contentAlignment = Alignment.Center,
                            ) {
                                Icon(
                                    Icons.Filled.RemoveCircle,
                                    contentDescription = null,
                                    tint = Palette.statusCritical,
                                    modifier = Modifier.size(Metrics.quickLaunchRemoveGlyph),
                                )
                            }
                        }
                    } else null,
                )
            }
        }
    }
}

@Composable
private fun EmptyFavouriteSlot(onChoose: (() -> Unit)?, highlighted: Boolean) {
    val description = stringResource(R.string.quick_launch_empty_slot)
    Box(
        modifier = Modifier
            .size(Metrics.quickLaunchIconCircle)
            .clip(CircleShape)
            .then(
                if (onChoose == null) Modifier else Modifier
                    .clickable(role = Role.Button, onClick = onChoose)
                    .semantics { contentDescription = description }
            ),
        contentAlignment = Alignment.Center,
    ) {
        val density = LocalDensity.current
        Canvas(Modifier.fillMaxSize()) {
            val strokeWidth = with(density) { Metrics.quickLaunchPlaceholderStroke.toPx() }
            drawCircle(
                color = if (highlighted) Palette.accent else Palette.hairlineStrong,
                radius = (size.minDimension - strokeWidth) / 2f,
                style = Stroke(
                    width = strokeWidth,
                    pathEffect = PathEffect.dashPathEffect(
                        floatArrayOf(
                            with(density) { Metrics.quickLaunchPlaceholderDash.toPx() },
                            with(density) { Metrics.quickLaunchPlaceholderGap.toPx() },
                        ),
                    ),
                ),
            )
        }
        if (onChoose != null) {
            Icon(
                Icons.Filled.Add,
                contentDescription = null,
                tint = Palette.textTertiary,
                modifier = Modifier.size(Metrics.iconSmall),
            )
        }
    }
}

@Composable
private fun rememberFavouriteJiggle(enabled: Boolean, index: Int): Float {
    // #909: the edit-mode jiggle is an unbounded frame loop, so battery saver must collapse it to its
    // posed frame too — not just "Remove animations", which the caller already folds into `enabled`.
    // Read unconditionally, before the early return, so the gate is a stable composition slot.
    val poseStill = rememberPoseStill()
    if (!enabled || poseStill) return 0f
    val transition = rememberInfiniteTransition(label = "favourite_jiggle")
    val angle by transition.animateFloat(
        initialValue = -NoopMotion.favouriteJiggleDegrees,
        targetValue = NoopMotion.favouriteJiggleDegrees,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = NoopMotion.favouriteJiggleMs),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "favourite_jiggle_angle",
    )
    return if (index % 2 == 0) angle else -angle
}
