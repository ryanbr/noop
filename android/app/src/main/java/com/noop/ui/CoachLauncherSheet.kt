package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.noop.R

/**
 * The compact Coach launcher opened from the optional Today card (#1862).
 *
 * Coach is otherwise reachable only through More, which makes it easy to miss and means leaving Today to
 * try it. This is the shortcut — and deliberately ONLY a shortcut.
 *
 * It owns no send, stream, error or consent surface of its own. Picking a suggestion hands the question
 * to [onPick], which routes to the Coach screen; that screen already has all of those. A second chat UI
 * would drift from the first, and #1862 explicitly defers the persistent-workspace redesign (threads,
 * retention, backup policy) to a follow-up.
 *
 * NO PROVIDER REQUEST IS MADE BY SHOWING THIS. [isConfigured] is a local key read and the prompts are
 * static copy; the first network call still happens where it always did, after an explicit send.
 *
 * Presentational by construction — every input is injected — so it can be exercised without a provider,
 * a key, or a ViewModel. Swift twin: `CoachLauncherSheet`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CoachLauncherSheet(
    isConfigured: Boolean,
    onPick: (String) -> Unit,
    onSetup: () -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = Palette.surfaceRaised,
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Overline(uiString(R.string.nav_coach))
            // Frames BOTH branches, so the sheet says what Coach is before it either offers questions or
            // asks for a provider. Using it once also avoids the duplicate that an unconfigured-only
            // explainer produced, where "Connect a provider" read as both the description and the button.
            Text(
                uiString(R.string.l10n_coach_screen_ask_anything_about_your_recent_recovery_e6c287ca),
                style = NoopType.caption,
                color = Palette.textTertiary,
            )
            if (isConfigured) {
                CoachPrompts.SUGGESTIONS.forEach { prompt ->
                    PromptRow(prompt = prompt, onClick = { onPick(prompt) })
                }
            } else {
                // The Coach screen stays the only place a key is entered; this just routes there.
                PromptRow(
                    prompt = uiString(R.string.l10n_coach_screen_connect_a_provider_6967f288),
                    onClick = onSetup,
                )
            }
        }
    }
}

@Composable
private fun PromptRow(prompt: String, onClick: () -> Unit) {
    val shape = RoundedCornerShape(12.dp)
    Text(
        prompt,
        style = NoopType.caption,
        color = Palette.textPrimary,
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(Palette.surfaceInset)
            .border(1.dp, Palette.hairline, shape)
            .clickable { onClick() }
            .padding(horizontal = 12.dp, vertical = 10.dp)
            .semantics { contentDescription = prompt },
    )
}
