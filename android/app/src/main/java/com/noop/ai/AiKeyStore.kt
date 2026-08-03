package com.noop.ai

import android.content.Context
import android.content.SharedPreferences
import com.noop.data.SecurePrefs

/**
 * Secure, at-rest-encrypted storage for the user's AI Coach API key.
 *
 * Backed by Jetpack Security `EncryptedSharedPreferences` — values are encrypted with a
 * key held in the Android Keystore (hardware-backed where available). The plaintext API
 * key is never written to disk in the clear. This is the Android counterpart to storing
 * the key in the macOS Keychain.
 *
 * The selected provider/model are NOT secret and are stored as plain preferences here too
 * for convenience, but the key itself is the only sensitive value.
 */
object AiKeyStore {

    private const val FILE_NAME = "noop_ai_secure_prefs"
    private const val KEY_API = "api_key"
    private const val KEY_PROVIDER = "provider"
    private const val KEY_KEY_OWNER = "key_provider"
    private const val KEY_CONSENT = "data_consent"
    private const val KEY_CUSTOM_URL = "custom_base_url"
    private const val KEY_CUSTOM_AUTH_HEADER = "custom_auth_header"
    private const val KEY_CUSTOM_CONNECTED = "custom_connected"

    /** Per-provider model preference key, so each provider remembers its own last model. */
    private fun modelKey(provider: AiProvider) = "model_${provider.name}"

    /**
     * The encrypted preferences file. The master key uses the AES256_GCM key scheme and lives in the
     * Android Keystore.
     *
     * Delegated to [SecurePrefs] so both credential stores open their file the same way — and so the
     * Keystore and Tink setup happens once per process rather than on every read and write, which is
     * what it used to do.
     */
    private fun prefs(ctx: Context): SharedPreferences = SecurePrefs.of(ctx, FILE_NAME)

    /**
     * Persist the API [key] (encrypted at rest). Blank keys are treated as a clear.
     *
     * Records [owner] (the provider the key belongs to) so a key saved for one provider is never
     * sent to another provider's endpoint — above all the arbitrary user-typed Custom server URL
     * (see the guarded [read] overload). [owner] defaults to the currently-persisted provider, which
     * the UI selects (and persists via [saveProvider]) before the user pastes a key for it.
     */
    fun save(ctx: Context, key: String, owner: AiProvider = readProvider(ctx)) {
        val trimmed = key.trim()
        if (trimmed.isEmpty()) {
            clear(ctx)
            return
        }
        prefs(ctx).edit()
            .putString(KEY_API, trimmed)
            .putString(KEY_KEY_OWNER, owner.name)
            .apply()
    }

    /** Read the stored API key, or null if none has been set. (Unguarded — used by [hasKey].) */
    fun read(ctx: Context): String? =
        prefs(ctx).getString(KEY_API, null)?.takeIf { it.isNotBlank() }

    /** The provider the stored key was saved for, or null for a legacy key saved before tracking. */
    fun keyOwner(ctx: Context): AiProvider? {
        val name = prefs(ctx).getString(KEY_KEY_OWNER, null) ?: return null
        return AiProvider.entries.firstOrNull { it.name == name }
    }

    /**
     * Read the stored key ONLY if it is safe to send to [provider]: it was saved for that exact
     * provider, OR it is a legacy key with no recorded owner AND [provider] is a cloud provider
     * (legacy keys keep working for the cloud providers but are never auto-sent to a Custom URL).
     * Otherwise returns null so the request fails safe — never Bearer one provider's secret to
     * another provider's (or an arbitrary Custom) endpoint.
     */
    fun read(ctx: Context, provider: AiProvider): String? {
        val key = read(ctx) ?: return null
        val owner = keyOwner(ctx)
        return when {
            owner == provider -> key
            owner == null && provider != AiProvider.CUSTOM -> key
            else -> null
        }
    }

    /** Remove the stored API key (and its owner). The provider/model preferences are left intact. */
    fun clear(ctx: Context) {
        prefs(ctx).edit()
            .remove(KEY_API)
            .remove(KEY_KEY_OWNER)
            .apply()
    }

    /** True when a non-blank key is stored — the gate the UI uses to enable sending. */
    fun hasKey(ctx: Context): Boolean = read(ctx) != null

    // --- Non-secret selection helpers (provider + model). Convenience only. ---

    /** Persist the chosen provider (by enum name). */
    fun saveProvider(ctx: Context, provider: AiProvider) {
        prefs(ctx).edit().putString(KEY_PROVIDER, provider.name).apply()
    }

    /** Read the chosen provider, defaulting to OpenAI. */
    fun readProvider(ctx: Context): AiProvider =
        AiProvider.fromName(prefs(ctx).getString(KEY_PROVIDER, null))

    /**
     * Persist the chosen model id for [provider]. Any non-blank id is accepted (curated,
     * live-fetched, or a custom id the user typed) — the model list is no longer a fixed,
     * shipped set. A blank id is ignored.
     */
    fun saveModel(ctx: Context, provider: AiProvider, model: String) {
        val trimmed = model.trim()
        if (trimmed.isEmpty()) return
        prefs(ctx).edit().putString(modelKey(provider), trimmed).apply()
    }

    /**
     * Read the chosen model id for [provider], defaulting to that provider's default model
     * when nothing valid is stored. A previously-saved custom or live model id is preserved
     * even if it isn't in the curated [AiProvider.models] list.
     */
    fun readModel(ctx: Context, provider: AiProvider): String =
        prefs(ctx).getString(modelKey(provider), null)?.takeIf { it.isNotBlank() }
            ?: provider.defaultModel

    /** Persist the data-access consent flag. */
    fun saveConsent(ctx: Context, consent: Boolean) {
        prefs(ctx).edit().putBoolean(KEY_CONSENT, consent).apply()
    }

    /** Read the data-access consent flag (default false — privacy-safe; no metrics sent until on). */
    fun readConsent(ctx: Context): Boolean = prefs(ctx).getBoolean(KEY_CONSENT, false)

    // --- Custom (OpenAI-compatible / local LLM) provider settings ---

    /** Persist the Custom provider's base URL (e.g. http://localhost:11434/v1). */
    fun saveCustomBaseUrl(ctx: Context, url: String) {
        prefs(ctx).edit().putString(KEY_CUSTOM_URL, url.trim()).apply()
    }

    /** Read the Custom provider's base URL, or empty string if unset. */
    fun readCustomBaseUrl(ctx: Context): String =
        prefs(ctx).getString(KEY_CUSTOM_URL, null)?.trim().orEmpty()

    /** Persist which header the Custom provider should use when an API key is present. */
    fun saveCustomAuthHeader(ctx: Context, header: CustomAiAuthHeader) {
        prefs(ctx).edit().putString(KEY_CUSTOM_AUTH_HEADER, header.name).apply()
    }

    /** Read the Custom provider auth header. Defaults to Bearer for existing local setups. */
    fun readCustomAuthHeader(ctx: Context): CustomAiAuthHeader =
        CustomAiAuthHeader.fromName(prefs(ctx).getString(KEY_CUSTOM_AUTH_HEADER, null))

    /**
     * Persist whether the user has committed the Custom provider (entered a URL and tapped
     * Connect). Lets the keyless local path reach the chat without a stored API key.
     */
    fun saveCustomConnected(ctx: Context, connected: Boolean) {
        prefs(ctx).edit().putBoolean(KEY_CUSTOM_CONNECTED, connected).apply()
    }

    /** Read the Custom-provider committed flag (default false). */
    fun readCustomConnected(ctx: Context): Boolean =
        prefs(ctx).getBoolean(KEY_CUSTOM_CONNECTED, false)
}
