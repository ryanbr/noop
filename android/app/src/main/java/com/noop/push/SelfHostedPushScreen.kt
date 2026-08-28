package com.noop.push

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CloudUpload
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.ui.NoopButton
import com.noop.ui.NoopButtonKind
import com.noop.ui.NoopType
import com.noop.ui.Palette
import com.noop.ui.ScreenScaffold
import com.noop.ui.SettingsCard
import com.noop.ui.SettingsToggleRow
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

private sealed interface CapabilityProbeUi {
    data object Idle : CapabilityProbeUi
    data object Testing : CapabilityProbeUi
    data class Success(val streams: List<String>, val checkedAt: Long) : CapabilityProbeUi
    data class Failure(val failure: PushFailure) : CapabilityProbeUi
}

/** Experimental, explicit consent surface for raw one-way health-data egress. */
@Composable
fun SelfHostedPushScreen() {
    val context = LocalContext.current
    val settings = remember { SelfHostedPushSettings.from(context) }
    var endpoint by remember { mutableStateOf(settings.endpointText()) }
    var token by remember { mutableStateOf("") }
    var snapshot by remember { mutableStateOf(settings.snapshot()) }
    var validationMessage by remember { mutableStateOf<String?>(null) }
    var capabilityProbe by remember { mutableStateOf<CapabilityProbeUi>(CapabilityProbeUi.Idle) }
    var capabilityProbeGeneration by remember { mutableStateOf(0) }
    val scope = rememberCoroutineScope()

    // WorkManager runs outside this composition. Refresh while visible so progress and completion do
    // not require navigating away and back (and avoid retaining a UI listener in process globals).
    LaunchedEffect(settings) {
        while (currentCoroutineContext().isActive) {
            snapshot = settings.snapshot()
            delay(750)
        }
    }

    val validatedEndpoint = PushEndpointPolicy.validate(endpoint) as? PushEndpointPolicy.Result.Valid
    val endpointValid = validatedEndpoint != null
    val tokenAvailable = token.isNotBlank() || snapshot.hasToken
    val active = snapshot.runState in setOf(
        SelfHostedPushSettings.RunState.QUEUED,
        SelfHostedPushSettings.RunState.RUNNING,
        SelfHostedPushSettings.RunState.CONTINUING,
        SelfHostedPushSettings.RunState.RETRYING,
    )

    ScreenScaffold(
        title = stringResource(R.string.push_title),
        subtitle = stringResource(R.string.push_subtitle),
    ) {
        SettingsCard(
            icon = Icons.Filled.CloudUpload,
            title = stringResource(R.string.push_destination_title),
            blurb = stringResource(R.string.push_disclosure),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    stringResource(R.string.push_one_way_warning),
                    style = NoopType.footnote,
                    color = Palette.statusWarning,
                )
                PushTextField(
                    value = endpoint,
                    onValueChange = {
                        endpoint = it
                        validationMessage = null
                        capabilityProbe = CapabilityProbeUi.Idle
                        capabilityProbeGeneration++
                    },
                    label = stringResource(R.string.push_endpoint),
                    secret = false,
                )
                PushTextField(
                    value = token,
                    onValueChange = {
                        token = it
                        capabilityProbe = CapabilityProbeUi.Idle
                        capabilityProbeGeneration++
                    },
                    label = if (snapshot.hasToken) stringResource(R.string.push_token_saved) else stringResource(R.string.push_token),
                    secret = true,
                )
                validationMessage?.let {
                    Text(it, style = NoopType.footnote, color = Palette.statusWarning)
                }
                NoopButton(
                    text = stringResource(R.string.push_save),
                    kind = NoopButtonKind.Secondary,
                    fullWidth = true,
                    enabled = endpointValid && tokenAvailable,
                    onClick = {
                        when (val result = settings.saveEndpoint(endpoint)) {
                            is PushEndpointPolicy.Result.Invalid ->
                                validationMessage = pushEndpointProblemMessage(context, result.problem)
                            is PushEndpointPolicy.Result.Valid -> {
                                val destinationChanged = snapshot.endpoint?.url != result.endpoint.url
                                endpoint = result.endpoint.url
                                if (token.isNotBlank()) settings.saveToken(token)
                                token = ""
                                snapshot = settings.snapshot()
                                if (destinationChanged && snapshot.ready) {
                                    SelfHostedPushScheduler.destinationChanged(context)
                                }
                                validationMessage = context.getString(R.string.push_saved)
                            }
                        }
                    },
                )
                NoopButton(
                    text = if (capabilityProbe == CapabilityProbeUi.Testing) {
                        stringResource(R.string.push_testing_connection)
                    } else {
                        stringResource(R.string.push_test_connection)
                    },
                    kind = NoopButtonKind.Secondary,
                    fullWidth = true,
                    enabled = endpointValid && tokenAvailable && capabilityProbe != CapabilityProbeUi.Testing,
                    onClick = {
                        val valid = PushEndpointPolicy.validate(endpoint) as? PushEndpointPolicy.Result.Valid
                        val testToken = token.trim().takeIf(String::isNotEmpty) ?: settings.token()
                        if (valid == null || testToken == null) {
                            validationMessage = context.getString(R.string.push_config_required)
                        } else if (!canStartPushConnectionTest(
                                networkAvailable = isPushNetworkAvailable(
                                    context,
                                    wifiOnly = snapshot.wifiOnly,
                                ),
                                endpointValid = true,
                                tokenAvailable = true,
                            )
                        ) {
                            validationMessage = context.getString(R.string.push_test_network_required)
                        } else {
                            val generation = capabilityProbeGeneration + 1
                            capabilityProbeGeneration = generation
                            val persistResult = token.isBlank() && valid.endpoint.url == snapshot.endpoint?.url
                            capabilityProbe = CapabilityProbeUi.Testing
                            scope.launch {
                                val result = PushConnectionTester().test(valid.endpoint, testToken)
                                if (capabilityProbeGeneration != generation) return@launch
                                capabilityProbe = when (result) {
                                    is PushCapabilitiesResult.Available -> {
                                        val checkedAt = System.currentTimeMillis()
                                        if (persistResult) runCatching {
                                            settings.recordCapabilities(
                                                valid.endpoint,
                                                result.capabilities,
                                                checkedAt,
                                            )
                                        }
                                        snapshot = settings.snapshot()
                                        CapabilityProbeUi.Success(result.capabilities.wireNames, checkedAt)
                                    }
                                    is PushCapabilitiesResult.Rejected -> CapabilityProbeUi.Failure(
                                        result.failure ?: PushFailure(PushFailureCode.NETWORK_IO),
                                    )
                                }
                            }
                        }
                    },
                )
                Text(
                    stringResource(R.string.push_test_connection_detail),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
                val probeSuccess = capabilityProbe as? CapabilityProbeUi.Success
                val savedEndpointMatches = token.isBlank() &&
                    validatedEndpoint?.endpoint?.url == snapshot.endpoint?.url
                val shownStreams = probeSuccess?.streams ?: snapshot.supportedStreams.takeIf { savedEndpointMatches }
                val capabilitiesCheckedAt = probeSuccess?.checkedAt
                    ?: snapshot.capabilitiesCheckedAt.takeIf { savedEndpointMatches }
                when (val probe = capabilityProbe) {
                    is CapabilityProbeUi.Failure -> Text(
                        pushFailureMessage(context, probe.failure),
                        style = NoopType.footnote,
                        color = Palette.statusWarning,
                    )
                    CapabilityProbeUi.Testing -> LinearProgressIndicator(
                        modifier = Modifier.fillMaxWidth(),
                        color = Palette.accent,
                    )
                    else -> Unit
                }
                shownStreams?.let { streams ->
                    Text(
                        stringResource(
                            R.string.push_capabilities_summary,
                            streams.size,
                            PushCapabilities.ALL.wireNames.size,
                        ),
                        style = NoopType.body,
                        color = if (streams.isEmpty()) Palette.statusWarning else Palette.textPrimary,
                    )
                    capabilitiesCheckedAt?.let { checkedAt ->
                        val checked = DateFormat.getDateTimeInstance(
                            DateFormat.MEDIUM,
                            DateFormat.SHORT,
                        ).format(Date(checkedAt))
                        Text(
                            stringResource(R.string.push_capabilities_checked, checked),
                            style = NoopType.footnote,
                            color = Palette.textSecondary,
                        )
                    }
                    Text(
                        if (streams.isEmpty()) stringResource(R.string.push_capabilities_none)
                        else stringResource(R.string.push_capabilities_streams, streams.joinToString(" · ")),
                        style = NoopType.footnote,
                        color = if (streams.isEmpty()) Palette.statusWarning else Palette.textSecondary,
                    )
                }
                if (snapshot.hasToken) {
                    NoopButton(
                        text = stringResource(R.string.push_clear_token),
                        kind = NoopButtonKind.Secondary,
                        fullWidth = true,
                        onClick = {
                            settings.saveToken("")
                            settings.setEnabled(false)
                            SelfHostedPushScheduler.cancel(context)
                            snapshot = settings.snapshot()
                            validationMessage = context.getString(R.string.push_token_cleared)
                        },
                    )
                }
                SettingsToggleRow(
                    title = stringResource(R.string.push_wifi_only),
                    detail = stringResource(R.string.push_wifi_only_detail),
                    checked = snapshot.wifiOnly,
                    onCheckedChange = { requested ->
                        capabilityProbe = CapabilityProbeUi.Idle
                        capabilityProbeGeneration++
                        settings.setWifiOnly(requested)
                        SelfHostedPushScheduler.networkPolicyChanged(context)
                        snapshot = settings.snapshot()
                    },
                )
                SettingsToggleRow(
                    title = stringResource(R.string.push_enabled),
                    detail = stringResource(R.string.push_enabled_detail),
                    checked = snapshot.enabled,
                    onCheckedChange = { requested ->
                        if (!requested) {
                            settings.setEnabled(false)
                            SelfHostedPushScheduler.cancel(context)
                        } else if (!settings.setEnabled(true)) {
                            validationMessage = context.getString(R.string.push_config_required)
                        } else {
                            SelfHostedPushScheduler.enqueueLaunchCatchUp(context)
                        }
                        snapshot = settings.snapshot()
                    },
                )
                NoopButton(
                    text = stringResource(R.string.push_export_now),
                    kind = NoopButtonKind.Secondary,
                    fullWidth = true,
                    enabled = snapshot.ready,
                    onClick = {
                        SelfHostedPushScheduler.enqueueManualCatchUp(context)
                        snapshot = settings.snapshot()
                    },
                )
                Text(
                    stringResource(R.string.push_export_now_detail),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
            }
        }

        SettingsCard(
            icon = Icons.Filled.CloudUpload,
            title = stringResource(R.string.push_status_title),
            blurb = stringResource(R.string.push_status_detail),
        ) {
            if (active) {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth(), color = Palette.accent)
            }
            val state = when (snapshot.runState) {
                SelfHostedPushSettings.RunState.IDLE -> stringResource(R.string.push_state_idle)
                SelfHostedPushSettings.RunState.QUEUED -> stringResource(R.string.push_state_queued)
                SelfHostedPushSettings.RunState.RUNNING -> stringResource(R.string.push_state_running)
                SelfHostedPushSettings.RunState.CONTINUING -> stringResource(R.string.push_state_continuing)
                SelfHostedPushSettings.RunState.RETRYING -> stringResource(R.string.push_state_retrying)
                SelfHostedPushSettings.RunState.COMPLETE -> stringResource(R.string.push_state_complete)
                SelfHostedPushSettings.RunState.FAILED -> stringResource(R.string.push_state_failed)
            }
            Text(stringResource(R.string.push_current_state, state), style = NoopType.body, color = Palette.textPrimary)
            Text(
                stringResource(R.string.push_progress, snapshot.acceptedBatches, snapshot.acceptedRecords),
                style = NoopType.footnote,
                color = Palette.textSecondary,
            )
            snapshot.currentStream?.let { stream ->
                Text(
                    stringResource(R.string.push_current_stream, stream),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
            }
            val success = snapshot.lastSuccessAt?.let {
                DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(it))
            } ?: stringResource(R.string.push_never)
            Text(stringResource(R.string.push_last_success, success), style = NoopType.body, color = Palette.textPrimary)
            snapshot.lastError?.let {
                Text(stringResource(R.string.push_last_error, it), style = NoopType.footnote, color = Palette.statusWarning)
            }
        }
    }
}

@Composable
private fun PushTextField(value: String, onValueChange: (String) -> Unit, label: String, secret: Boolean) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        singleLine = true,
        visualTransformation = if (secret) PasswordVisualTransformation() else VisualTransformation.None,
        textStyle = NoopType.mono(13f),
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        colors = OutlinedTextFieldDefaults.colors(
            focusedTextColor = Palette.textPrimary,
            unfocusedTextColor = Palette.textPrimary,
            focusedBorderColor = Palette.accent,
            unfocusedBorderColor = Palette.hairline,
            cursorColor = Palette.accent,
            focusedContainerColor = Palette.surfaceInset,
            unfocusedContainerColor = Palette.surfaceInset,
        ),
    )
}
