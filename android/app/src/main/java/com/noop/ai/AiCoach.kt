package com.noop.ai

import android.content.Context
import com.noop.analytics.EffectRanker
import com.noop.analytics.LabMarkerCategory
import com.noop.analytics.MarkerCatalog
import com.noop.analytics.StressIndex
import com.noop.data.DailyMetric
import com.noop.data.JournalEntry
import com.noop.data.LabMarkerRow
import com.noop.data.WhoopRepository
import com.noop.ui.NoopPrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import kotlin.math.roundToInt

/**
 * The AI Coach.
 *
 * Privacy posture: this is the ONE networked feature in the app. Nothing leaves the device
 * until the user has saved their own API key (see [AiKeyStore]) and asked a question. Only a
 * compact plain-text summary of their metrics plus their question is sent to the provider the
 * user picked. No raw samples, no identifiers.
 *
 * Anonymous: the only branding is the provider name the user selected. The system prompt does
 * not name any app author or model vendor.
 */
class AiCoach(private val repo: WhoopRepository) {

    /** The device key the rest of the app reads/writes daily metrics under. Coach reads go
     *  through the MERGED raw+computed view ([WhoopRepository.daysMerged]), the same per-field
     *  coalesce every screen uses, so on-device "-noop" scores are visible too (#124). */
    private val deviceId = "my-whoop"

    /** The source id native (in-app) journal answers are stored under (matches the UI's
     *  JOURNAL_DEVICE_ID); used for the opt-in on-device-signals context only. */
    private val journalDeviceId = "noop-journal"

    private val http: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    /**
     * Send the conversation to [provider] using [model] and return the assistant reply text.
     *
     * Builds the data context from the user's cached daily metrics and prepends it to the
     * FIRST user turn so the model is grounded in real numbers. The system prompt is passed
     * out-of-band (top-level field for Anthropic, a system message for OpenAI).
     *
     * Runs on [Dispatchers.IO]. Throws a clear [Exception] on any failure (missing key, bad
     * key, network, rate limit, malformed response); the ViewModel maps that to a visible
     * error message and the app never crashes.
     */
    suspend fun chat(
        ctx: Context,
        history: List<ChatMsg>,
        provider: AiProvider,
        model: String,
        consent: Boolean = false,
        customBaseUrl: String = "",
        customAuthHeader: CustomAiAuthHeader = CustomAiAuthHeader.BEARER,
        includeSignals: Boolean = false,
    ): String = withContext(Dispatchers.IO) {
        // Local (Custom) servers usually need no key; the cloud providers always do. The guarded read
        // returns the stored key ONLY if it belongs to THIS provider (or is a legacy cloud key), so a
        // key saved for one provider is never Bearer-sent to another provider's (or a Custom) endpoint.
        val key = AiKeyStore.read(ctx, provider)
        if (key == null && provider != AiProvider.CUSTOM) {
            throw Exception("No API key set. Add your ${provider.displayName} key to use the coach.")
        }
        if (provider == AiProvider.CUSTOM) {
            require(customBaseUrl.isNotBlank()) { "Set your server URL first." }
            require(model.isNotBlank()) { "Pick a model your server serves." }
        }

        require(history.isNotEmpty()) { "Ask a question first." }
        require(history.last().role == "user") { "The last message must be your question." }

        // Include the user's data ONLY with explicit consent; otherwise a note, never their numbers.
        val groundedFull = if (consent) {
            // Merged read, NOT raw days(): a live-strap user's scores live under "my-whoop-noop"
            // and a raw read misses them, the coach then claimed it had no data. (#124)
            val days = runCatching { repo.daysMerged(deviceId) }.getOrDefault(emptyList())
            // Derived stress: a single Baevsky Stress Index summary line over TODAY's R-R, read the
            // same way StressScreen does (repo.rrIntervals over the local day) and gated UNDER this same
            // `consent` block as the HRV/RHR summary, a derived number, never raw R-R egress. Absent
            // when there aren't enough clean beats yet. Best-effort; never blocks the send.
            val stress = runCatching { stressLineToday() }.getOrNull()
            // v5: a SECOND opt-in (on top of `consent`) may append a SUMMARY-ONLY line of the user's
            // strongest on-device patterns + Lab Book markers. Summary text only, no raw rows, no
            // per-day series, so the anonymity / no-raw-egress posture holds. Best-effort; never blocks.
            val signals = if (includeSignals) runCatching { buildSignalsContext() }.getOrNull() else null
            val full = buildString {
                append(buildContext(days))
                if (!stress.isNullOrBlank()) append("\n\n").append(stress)
                if (!signals.isNullOrBlank()) append("\n\n").append(signals)
            }
            injectContext(history, full)
        } else {
            injectContext(history, NO_CONSENT_NOTE)
        }

        // Resolve the system prompt fresh (user override or the built-in default) so an edit in the
        // Coach settings takes effect on this very send.
        val systemPrompt = resolveSystemPrompt(ctx)

        // Slide a window over a long conversation so the history can't crowd out the reply on a
        // small local context window (e.g. Ollama's 2048-token default). The first user turn carries
        // the data context, so it is always kept; the middle is dropped, the recent tail retained.
        val grounded = trimmedHistory(groundedFull, MAX_HISTORY_TURNS)

        when (provider) {
            AiProvider.OPENAI ->
                callOpenAiCompatible(provider, provider.endpoint, model, key, grounded, systemPrompt)
            AiProvider.ANTHROPIC ->
                callAnthropic(provider, model, key!!, grounded, systemPrompt)
            AiProvider.GEMINI ->
                callGemini(provider, model, key!!, grounded, systemPrompt)
            AiProvider.CUSTOM ->
                callOpenAiCompatible(
                    provider,
                    customChatUrl(customBaseUrl),
                    model,
                    key,
                    grounded,
                    systemPrompt,
                    customAuthHeader,
                )
        }
    }

    /**
     * Today's derived stress line for the consent-gated coach context. Reads R-R for the local day
     * via [WhoopRepository.rrIntervals] (the SAME path StressScreen uses) and summarises it with the
     * pure [stressIndexLine]. Returns null when there aren't enough clean beats. Summary number only,      * the raw R-R never leaves the device.
     */
    private suspend fun stressLineToday(): String? {
        val nowSeconds = System.currentTimeMillis() / 1000L
        val tzOffset = java.util.TimeZone.getDefault().getOffset(nowSeconds * 1_000L) / 1_000L
        val localNow = nowSeconds + tzOffset
        val from = (localNow - Math.floorMod(localNow, 86_400L)) - tzOffset
        val rr = repo.rrIntervals(deviceId, from, nowSeconds, limit = 200_000)
        return stressIndexLine(rr)
    }

    /**
     * Fetch the provider's live list of model ids, using the saved API key.
     *
     * Best-effort: GETs the provider's models endpoint and returns the ids it advertises.
     * On any failure (no key, network, bad key, malformed body) this returns an EMPTY list
     * rather than throwing, the caller simply keeps its curated/static list. The result is
     * filtered to the ids that make sense for chat (OpenAI: ids starting with "gpt" or "o";
     * Anthropic: all returned ids) and de-duplicated.
     *
     * Runs on [Dispatchers.IO].
     */
    suspend fun fetchModels(
        ctx: Context,
        provider: AiProvider,
        customBaseUrl: String = "",
        customAuthHeader: CustomAiAuthHeader = CustomAiAuthHeader.BEARER,
    ): List<String> = withContext(Dispatchers.IO) {
        // Guarded read: only a key saved for THIS provider (or a legacy cloud key) is used, never one
        // provider's key against another's models endpoint.
        val key = AiKeyStore.read(ctx, provider)
        // Cloud providers need a key to list models; a local Custom server usually doesn't.
        if (key == null && provider != AiProvider.CUSTOM) return@withContext emptyList()

        val url = when (provider) {
            AiProvider.CUSTOM -> {
                if (customBaseUrl.isBlank()) return@withContext emptyList()
                // Best-effort: a bad/public-cleartext URL just yields no model list here (the chat
                // path surfaces the precise guard error). Never throw out of fetchModels.
                runCatching { customModelsUrl(customBaseUrl) }.getOrNull() ?: return@withContext emptyList()
            }
            else -> provider.modelsEndpoint
        }

        val builder = Request.Builder().url(url).get()
        when (provider) {
            // key is non-null here: the early return above only spares the Custom provider.
            AiProvider.OPENAI -> builder.addHeader("Authorization", "Bearer ${key!!}")
            AiProvider.ANTHROPIC -> {
                builder.addHeader("x-api-key", key!!)
                builder.addHeader("anthropic-version", "2023-06-01")
            }
            AiProvider.GEMINI -> builder.addHeader("x-goog-api-key", key!!)
            AiProvider.CUSTOM -> applyCustomAuthHeader(builder, key, customAuthHeader)
        }

        runCatching {
            val (code, text) = execute(builder.build())
            if (code !in 200..299) return@runCatching emptyList<String>()

            // Gemini is shaped differently ({"models":[{"name":"models/…"}]}), so it has its own pure
            // parse; every other provider is OpenAI-shaped ({"data":[{"id":"…"}]}).
            if (provider == AiProvider.GEMINI) return@runCatching parseGeminiModels(text)

            parseOpenAiCompatibleModels(provider, text)
        }.getOrDefault(emptyList())
    }

    // ---------------------------------------------------------------------------------------
    // Context builder
    // ---------------------------------------------------------------------------------------

    /**
     * Compact plain-text summary of the user's recent data: the last ~14 days of
     * charge / effort / rest-hours / HRV / resting-HR (where present), 30-day averages,
     * and a recent-workouts line derived from logged exercise counts and effort.
     *
     * Kept well under ~1500 tokens. If there is no data at all, says so explicitly so the
     * model doesn't invent numbers.
     */
    fun buildContext(days: List<DailyMetric>): String {
        if (days.isEmpty()) {
            return "USER DATA: No wearable data is available yet (no synced days). " +
                "Do not invent specific numbers; give general guidance and encourage the user " +
                "to sync their strap so future advice can reference their real metrics."
        }

        // daysMerged() returns oldest-first; take the most recent up to 30 for averages, 14 for the table.
        val last30 = days.takeLast(30)
        val last14 = days.takeLast(14)

        val sb = StringBuilder()
        sb.append("USER DATA (most recent first; figures rounded; a dash means not recorded that day).\n\n")

        // --- Recent daily table (newest first for readability) ---
        sb.append("Last ${last14.size} days:\n")
        for (d in last14.reversed()) {
            val recovery = d.recovery?.let { "${it.roundToInt()}%" } ?: "-"
            val strain = d.strain?.let { fmt1(it) } ?: "-"
            val sleepH = d.totalSleepMin?.let { fmt1(it / 60.0) + "h" } ?: "-"
            val hrv = d.avgHrv?.let { "${it.roundToInt()}ms" } ?: "-"
            val rhr = d.restingHr?.let { "${it}bpm" } ?: "-"
            sb.append(
                "  ${d.day}: charge $recovery, effort $strain, rest $sleepH, HRV $hrv, RHR $rhr\n"
            )
        }

        // --- 30-day averages ---
        sb.append("\n30-day averages (over ${last30.size} days):\n")
        sb.append("  charge ${avgInt(last30) { it.recovery }}%, ")
        sb.append("effort ${avg1(last30) { it.strain }}, ")
        sb.append("rest ${avg1(last30) { d -> d.totalSleepMin?.div(60.0) }}h, ")
        sb.append("HRV ${avgInt(last30) { it.avgHrv }}ms, ")
        sb.append("RHR ${avgInt(last30) { d -> d.restingHr?.toDouble() }}bpm\n")
        // Additional vitals when present (#124, the coach used to see only recovery/strain/sleep/HRV/RHR).
        sb.append("  SpO₂ ${avgInt(last30) { it.spo2Pct }}%, ")
        sb.append("respiration ${avg1(last30) { it.respRateBpm }}/min, ")
        sb.append("skin-temp deviation ${avg1(last30) { it.skinTempDevC }}°C, ")
        sb.append("steps ${avgInt(last30) { d -> d.steps?.toDouble() }}/day, ")
        sb.append("active energy ${avgInt(last30) { it.activeKcalEst }}kcal/day\n")

        // --- Recent workouts (derived from logged exercise counts + day strain) ---
        val workoutDays = last14.filter { (it.exerciseCount ?: 0) > 0 }
        sb.append("\nRecent workouts (last ${last14.size} days):\n")
        if (workoutDays.isEmpty()) {
            sb.append("  None logged.\n")
        } else {
            for (d in workoutDays.reversed()) {
                val n = d.exerciseCount ?: 0
                val label = if (n == 1) "1 workout" else "$n workouts"
                val strain = d.strain?.let { ", effort ${fmt1(it)}" } ?: ""
                sb.append("  ${d.day}: $label$strain\n")
            }
        }

        // Latest snapshot line, handy single reference for the model.
        days.lastOrNull()?.let { latest ->
            val r = latest.recovery?.let { "${it.roundToInt()}%" } ?: "n/a"
            val s = latest.strain?.let { fmt1(it) } ?: "n/a"
            sb.append("\nMost recent day (${latest.day}): charge $r, effort $s.\n")
        }

        return sb.toString().trim()
    }

    /**
     * SUMMARY-ONLY on-device signals context (v5): the user's strongest associations (from the same
     * [EffectRanker] the Insights hub surfaces) and a one-line-per-marker Lab Book snapshot. Sent only
     * behind the second opt-in. Deliberately compact + textual, no raw per-day series, no identifiers,      * so nothing beyond a plain English summary leaves the device. Returns null/blank when there's
     * nothing to say (the coach then just uses the standard metrics context).
     */
    private suspend fun buildSignalsContext(): String? {
        val sb = StringBuilder()

        // --- Strongest associations on the user's own logged days (recovery as the outcome) ---
        val behaviours = runCatching { journalBehaviours() }.getOrDefault(emptyMap())
        val days = runCatching { repo.daysMerged(deviceId) }.getOrDefault(emptyList())
        if (behaviours.isNotEmpty() && days.isNotEmpty()) {
            val recoveryByDay = days.mapNotNull { d -> d.recovery?.let { d.day to it } }.toMap()
            val ranked = runCatching { EffectRanker.rank(behaviours, recoveryByDay, "Charge") }
                .getOrDefault(emptyList())
                .take(3)
            if (ranked.isNotEmpty()) {
                sb.append("ON-DEVICE PATTERNS (associations in the user's own logged days — not causes, ")
                sb.append("not diagnoses; weaker confidence means fewer days so far):\n")
                for (r in ranked) {
                    sb.append("  • ${r.behavior}: ${r.sentence()} [${r.confidence.name.lowercase()}]\n")
                }
            }
        }

        // --- Lab Book snapshot: the latest reading per marker the user has entered ---
        val latestByMarker = runCatching { latestLabMarkers() }.getOrDefault(emptyList())
        if (latestByMarker.isNotEmpty()) {
            if (sb.isNotEmpty()) sb.append("\n")
            sb.append("LAB BOOK (numbers the user entered themselves from their own reports; NOOP does not ")
            sb.append("test or interpret them — never assert whether a value is normal/high/low):\n")
            for (row in latestByMarker) {
                val name = MarkerCatalog.definition(row.markerKey)?.displayName
                    ?: row.markerKey.replace("_", " ").replaceFirstChar { it.uppercase() }
                val value = row.value?.let { fmt1(it) + " " + row.unit } ?: (row.valueText ?: "—")
                sb.append("  • $name: $value\n")
            }
        }

        return sb.toString().trim().takeIf { it.isNotEmpty() }
    }

    /** Behaviour → set of "yyyy-MM-dd" days it was logged "yes" (imported ∪ native), for EffectRanker. */
    private suspend fun journalBehaviours(): Map<String, Set<String>> {
        val imported = repo.journal(deviceId, "0000-01-01", "9999-12-31")
        val native = repo.journal(journalDeviceId, "0000-01-01", "9999-12-31")
        val byKey = LinkedHashMap<Pair<String, String>, JournalEntry>()
        for (e in imported) byKey[e.day to e.question] = e
        for (e in native) byKey[e.day to e.question] = e   // native wins on a collision
        val out = HashMap<String, MutableSet<String>>()
        for (e in byKey.values) if (e.answeredYes) out.getOrPut(e.question) { mutableSetOf() }.add(e.day)
        return out.mapValues { it.value.toSet() }
    }

    /** The latest reading per Lab Book marker key (stored under the strap deviceId). */
    private suspend fun latestLabMarkers(): List<LabMarkerRow> {
        val all = ArrayList<LabMarkerRow>()
        for (category in LabMarkerCategory.entries) {
            all += runCatching { repo.labMarkersByCategory(deviceId, category.raw) }.getOrDefault(emptyList())
        }
        return all.groupBy { it.markerKey }.values.map { rows -> rows.maxByOrNull { it.takenAt }!! }
            .sortedBy { it.markerKey }
    }

    /**
     * Prepend [context] to the first user message so the model is grounded in real numbers.
     * Returns a copy of [history]; the original list is not mutated.
     */
    private fun injectContext(history: List<ChatMsg>, context: String): List<ChatMsg> {
        val firstUserIdx = history.indexOfFirst { it.role == "user" }
        if (firstUserIdx < 0) return history
        return history.mapIndexed { i, m ->
            if (i == firstUserIdx) {
                m.copy(text = "$context\n\n---\n\nMy question: ${m.text}")
            } else m
        }
    }

    // ---------------------------------------------------------------------------------------
    // OpenAI-compatible, POST {base}/chat/completions
    //   Used for OpenAI itself and the Custom (local LLM) provider. [key] may be null/blank for a
    //   local server that needs no auth, the Authorization header is then omitted.
    // ---------------------------------------------------------------------------------------

    private fun callOpenAiCompatible(
        provider: AiProvider,
        url: String,
        model: String,
        key: String?,
        history: List<ChatMsg>,
        systemPrompt: String,
        customAuthHeader: CustomAiAuthHeader = CustomAiAuthHeader.BEARER,
    ): String {
        val messages = JSONArray()
        messages.put(JSONObject().put("role", "system").put("content", systemPrompt))
        for (m in history) {
            // OpenAI roles map 1:1 to "user"/"assistant".
            messages.put(JSONObject().put("role", m.role).put("content", m.text))
        }

        val (code, text) = executeOpenAiCompatible(
            provider = provider,
            url = url,
            model = model,
            messages = messages,
            key = key,
            customAuthHeader = customAuthHeader,
            modernParams = false,
        )
        val responseText = if (code in 200..299) {
            text
        } else if (code == 400 && shouldRetryOpenAiModernParams(text)) {
            val (retryCode, retryText) = executeOpenAiCompatible(
                provider = provider,
                url = url,
                model = model,
                messages = messages,
                key = key,
                customAuthHeader = customAuthHeader,
                modernParams = true,
            )
            if (retryCode !in 200..299) throw httpError(provider, retryCode, retryText)
            retryText
        } else {
            throw httpError(provider, code, text)
        }

        val json = parse(responseText)
        val firstChoice = json.optJSONArray("choices")?.optJSONObject(0)
        val content = firstChoice
            ?.optJSONObject("message")
            ?.optString("content")
            ?.trim()

        if (content.isNullOrEmpty()) throw Exception("The provider returned an empty reply. Please try again.")

        // Local servers (notably Ollama) stop with finish_reason "length" at the context-window edge
        // and give NO error, keep the partial text and append the actionable notice so it isn't silent.
        val truncated = firstChoice.optString("finish_reason").lowercase() == "length"
        return if (truncated) content + TRUNCATION_NOTE else content
    }

    private fun executeOpenAiCompatible(
        provider: AiProvider,
        url: String,
        model: String,
        messages: JSONArray,
        key: String?,
        customAuthHeader: CustomAiAuthHeader,
        modernParams: Boolean,
    ): Pair<Int, String> {
        val body = JSONObject()
            .put("model", model)
            .put("messages", messages)
        if (modernParams) {
            body.put("max_completion_tokens", 900)
        } else {
            body.put("temperature", 0.6)
            body.put("max_tokens", 900)
        }

        val builder = Request.Builder()
            .url(url)
            .addHeader("Content-Type", "application/json")
            .post(body.toString().toRequestBody(JSON))
        when (provider) {
            AiProvider.CUSTOM -> applyCustomAuthHeader(builder, key, customAuthHeader)
            else -> if (!key.isNullOrBlank()) builder.addHeader("Authorization", "Bearer $key")
        }
        return execute(builder.build())
    }

    private fun applyCustomAuthHeader(
        builder: Request.Builder,
        key: String?,
        customAuthHeader: CustomAiAuthHeader,
    ) {
        if (key.isNullOrBlank()) return
        when (customAuthHeader) {
            CustomAiAuthHeader.BEARER -> builder.addHeader("Authorization", "Bearer $key")
            CustomAiAuthHeader.X_API_KEY -> builder.addHeader("x-api-key", key)
        }
    }

    private fun shouldRetryOpenAiModernParams(text: String): Boolean {
        val detail = runCatching { parse(text).toString() }.getOrDefault(text).lowercase()
        return detail.contains("max_completion_tokens") ||
            detail.contains("max_tokens") ||
            detail.contains("temperature") ||
            detail.contains("unsupported")
    }

    /** Base for the Custom provider, the user's URL with any trailing slashes trimmed. */
    private fun customBase(url: String): String = url.trim().trimEnd('/')

    private fun customChatUrl(url: String): String {
        val base = customBase(url)
        guardCustomUrl(base)
        return base + "/chat/completions"
    }

    private fun customModelsUrl(url: String): String {
        val base = customBase(url)
        guardCustomUrl(base)
        return base + "/models"
    }

    /**
     * Gatekeeper for the Custom (local LLM) provider. https:// is always fine. Plain http:// is
     * allowed only for local user-owned endpoints: loopback, RFC1918 private LAN addresses,
     * IPv4 link-local addresses, and *.local mDNS names. Android XML cannot express those CIDR
     * ranges, so network-security-config permits platform cleartext and this guard is the public
     * HTTP boundary.
     */
    private fun guardCustomUrl(base: String) {
        val uri = runCatching { java.net.URI(base) }.getOrNull()
        val host = uri?.host
        val scheme = uri?.scheme?.lowercase()
        require(host != null && !scheme.isNullOrBlank()) {
            "That server URL isn't valid. Use http://<host>:<port> for a local server, or https://… for a remote one."
        }
        if (scheme == "https") return
        require(scheme == "http") {
            "Unsupported URL scheme \"$scheme\". Use http:// for a local server or https:// for a remote one."
        }
        require(isPrivateLanOrLoopback(host)) {
            "Plain http:// is only allowed for localhost, private LAN IPs, link-local IPs, or " +
                ".local hostnames. Use https:// to reach \"$host\"."
        }
    }


    // ---------------------------------------------------------------------------------------
    // Anthropic, POST /v1/messages
    // ---------------------------------------------------------------------------------------

    private fun callAnthropic(
        provider: AiProvider,
        model: String,
        key: String,
        history: List<ChatMsg>,
        systemPrompt: String,
    ): String {
        // Anthropic has no system role inside messages: the system prompt is a top-level field
        // and messages alternate user/assistant.
        val messages = JSONArray()
        for (m in history) {
            messages.put(JSONObject().put("role", m.role).put("content", m.text))
        }

        val body = JSONObject()
            .put("model", model)
            .put("max_tokens", 900)
            .put("system", systemPrompt)
            .put("messages", messages)
            .toString()

        val request = Request.Builder()
            .url(provider.endpoint)
            .addHeader("x-api-key", key)
            .addHeader("anthropic-version", "2023-06-01")
            .addHeader("content-type", "application/json")
            .post(body.toRequestBody(JSON))
            .build()

        val (code, text) = execute(request)
        if (code !in 200..299) throw httpError(provider, code, text)

        val json = parse(text)
        val content = json.optJSONArray("content")
            ?.optJSONObject(0)
            ?.optString("text")
            ?.trim()

        if (content.isNullOrEmpty()) throw Exception("The provider returned an empty reply. Please try again.")
        return content
    }

    // ---------------------------------------------------------------------------------------
    // Google Gemini, POST /v1beta/models/<model>:generateContent
    // ---------------------------------------------------------------------------------------

    /**
     * Native Google Gemini call — byte-for-byte twin of Swift `GeminiClient.send`. Gemini has no
     * "system" role inside the turn list: the system prompt is a top-level `system_instruction`, and
     * each turn carries `role` ("user"/"model") + one text `part`. Auth is the `x-goog-api-key` header.
     */
    private fun callGemini(
        provider: AiProvider,
        model: String,
        key: String,
        history: List<ChatMsg>,
        systemPrompt: String,
    ): String {
        val contents = JSONArray()
        for (m in history) {
            contents.put(
                JSONObject()
                    // Gemini names the assistant turn "model"; everything else is "user".
                    .put("role", if (m.role == "assistant") "model" else "user")
                    .put("parts", JSONArray().put(JSONObject().put("text", m.text))),
            )
        }

        val body = JSONObject()
            .put("system_instruction", JSONObject().put("parts", JSONArray().put(JSONObject().put("text", systemPrompt))))
            .put("contents", contents)
            // Gemini 2.5 counts THINKING tokens against maxOutputTokens; the 900 cap the other providers
            // use starves a thinking model into an empty reply (finishReason MAX_TOKENS, no text parts).
            // 4096 leaves room for both — the system prompt keeps the visible reply short. (Same as Swift.)
            .put("generationConfig", JSONObject().put("temperature", 0.6).put("maxOutputTokens", 4096))
            .toString()

        // Built from a literal string (NOT a path-appending API) so the ":" in ":generateContent" stays
        // literal — a percent-encoded %3A is rejected by the API. Mirrors the Swift URL(string:) note.
        val request = Request.Builder()
            .url("${provider.endpoint}/$model:generateContent")
            .addHeader("x-goog-api-key", key)
            .addHeader("content-type", "application/json")
            .post(body.toRequestBody(JSON))
            .build()

        val (code, text) = execute(request)
        if (code !in 200..299) throw httpError(provider, code, text)

        // A reply can span several parts (thinking models emit more than one); join them.
        val parts = parse(text)
            .optJSONArray("candidates")?.optJSONObject(0)
            ?.optJSONObject("content")?.optJSONArray("parts")
        val reply = buildString {
            if (parts != null) for (i in 0 until parts.length()) append(parts.optJSONObject(i)?.optString("text").orEmpty())
        }.trim()

        if (reply.isEmpty()) throw Exception("The provider returned an empty reply. Please try again.")
        return reply
    }

    // ---------------------------------------------------------------------------------------
    // HTTP / error plumbing
    // ---------------------------------------------------------------------------------------

    /** Execute a request, mapping low-level network failures to a friendly [Exception]. */
    private fun execute(request: Request): Pair<Int, String> {
        try {
            http.newCall(request).execute().use { resp ->
                val text = resp.body?.string().orEmpty()
                return resp.code to text
            }
        } catch (e: java.net.UnknownHostException) {
            throw Exception("No internet connection. The coach needs a connection to reach the provider.")
        } catch (e: java.net.SocketTimeoutException) {
            throw Exception("The request timed out. Please check your connection and try again.")
        } catch (e: javax.net.ssl.SSLException) {
            throw Exception("A secure connection to the provider could not be established.")
        } catch (e: java.io.IOException) {
            // The platform reports a blocked plain-HTTP request as a generic IOException whose
            // message is "Cleartext HTTP traffic to <host> not permitted" (no dedicated exception
            // class exists). Detect it and explain, instead of the opaque generic line.
            val msg = e.message.orEmpty()
            if (msg.contains("Cleartext", ignoreCase = true) && msg.contains("not permitted", ignoreCase = true)) {
                throw Exception(
                    "Plain http:// is blocked for that host. Use localhost, 127.0.0.1, 10.0.2.2, " +
                        "a .local hostname, or switch the server to https://."
                )
            }
            throw Exception("Network error reaching the provider: ${e.message ?: "unknown"}.")
        }
    }

    /** Map a non-2xx response to a clear, user-facing message (key, rate-limit, server). */
    private fun httpError(provider: AiProvider, code: Int, body: String): Exception {
        val detail = extractApiErrorMessage(body)
        val base = when (code) {
            401, 403 -> "Your ${provider.displayName} API key was rejected. Check the key and try again."
            429 -> "${provider.displayName} rate limit reached (or quota exhausted). Wait a moment and retry."
            in 500..599 -> "${provider.displayName} had a server error (HTTP $code). Please try again shortly."
            400 -> "The request was rejected by ${provider.displayName} (HTTP 400)."
            else -> "${provider.displayName} returned an error (HTTP $code)."
        }
        return Exception(if (detail != null) "$base ($detail)" else base)
    }

    /** Pull the provider's error message out of an error JSON body, if present. */
    private fun extractApiErrorMessage(body: String): String? {
        if (body.isBlank()) return null
        return runCatching {
            val obj = JSONObject(body)
            // Both providers wrap errors as {"error": {"message": "..."}} (OpenAI) or
            // {"type":"error","error":{"message":"..."}} (Anthropic).
            obj.optJSONObject("error")?.optString("message")?.takeIf { it.isNotBlank() }
        }.getOrNull()
    }

    /** Parse a successful response body, turning malformed JSON into a clear error. */
    private fun parse(text: String): JSONObject =
        runCatching { JSONObject(text) }.getOrElse {
            throw Exception("Could not understand the provider's response.")
        }

    // ---------------------------------------------------------------------------------------
    // Small numeric formatting helpers
    // ---------------------------------------------------------------------------------------

    private fun fmt1(v: Double): String =
        if (v == v.roundToInt().toDouble()) v.roundToInt().toString()
        else String.format("%.1f", v)

    private inline fun avgInt(days: List<DailyMetric>, sel: (DailyMetric) -> Double?): String {
        val vals = days.mapNotNull(sel)
        return if (vals.isEmpty()) "-" else vals.average().roundToInt().toString()
    }

    private inline fun avg1(days: List<DailyMetric>, sel: (DailyMetric) -> Double?): String {
        val vals = days.mapNotNull(sel)
        return if (vals.isEmpty()) "-" else fmt1(vals.average())
    }

    companion object {
        private val JSON = "application/json; charset=utf-8".toMediaType()

        /**
         * Pure: unwrap Gemini's `{"models":[{"name":"models/…"}]}` into chat-capable ids. Strips the
         * `models/` prefix, keeps `gemini*` only (drops embedding / AQA models). Byte-for-byte twin of
         * the Swift `GeminiClient.parseModels`, so both platforms surface the same fetched catalogue.
         * Pure + `internal` so it is unit-testable without a network or a Context. No network.
         */
        internal fun parseGeminiModels(text: String): List<String> {
            val list = runCatching { JSONObject(text).optJSONArray("models") }.getOrNull() ?: return emptyList()
            val ids = ArrayList<String>(list.length())
            for (i in 0 until list.length()) {
                val name = list.optJSONObject(i)?.optString("name")?.trim().orEmpty()
                if (name.isEmpty()) continue
                val id = if (name.startsWith("models/")) name.removePrefix("models/") else name
                if (id.startsWith("gemini") && !id.contains("embedding") && !id.contains("aqa")) ids.add(id)
            }
            return ids.distinct()
        }

        /**
         * Pure: unwrap OpenAI-compatible `/models` ids. Custom gateways may return either the normal
         * `data[].id` envelope or a gateway catalog with `catalog[].models`; keep all Custom ids.
         */
        internal fun parseOpenAiCompatibleModels(provider: AiProvider, text: String): List<String> {
            val json = runCatching { JSONObject(text) }.getOrNull() ?: return emptyList()
            val data = json.optJSONArray("data")
            if (data != null) {
                val ids = ArrayList<String>(data.length())
                for (i in 0 until data.length()) {
                    val id = data.optJSONObject(i)?.optString("id")?.trim().orEmpty()
                    if (id.isEmpty()) continue
                    val keep = when (provider) {
                        AiProvider.OPENAI -> id.startsWith("gpt") || id.startsWith("o")
                        AiProvider.ANTHROPIC, AiProvider.CUSTOM -> true
                        AiProvider.GEMINI -> true
                    }
                    if (keep) ids.add(id)
                }
                return ids.distinct()
            }

            val catalog = json.optJSONArray("catalog") ?: return emptyList()
            val ids = ArrayList<String>()
            for (i in 0 until catalog.length()) {
                val models = catalog.optJSONObject(i)?.optJSONArray("models") ?: continue
                for (j in 0 until models.length()) {
                    val id = models.optString(j).trim()
                    if (id.isNotEmpty()) ids.add(id)
                }
            }
            return ids.distinct()
        }

        /**
         * True when [host] is local/private enough for Custom-provider plain HTTP: localhost,
         * loopback, RFC1918 private LAN, IPv4 link-local, or any *.local mDNS name. Anything else
         * is treated as requiring HTTPS. Pure; `internal` so it's unit-testable (#321/#187).
         * Called unqualified by `guardCustomUrl`.
         */
        internal fun isPrivateLanOrLoopback(host: String): Boolean {
            val raw = host.trim()
            val h = raw.trim('[', ']').lowercase()  // strip IPv6 brackets if present
            if (h.isEmpty()) return false

            val isIpv6Literal = raw.startsWith("[") || h.contains(':')
            if (isIpv6Literal) {
                return h == "::1" ||
                    h.startsWith("fe80:") || h.startsWith("fe80::") ||
                    h.startsWith("fc") || h.startsWith("fd")
            }

            if (h == "localhost" || h.endsWith(".localhost")) return true
            // mDNS / Bonjour LAN names: require a real label before ".local" (so the bare ".local" /
            // "local" can't slip through), and only for an actual hostname (handled above for literals).
            if (h.endsWith(".local") && h.length > ".local".length) return true

            val parts = h.split(".")
            if (parts.size != 4) return false
            val octets = parts.map { it.toIntOrNull() ?: -1 }
            if (octets.any { it < 0 || it > 255 }) return false
            val a = octets[0]
            val b = octets[1]
            return a == 127 ||                  // loopback
                a == 10 ||                      // RFC1918 10/8
                (a == 172 && b in 16..31) ||    // RFC1918 172.16/12
                (a == 192 && b == 168) ||       // RFC1918 192.168/16
                (a == 169 && b == 254)          // IPv4 link-local
        }

        /**
         * Max chat turns sent on a single request, beyond the context-bearing first user turn. Caps
         * how much history we ship so a long conversation can't crowd out the reply on a small local
         * context window (e.g. Ollama's 2048-token default). High enough that normal chats go in full.
         */
        const val MAX_HISTORY_TURNS = 10

        /**
         * Appended to a reply when the server stopped early because it ran out of context window.
         * Local OpenAI-compatible servers (notably Ollama, which defaults to a 2048-token window and
         * IGNORES `num_ctx` on the `/v1` endpoint) truncate silently, no error, the text just stops
         * mid-sentence. We can't raise the window over the OpenAI wire format, so we make the cutoff
         * visible and tell the user exactly how to fix it.
         */
        const val TRUNCATION_NOTE =
            "\n\n---\n*Reply cut off: the model hit its context-window limit. " +
                "On a local server like Ollama (default 2048 tokens), raise it - create a Modelfile " +
                "with `PARAMETER num_ctx 8192` and select that model, or set " +
                "`OLLAMA_CONTEXT_LENGTH=8192` and relaunch Ollama - then ask again.*"

        /**
         * Pure: sliding-window the chat. Returns everything when short; otherwise the first user turn
         * (so the data context still has a turn to ride) followed by the last [maxRecent] messages,
         * with no duplication. No state, unit-tested.
         */
        fun trimmedHistory(msgs: List<ChatMsg>, maxRecent: Int): List<ChatMsg> {
            if (msgs.size <= maxRecent + 1) return msgs
            val tailStart = msgs.size - maxRecent
            val tail = msgs.subList(tailStart, msgs.size)
            val firstUserIdx = msgs.indexOfFirst { it.role == "user" }
            // No user turn (shouldn't happen for a real chat), or the first user turn is already
            // inside the retained tail → just return the tail, no duplication.
            if (firstUserIdx < 0 || firstUserIdx >= tailStart) return tail.toList()
            return listOf(msgs[firstUserIdx]) + tail
        }

        /**
         * The built-in coach persona. Anonymous (names no app author or model vendor) and includes the
         * not-a-doctor guardrail. The user can OVERRIDE this from the Coach settings; the override is
         * stored in NoopPrefs and read fresh per request via [resolveSystemPrompt].
         */
        const val DEFAULT_SYSTEM_PROMPT =
            "You are an elite, supportive recovery and performance coach with a real training " +
                "methodology. You may be given a summary of the user's own wearable data (charge " +
                "0-100, effort 0-100, rest/sleep, HRV, resting heart rate) and recent workouts. " +
                "Charge is the daily recovery/readiness score; effort is the day's cardiovascular " +
                "load. Coach using autoregulation: charge 67-100 = green light to build/push, " +
                "higher effort is fine; 34-66 = maintain, quality over volume, keep it controlled; " +
                "0-33 = active recovery only (Zone 2, mobility, extra sleep) and protect against " +
                "accumulating effort debt. Optimise workouts with progressive overload, polarised ~80/20 " +
                "intensity, spacing hard sessions, deloads/periodisation, and treat sleep as the " +
                "biggest recovery lever. Always cite the user's ACTUAL numbers, give a concrete plan " +
                "(today and the week), and be specific, punchy and motivating. If no data is " +
                "provided, coach generally and invite them to enable data access. You are NOT a " +
                "doctor - never diagnose; suggest a professional for genuine health concerns. " +
                "Format replies in simple Markdown, chat-sized: short paragraphs, **bold** for key " +
                "numbers, bullet or numbered lists for plans, and ### headings only when structure " +
                "genuinely helps. No tables or code blocks."

        /** Used in place of the metrics context when the user has not granted data access. */
        const val NO_CONSENT_NOTE =
            "NOTE: The user has not granted access to their biometric data. Coach generally and " +
                "encourage them to enable \"Let the coach use my data\" for tailored guidance."

        /**
         * The system prompt actually sent: the user's edited override from [NoopPrefs] when it is
         * non-blank, otherwise [DEFAULT_SYSTEM_PROMPT]. Read fresh per request so an edit in the Coach
         * settings takes effect on the very next message, with no engine rebuild. Mirrors macOS/iOS
         * `AICoachEngine.systemPrompt`.
         */
        fun resolveSystemPrompt(ctx: Context): String {
            val custom = NoopPrefs.coachSystemPrompt(ctx).trim()
            return if (custom.isNotEmpty()) custom else DEFAULT_SYSTEM_PROMPT
        }

        /**
         * One derived stress line for the coach context: the Baevsky Stress Index over a series of R-R
         * intervals, summarised to a single number. Pure (no IO) so it is unit-testable; returns null
         * when there are too few clean beats (the histogram needs >= [StressIndex.MIN_BEATS]), so the
         * line is simply absent, never a fabricated value. Summary-only: no raw R-R leaves the device.
         */
        fun stressIndexLine(rr: List<com.noop.data.RrInterval>): String? {
            val si = StressIndex.stressIndex(rr) ?: return null
            return stressIndexSummary(si)
        }

        /** Pure formatter for the derived stress line, one labelled summary number. */
        fun stressIndexSummary(si: Double): String =
            "Stress (SI): ${si.roundToInt()} (Baevsky Stress Index over today's R-R; higher means more " +
                "sympathetic / under load; an autonomic-balance proxy, not a clinical figure)."
    }
}
