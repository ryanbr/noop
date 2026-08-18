package com.noop.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BatteryStd
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.noop.R
import kotlin.math.roundToInt

/**
 * Power saving (#477) — lifted out of Settings into its own screen so the strap-battery levers are a
 * first-class More row (between Test Centre and Settings) instead of one card buried mid-scroll. Twin of
 * the Apple `PowerSavingView`.
 *
 * The controls, their prefs and their wiring are UNCHANGED: [AppViewModel.applyPowerSaving] still reads
 * every value from [NoopPrefs], so moving the surface cannot alter behaviour. The master gates the
 * sub-options — the threshold slider, "Pause HRV capture" and "Low refresh" only appear (and only apply)
 * while Power saving is on.
 */
@Composable
fun PowerSavingScreen(vm: AppViewModel) {
    val context = LocalContext.current
    var powerSaving by remember { mutableStateOf(NoopPrefs.powerSaving(context)) }
    var powerSavingBatteryPct by remember { mutableStateOf(NoopPrefs.powerSavingBatteryPct(context)) }
    var pauseHrvOnPowerSave by remember { mutableStateOf(NoopPrefs.pauseHrvOnPowerSave(context)) }
    var lowRefresh by remember { mutableStateOf(NoopPrefs.lowRefresh(context)) }

    ScreenScaffold(
        title = stringResource(R.string.power_saving),
        subtitle = "Ease the load on your strap when its battery is running low.",
    ) {
    // #477 Power saving. Two BENIGN battery levers only: the offload-cadence stretch (%-gated) and
    // the HRV-capture pause (Battery-Saver-gated). The riskier connection-priority idle throttle is
    // deliberately not surfaced here — it stays dormant pending on-strap validation (#478).
    SettingsCard(
        icon = Icons.Filled.BatteryStd,
        title = stringResource(R.string.power_saving),
        blurb = stringResource(R.string.power_saving_blurb),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(stringResource(R.string.power_saving_mode), style = NoopType.subhead, color = Palette.textPrimary)
                Text(
                    stringResource(R.string.power_saving_mode_desc),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
            Switch(
                checked = powerSaving,
                onCheckedChange = {
                    powerSaving = it
                    vm.setPowerSaving(it)
                },
                colors = SwitchDefaults.colors(
                    checkedThumbColor = Palette.surfaceBase,
                    checkedTrackColor = Palette.accent,
                    uncheckedThumbColor = Palette.textSecondary,
                    uncheckedTrackColor = Palette.surfaceInset,
                    uncheckedBorderColor = Palette.hairline,
                ),
            )
        }
        if (powerSaving) {
            SettingsRowDivider()
            Column(modifier = Modifier.fillMaxWidth()) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(stringResource(R.string.power_saving_kick_in), style = NoopType.subhead, color = Palette.textPrimary)
                    Text(stringResource(R.string.power_saving_pct, powerSavingBatteryPct), style = NoopType.subhead, color = Palette.accent)
                }
                Slider(
                    value = powerSavingBatteryPct.toFloat(),
                    // 10–35% snapping to 5% steps (10/15/20/25/30/35). steps = the 4 stops BETWEEN ends.
            // 35 buys one more step of strap life than the old 30 ceiling: the levers engage ~5%
            // earlier in the discharge, at the cost of a slightly longer stretch of quieter syncing.
                    onValueChange = { powerSavingBatteryPct = it.roundToInt() },
                    onValueChangeFinished = { vm.setPowerSavingBatteryPct(powerSavingBatteryPct) },
                    valueRange = 10f..35f,
                    steps = 4,
                    colors = SliderDefaults.colors(
                        thumbColor = Palette.accent,
                        activeTrackColor = Palette.accent,
                        inactiveTrackColor = Palette.surfaceInset,
                    ),
                )
            }
            SettingsRowDivider()
            // HRV pause: a sub-option of power saving, ON by default when the master is on.
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(stringResource(R.string.power_saving_hrv_pause), style = NoopType.subhead, color = Palette.textPrimary)
                    Text(
                        stringResource(R.string.power_saving_hrv_pause_desc),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                Switch(
                    checked = pauseHrvOnPowerSave,
                    onCheckedChange = {
                        pauseHrvOnPowerSave = it
                        vm.setPauseHrvOnPowerSave(it)
                    },
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = Palette.surfaceBase,
                        checkedTrackColor = Palette.accent,
                        uncheckedThumbColor = Palette.textSecondary,
                        uncheckedTrackColor = Palette.surfaceInset,
                        uncheckedBorderColor = Palette.hairline,
                    ),
                )
            }
            SettingsRowDivider()
            // Low refresh: a sub-option that applies at ANY charge, not just below the threshold.
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(stringResource(R.string.power_saving_low_refresh), style = NoopType.subhead, color = Palette.textPrimary)
                    Text(
                        stringResource(R.string.power_saving_low_refresh_desc),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                Switch(
                    checked = lowRefresh,
                    onCheckedChange = {
                        lowRefresh = it
                        vm.setLowRefresh(it)
                    },
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = Palette.surfaceBase,
                        checkedTrackColor = Palette.accent,
                        uncheckedThumbColor = Palette.textSecondary,
                        uncheckedTrackColor = Palette.surfaceInset,
                        uncheckedBorderColor = Palette.hairline,
                    ),
                )
            }
        }
    }
    }
}
