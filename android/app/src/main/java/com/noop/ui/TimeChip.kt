package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Text
import androidx.compose.material3.TimePicker
import androidx.compose.material3.TimePickerDefaults
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog

/** Shared 24-hour time selector used by Automations and other settings screens. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun TimeChip(
    minutes: Int,
    accessibilityLabel: String,
    onPicked: (Int) -> Unit,
) {
    var showPicker by remember { mutableStateOf(false) }
    val hour = (minutes / 60).coerceIn(0, 23)
    val minute = (minutes % 60).coerceIn(0, 59)

    Text(
        text = "%02d:%02d".format(hour, minute),
        style = NoopType.number(15f),
        color = Palette.accent,
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(Palette.surfaceInset)
            .border(1.dp, Palette.hairline, RoundedCornerShape(50))
            .clickable { showPicker = true }
            .padding(horizontal = 12.dp, vertical = 6.dp),
    )

    if (showPicker) {
        val state = rememberTimePickerState(initialHour = hour, initialMinute = minute, is24Hour = true)
        Dialog(onDismissRequest = { showPicker = false }) {
            Column(
                modifier = Modifier
                    .clip(RoundedCornerShape(20.dp))
                    .background(Palette.surfaceOverlay)
                    .padding(20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Text(accessibilityLabel, style = NoopType.headline, color = Palette.textPrimary)
                TimePicker(
                    state = state,
                    colors = TimePickerDefaults.colors(
                        clockDialColor = Palette.surfaceInset,
                        clockDialSelectedContentColor = Palette.surfaceBase,
                        clockDialUnselectedContentColor = Palette.textPrimary,
                        selectorColor = Palette.accent,
                        periodSelectorBorderColor = Palette.hairline,
                        timeSelectorSelectedContainerColor = Palette.accentMuted,
                        timeSelectorUnselectedContainerColor = Palette.surfaceInset,
                        timeSelectorSelectedContentColor = Palette.accent,
                        timeSelectorUnselectedContentColor = Palette.textPrimary,
                    ),
                )
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
                ) {
                    Text("Cancel", color = Palette.textSecondary, modifier = Modifier.clickable { showPicker = false }.padding(10.dp))
                    Text(
                        "Set",
                        color = Palette.accent,
                        modifier = Modifier.clickable {
                            onPicked(state.hour * 60 + state.minute)
                            showPicker = false
                        }.padding(10.dp),
                    )
                }
            }
        }
    }
}
