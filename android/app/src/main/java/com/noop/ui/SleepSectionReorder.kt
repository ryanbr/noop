package com.noop.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.lazy.LazyItemScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.zIndex
import kotlinx.coroutines.launch

/**
 * #sleep-layout (hold-to-drag) — the Sleep tab's on-card long-press reorder. This is a DELIBERATE, verbatim
 * mirror of the Today tab's #today-layout drag infrastructure (`TodaySectionDragState` /
 * `swapTargetForDraggedSection` / `movedTodaySection` / `TodayReorderableSection` in TodayScreen.kt), kept
 * as a separate SleepSection-typed copy so adding drag to Sleep can't destabilise the shipping Today
 * reorder. The two are behaviourally identical; if you fix a drag bug in one, port it to the other. The
 * screen-level frame loop (retry-swap + edge auto-scroll) lives in SleepScreen, exactly as Today's lives in
 * TodayScreen — it reads the screen's own `sleepSectionOrder` state fresh each frame.
 */

/** LazyColumn key prefix for a reorderable Sleep section item, so the drag can tell a section from the
 *  pinned rows around it. Twin of `TODAY_SECTION_KEY_PREFIX`. */
const val SLEEP_SECTION_KEY_PREFIX = "sleepSection:"

/**
 * Live drag state for the Sleep hold-to-drag reorder. One instance per screen. `key`/`distance` are
 * snapshot state (they drive the lifted card's translation each frame); the rest are plain fields written
 * by the gesture and read on the same (main) thread. Twin of `TodaySectionDragState`.
 */
class SleepSectionDragState {
    /** LazyColumn key of the section being dragged; null when idle. */
    var key by mutableStateOf<String?>(null)

    /** Accumulated finger travel since pickup (px). */
    var distance by mutableFloatStateOf(0f)

    /** The dragged item's viewport offset at pickup (px) — with [distance], the finger-anchored position. */
    var pickedUpAt = 0f

    /** Edge auto-scroll velocity (px/SECOND — the frame loop scales by real frame time, so the speed is
     *  identical on 60/90/120 Hz displays), set by onDrag from edge proximity; 0 outside the edge zones. */
    var autoScrollPxPerSecond = 0f
}

/** This order with [section] moved to [target]'s position (the classic list move). Twin of
 *  `movedTodaySection`. */
fun List<SleepSection>.movedSleepSection(section: SleepSection, target: SleepSection): List<SleepSection> {
    val from = indexOf(section)
    val to = indexOf(target)
    if (from == -1 || to == -1 || from == to) return this
    return toMutableList().apply { add(to, removeAt(from)) }
}

/**
 * The (dragged, target) pair to swap right now, or null. The lifted card's finger-anchored middle
 * (`pickedUpAt + distance + size/2`, viewport space) must sit over another section item AND have crossed
 * that item's CENTRE in the direction of travel — the centre gate stops a tall card over a short one from
 * ping-ponging. The direction is derived from [order] (the section list, the source of truth), NOT from
 * layout offsets, so a stale post-swap frame can't re-derive and undo the move. Pure read; the caller
 * applies the move. Twin of `swapTargetForDraggedSection`.
 */
fun swapTargetForDraggedSleepSection(
    listState: LazyListState,
    drag: SleepSectionDragState,
    order: List<SleepSection>,
): Pair<SleepSection, SleepSection>? {
    val key = drag.key ?: return null
    val info = listState.layoutInfo
    val current = info.visibleItemsInfo.firstOrNull { it.key == key } ?: return null
    val middle = drag.pickedUpAt + drag.distance + current.size / 2f
    val target = info.visibleItemsInfo.firstOrNull { item ->
        item.key != key && (item.key as? String)?.startsWith(SLEEP_SECTION_KEY_PREFIX) == true &&
            middle >= item.offset && middle <= item.offset + item.size
    } ?: return null
    val dragged = SleepSection.fromRaw(key.removePrefix(SLEEP_SECTION_KEY_PREFIX)) ?: return null
    val tgt = SleepSection.fromRaw((target.key as String).removePrefix(SLEEP_SECTION_KEY_PREFIX)) ?: return null
    val targetCentre = target.offset + target.size / 2f
    val movingDown = order.indexOf(tgt) > order.indexOf(dragged)
    if (movingDown && middle < targetCentre) return null
    if (!movingDown && middle > targetCentre) return null
    return dragged to tgt
}

/**
 * #sleep-layout (hold-to-drag): the per-section drag wrapper. LONG-PRESS anywhere on the section lifts it
 * (haptic; the card raises + follows the finger via graphicsLayer, translation computed against the item's
 * CURRENT layout offset so a mid-drag reorder or auto-scroll can't teleport it). onDrag only accumulates
 * finger travel + the edge auto-scroll velocity — the screen-level frame loop owns the swap + scroll.
 * Taps/scrolls pass through untouched (the detector waits for a long press). Twin of `TodayReorderableSection`.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun LazyItemScope.SleepReorderableSection(
    itemKey: String,
    listState: LazyListState,
    drag: SleepSectionDragState,
    onDrop: () -> Unit,
    content: @Composable () -> Unit,
) {
    val isDragging = drag.key == itemKey
    val haptics = LocalHapticFeedback.current
    // Drop SETTLE: on release the lifted card is usually mid-air between slots; the residual offset animates
    // to 0 so the card glides into its slot. `settling` keeps the lifted chrome (zIndex) during the glide.
    val settleScope = rememberCoroutineScope()
    val settle = remember { Animatable(0f) }
    var settling by remember { mutableStateOf(false) }
    fun releaseWithSettle() {
        val current = listState.layoutInfo.visibleItemsInfo.firstOrNull { it.key == itemKey }
        val residual = if (current != null) drag.pickedUpAt + drag.distance - current.offset else 0f
        onDrop()
        drag.key = null
        drag.distance = 0f
        drag.autoScrollPxPerSecond = 0f
        if (residual != 0f) {
            settling = true
            settleScope.launch {
                settle.snapTo(residual)
                settle.animateTo(0f, tween(durationMillis = 220, easing = FastOutSlowInEasing))
                settling = false
            }
        }
    }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .zIndex(if (isDragging || settling) 1f else 0f)
            .then(
                if (isDragging || settling) {
                    Modifier.graphicsLayer {
                        translationY = if (isDragging) {
                            // Finger-anchored viewport position minus wherever layout currently placed it.
                            val current = listState.layoutInfo.visibleItemsInfo.firstOrNull { it.key == itemKey }
                            if (current != null) drag.pickedUpAt + drag.distance - current.offset else 0f
                        } else {
                            settle.value
                        }
                        shadowElevation = if (isDragging) 12f else 6f
                        scaleX = 1.01f
                        scaleY = 1.01f
                    }
                } else {
                    // Non-dragged sections animate to their new slot as the lifted card crosses them.
                    Modifier.animateItemPlacement(tween(durationMillis = 260, easing = FastOutSlowInEasing))
                },
            )
            .pointerInput(itemKey) {
                detectDragGesturesAfterLongPress(
                    onDragStart = {
                        settling = false
                        drag.key = itemKey
                        drag.distance = 0f
                        drag.pickedUpAt = listState.layoutInfo.visibleItemsInfo
                            .firstOrNull { it.key == itemKey }?.offset?.toFloat() ?: 0f
                        drag.autoScrollPxPerSecond = 0f
                        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                    },
                    onDragEnd = { releaseWithSettle() },
                    onDragCancel = {
                        // The list already reordered live; persist what the user sees rather than
                        // silently reverting on a system-cancelled gesture.
                        releaseWithSettle()
                    },
                    onDrag = onDrag@{ change, amount ->
                        change.consume()
                        drag.distance += amount.y
                        val info = listState.layoutInfo
                        val current = info.visibleItemsInfo.firstOrNull { it.key == itemKey } ?: return@onDrag
                        // Edge auto-scroll velocity (px/SECOND — the frame loop scales by real frame time)
                        // from the lifted card's proximity to the viewport edges; ramps linearly across the
                        // zone with an eased-in feel via the squared fraction.
                        val zone = 112.dp.toPx()
                        val maxV = 620.dp.toPx()
                        val top = drag.pickedUpAt + drag.distance
                        val bottom = top + current.size
                        drag.autoScrollPxPerSecond = when {
                            bottom > info.viewportEndOffset - zone -> {
                                val f = ((bottom - (info.viewportEndOffset - zone)) / zone).coerceAtMost(1f)
                                maxV * f * f
                            }
                            top < info.viewportStartOffset + zone -> {
                                val f = (((info.viewportStartOffset + zone) - top) / zone).coerceAtMost(1f)
                                -maxV * f * f
                            }
                            else -> 0f
                        }
                    },
                )
            },
    ) { content() }
}
