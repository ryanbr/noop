package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.noop.ai.AiProvider
import com.noop.ai.ChatMsg
import com.noop.ai.CustomAiAuthHeader

/**
 * AI Coach, the single opt-in, bring-your-own-key feature.
 *
 * Two states:
 *  - No key saved → a setup card: masked key field, provider choice, model dropdown, Save, and a
 *    one-line privacy note.
 *  - Key saved → the chat: transcript of user/assistant bubbles, suggested-prompt chips, an input
 *    row with Send (disabled while sending), an error line in red, and a reset-key affordance.
 *
 * Everything is composed from the locked design system (ScreenScaffold / NoopCard / NoopType /
 * Palette / StatePill / SegmentedPillControl), dark Material3.
 */
@Composable
fun CoachScreen(vm: CoachViewModel = viewModel()) {
    val context = LocalContext.current
    val keyVersion by vm.keyVersion.collectAsStateWithLifecycle()
    val provider by vm.provider.collectAsStateWithLifecycle()
    val customConnected by vm.customConnected.collectAsStateWithLifecycle()
    // Re-evaluate the gate whenever the stored key, provider, or custom-connect state changes.
    val configured = remember(keyVersion, provider, customConnected) { vm.isConfigured(context) }
    // #1862: a question handed over by the Today launcher sheet. Consumed once — `consume()` clears it —
    // so a recomposition cannot resend it, and only when the coach can actually send, so an unconfigured
    // handoff degrades to showing setup rather than a failed request. Swift twin: CoachView's task.
    LaunchedEffect(configured) {
        val handed = CoachHandoff.consume()
        if (handed != null && configured) vm.send(context, handed)
    }
    // Same day-cycle gate as the liquid Today: the time-of-day sky settles behind the top content when the
    // user hasn't opted out; otherwise the scaffold paints the plain dark canvas.
    val showDayCycleBackground = remember { NoopPrefs.showDayCycleBackground(context) }
    val skyBehindCards = remember { NoopPrefs.skyBehindCards(context) }

    ScreenScaffold(
        title = uiString(R.string.l10n_coach_screen_coach_b32c9ad3),
        subtitle = "Ask about your recovery, strain, sleep and HRV, grounded in your own numbers.",
        // LIQUID SKY BACKDROP (the pilot pattern — LiquidScreenSky.kt): the liquid sky sits behind the
        // header and the cards float over the flat canvas below. Reuses the shared LiquidScreenSky() slot
        // verbatim; when the day-cycle background is off, the scaffold paints the plain surface instead.
        topBackground = screenBackdropSlot(showDayCycleBackground, skyBehindCards),
        // Sky-behind-cards fills the viewport so the transparent cards reveal the sky the whole way
        // down (Today / Trends / Sleep / metric-detail parity - same two prefs, same two behaviours).
        fullBleedBackground = screenBackdropFullBleed(showDayCycleBackground, skyBehindCards),
    ) {
        if (!configured) {
            CoachSetup(vm = vm)
        } else {
            CoachChat(vm = vm)
        }
    }
}

// MARK: - Setup (no key saved)

@Composable
private fun CoachSetup(vm: CoachViewModel) {
    val context = LocalContext.current
    val provider by vm.provider.collectAsStateWithLifecycle()
    val model by vm.model.collectAsStateWithLifecycle()
    val availableModels by vm.availableModels.collectAsStateWithLifecycle()
    val refreshingModels by vm.refreshingModels.collectAsStateWithLifecycle()
    val customBaseUrl by vm.customBaseUrl.collectAsStateWithLifecycle()
    val customAuthHeader by vm.customAuthHeader.collectAsStateWithLifecycle()
    var keyInput by remember { mutableStateOf("") }
    val isCustom = provider == AiProvider.CUSTOM

    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Filled.Lock, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(18.dp))
                Text(uiString(R.string.l10n_coach_screen_connect_a_provider_6967f288), style = NoopType.headline, color = Palette.textPrimary)
            }
            Text(
                if (isCustom)
                    "Point the coach at any OpenAI-compatible server: a local model (Ollama, LM " +
                        "Studio, llama.cpp) keeps everything on your device; an API key is optional."
                else
                    "Bring your own API key. It is stored encrypted on this device and only used to " +
                        "send your question plus a short summary of your metrics to the provider you pick.",
                style = NoopType.subhead, color = Palette.textSecondary,
            )

            // Provider choice.
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Overline("Provider")
                SegmentedPillControl(
                    items = AiProvider.entries,
                    selection = provider,
                    label = { it.displayName },
                    onSelect = { vm.selectProvider(context, it) },
                )
            }

            // Server URL, Custom (local LLM) only.
            if (isCustom) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Overline("Server URL")
                    OutlinedTextField(
                        value = customBaseUrl,
                        onValueChange = { vm.setCustomBaseUrl(context, it) },
                        modifier = Modifier
                            .fillMaxWidth()
                            .semantics { contentDescription = uiString(R.string.l10n_coach_screen_server_url_1d5d1eff) },
                        placeholder = { Text("http://localhost:11434/v1", style = NoopType.body, color = Palette.textTertiary) },
                        textStyle = NoopType.mono(13f),
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                        colors = coachFieldColors(),
                        shape = RoundedCornerShape(14.dp),
                    )
                }

                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Overline(uiString(R.string.l10n_coach_screen_key_header_3f2a9b10))
                    SegmentedPillControl(
                        items = CustomAiAuthHeader.entries,
                        selection = customAuthHeader,
                        label = { it.displayName },
                        onSelect = { vm.setCustomAuthHeader(context, it) },
                    )
                    Text(
                        uiString(R.string.l10n_coach_screen_use_bearer_for_most_local_servers_4429ab64),
                        style = NoopType.footnote,
                        color = Palette.textSecondary,
                    )
                }
            }

            // Model dropdown + live-list refresh.
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Overline("Model")
                    Spacer(Modifier.weight(1f))
                    RefreshModelsButton(
                        refreshing = refreshingModels,
                        // Cloud providers need a saved key to fetch; a local server just needs a URL.
                        enabled = if (isCustom) customBaseUrl.isNotBlank() else vm.hasKey(context),
                        onClick = { vm.refreshModels(context) },
                    )
                }
                ModelDropdown(
                    models = availableModels,
                    selected = model,
                    onSelect = { vm.selectModel(context, it) },
                )
            }

            // Masked key field, optional for a local Custom server.
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Overline(if (isCustom) "API Key (optional)" else "API Key")
                CoachKeyField(
                    value = keyInput,
                    onValueChange = { keyInput = it },
                    placeholder = if (isCustom) "Only if your server requires one"
                                  else "Paste your ${provider.displayName} key",
                )
            }

            // Connect (Custom) / Save key (cloud).
            if (isCustom) {
                CoachPrimaryButton(
                    label = uiString(R.string.l10n_coach_screen_connect_b65463cb),
                    enabled = customBaseUrl.isNotBlank(),
                    onClick = {
                        if (keyInput.isNotBlank()) vm.saveKey(context, keyInput)
                        vm.connectCustom(context)
                    },
                )
            } else {
                CoachPrimaryButton(
                    label = uiString(R.string.l10n_coach_screen_save_key_f5216b3a),
                    enabled = keyInput.isNotBlank(),
                    onClick = { vm.saveKey(context, keyInput) },
                )
            }

            // Privacy note, one line, always visible.
            PrivacyNote(local = isCustom)
        }
    }
}

// MARK: - Chat (key saved)

@Composable
private fun CoachChat(vm: CoachViewModel) {
    val context = LocalContext.current
    val messages by vm.messages.collectAsStateWithLifecycle()
    val sending by vm.sending.collectAsStateWithLifecycle()
    val error by vm.error.collectAsStateWithLifecycle()
    val provider by vm.provider.collectAsStateWithLifecycle()
    val model by vm.model.collectAsStateWithLifecycle()
    val suggestions by vm.suggestions.collectAsStateWithLifecycle()
    // K15: the composer draft is persisted to SharedPreferences so it survives an app relaunch.
    // Restored on first composition, saved on every change. Keyed identically to the iOS twin.
    val draftPrefs = remember { context.getSharedPreferences("noop_coach_draft", android.content.Context.MODE_PRIVATE) }
    var input by remember { mutableStateOf(draftPrefs.getString("draft", "") ?: "") }
    // K2: confirmation gate for the destructive "Clear conversation" action.
    var showClearConfirm by remember { mutableStateOf(false) }

    // Refresh the contextual chips whenever the chat empties (so a fresh sync updates them) and
    // once on first show. Best-effort; the VM falls back to the generic set on any failure.
    LaunchedEffect(messages.isEmpty()) {
        if (messages.isEmpty()) vm.refreshSuggestions()
    }

    // K14: vibrate when a reply arrives (sending goes true → false with messages present).
    var wasSending by remember { mutableStateOf(false) }
    LaunchedEffect(sending) {
        if (wasSending && !sending && messages.isNotEmpty()) {
            val vibrator = context.getSystemService(android.content.Context.VIBRATOR_SERVICE)
                as android.os.Vibrator
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                vibrator.vibrate(
                    android.os.VibrationEffect.createOneShot(50, android.os.VibrationEffect.DEFAULT_AMPLITUDE)
                )
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(50)
            }
        }
        wasSending = sending
    }

    // K2 + K5 ordering matters and both gate on an EMPTY transcript, so this is ONE coroutine,
    // sequential: restore whatever the prior launch persisted FIRST, THEN surface a brief the
    // scheduled notification already generated (if any) — so K5 never overwrites K2's restore, and
    // never appends a duplicate brief onto a transcript K2 just repopulated.
    LaunchedEffect(Unit) {
        vm.loadPersistedMessagesIfNeeded()
        vm.loadBriefSettings(context)
        vm.consumeScheduledBriefIfAny(context)
    }

    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {

        // Active-provider strip + reset-key affordance.
        NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                // The pill takes the flexible space (ellipsizing a long model id); the Disconnect keeps
                // its intrinsic single-line width so it can never be squeezed into a vertical stack (#1074).
                StatePill(
                    title = uiString(R.string.l10n_coach_screen_provider_displayname_model_8b39f761, provider.displayName, model),
                    tone = StrandTone.Accent, showsDot = true,
                    modifier = Modifier.weight(1f),
                )
                Spacer(Modifier.width(8.dp))
                val disconnectInteraction = remember { MutableInteractionSource() }
                Text(
                    uiString(R.string.l10n_coach_screen_disconnect_ed28e068),
                    style = NoopType.caption,
                    color = Palette.textSecondary,
                    maxLines = 1,
                    softWrap = false,
                    modifier = Modifier
                        .clip(RoundedCornerShape(50))
                        .liquidPress(disconnectInteraction)
                        .clickable(interactionSource = disconnectInteraction, indication = null) { vm.disconnect(context) }
                        .padding(horizontal = 10.dp, vertical = 6.dp)
                        .semantics { contentDescription = uiString(R.string.l10n_coach_screen_disconnect_provider_fa13625c) },
                )
            }
        }

        if (showClearConfirm) {
            AlertDialog(
                onDismissRequest = { showClearConfirm = false },
                title = { Text(stringResource(R.string.coach_clear_conversation_confirm)) },
                text = { Text(stringResource(R.string.coach_clear_conversation_message)) },
                confirmButton = {
                    TextButton(onClick = { vm.clearConversation(); showClearConfirm = false }) {
                        Text(stringResource(R.string.coach_clear_action), color = Palette.statusCritical)
                    }
                },
                dismissButton = {
                    TextButton(onClick = { showClearConfirm = false }) { Text(stringResource(R.string.l10n_coach_screen_cancel_77dfd213)) }
                },
            )
        }

        // Data-access consent, off by default; no metrics are sent until this is on.
        val consent by vm.consent.collectAsStateWithLifecycle()
        NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(uiString(R.string.l10n_coach_screen_let_the_coach_use_my_data_405d1188), style = NoopType.subhead, color = Palette.textPrimary)
                    Text(
                        if (consent) "On: your recovery, sleep, HRV and workouts are shared with the provider for tailored coaching."
                        else "Off: the coach answers generally and sends none of your metrics.",
                        style = NoopType.footnote, color = Palette.textTertiary,
                    )
                }
                androidx.compose.material3.Switch(
                    checked = consent,
                    onCheckedChange = { vm.setConsent(context, it) },
                )
            }
        }

        // Editable system prompt, inline in the settings, collapsed by default. Edits persist and
        // take effect on the next message (the engine reads the stored prompt fresh per send).
        CoachInstructions(vm = vm)

        // K5: the scheduled morning-brief notification.
        MorningBriefCard(vm = vm)

        // Transcript or empty-state with suggested prompts.
        if (messages.isEmpty()) {
            NoopCard(padding = 18.dp) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(
                        uiString(R.string.l10n_coach_screen_ask_anything_about_your_recent_recovery_e6c287ca),
                        style = NoopType.subhead, color = Palette.textSecondary,
                    )
                    SuggestedPrompts(prompts = suggestions, onPick = { input = it })
                }
            }
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                messages.forEach { msg -> ChatBubble(msg, vm) }
                if (sending) ThinkingBubble()
                // K7: follow-up suggestion chips after each assistant reply (when not mid-send).
                if (!sending && messages.isNotEmpty() && messages.last().role == "assistant") {
                    SuggestedPrompts(prompts = vm.followUpSuggestions, onPick = { input = it })
                }
            }
        }

        // Error line (red). Capture into a stable local first: `error` is a state-backed nullable, and
        // the `semantics {}` contentDescription is a DEFERRED closure run later during the accessibility
        // pass — by then a recomposition can have cleared `error`, so `error!!` inside the lambda would
        // NPE (#1074). The local `errorMsg` is a fixed non-null snapshot the lambda can't null out from
        // under it.
        val errorMsg = error
        if (errorMsg != null) {
            Text(
                errorMsg,
                style = NoopType.subhead,
                color = Palette.statusCritical,
                modifier = Modifier.semantics { contentDescription = uiString(R.string.l10n_coach_screen_coach_error_error_ad9c8c46, errorMsg) },
            )
        }

        // Input row + Send, a frosted overlay surface so the composer reads as a docked input bar.
        // K4: the mic button (on-device voice input) sits between the text field and Send.
        MicComposerRow(
            input = input,
            onInputChange = {
                input = it
                // K15: persist the draft so it survives an app relaunch.
                draftPrefs.edit().putString("draft", it).apply()
                if (error != null) vm.clearError()
            },
            sending = sending,
            onSend = {
                vm.send(context, input)
                input = ""
                // K15: clear the persisted draft on send.
                draftPrefs.edit().remove("draft").apply()
            },
        )

        // K12: rough token estimate shown when the draft is non-empty.
        if (input.isNotBlank()) {
            vm.estimatedTokens(input)?.let { tokens ->
                Row(
                    modifier = Modifier.fillMaxWidth().padding(top = 2.dp),
                    horizontalArrangement = Arrangement.Start,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        imageVector = Icons.Filled.Speed,
                        contentDescription = null,
                        modifier = Modifier.size(10.dp),
                        tint = Palette.textTertiary,
                    )
                    Spacer(modifier = Modifier.width(4.dp))
                    Text(
                        stringResource(R.string.coach_token_estimate, tokens),
                        style = NoopType.caption,
                        color = Palette.textTertiary,
                    )
                    if (tokens > 8000) {
                        Text(
                            stringResource(R.string.coach_token_warning),
                            style = NoopType.caption,
                            color = Palette.textTertiary,
                        )
                    }
                }
            }
        }

        // Privacy note repeated under the input so it's always on screen.
        PrivacyNote(local = provider == AiProvider.CUSTOM)
    }
}

/**
 * K5: the scheduled morning-brief notification settings — enable switch, time-of-day chip, and an
 * explicit "Generate now" action. Mirrors the daily-debug-export settings row shape
 * ([DebugExportScheduler]) and the Swift twin's `morningBriefBar`.
 */
@Composable
private fun MorningBriefCard(vm: CoachViewModel) {
    val context = LocalContext.current
    val enabled by vm.briefEnabled.collectAsStateWithLifecycle()
    val minutes by vm.briefMinutes.collectAsStateWithLifecycle()
    val generating by vm.briefGenerating.collectAsStateWithLifecycle()
    val status by vm.briefStatus.collectAsStateWithLifecycle()

    NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(stringResource(R.string.coach_morning_brief), style = NoopType.subhead, color = Palette.textPrimary)
                    Text(
                        if (enabled)
                            stringResource(R.string.coach_morning_brief_desc)
                        else stringResource(R.string.coach_morning_brief_off),
                        style = NoopType.footnote, color = Palette.textTertiary,
                    )
                }
                androidx.compose.material3.Switch(
                    checked = enabled,
                    onCheckedChange = { vm.setBriefEnabled(context, it) },
                )
            }
            if (enabled) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.coach_morning_brief_time), style = NoopType.subhead, color = Palette.textPrimary, modifier = Modifier.weight(1f))
                    TimeChip(
                        minutes = minutes,
                        accessibilityLabel = "Morning brief time",
                        onPicked = { vm.setBriefMinutes(context, it) },
                    )
                }
                Text(
                    stringResource(R.string.coach_morning_brief_best_effort),
                    style = NoopType.caption, color = Palette.textTertiary,
                )
                CoachPrimaryButton(
                    label = if (generating) stringResource(R.string.coach_generating) else stringResource(R.string.coach_generate_now),
                    enabled = !generating,
                    onClick = { vm.generateBriefNow(context) },
                )
                if (status != null) {
                    Text(status.orEmpty(), style = NoopType.footnote, color = Palette.textTertiary)
                }
            }
        }
    }
}

/**
 * Editable system prompt, the instructions that frame the coach. Collapsed by default; expanding
 * reveals a multi-line field bound to the view model (edits persist to [NoopPrefs] and take effect on
 * the next message) plus a Reset-to-default control. Inline in the settings, not a separate sheet.
 */
@Composable
private fun CoachInstructions(vm: CoachViewModel) {
    val context = LocalContext.current
    val prompt by vm.systemPrompt.collectAsStateWithLifecycle()
    val hasCustom by vm.hasCustomPrompt.collectAsStateWithLifecycle()
    var expanded by remember { mutableStateOf(false) }

    val headerInteraction = remember { MutableInteractionSource() }
    NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
        Column(verticalArrangement = Arrangement.spacedBy(if (expanded) 10.dp else 0.dp)) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .liquidPress(headerInteraction)
                    .clickable(interactionSource = headerInteraction, indication = null) { expanded = !expanded }
                    .semantics {
                        contentDescription = if (expanded) "Collapse coach instructions" else "Edit coach instructions"
                    },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(uiString(R.string.l10n_coach_screen_coach_instructions_28a07975), style = NoopType.subhead, color = Palette.textPrimary)
                    Text(
                        if (hasCustom) "Customised. Your edited instructions frame every reply."
                        else "Edit how the coach thinks and talks. Takes effect on your next message.",
                        style = NoopType.footnote, color = Palette.textTertiary,
                    )
                }
                Icon(
                    Icons.Filled.ArrowDropDown,
                    contentDescription = null,
                    tint = Palette.textTertiary,
                    modifier = Modifier.size(20.dp),
                )
            }

            if (expanded) {
                OutlinedTextField(
                    value = prompt,
                    onValueChange = { vm.setSystemPrompt(context, it) },
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 140.dp, max = 260.dp)
                        .semantics { contentDescription = uiString(R.string.l10n_coach_screen_coach_instructions_editor_b8f3ad31) },
                    textStyle = NoopType.body,
                    singleLine = false,
                    colors = coachFieldColors(),
                    shape = RoundedCornerShape(14.dp),
                )
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    TextButton(
                        onClick = { vm.resetSystemPrompt(context) },
                        enabled = hasCustom,
                    ) {
                        Text(
                            uiString(R.string.l10n_coach_screen_reset_to_default_39c90eb7),
                            style = NoopType.footnote,
                            color = if (hasCustom) Palette.accent else Palette.textTertiary,
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Chat bubbles

@Composable
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
private fun ChatBubble(msg: ChatMsg, vm: CoachViewModel) {
    val isUser = msg.role == "user"
    val bubbleShape = RoundedCornerShape(16.dp)
    val context = LocalContext.current
    val clipboardManager = androidx.compose.ui.platform.LocalClipboardManager.current
    // K8: long-press popup menu for Copy / Share / Save on assistant replies.
    var showMenu by remember { mutableStateOf(false) }
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = if (isUser) Arrangement.End else Arrangement.Start,
    ) {
        // User bubbles = a brand-green tinted bubble; Coach replies = a frosted Charge-tinted surface
        // so the reply reads as a card in the green Coach world rather than a flat grey box.
        val bubbleModifier = if (isUser) {
            Modifier
                .clip(bubbleShape)
                .background(Palette.accentMuted)
                .border(1.dp, Palette.accent.copy(alpha = 0.35f), bubbleShape)
        } else {
            Modifier
                .clip(bubbleShape)
                .frostedCardSurface(tint = Palette.chargeColor, cornerRadius = 16.dp)
        }
        Box(
            modifier = Modifier
                .widthIn(max = 320.dp)
                .then(bubbleModifier)
                .padding(horizontal = 14.dp, vertical = 10.dp)
                // K8: long-press assistant bubbles to show Copy / Share / Save. User bubbles
                // are not actionable (the text is the user's own input).
                .then(
                    if (isUser) Modifier
                    else Modifier.combinedClickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = {},
                        onLongClick = { showMenu = true },
                    )
                ),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Overline(
                    if (isUser) "You" else "Coach",
                    color = if (isUser) Palette.accentHover else Palette.textTertiary,
                )
                if (isUser) {
                    Text(msg.text, style = NoopType.body, color = Palette.textPrimary)
                } else {
                    // Render the Coach's Markdown (bold/lists/headings) instead of raw symbols (#149).
                    CoachMarkdown(msg.text, color = Palette.textPrimary)
                }
            }
            // K8: dropdown popup anchored to the bubble.
            DropdownMenu(
                expanded = showMenu,
                onDismissRequest = { showMenu = false },
            ) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.coach_copy_action)) },
                    onClick = {
                        clipboardManager.setText(androidx.compose.ui.text.AnnotatedString(msg.text))
                        showMenu = false
                    },
                )
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.coach_share_action)) },
                    onClick = {
                        val sendIntent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(android.content.Intent.EXTRA_TEXT, msg.text)
                        }
                        context.startActivity(
                            android.content.Intent.createChooser(sendIntent, "Share Coach advice")
                        )
                        showMenu = false
                    },
                )
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.coach_save_to_journal)) },
                    onClick = {
                        vm.saveAdviceToJournal(msg.text)
                        showMenu = false
                    },
                )
            }
        }
    }
}

@Composable
private fun ThinkingBubble() {
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Start) {
        Row(
            modifier = Modifier
                .clip(RoundedCornerShape(16.dp))
                .frostedCardSurface(tint = Palette.chargeColor, cornerRadius = 16.dp)
                .padding(horizontal = 14.dp, vertical = 12.dp)
                .semantics { contentDescription = uiString(R.string.l10n_coach_screen_coach_is_thinking_aaf91547) },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            CircularProgressIndicator(
                modifier = Modifier.size(16.dp),
                strokeWidth = 2.dp,
                color = Palette.accent,
            )
            Text(uiString(R.string.l10n_coach_screen_thinking_a60d9c9c), style = NoopType.subhead, color = Palette.textSecondary)
        }
    }
}

// MARK: - Suggested prompts

/**
 * #1862: shared with the Today Coach launcher sheet — see [CoachPrompts].
 *
 * Two hardcoded lists would have drifted the moment either was edited, and the launcher's whole purpose
 * is to be a shortcut INTO this screen rather than a second, subtly different Coach.
 */
internal val SUGGESTED_PROMPTS: List<String> get() = CoachPrompts.SUGGESTIONS

@Composable
private fun SuggestedPrompts(prompts: List<String>, onPick: (String) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Overline("Try asking")
        // Simple wrapped column of chips (one per row keeps long prompts readable).
        prompts.forEach { prompt ->
            val shape = RoundedCornerShape(50)
            val chipInteraction = remember { MutableInteractionSource() }
            Text(
                prompt,
                style = NoopType.caption,
                color = Palette.textPrimary,
                modifier = Modifier
                    .wrapContentWidth()
                    .clip(shape)
                    .background(Palette.surfaceInset)
                    .border(1.dp, Palette.hairline, shape)
                    .liquidPress(chipInteraction)
                    .clickable(interactionSource = chipInteraction, indication = null) { onPick(prompt) }
                    .padding(horizontal = 12.dp, vertical = 8.dp)
                    .semantics { contentDescription = uiString(R.string.l10n_coach_screen_suggested_prompt_prompt_379c0b15, prompt) },
            )
        }
    }
}

// MARK: - Model dropdown

@Composable
private fun ModelDropdown(
    models: List<String>,
    selected: String,
    onSelect: (String) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    var showCustom by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(14.dp)
    val triggerInteraction = remember { MutableInteractionSource() }
    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(shape)
                .background(Palette.surfaceInset)
                .border(1.dp, Palette.hairline, shape)
                .liquidPress(triggerInteraction)
                .clickable(interactionSource = triggerInteraction, indication = null) { expanded = true }
                .padding(horizontal = 14.dp, vertical = 12.dp)
                .semantics { contentDescription = uiString(R.string.l10n_coach_screen_model_selected_tap_to_change_043056c1, selected) },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(selected, style = NoopType.body, color = Palette.textPrimary, modifier = Modifier.weight(1f))
            Icon(Icons.Filled.ArrowDropDown, contentDescription = null, tint = Palette.textSecondary)
        }
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            modifier = Modifier.background(Palette.surfaceOverlay),
        ) {
            models.forEach { m ->
                DropdownMenuItem(
                    text = {
                        Text(
                            m,
                            style = NoopType.body,
                            color = if (m == selected) Palette.accent else Palette.textPrimary,
                        )
                    },
                    onClick = {
                        onSelect(m)
                        expanded = false
                    },
                )
            }
            // Free-text escape hatch, any model id the provider accepts can be entered.
            DropdownMenuItem(
                text = { Text(uiString(R.string.l10n_coach_screen_custom_dce04fd3), style = NoopType.body, color = Palette.textSecondary) },
                onClick = {
                    expanded = false
                    showCustom = true
                },
            )
        }
    }

    if (showCustom) {
        CustomModelDialog(
            initial = selected,
            onDismiss = { showCustom = false },
            onConfirm = { id ->
                showCustom = false
                if (id.isNotBlank()) onSelect(id)
            },
        )
    }
}

// MARK: - Custom model dialog (free-text id)

@Composable
private fun CustomModelDialog(
    initial: String,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    var text by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = { Text(uiString(R.string.l10n_coach_screen_custom_model_2e3bedea), style = NoopType.headline, color = Palette.textPrimary) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    uiString(R.string.l10n_coach_screen_enter_any_model_id_the_provider_dce4bbcb),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it },
                    modifier = Modifier
                        .fillMaxWidth()
                        .semantics { contentDescription = uiString(R.string.l10n_coach_screen_custom_model_id_6ffe2740) },
                    placeholder = { Text(uiString(R.string.l10n_coach_screen_e_g_gpt_4o_1da2e4d2), style = NoopType.body, color = Palette.textTertiary) },
                    textStyle = NoopType.mono(13f),
                    singleLine = true,
                    colors = coachFieldColors(),
                    shape = RoundedCornerShape(14.dp),
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onConfirm(text.trim()) },
                enabled = text.isNotBlank(),
            ) {
                Text(uiString(R.string.l10n_coach_screen_use_model_8d558ce2), style = NoopType.headline, color = Palette.accent)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(uiString(R.string.l10n_coach_screen_cancel_77dfd213), style = NoopType.subhead, color = Palette.textSecondary)
            }
        },
    )
}

// MARK: - Refresh models (fetch live list)

@Composable
private fun RefreshModelsButton(
    refreshing: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val shape = RoundedCornerShape(50)
    val active = enabled && !refreshing
    val refreshInteraction = remember { MutableInteractionSource() }
    Row(
        modifier = Modifier
            .clip(shape)
            .background(Palette.surfaceInset)
            .border(1.dp, Palette.hairline, shape)
            .let {
                if (active)
                    it
                        .liquidPress(refreshInteraction)
                        .clickable(interactionSource = refreshInteraction, indication = null, onClick = onClick)
                else it
            }
            .padding(horizontal = 10.dp, vertical = 6.dp)
            .semantics { contentDescription = uiString(R.string.l10n_coach_screen_fetch_models_from_provider_6654e1a0) },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (refreshing) {
            CircularProgressIndicator(modifier = Modifier.size(13.dp), strokeWidth = 2.dp, color = Palette.accent)
        } else {
            Icon(
                Icons.Filled.Refresh,
                contentDescription = null,
                tint = if (active) Palette.accent else Palette.textTertiary,
                modifier = Modifier.size(14.dp),
            )
        }
        Text(
            if (refreshing) "Fetching…" else "Refresh models",
            style = NoopType.caption,
            color = if (active) Palette.textPrimary else Palette.textTertiary,
        )
    }
}

// MARK: - Key field

@Composable
private fun CoachKeyField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = Modifier
            .fillMaxWidth()
            .semantics { contentDescription = uiString(R.string.l10n_coach_screen_api_key_hidden_f3cde531) },
        placeholder = { Text(placeholder, style = NoopType.body, color = Palette.textTertiary) },
        textStyle = NoopType.mono(13f),
        singleLine = true,
        visualTransformation = PasswordVisualTransformation(),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
        colors = coachFieldColors(),
        shape = RoundedCornerShape(14.dp),
    )
}

// MARK: - Buttons

@Composable
private fun CoachPrimaryButton(label: String, enabled: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(14.dp)
    val bg = if (enabled) Palette.accent else Palette.accent.copy(alpha = Palette.disabledOpacity)
    val interaction = remember { MutableInteractionSource() }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(48.dp)
            .clip(shape)
            .background(bg)
            .let {
                if (enabled)
                    it
                        .liquidPress(interaction)
                        .clickable(interactionSource = interaction, indication = null, onClick = onClick)
                else it
            }
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Text(label, style = NoopType.headline, color = Palette.surfaceBase)
    }
}

// MARK: - K4: Voice input composer row (mic button + text field + send)

/**
 * K4: The composer row with a mic button (on-device voice input) between the text field and Send.
 * Mirrors the iOS `CoachView.composer` + `micButton` twin. The mic button:
 *  - requests RECORD_AUDIO at runtime on first tap (via [rememberLauncherForActivityResult]),
 *  - starts/stops [CoachVoiceInput] (Android platform SpeechRecognizer, EXTRA_PREFER_OFFLINE),
 *  - streams the partial transcript into the text field live,
 *  - on stop, appends the finalized transcript to the draft (not replace, so it composes with
 *    typed text).
 * Only the resulting TEXT ever reaches the AI provider — no new network path, no audio egress.
 */
@Composable
private fun MicComposerRow(
    input: String,
    onInputChange: (String) -> Unit,
    sending: Boolean,
    onSend: () -> Unit,
) {
    val context = LocalContext.current
    var isRecording by remember { mutableStateOf(false) }
    var voiceStatus by remember { mutableStateOf<String?>(null) }

    // The voice controller is remembered for the lifetime of the composer; destroyed on leave.
    val voiceInput = remember {
        CoachVoiceInput(
            context = context,
            onPartial = { partial -> onInputChange(partial) },
            onFinal = { final ->
                val trimmed = final.trim()
                if (trimmed.isNotEmpty()) {
                    // Append to the draft (not replace) so voice composes with typed text.
                    val merged = if (input.isBlank()) trimmed else "$input $trimmed"
                    onInputChange(merged)
                }
            },
            onError = { msg -> voiceStatus = msg },
        )
    }
    // Release the recognizer when the composer leaves composition.
    androidx.compose.runtime.DisposableEffect(voiceInput) {
        onDispose { voiceInput.destroy() }
    }

    // Runtime RECORD_AUDIO permission launcher — raised on the first mic tap if not yet granted.
    val permLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) {
            voiceInput.start()
            isRecording = true
        } else {
            voiceStatus = context.getString(R.string.coach_voice_permission_denied)
        }
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(Palette.surfaceOverlay)
            .border(1.dp, Palette.hairline, RoundedCornerShape(18.dp))
            .padding(8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        OutlinedTextField(
            value = input,
            onValueChange = onInputChange,
            modifier = Modifier.weight(1f),
            placeholder = {
                Text(
                    if (isRecording) stringResource(R.string.coach_listening) else uiString(R.string.l10n_coach_screen_ask_your_coach_b1577d4c),
                    style = NoopType.body,
                    color = Palette.textTertiary,
                )
            },
            textStyle = NoopType.body,
            singleLine = false,
            maxLines = 4,
            enabled = !sending,
            colors = coachFieldColors(),
            shape = RoundedCornerShape(14.dp),
        )

        // K4: mic button — on-device voice input. Hidden entirely when on-device recognition
        // is not available (API < 31 or locale without an offline model), matching iOS which
        // disables voice when `supportsOnDeviceRecognition` is false.
        if (voiceInput.isAvailable()) {
            MicButton(
                isRecording = isRecording,
                enabled = !sending,
                statusMessage = voiceStatus,
                onClick = {
                    voiceStatus = null
                    if (isRecording) {
                        voiceInput.stop()
                        isRecording = false
                    } else {
                        if (voiceInput.isPermissionGranted()) {
                            voiceInput.start()
                            isRecording = true
                        } else {
                            permLauncher.launch(voiceInput.requiredPermission)
                        }
                    }
                },
            )
        }

        SendButton(
            enabled = input.isNotBlank() && !sending,
            sending = sending,
            onClick = onSend,
        )
    }

    // Voice status / error line (e.g. "Microphone permission denied" or locale-not-supported).
    if (voiceStatus != null) {
        Text(
            voiceStatus!!,
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )
    }
}

@Composable
private fun MicButton(
    isRecording: Boolean,
    enabled: Boolean,
    statusMessage: String?,
    onClick: () -> Unit,
) {
    val bg = if (isRecording) Palette.statusCritical.copy(alpha = 0.15f) else Palette.surfaceInset
    val tint = if (isRecording) Palette.statusCritical else Palette.textSecondary
    val interaction = remember { MutableInteractionSource() }
    val desc = if (isRecording) "Stop voice input" else "Voice input"
    val statusSuffix = statusMessage?.let { stringResource(R.string.coach_status_suffix, it) } ?: ""
    Box(
        modifier = Modifier
            .size(48.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(bg)
            .border(1.dp, Palette.hairline, RoundedCornerShape(14.dp))
            .let {
                if (enabled)
                    it
                        .liquidPress(interaction)
                        .clickable(interactionSource = interaction, indication = null, onClick = onClick)
                else it
            }
            .semantics {
                contentDescription = desc + statusSuffix
            },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            if (isRecording) Icons.Filled.Stop else Icons.Filled.Mic,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(20.dp),
        )
    }
}

@Composable
private fun SendButton(enabled: Boolean, sending: Boolean, onClick: () -> Unit) {
    val bg = if (enabled) Palette.accent else Palette.surfaceInset
    val interaction = remember { MutableInteractionSource() }
    Box(
        modifier = Modifier
            .size(52.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(bg)
            .border(1.dp, if (enabled) Color.Transparent else Palette.hairline, RoundedCornerShape(14.dp))
            .let {
                if (enabled)
                    it
                        .liquidPress(interaction)
                        .clickable(interactionSource = interaction, indication = null, onClick = onClick)
                else it
            }
            .semantics { contentDescription = uiString(R.string.l10n_coach_screen_send_message_c70a890d) },
        contentAlignment = Alignment.Center,
    ) {
        if (sending) {
            CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp, color = Palette.accent)
        } else {
            Icon(
                Icons.AutoMirrored.Filled.Send,
                contentDescription = null,
                tint = if (enabled) Palette.surfaceBase else Palette.textTertiary,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

// MARK: - Privacy note (one line)

@Composable
private fun PrivacyNote(local: Boolean = false) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(Icons.Filled.Lock, contentDescription = null, tint = Palette.textTertiary, modifier = Modifier.size(13.dp))
        Text(
            if (local)
                "The coach talks only to the server URL you set. Point it at a local model to " +
                    "keep everything on your device. Nothing is sent until you ask."
            else
                "Private by default: only your question and a short metrics summary are sent, " +
                    "and only after you set a key.",
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )
    }
}

// MARK: - Shared field colors (dark, design-system tinted)

@Composable
private fun coachFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = Palette.textPrimary,
    unfocusedTextColor = Palette.textPrimary,
    disabledTextColor = Palette.textTertiary,
    cursorColor = Palette.accent,
    focusedBorderColor = Palette.accent,
    unfocusedBorderColor = Palette.hairline,
    disabledBorderColor = Palette.hairline,
    focusedContainerColor = Palette.surfaceInset,
    unfocusedContainerColor = Palette.surfaceInset,
    disabledContainerColor = Palette.surfaceInset,
)
