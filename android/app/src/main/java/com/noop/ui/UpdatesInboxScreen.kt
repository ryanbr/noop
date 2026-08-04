@file:OptIn(ExperimentalMaterial3Api::class)

package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Undo
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.DeleteSweep
import androidx.compose.material.icons.outlined.Done
import androidx.compose.material.icons.outlined.DoneAll
import androidx.compose.material.icons.outlined.Layers
import androidx.compose.material.icons.outlined.MonitorHeart
import androidx.compose.material.icons.outlined.NotificationsOff
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

// MARK: - Updates inbox
//
// The sheet behind the Today header's bell. A calm, newest-first log of what's new — release notes,
// "new data arrived" readings, strap heads-ups, and the Today info-cards the user swiped away (which
// can be restored from here). Tapping an actionable row routes via the app's nav; a dismissed-card
// row offers "Restore to Today". Everything is on-device and non-clinical — informational, never a
// verdict.
//
// Kotlin port of Strand/Screens/UpdatesInboxView.swift, presented as the content of a ModalBottomSheet
// (the app's sheet idiom — see AppRoot's More / Quick-actions sheets). Tokens only.

/**
 * The inbox sheet body. Hosted inside a [androidx.compose.material3.ModalBottomSheet] by [AppRoot].
 *
 * @param store the shared [UpdateStore] the bell observes.
 * @param onClose dismiss the sheet (after a tap that routes, or a restore).
 * @param onDeepLink route to a destination by its key (e.g. "trends"); unknown keys are ignored.
 * @param onRestore flip a Today card's dismissed flag back on (by its card id) so it reappears.
 */
@Composable
fun UpdatesInboxScreen(
    store: UpdateStore,
    onClose: () -> Unit,
    onDeepLink: (String) -> Unit,
    onRestore: (String) -> Unit,
) {
    val sorted = store.sortedItems
    val unread = sorted.filter { !it.read }
    val read = sorted.filter { it.read }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            // #984: the sheet could not scroll. `ModalBottomSheet` hands its content a plain
            // `ColumnScope` and does NOT scroll it, so everything past the bottom of the screen was
            // simply clipped and unreachable — the footer's Clear all / Mark all read included.
            //
            // It is also half of why a tapped row looked deleted: marking it read moves it out of "New"
            // and down into "Earlier", which is rendered below, i.e. into the part that could not be
            // reached. Safe to wrap because nothing in this screen is itself lazily scrolling; a
            // LazyColumn nested in a verticalScroll would crash on an infinite height constraint.
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp)
            .padding(bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(Metrics.sectionGap),
    ) {
        // Header — "INBOX" overline + "Updates" title + a live subtitle.
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Overline("Inbox", color = Palette.textTertiary)
            Text(uiString(R.string.l10n_updates_inbox_screen_updates_c76d1807), style = NoopType.title1, color = Palette.textPrimary)
            Text(subtitle(store), style = NoopType.caption, color = Palette.textSecondary)
        }

        if (store.items.isEmpty()) {
            EmptyInboxState()
        } else {
            if (unread.isNotEmpty()) {
                InboxSection(
                    label = uiString(R.string.l10n_updates_inbox_screen_new_6403f2b7),
                    items = unread,
                    onTap = { handleTap(it, store, onDeepLink, onClose) },
                    onRestore = { handleRestore(it, store, onRestore, onClose) },
                    // Swipe an unread card to mark it read (same path as a tap, just no routing).
                    onSwipeRead = { store.markRead(it.id) },
                )
            }
            if (read.isNotEmpty()) {
                InboxSection(
                    label = uiString(R.string.l10n_updates_inbox_screen_earlier_13f7aee7),
                    items = read,
                    onTap = { handleTap(it, store, onDeepLink, onClose) },
                    onRestore = { handleRestore(it, store, onRestore, onClose) },
                    // Read rows are never wrapped for swipe, so this is unused for this section.
                    onSwipeRead = { store.markRead(it.id) },
                )
            }

            // Footer — Clear all (left) + Mark all read (right). Both disabled when they'd no-op.
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TextButton(
                    onClick = { store.clearAll() },
                    enabled = store.items.isNotEmpty(),
                ) {
                    Icon(
                        Icons.Outlined.DeleteSweep,
                        contentDescription = null,
                        tint = Palette.textSecondary,
                        modifier = Modifier.size(Metrics.iconSmall),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(uiString(R.string.l10n_updates_inbox_screen_clear_all_c043160a), style = NoopType.subhead, color = Palette.textSecondary)
                }
                Spacer(Modifier.weight(1f))
                Button(
                    onClick = { store.markAllRead() },
                    enabled = store.unreadCount > 0,
                    // Filled accent PILL, matching the iOS "Mark all read" button (blue in light, gold in
                    // dark). Icon + label inherit the button's contentColor.
                    shape = RoundedCornerShape(percent = 50),
                    contentPadding = PaddingValues(horizontal = 18.dp, vertical = 8.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Palette.accent,
                        contentColor = if (Palette.isLight) Color.White else Palette.goldDeepText,
                        disabledContainerColor = Palette.surfaceInset,
                        disabledContentColor = Palette.textTertiary,
                    ),
                ) {
                    Icon(
                        Icons.Outlined.DoneAll,
                        contentDescription = null,
                        modifier = Modifier.size(Metrics.iconSmall),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(uiString(R.string.l10n_updates_inbox_screen_mark_all_read_8958e22c), style = NoopType.subhead)
                }
            }
        }
    }
}

private fun subtitle(store: UpdateStore): String {
    if (store.items.isEmpty()) return "What's new in the app and your data"
    val n = store.unreadCount
    return if (n == 0) "All caught up" else "$n unread"
}

@Composable
private fun InboxSection(
    label: String,
    items: List<UpdateItem>,
    onTap: (UpdateItem) -> Unit,
    onRestore: (UpdateItem) -> Unit,
    onSwipeRead: (UpdateItem) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        Overline(label, color = Palette.textTertiary)
        items.forEach { item ->
            // key(item.id) so a row that flips read→falls-out-of-this-section recomposes cleanly and
            // its neighbours don't inherit a stale swipe state.
            key(item.id) {
                if (item.read) {
                    UpdateRow(item = item, onTap = { onTap(item) }, onRestore = { onRestore(item) })
                } else {
                    SwipeableUnreadRow(
                        item = item,
                        onTap = { onTap(item) },
                        onRestore = { onRestore(item) },
                        onSwipeRead = { onSwipeRead(item) },
                    )
                }
            }
        }
    }
}

// MARK: - Swipe-to-mark-read
//
// Idea credit: contributor "A" (PR #65) — swipe an inbox card to mark it read. Reimplemented under
// the project: the original PR referenced a non-existent UpdateKind and gated its wash on the fragile
// `state.progress` (anchor-relative in material3 1.2.1, ~1.0 at rest), so this is a from-scratch take.
//
// Wraps an UNREAD card in a material3 SwipeToDismissBox. A swipe in either direction marks the item
// read via the same `UpdateStore.markRead` path a tap uses; we DON'T actually remove the row — the
// store re-emits it as read and it slides into the "Earlier" section on the next recompose, so
// `confirmValueChange` returns false (no real dismissal). The background wash + check glyph are gated
// on `dismissDirection` (a robust, settle-aware signal), never on `progress`.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SwipeableUnreadRow(
    item: UpdateItem,
    onTap: () -> Unit,
    onRestore: () -> Unit,
    onSwipeRead: () -> Unit,
) {
    val dismissState = rememberSwipeToDismissBoxState(
        confirmValueChange = { value ->
            if (value != SwipeToDismissBoxValue.Settled) {
                // Mark read in place; keep the row (it re-emits as read), so reject the dismissal.
                onSwipeRead()
            }
            false
        },
    )
    SwipeToDismissBox(
        state = dismissState,
        modifier = Modifier.clip(RoundedCornerShape(Metrics.cardRadius)),
        enableDismissFromStartToEnd = true,
        enableDismissFromEndToStart = true,
        backgroundContent = { SwipeBackground(direction = dismissState.dismissDirection) },
    ) {
        UpdateRow(item = item, onTap = onTap, onRestore = onRestore)
    }
}

/** The wash revealed under a swiping unread card: an accent fill with a "mark read" check, aligned to
 *  the trailing edge of the swipe. Gated on [direction] (settle-aware) — not the fragile progress. */
@Composable
private fun SwipeBackground(direction: SwipeToDismissBoxValue) {
    // Settled = nothing revealed; keep it transparent so a resting card shows no wash.
    val alignment = when (direction) {
        SwipeToDismissBoxValue.StartToEnd -> Alignment.CenterStart
        SwipeToDismissBoxValue.EndToStart -> Alignment.CenterEnd
        SwipeToDismissBoxValue.Settled -> Alignment.Center
    }
    val washColor =
        if (direction == SwipeToDismissBoxValue.Settled) Color.Transparent else Palette.accent
    val contentColor = if (Palette.isLight) Color.White else Palette.goldDeepText
    Box(
        modifier = Modifier
            .fillMaxSize()
            .clip(RoundedCornerShape(Metrics.cardRadius))
            .background(washColor)
            .padding(horizontal = 24.dp),
        contentAlignment = alignment,
    ) {
        if (direction != SwipeToDismissBoxValue.Settled) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    Icons.Outlined.Done,
                    contentDescription = null,
                    tint = contentColor,
                    modifier = Modifier.size(Metrics.iconSmall),
                )
                Text(uiString(R.string.l10n_updates_inbox_screen_mark_read_3bf98fa6), style = NoopType.subhead, color = contentColor)
            }
        }
    }
}

@Composable
private fun UpdateRow(
    item: UpdateItem,
    onTap: () -> Unit,
    onRestore: () -> Unit,
) {
    val tint = kindTint(item.kind)
    NoopCard(
        // Unread rows carry the kind's colour wash; read rows sit on the plain navy fill.
        tint = if (item.read) null else tint,
        modifier = Modifier
            .clip(RoundedCornerShape(Metrics.cardRadius))
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onTap,
            )
            .semantics {
                contentDescription = if (item.read) {
                    "${item.title}. ${item.message}"
                } else {
                    "Unread. ${item.title}. ${item.message}"
                }
            },
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.Top,
            ) {
                Icon(
                    kindIcon(item.kind),
                    contentDescription = null,
                    tint = tint,
                    modifier = Modifier
                        .size(24.dp)
                        .padding(top = 1.dp),
                )
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(3.dp),
                ) {
                    Text(item.title, style = NoopType.headline, color = Palette.textPrimary)
                    Text(
                        item.message,
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        relativeAgo(item.date / 1000L),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                        modifier = Modifier.padding(top = 1.dp),
                    )
                }
                if (!item.read) {
                    // Gold unread dot.
                    Box(
                        modifier = Modifier
                            .padding(top = 5.dp)
                            .size(8.dp)
                            .clip(CircleShape)
                            .background(Palette.gold),
                    )
                }
            }
            if (item.kind == UpdateKind.DISMISSED_CARD) {
                Row(modifier = Modifier.fillMaxWidth()) {
                    TextButton(onClick = onRestore) {
                        Icon(
                            Icons.AutoMirrored.Outlined.Undo,
                            contentDescription = null,
                            tint = Palette.accent,
                            modifier = Modifier.size(Metrics.iconSmall),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(uiString(R.string.l10n_updates_inbox_screen_restore_to_today_77c7c8e5), style = NoopType.subhead, color = Palette.accent)
                    }
                }
            }
        }
    }
}

@Composable
private fun EmptyInboxState() {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 40.dp, horizontal = 12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(
            Icons.Outlined.NotificationsOff,
            contentDescription = null,
            tint = Palette.textTertiary,
            modifier = Modifier.size(34.dp),
        )
        Text(uiString(R.string.l10n_updates_inbox_screen_you_re_all_caught_up_3d39c469), style = NoopType.headline, color = Palette.textPrimary)
        Text(
            uiString(R.string.l10n_updates_inbox_screen_new_release_notes_and_fresh_data_1632c576),
            style = NoopType.subhead,
            color = Palette.textSecondary,
        )
    }
}

/** The per-kind icon — mirrors the Swift SF Symbol → Material mapping in the spec. */
private fun kindIcon(kind: UpdateKind): ImageVector = when (kind) {
    UpdateKind.DISMISSED_CARD -> Icons.Outlined.Layers
    UpdateKind.WHATS_NEW -> Icons.Outlined.AutoAwesome
    UpdateKind.READING -> Icons.Outlined.MonitorHeart
    UpdateKind.STRAP_ALERT -> Icons.Outlined.Warning
}

/** A per-kind tint drawn from the domain palette so each row reads in its own colour world.
 *  Mirrors the Swift `UpdateRow.tint`. */
private fun kindTint(kind: UpdateKind): Color = when (kind) {
    UpdateKind.DISMISSED_CARD -> Palette.textSecondary
    UpdateKind.WHATS_NEW -> Palette.accent
    UpdateKind.READING -> Palette.restColor
    UpdateKind.STRAP_ALERT -> Palette.statusWarning
}

/** Tapping a row marks it read, then routes if it carries a deep link (else just stays open). */
private fun handleTap(
    item: UpdateItem,
    store: UpdateStore,
    onDeepLink: (String) -> Unit,
    onClose: () -> Unit,
) {
    store.markRead(item.id)
    // #984: resolved by UpdateStore.deepLinkTarget so the rule is testable (it also covers What's New
    // rows posted before this fix, which carry no deepLink of their own).
    val key = UpdateStore.deepLinkTarget(item) ?: return
    onDeepLink(key)
    onClose()
}

/** Restore a dismissed Today card: flip its flag back (so it reappears), drop the inbox item, and
 *  close so the card is on screen. */
private fun handleRestore(
    item: UpdateItem,
    store: UpdateStore,
    onRestore: (String) -> Unit,
    onClose: () -> Unit,
) {
    item.restorePayload?.let { onRestore(it) }
    store.remove(item.id)
    onClose()
}
