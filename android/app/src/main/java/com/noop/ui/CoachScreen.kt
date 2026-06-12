package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
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
import androidx.compose.material.icons.filled.Send
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

/**
 * AI Coach — the single opt-in, bring-your-own-key feature.
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

    ScreenScaffold(
        title = "Coach",
        subtitle = "Ask about your recovery, strain, sleep and HRV — grounded in your own numbers.",
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
    var keyInput by remember { mutableStateOf("") }
    val isCustom = provider == AiProvider.CUSTOM

    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Filled.Lock, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(18.dp))
                Text("Connect a provider", style = NoopType.headline, color = Palette.textPrimary)
            }
            Text(
                if (isCustom)
                    "Point the coach at any OpenAI-compatible server — a local model (Ollama, LM " +
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

            // Server URL — Custom (local LLM) only.
            if (isCustom) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Overline("Server URL")
                    OutlinedTextField(
                        value = customBaseUrl,
                        onValueChange = { vm.setCustomBaseUrl(context, it) },
                        modifier = Modifier
                            .fillMaxWidth()
                            .semantics { contentDescription = "Server URL" },
                        placeholder = { Text("http://localhost:11434/v1", style = NoopType.body, color = Palette.textTertiary) },
                        textStyle = NoopType.mono(13f),
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                        colors = coachFieldColors(),
                        shape = RoundedCornerShape(14.dp),
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

            // Masked key field — optional for a local Custom server.
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
                    label = "Connect",
                    enabled = customBaseUrl.isNotBlank(),
                    onClick = {
                        if (keyInput.isNotBlank()) vm.saveKey(context, keyInput)
                        vm.connectCustom(context)
                    },
                )
            } else {
                CoachPrimaryButton(
                    label = "Save key",
                    enabled = keyInput.isNotBlank(),
                    onClick = { vm.saveKey(context, keyInput) },
                )
            }

            // Privacy note — one line, always visible.
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
        NoopCard(padding = 14.dp) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                StatePill(title = "${provider.displayName} · $model", tone = StrandTone.Accent, showsDot = true)
                Spacer(Modifier.weight(1f))
                Text(
                    "Disconnect",
                    style = NoopType.caption,
                    color = Palette.textSecondary,
                    modifier = Modifier
                        .clip(RoundedCornerShape(50))
                        .clickable { vm.disconnect(context) }
                        .padding(horizontal = 10.dp, vertical = 6.dp)
                        .semantics { contentDescription = "Disconnect provider" },
                )
            }
        }

        // Data-access consent — off by default; no metrics are sent until this is on.
        val consent by vm.consent.collectAsStateWithLifecycle()
        NoopCard(padding = 14.dp) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text("Let the coach use my data", style = NoopType.subhead, color = Palette.textPrimary)
                    Text(
                        if (consent) "On — your recovery, sleep, HRV and workouts are shared with the provider for tailored coaching."
                        else "Off — the coach answers generally and sends none of your metrics.",
                        style = NoopType.footnote, color = Palette.textTertiary,
                    )
                }
                androidx.compose.material3.Switch(
                    checked = consent,
                    onCheckedChange = { vm.setConsent(context, it) },
                )
            }
        }

        // Transcript or empty-state with suggested prompts.
        if (messages.isEmpty()) {
            NoopCard(padding = 18.dp) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(
                        "Ask anything about your recent recovery, strain, sleep or HRV.",
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
                modifier = Modifier.semantics { contentDescription = "Coach error: ${error}" },
            )
        }

        // Input row + Send.
        Row(
            modifier = Modifier.fillMaxWidth(),
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
                placeholder = { Text("Ask your coach…", style = NoopType.body, color = Palette.textTertiary) },
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

// MARK: - Chat bubbles

@Composable
private fun ChatBubble(msg: ChatMsg) {
    val isUser = msg.role == "user"
    val bubbleShape = RoundedCornerShape(16.dp)
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = if (isUser) Arrangement.End else Arrangement.Start,
    ) {
        Box(
            modifier = Modifier
                .widthIn(max = 320.dp)
                .clip(bubbleShape)
                .background(if (isUser) Palette.accentMuted else Palette.surfaceRaised)
                .border(
                    1.dp,
                    if (isUser) Palette.accent.copy(alpha = 0.35f) else Palette.hairline,
                    bubbleShape,
                )
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
    val bubbleShape = RoundedCornerShape(16.dp)
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Start) {
        Row(
            modifier = Modifier
                .clip(bubbleShape)
                .background(Palette.surfaceRaised)
                .border(1.dp, Palette.hairline, bubbleShape)
                .padding(horizontal = 14.dp, vertical = 12.dp)
                .semantics { contentDescription = "Coach is thinking" },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            CircularProgressIndicator(
                modifier = Modifier.size(16.dp),
                strokeWidth = 2.dp,
                color = Palette.accent,
            )
            Text("Thinking…", style = NoopType.subhead, color = Palette.textSecondary)
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
            Text(
                prompt,
                style = NoopType.caption,
                color = Palette.textPrimary,
                modifier = Modifier
                    .wrapContentWidth()
                    .clip(shape)
                    .background(Palette.surfaceInset)
                    .border(1.dp, Palette.hairline, shape)
                    .clickable { onPick(prompt) }
                    .padding(horizontal = 12.dp, vertical = 8.dp)
                    .semantics { contentDescription = "Suggested prompt: $prompt" },
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
    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(shape)
                .background(Palette.surfaceInset)
                .border(1.dp, Palette.hairline, shape)
                .clickable { expanded = true }
                .padding(horizontal = 14.dp, vertical = 12.dp)
                .semantics { contentDescription = "Model: $selected. Tap to change." },
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
            // Free-text escape hatch — any model id the provider accepts can be entered.
            DropdownMenuItem(
                text = { Text("Custom…", style = NoopType.body, color = Palette.textSecondary) },
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
        title = { Text("Custom model", style = NoopType.headline, color = Palette.textPrimary) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    "Enter any model id the provider accepts.",
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it },
                    modifier = Modifier
                        .fillMaxWidth()
                        .semantics { contentDescription = "Custom model id" },
                    placeholder = { Text("e.g. gpt-4o", style = NoopType.body, color = Palette.textTertiary) },
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
                Text("Use model", style = NoopType.headline, color = Palette.accent)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel", style = NoopType.subhead, color = Palette.textSecondary)
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
    Row(
        modifier = Modifier
            .clip(shape)
            .background(Palette.surfaceInset)
            .border(1.dp, Palette.hairline, shape)
            .let { if (active) it.clickable(onClick = onClick) else it }
            .padding(horizontal = 10.dp, vertical = 6.dp)
            .semantics { contentDescription = "Fetch models from provider" },
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
            .semantics { contentDescription = "API key (hidden)" },
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
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(48.dp)
            .clip(shape)
            .background(bg)
            .let { if (enabled) it.clickable(onClick = onClick) else it }
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Text(label, style = NoopType.headline, color = Palette.surfaceBase)
    }
}

@Composable
private fun SendButton(enabled: Boolean, sending: Boolean, onClick: () -> Unit) {
    val bg = if (enabled) Palette.accent else Palette.surfaceInset
    Box(
        modifier = Modifier
            .size(52.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(bg)
            .border(1.dp, if (enabled) Color.Transparent else Palette.hairline, RoundedCornerShape(14.dp))
            .let { if (enabled) it.clickable(onClick = onClick) else it }
            .semantics { contentDescription = "Send message" },
        contentAlignment = Alignment.Center,
    ) {
        if (sending) {
            CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp, color = Palette.accent)
        } else {
            Icon(
                Icons.Filled.Send,
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
                "The coach talks only to the server URL you set — point it at a local model to " +
                    "keep everything on your device. Nothing is sent until you ask."
            else
                "Private by default — only your question and a short metrics summary are sent, " +
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
