package com.noop.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.noop.R

/**
 * "Arrange sleep cards" dialog (#sleep-layout) — reorder / show-hide the Sleep tab's analytical cards.
 * A direct twin of the Today customize dialog: it reuses the SAME generic [EditableVisibilityRows] editor
 * (drag to reorder in the shown list, tap to move a card between shown/hidden), then persists via
 * [SleepLayoutPrefs]. Nothing Sleep-specific but the section type + the persistence namespace, so the
 * reorder UX is byte-for-byte the one Today already ships.
 *
 * `onSave` receives the FULL order (shown ++ hidden, so a hidden card keeps its stable slot for when it's
 * re-shown) and the hidden set separately, matching `SleepLayoutPrefs.setOrder`/`setHidden`.
 */
@Composable
fun SleepArrangeSheet(
    initialOrder: List<SleepSection>,
    initialHidden: List<SleepSection>,
    onDismiss: () -> Unit,
    onSave: (order: List<SleepSection>, hidden: List<SleepSection>) -> Unit,
) {
    val hiddenSet = remember(initialHidden) { initialHidden.toSet() }
    val shown = remember {
        mutableStateListOf<SleepSection>().apply { addAll(initialOrder.filterNot { it in hiddenSet }) }
    }
    val hidden = remember {
        mutableStateListOf<SleepSection>().apply { addAll(initialOrder.filter { it in hiddenSet }) }
    }

    Dialog(onDismissRequest = onDismiss) {
        Surface(color = Palette.surfaceOverlay, shape = RoundedCornerShape(16.dp)) {
            Column(
                modifier = Modifier.padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(stringResource(R.string.sleep_customize_title), style = NoopType.title2, color = Palette.textPrimary)
                    Text(
                        stringResource(R.string.sleep_customize_description),
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                    )
                }

                // Resolve the localized title per section up front (the composable-only stringResource
                // call can't run inside the plain itemTitle lambda). The enum's raw title stays the English
                // source of truth; the sheet shows the translated text.
                val titleFor = SleepSection.entries.associateWith { it.localizedTitle() }
                EditableVisibilityRows(
                    shown = shown,
                    hidden = hidden,
                    itemTitle = { titleFor.getValue(it) },
                )

                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(
                        onClick = {
                            shown.clear()
                            shown.addAll(SleepSection.defaultOrder)
                            hidden.clear()
                        },
                        colors = ButtonDefaults.textButtonColors(contentColor = Palette.textSecondary),
                    ) { Text(uiString(R.string.l10n_today_screen_reset_44c57abd), style = NoopType.body) }
                    Spacer(Modifier.weight(1f))
                    Button(
                        onClick = { onSave(shown.toList() + hidden.toList(), hidden.toList()) },
                        enabled = shown.isNotEmpty(),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.accent,
                            contentColor = Palette.surfaceBase,
                        ),
                    ) { Text(uiString(R.string.l10n_today_screen_done_e9b450d1), style = NoopType.captionNumber) }
                }
            }
        }
    }
}
