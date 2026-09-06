package com.noop.ui

import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.noop.NoopApplication
import com.noop.ai.AiCoach
import com.noop.ai.AiKeyStore
import com.noop.ai.AiProvider
import com.noop.ai.ChatMsg
import com.noop.ai.CustomAiAuthHeader
import com.noop.R
import com.noop.data.CoachMessageRow
import com.noop.data.JournalEntry
import com.noop.data.WhoopDatabase
import com.noop.data.WhoopRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.text.SimpleDateFormat
import java.util.Locale

/**
 * View model for the AI Coach screen.
 *
 * Holds the [AiCoach] engine (built over the same Room-backed [WhoopRepository] the rest of
 * the app uses) and the chat state. The API key and the chosen provider/model are persisted
 * by [AiKeyStore], the key encrypted at rest in the Android Keystore, the provider/model as
 * plain (non-secret) preferences.
 *
 * Privacy posture mirrors the engine: nothing is sent until the user has saved a key and asked
 * a question, and only a compact text summary of their own metrics plus their question leaves
 * the device. Errors never crash, they surface in [error].
 */
class CoachViewModel(app: Application) : AndroidViewModel(app) {

    // The networked coach, over the local store. No key is held here; the engine reads it from
    // the encrypted store at call time.
    private val aiCoach = AiCoach(
        WhoopRepository(WhoopDatabase.get(app.applicationContext)),
        // #1304/#512: thread the active strap id (resolved lazily by NoopApplication) so the coach reasons
        // off the active strap's data — daysMerged/R-R/Lab markers union active ∪ canonical — instead of a
        // hardcoded "my-whoop" that misses a strap banked under "whoop-<uuid>".
        activeStrapId = { (app as NoopApplication).activeDeviceId },
    )

    // PRD-K2: persisted conversation history (Room `coachMessage` table).
    private val coachDao = WhoopDatabase.get(app.applicationContext).whoopDao()
    private var didLoadPersistedMessages = false

    // MARK: - Transcript

    private val _messages = MutableStateFlow<List<ChatMsg>>(emptyList())
    /** The conversation so far (user/assistant turns), oldest first. */
    val messages: StateFlow<List<ChatMsg>> = _messages.asStateFlow()

    private val _sending = MutableStateFlow(false)
    /** True while a request is in flight, the UI disables Send and shows a thinking state. */
    val sending: StateFlow<Boolean> = _sending.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    /** Non-null when the last send failed; the UI shows it in red. Cleared on the next send. */
    val error: StateFlow<String?> = _error.asStateFlow()

    // MARK: - Provider / model selection (persisted via AiKeyStore)

    private val _provider = MutableStateFlow(AiKeyStore.readProvider(app.applicationContext))
    /** The currently selected provider. Persisted across launches. */
    val provider: StateFlow<AiProvider> = _provider.asStateFlow()

    private val _model = MutableStateFlow(
        AiKeyStore.readModel(app.applicationContext, _provider.value)
    )
    /** The currently selected model id. Persisted per provider. May be a custom/live id. */
    val model: StateFlow<String> = _model.asStateFlow()

    private val _availableModels = MutableStateFlow(seedModels(_provider.value, _model.value))
    /**
     * The models offered in the picker for the current provider: the provider's curated list,
     * plus any live-fetched ids merged in, plus the currently-selected id if it's a custom one.
     * Re-seeded whenever the provider changes; extended by [refreshModels].
     */
    val availableModels: StateFlow<List<String>> = _availableModels.asStateFlow()

    private val _refreshingModels = MutableStateFlow(false)
    /** True while a live model-list fetch is in flight; the UI disables the Refresh action. */
    val refreshingModels: StateFlow<Boolean> = _refreshingModels.asStateFlow()

    private val _consent = MutableStateFlow(AiKeyStore.readConsent(app.applicationContext))
    /** Explicit permission for the coach to read & send the user's data. Off by default. */
    val consent: StateFlow<Boolean> = _consent.asStateFlow()

    // MARK: - Custom (local LLM) provider settings

    private val _customBaseUrl = MutableStateFlow(AiKeyStore.readCustomBaseUrl(app.applicationContext))
    /** Base URL for the Custom (OpenAI-compatible) provider, e.g. http://localhost:11434/v1. */
    val customBaseUrl: StateFlow<String> = _customBaseUrl.asStateFlow()

    private val _customAuthHeader = MutableStateFlow(AiKeyStore.readCustomAuthHeader(app.applicationContext))
    /** Header used by the Custom provider when an API key is present. */
    val customAuthHeader: StateFlow<CustomAiAuthHeader> = _customAuthHeader.asStateFlow()

    private val _customConnected = MutableStateFlow(AiKeyStore.readCustomConnected(app.applicationContext))
    /** True once the user has committed the Custom provider (entered a URL and tapped Connect). */
    val customConnected: StateFlow<Boolean> = _customConnected.asStateFlow()

    // MARK: - Contextual suggestion chips

    private val _suggestions = MutableStateFlow(com.noop.analytics.CoachSuggestions.fallback)
    /**
     * Contextual composer chips derived from today's bands (byte-twin of the Swift
     * `AICoachEngine.suggestions`). Refreshed by [refreshSuggestions]; the UI calls it when the
     * chat is empty so a fresh sync immediately updates the chips. Falls back to the generic set
     * when there is no usable data.
     */
    val suggestions: StateFlow<List<String>> = _suggestions.asStateFlow()

    /** K7: Follow-up chips shown after each assistant reply. Static, byte-twin of the Swift list. */
    val followUpSuggestions: List<String> = aiCoach.followUpSuggestions

    /**
     * K12: Rough token estimate for the next send, based on the current draft + context size.
     * Uses the standard ~4 chars/token heuristic. Returns null when not configured.
     */
    fun estimatedTokens(draft: String): Int? {
        val app = getApplication<Application>()
        if (!isConfigured(app.applicationContext)) return null
        val systemPrompt = AiCoach.resolveSystemPrompt(app.applicationContext)
        val systemPromptTokens = systemPrompt.length / 4
        val contextTokens = if (consent.value) 750 else 50
        val historyTokens = messages.value.sumOf { it.text.length / 4 }
        val draftTokens = draft.length / 4
        return systemPromptTokens + contextTokens + historyTokens + draftTokens
    }

    /** Recompute the contextual chips from the current on-device days. Best-effort; never throws. */
    fun refreshSuggestions() {
        viewModelScope.launch {
            _suggestions.value = runCatching { aiCoach.suggestions() }
                .getOrDefault(com.noop.analytics.CoachSuggestions.fallback)
        }
    }

    /** Update (and persist) the Custom provider's base URL as the user types. */
    fun setCustomBaseUrl(ctx: Context, url: String) {
        _customBaseUrl.value = url
        AiKeyStore.saveCustomBaseUrl(ctx, url)
    }

    fun setCustomAuthHeader(ctx: Context, header: CustomAiAuthHeader) {
        _customAuthHeader.value = header
        AiKeyStore.saveCustomAuthHeader(ctx, header)
    }

    /** Grant or revoke data access; persisted. */
    fun setConsent(ctx: Context, value: Boolean) {
        _consent.value = value
        AiKeyStore.saveConsent(ctx, value)
    }

    // MARK: - Editable system prompt

    private val _systemPrompt = MutableStateFlow(
        AiCoach.resolveSystemPrompt(app.applicationContext)
    )
    /**
     * The Coach's system prompt as currently shown in the editor: the user's stored override, or the
     * built-in default when nothing custom is set. Read fresh by the engine per send (see
     * [AiCoach.resolveSystemPrompt]); this flow just backs the editor UI.
     */
    val systemPrompt: StateFlow<String> = _systemPrompt.asStateFlow()

    private val _hasCustomPrompt = MutableStateFlow(
        NoopPrefs.coachSystemPrompt(app.applicationContext).isNotBlank()
    )
    /** True when an edited prompt differs from the default, gates the "Reset to default" control. */
    val hasCustomPrompt: StateFlow<Boolean> = _hasCustomPrompt.asStateFlow()

    /** Persist the edited [prompt] (blank clears it back to default) and reflect it in the editor. */
    fun setSystemPrompt(ctx: Context, prompt: String) {
        NoopPrefs.setCoachSystemPrompt(ctx, prompt)
        _systemPrompt.value = prompt
        _hasCustomPrompt.value = prompt.isNotBlank() && prompt.trim() != AiCoach.DEFAULT_SYSTEM_PROMPT
    }

    /** Restore the built-in default prompt by clearing any override. */
    fun resetSystemPrompt(ctx: Context) {
        NoopPrefs.setCoachSystemPrompt(ctx, "")
        _systemPrompt.value = AiCoach.DEFAULT_SYSTEM_PROMPT
        _hasCustomPrompt.value = false
    }

    // Bumped whenever the stored key changes so the UI recomposes its setup/chat gate.
    private val _keyVersion = MutableStateFlow(0)
    /** Increments when the key is saved or cleared; observe to re-read [hasKey]. */
    val keyVersion: StateFlow<Int> = _keyVersion.asStateFlow()

    // MARK: - Key gate

    /** True when a non-blank API key is stored. The UI shows the chat only when this is true. */
    fun hasKey(ctx: Context): Boolean = AiKeyStore.hasKey(ctx)

    /**
     * True once the coach can actually send: a stored key for the cloud providers, or, for the
     * Custom (local) provider, a committed base URL (a key is optional there). Gates setup vs. chat.
     */
    fun isConfigured(ctx: Context): Boolean =
        if (_provider.value == AiProvider.CUSTOM) _customConnected.value else hasKey(ctx)

    // MARK: - Selection mutators

    /**
     * Choose a provider; resets the model to that provider's stored/default model, re-seeds
     * the available-models list for the new provider, and persists.
     */
    fun selectProvider(ctx: Context, p: AiProvider) {
        if (p == _provider.value) return
        _provider.value = p
        AiKeyStore.saveProvider(ctx, p)
        val resolved = AiKeyStore.readModel(ctx, p)
        _model.value = resolved
        AiKeyStore.saveModel(ctx, p, resolved)
        // Reset the picker to the new provider's catalogue (plus the resolved id if custom).
        _availableModels.value = seedModels(p, resolved)
    }

    /**
     * Choose a model id and persist it for the current provider. Any non-blank id is accepted
     * (curated, live-fetched, or a custom id typed by the user); a brand-new custom id is also
     * merged into [availableModels] so it shows in the picker.
     */
    fun selectModel(ctx: Context, m: String) {
        val id = m.trim()
        if (id.isEmpty()) return
        _model.value = id
        AiKeyStore.saveModel(ctx, _provider.value, id)
        if (!_availableModels.value.contains(id)) {
            _availableModels.value = _availableModels.value + id
        }
    }

    /**
     * Best-effort: fetch the current provider's live model list using the saved key and merge
     * the returned ids into [availableModels] (curated ids first, then any new live ids). Never
     * throws and never changes the current selection; a failure simply leaves the list as-is.
     */
    fun refreshModels(ctx: Context) {
        if (_refreshingModels.value) return
        val appCtx = ctx.applicationContext
        val p = _provider.value
        val url = _customBaseUrl.value
        _refreshingModels.value = true
        viewModelScope.launch {
            try {
                val live = aiCoach.fetchModels(appCtx, p, url, _customAuthHeader.value)
                if (p == _provider.value) {
                    val merged = (_availableModels.value + live).distinct()
                    _availableModels.value = merged
                    // For Custom there's no curated/default model, adopt the first the server lists.
                    if (p == AiProvider.CUSTOM && _model.value.isBlank() && merged.isNotEmpty()) {
                        selectModel(appCtx, merged.first())
                    }
                }
            } catch (_: Exception) {
                // Best-effort, keep whatever list we already have.
            } finally {
                _refreshingModels.value = false
            }
        }
    }

    /**
     * Commit the Custom (local) provider once a server URL is entered: persist the committed flag
     * (so the chat unlocks without a key) and pull the server's model list, adopting the first.
     */
    fun connectCustom(ctx: Context) {
        if (_customBaseUrl.value.isBlank()) return
        val appCtx = ctx.applicationContext
        _customConnected.value = true
        AiKeyStore.saveCustomConnected(appCtx, true)
        _error.value = null
        refreshModels(appCtx)
    }

    // MARK: - Key management

    /** Save the user's API key (encrypted at rest). Blank input clears the key instead. */
    fun saveKey(ctx: Context, key: String) {
        AiKeyStore.save(ctx, key)
        _error.value = null
        _keyVersion.value += 1
        // #288: do NOT auto-fetch the provider's model list on key-save. For a cloud provider that GET hits
        // the provider the MOMENT a key is saved (leaking IP + request timing + key-validity) — before the
        // user has sent anything, in an app that is zero-network by default. The picker shows the curated
        // shipped models (seedModels); the LIVE list is pulled only when the user taps Refresh (an explicit
        // action that is its own consent) or sends. Local Custom servers still refresh on Connect.
    }

    /** Clear the stored key and reset the transcript back to the setup screen. */
    fun clearKey(ctx: Context) {
        AiKeyStore.clear(ctx)
        _messages.value = emptyList()
        // The day belongs to the transcript, so it goes with it. Harmless if left (a stale day only ever
        // clears an already-empty list) but it would be a field claiming something untrue.
        conversationDay = null
        _error.value = null
        _keyVersion.value += 1
    }

    /**
     * Disconnect entirely: forget any stored key AND un-commit the Custom provider, returning to
     * the setup screen. The Custom base URL is kept so reconnecting pre-fills it.
     */
    fun disconnect(ctx: Context) {
        AiKeyStore.clear(ctx)
        _customConnected.value = false
        AiKeyStore.saveCustomConnected(ctx, false)
        _messages.value = emptyList()
        conversationDay = null
        _error.value = null
        _keyVersion.value += 1
    }

    // MARK: - Send

    /** Local day ([LocalDate.toEpochDay]) the current transcript was last written on; null while it is
     *  empty. Drives the day boundary in [send] — see [isStaleConversation]. */
    private var conversationDay: Long? = null

    /** Append [msg] to the transcript, trimming to the newest [MAX_STORED_MESSAGES] so the in-memory list
     *  (and the Compose transcript) stays bounded over a long-lived session. (parity with Swift) */
    private fun appendMessage(msg: ChatMsg) {
        _messages.value = (_messages.value + msg).takeLast(MAX_STORED_MESSAGES)
    }

    /**
     * Send [text] as the next user turn: append it, stream the reply token-by-token into the
     * transcript, then finalize. K1: uses [AiCoach.chatStream] so the user sees text appear as
     * it's generated (perceived latency drops from "full reply" to "first token"). No-ops on
     * blank input or while a send is already in flight. All failures land in [error].
     *
     * On error mid-stream, keeps the partial text + an interrupted marker (PRD K1 acceptance).
     */
    fun send(ctx: Context, text: String) {
        val question = text.trim()
        if (question.isEmpty() || _sending.value) return

        // A transcript from an earlier local day is retired before the new turn is appended. The
        // ViewModel outlives a night (Android keeps the process around for days), so without this the
        // coach answers TODAY's question inside YESTERDAY's conversation: buildContext() re-reads the
        // store on every send, so the numbers are current, but the assistant's own earlier turns state
        // yesterday's figures and the model stays consistent with them. Reported as "the coach only
        // talks about my imported data" after a night of fresh strap data — force-quitting the app
        // (which destroys the ViewModel) was the only cure. MAX_STORED_MESSAGES bounds the transcript's
        // SIZE; this bounds its AGE.
        val today = LocalDate.now().toEpochDay()
        if (isStaleConversation(conversationDay, today)) {
            _messages.value = emptyList()
        }
        conversationDay = today

        val appCtx = ctx.applicationContext
        _error.value = null
        appendMessage(ChatMsg(role = "user", text = question))
        _sending.value = true

        // K1: append a placeholder assistant message, then mutate its text as chunks arrive.
        val placeholderId = java.util.UUID.randomUUID().toString()
        appendMessage(ChatMsg(id = placeholderId, role = "assistant", text = ""))
        var accumulated = ""

        viewModelScope.launch {
            try {
                aiCoach.chatStream(
                    ctx = appCtx,
                    history = _messages.value.dropLast(1), // exclude the placeholder
                    provider = _provider.value,
                    model = _model.value,
                    consent = _consent.value,
                    customBaseUrl = _customBaseUrl.value,
                    customAuthHeader = _customAuthHeader.value,
                    includeSignals = _consent.value && NoopPrefs.coachSignals(appCtx),
                ) { delta ->
                    accumulated += delta
                    // Replace the placeholder's text with the accumulated stream so far.
                    _messages.value = _messages.value.map { msg ->
                        if (msg.id == placeholderId) ChatMsg(id = placeholderId, role = "assistant", text = accumulated)
                        else msg
                    }
                }
                // Finalize: trim whitespace. If the stream produced nothing, show "(no reply)".
                val clean = accumulated.trim()
                _messages.value = _messages.value.map { msg ->
                    if (msg.id == placeholderId) {
                        ChatMsg(id = placeholderId, role = "assistant",
                                text = if (clean.isEmpty()) getApplication<Application>().getString(R.string.coach_no_reply) else clean)
                    } else msg
                }
            } catch (e: Exception) {
                val partial = accumulated.trim()
                if (partial.isNotEmpty()) {
                    _messages.value = _messages.value.map { msg ->
                        if (msg.id == placeholderId) {
                            ChatMsg(id = placeholderId, role = "assistant",
                                    text = getApplication<Application>().getString(R.string.coach_stream_interrupted, partial))
                        } else msg
                    }
                } else {
                    // No text received at all — remove the empty placeholder.
                    _messages.value = _messages.value.filterNot { it.id == placeholderId }
                }
                _error.value = e.message ?: "Something went wrong. Please try again."
            } finally {
                _sending.value = false
                // K2: persist once the turn is fully settled (success, mid-stream error, or empty-
                // stream removal) — not per streamed chunk, so a long reply doesn't hammer the store.
                persistMessages()
            }
        }
    }

    // MARK: - PRD-K2: persisted conversation history

    /**
     * Load the conversation persisted by a PRIOR launch, so relaunching doesn't lose it. `suspend` —
     * NOT fire-and-forget — so the caller (the Coach screen's single `LaunchedEffect`) can await it
     * before deciding whether the transcript is genuinely empty (K5's `consumeScheduledBriefIfAny`
     * makes exactly that check). A fire-and-forget `viewModelScope.launch` here would race: this load
     * could complete AFTER K5 already appended the scheduled brief and unconditionally overwrite it.
     * Best-effort: a store failure just leaves the transcript empty, matching pre-K2 behaviour.
     */
    suspend fun loadPersistedMessagesIfNeeded() {
        if (didLoadPersistedMessages) return
        didLoadPersistedMessages = true
        if (_messages.value.isNotEmpty()) return
        val rows = runCatching { coachDao.coachMessages() }.getOrDefault(emptyList())
        if (rows.isEmpty()) return
        _messages.value = rows.sortedBy { it.orderIndex }
            .map { ChatMsg(id = it.id, role = it.role, text = it.text) }
    }

    /** Replace the ENTIRE persisted conversation with the current in-memory [_messages]. Called once
     *  per completed send/brief (not per streamed chunk). Fire-and-forget; a store failure never
     *  blocks the UI — the in-memory transcript (what the user sees) is unaffected either way. */
    private fun persistMessages() {
        val snapshot = _messages.value
        val providerId = _provider.value.name
        viewModelScope.launch {
            val rows = snapshot.mapIndexed { index, m ->
                CoachMessageRow(
                    id = m.id, role = m.role, text = m.text, provider = providerId,
                    createdAt = System.currentTimeMillis() / 1000, orderIndex = index,
                )
            }
            runCatching { coachDao.replaceCoachMessages(rows) }
        }
    }

    /** The Coach toolbar's "Clear conversation" action: wipes both the in-memory transcript and the
     *  persisted table. */
    fun clearConversation() {
        _messages.value = emptyList()
        viewModelScope.launch { runCatching { coachDao.clearCoachMessages() } }
    }

    /** Dismiss the current error (e.g. when the user edits the input again). */
    fun clearError() {
        _error.value = null
    }

    // MARK: - K8: Copy/Share/Save advice

    /**
     * K8: Save a coach reply to the journal as a note, so it appears alongside other journal
     * entries in Insights and can be reviewed later. Uses the existing journal API with a
     * fixed question ("Coach advice") and the reply text in the notes field.
     */
    fun saveAdviceToJournal(text: String) {
        val app = getApplication<Application>()
        val day = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(java.util.Date())
        viewModelScope.launch {
            runCatching {
                WhoopRepository(WhoopDatabase.get(app.applicationContext)).upsertJournal(
                    listOf(
                        JournalEntry(
                            deviceId = (app as NoopApplication).activeDeviceId,
                            day = day,
                            question = "Coach advice",
                            answeredYes = true,
                            notes = text,
                        )
                    )
                )
            }
        }
    }

    // MARK: - K5: scheduled morning-brief notification

    private val _briefEnabled = MutableStateFlow(false)
    /** Whether the scheduled morning-brief notification is armed. Default OFF. */
    val briefEnabled: StateFlow<Boolean> = _briefEnabled.asStateFlow()

    private val _briefMinutes = MutableStateFlow(CoachBriefSettings.DEFAULT_TIME)
    /** Time-of-day (minutes since local midnight) the brief is generated. */
    val briefMinutes: StateFlow<Int> = _briefMinutes.asStateFlow()

    private val _briefGenerating = MutableStateFlow(false)
    val briefGenerating: StateFlow<Boolean> = _briefGenerating.asStateFlow()

    private val _briefStatus = MutableStateFlow<String?>(null)
    /** Non-null after a failed "Generate now" — surfaced once, then cleared by the caller. */
    val briefStatus: StateFlow<String?> = _briefStatus.asStateFlow()

    /** Load the persisted schedule state. Call once when the Coach settings become visible. */
    fun loadBriefSettings(ctx: Context) {
        val settings = CoachBriefSettings.from(ctx.applicationContext)
        _briefEnabled.value = settings.enabled
        _briefMinutes.value = settings.timeMinutes
    }

    /** Enable/disable the schedule and (re)arm the daily WorkManager job. */
    fun setBriefEnabled(ctx: Context, on: Boolean) {
        val appCtx = ctx.applicationContext
        val settings = CoachBriefSettings.from(appCtx)
        settings.enabled = on
        _briefEnabled.value = on
        CoachBriefScheduler.reschedule(appCtx, settings)
    }

    /** Update the time-of-day and reschedule so the new time takes effect immediately. */
    fun setBriefMinutes(ctx: Context, minutes: Int) {
        val appCtx = ctx.applicationContext
        val settings = CoachBriefSettings.from(appCtx)
        settings.timeMinutes = minutes
        _briefMinutes.value = settings.timeMinutes
        if (settings.enabled) CoachBriefScheduler.applyTimeChange(appCtx, settings)
    }

    /** The explicit "Generate now" button: always generates, appends the result as a new assistant
     *  message on success, or surfaces [briefStatus] on failure. Never touches the daily dedup. */
    fun generateBriefNow(ctx: Context) {
        if (_briefGenerating.value) return
        val appCtx = ctx.applicationContext
        _briefGenerating.value = true
        _briefStatus.value = null
        viewModelScope.launch {
            val text = CoachBriefScheduler.generateNow(appCtx)
            if (text != null) {
                appendMessage(ChatMsg(role = "assistant", text = getApplication<Application>().getString(R.string.coach_today_brief_format, text)))
                persistMessages()
            } else {
                _briefStatus.value = "Couldn't generate a brief right now — check your key and data access."
            }
            _briefGenerating.value = false
        }
    }

    /** Surface a brief the SCHEDULED notification already generated (if any) as the transcript's
     *  first message, with no network call. No-op if a conversation already exists. Call once when
     *  the Coach screen appears. */
    fun consumeScheduledBriefIfAny(ctx: Context) {
        if (_messages.value.isNotEmpty()) return
        val text = CoachBriefSettings.from(ctx.applicationContext).consumeStoredBrief() ?: return
        appendMessage(ChatMsg(role = "assistant", text = getApplication<Application>().getString(R.string.coach_today_brief_format, text)))
        persistMessages()
    }

    companion object {
        /**
         * Hard rolling cap on the STORED transcript. The network payload is separately windowed inside
         * [AiCoach]; this bounds the in-memory [_messages] list — and the Compose transcript rendered from
         * it — so a long-lived session can't grow it without bound. The ViewModel survives tab-switching,
         * so before this an active chat grew until the process was killed: the "gets laggy the longer the
         * app runs, reopening fixes it, feels like RAM" report. Cap >> the wire window, so it never changes
         * what's sent. (parity with Swift `maxStoredMessages`)
         */
        private const val MAX_STORED_MESSAGES = 40

        /**
         * True when a transcript last written on [lastEpochDay] should be retired before a question
         * asked on [todayEpochDay] — i.e. the conversation crossed into a new local day.
         *
         * STRICTLY forward (`>`), never `!=`: a clock that moves BACKWARDS — the user flying west, a
         * timezone change, an NTP correction — must not wipe a conversation the user is in the middle
         * of. Only real elapsed days retire a transcript; going back in time leaves it alone.
         *
         * Null [lastEpochDay] (nothing sent yet this session) is never stale. Pure companion so the
         * rule is pinned by [com.noop.ui.CoachConversationDayTest] without a ViewModel or a framework.
         */
        internal fun isStaleConversation(lastEpochDay: Long?, todayEpochDay: Long): Boolean =
            lastEpochDay != null && todayEpochDay > lastEpochDay

        /**
         * Initial model list for [provider]: its curated ids, plus [selected] appended if it's a
         * custom id not already in that list (so a previously-saved custom model still shows).
         */
        private fun seedModels(provider: AiProvider, selected: String): List<String> = when {
            selected.isBlank() -> provider.models          // Custom has no default, start empty
            provider.models.contains(selected) -> provider.models
            else -> provider.models + selected
        }
    }
}
