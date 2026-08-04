package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Refresh
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
        topBackground = if (showDayCycleBackground) { { LiquidScreenSky(fillHeight = skyBehindCards) } } else null,
        // Sky-behind-cards fills the viewport so the transparent cards reveal the sky the whole way
        // down (Today / Trends / Sleep / metric-detail parity - same two prefs, same two behaviours).
        fullBleedBackground = showDayCycleBackground && skyBehindCards,
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
    var input by remember { mutableStateOf("") }

    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {

        // Active-provider strip + reset-key affordance.
        NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                StatePill(title = uiString(R.string.l10n_coach_screen_provider_displayname_model_8b39f761, provider.displayName, model), tone = StrandTone.Accent, showsDot = true)
                Spacer(Modifier.weight(1f))
                val disconnectInteraction = remember { MutableInteractionSource() }
                Text(
                    uiString(R.string.l10n_coach_screen_disconnect_ed28e068),
                    style = NoopType.caption,
                    color = Palette.textSecondary,
                    modifier = Modifier
                        .clip(RoundedCornerShape(50))
                        .liquidPress(disconnectInteraction)
                        .clickable(interactionSource = disconnectInteraction, indication = null) { vm.disconnect(context) }
                        .padding(horizontal = 10.dp, vertical = 6.dp)
                        .semantics { contentDescription = uiString(R.string.l10n_coach_screen_disconnect_provider_fa13625c) },
                )
            }
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

        // Transcript or empty-state with suggested prompts.
        if (messages.isEmpty()) {
            NoopCard(padding = 18.dp) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(
                        uiString(R.string.l10n_coach_screen_ask_anything_about_your_recent_recovery_e6c287ca),
                        style = NoopType.subhead, color = Palette.textSecondary,
                    )
                    SuggestedPrompts(onPick = { input = it })
                }
            }
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                messages.forEach { msg -> ChatBubble(msg) }
                if (sending) ThinkingBubble()
            }
        }

        // Error line (red).
        if (error != null) {
            Text(
                error!!,
                style = NoopType.subhead,
                color = Palette.statusCritical,
                modifier = Modifier.semantics { contentDescription = uiString(R.string.l10n_coach_screen_coach_error_error_ad9c8c46, error!!) },
            )
        }

        // Input row + Send, a frosted overlay surface so the composer reads as a docked input bar.
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
                onValueChange = {
                    input = it
                    if (error != null) vm.clearError()
                },
                modifier = Modifier.weight(1f),
                placeholder = { Text(uiString(R.string.l10n_coach_screen_ask_your_coach_b1577d4c), style = NoopType.body, color = Palette.textTertiary) },
                textStyle = NoopType.body,
                singleLine = false,
                maxLines = 4,
                enabled = !sending,
                colors = coachFieldColors(),
                shape = RoundedCornerShape(14.dp),
            )
            SendButton(
                enabled = input.isNotBlank() && !sending,
                sending = sending,
                onClick = {
                    vm.send(context, input)
                    input = ""
                },
            )
        }

        // Privacy note repeated under the input so it's always on screen.
        PrivacyNote(local = provider == AiProvider.CUSTOM)
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
private fun ChatBubble(msg: ChatMsg) {
    val isUser = msg.role == "user"
    val bubbleShape = RoundedCornerShape(16.dp)
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
                .padding(horizontal = 14.dp, vertical = 10.dp),
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

private val SUGGESTED_PROMPTS = listOf(
    "How's my recovery trending this week?",
    "Should I train hard or take it easy today?",
    "Why might my HRV be low lately?",
    "How can I improve my sleep?",
)

@Composable
private fun SuggestedPrompts(onPick: (String) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Overline("Try asking")
        // Simple wrapped column of chips (one per row keeps long prompts readable).
        SUGGESTED_PROMPTS.forEach { prompt ->
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
