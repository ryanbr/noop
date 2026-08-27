package com.noop.update

/**
 * When may NOOP look for a newer release on its own, and when is that worth telling the user about?
 *
 * The manual "Check for updates" button has always been deliberately user-initiated (see [UpdateCheck]).
 * This adds the automatic half, for the reason #1659 asks for it: on iOS there is NO auto-update to fall
 * back on. A sideloaded app cannot install or re-sign an `.ipa` — only AltStore/SideStore can, and only
 * for people who added the source. Everyone else has no way to learn a release happened without going
 * looking, which is exactly the state the issue describes. Android sideloads share the problem, minus the
 * seven-day re-sign.
 *
 * So the most the app can honestly do is NOTICE and SAY SO. It posts into the Updates inbox the app
 * already has, which means no new surface and no interruption: the bell picks up an unread row, the same
 * way What's New does after an update.
 *
 * Swift twin: `UpdateAvailability`.
 */
object UpdateAvailability {

    /**
     * ON by default (maintainer's call, #1659).
     *
     * It shipped off first, on the reading that "fully offline, on-device, no telemetry" made an
     * unasked-for launch request wrong on principle. The counter-argument won: a sideloaded app has no
     * store to update it, so a user who never finds this setting is a user who silently runs an old
     * build — which is the whole problem the issue reported. A default nobody discovers is not a
     * compromise, it is the feature not existing.
     *
     * What keeps it honest is what the request IS: one read of a public version number, once a day,
     * after onboarding. Nothing about the user is sent, nothing is uploaded, and no data leaves the
     * device — the offline promise is about the user's HEALTH DATA, and that is untouched. Anyone who
     * disagrees turns it off in Settings, and it then makes no request at all.
     */
    const val DEFAULT_ENABLED = true

    /** Once a day. The thing being watched moves on the order of days-to-weeks, so anything tighter
     *  spends requests (and a little battery) to learn nothing. */
    const val CHECK_INTERVAL_MS = 24L * 60L * 60L * 1000L

    /**
     * May a background check run now?
     *
     * [lastCheckedAtMs] is epoch millis, 0 meaning "never checked". A never-checked install is due
     * immediately, so turning the toggle on gives an answer during that session rather than tomorrow.
     *
     * A clock that has moved BACKWARDS (timezone edit, NTP correction, a restored backup) would otherwise
     * park the next check arbitrarily far in the future — `now < lastCheckedAt` is treated as due, which
     * self-heals on the next write.
     */
    fun shouldCheckNow(
        enabled: Boolean,
        lastCheckedAtMs: Long,
        nowMs: Long,
        intervalMs: Long = CHECK_INTERVAL_MS,
    ): Boolean {
        if (!enabled) return false
        if (lastCheckedAtMs <= 0L) return true
        if (nowMs < lastCheckedAtMs) return true       // clock went backwards — don't strand the check
        return nowMs - lastCheckedAtMs >= intervalMs
    }

    /**
     * Is this result worth a row in the inbox?
     *
     * ONCE PER VERSION. [lastPostedVersion] is persisted, so a user who reads the row and does nothing is
     * not told again tomorrow, and the day after. An app that nags about something the user may not want
     * to act on quickly teaches people to ignore the bell, which costs more than the feature is worth.
     */
    fun shouldPost(latest: String, current: String, lastPostedVersion: String?): Boolean {
        if (!UpdateCheck.isNewer(latest, current)) return false
        return latest != lastPostedVersion
    }

    /**
     * Has the install CAUGHT UP with a version we previously announced?
     *
     * The row says "NOOP 10.7.0 is available". Once the user actually installs 10.7.0 that sentence is
     * false, and it sits in the inbox directly beside the What's New row for the same version — an app
     * telling you to get something you already have. Nothing else prunes it, because the row carries no
     * version field of its own; the persisted last-posted version is what makes this answerable without
     * parsing the title back out.
     *
     * Must be evaluated even when the toggle is OFF: someone can post a row, switch the check off, then
     * update — and the stale row would otherwise outlive the feature that made it.
     */
    fun shouldPruneAnnouncement(lastPostedVersion: String?, current: String): Boolean {
        if (lastPostedVersion.isNullOrEmpty()) return false
        return !UpdateCheck.isNewer(lastPostedVersion, current)
    }

    /**
     * Assemble the row's body from ALREADY-LOCALIZED fragments.
     *
     * The copy itself deliberately does NOT live here any more. A first cut built these strings as a
     * byte-identical twin, the way the BLE diagnostic lines are — but that is the wrong half of the
     * parity contract. Analytics and stored data are byte-identical; user-facing copy is LOCALIZED per
     * platform. An unlocalized row would have sat in a translated inbox in English, and no i18n gate
     * would have caught it: they scan `Text` and `@Composable` literals, not model-layer strings.
     *
     * What stays twinned is the ASSEMBLY — order, the single space, the blank line before notes, and the
     * trimming — which is real logic and is what the tests pin. The fragments are separate sentences, so
     * joining them cannot produce the word-order damage that concatenating clauses would.
     */
    fun composeMessage(body: String, sideload: String?, notes: String): String {
        var s = body
        if (!sideload.isNullOrEmpty()) s += " " + sideload
        val trimmed = notes.trim()
        if (trimmed.isNotEmpty()) s += "\n\n" + trimmed
        return s
    }
}

/**
 * Drives the #1659 automatic check: decide, fetch, post, remember. Kept out of [UpdateAvailability] so
 * that stays pure — every rule this obeys is tested there without a network or a clock.
 *
 * Swift twin: `UpdateWatch`.
 */
object UpdateWatch {

    /** On by default; see [UpdateAvailability.DEFAULT_ENABLED] for why, and what the request is. */
    const val KEY_ENABLED = "updates.autoCheck"
    const val KEY_LAST_CHECKED_AT = "updates.lastCheckedAt"
    const val KEY_LAST_POSTED_VERSION = "updates.lastPostedVersion"

    fun isEnabled(context: android.content.Context): Boolean =
        prefs(context).getBoolean(KEY_ENABLED, UpdateAvailability.DEFAULT_ENABLED)

    fun setEnabled(context: android.content.Context, on: Boolean) {
        prefs(context).edit().putBoolean(KEY_ENABLED, on).apply()
    }

    private fun prefs(context: android.content.Context) =
        context.getSharedPreferences(com.noop.ui.NoopPrefs.NAME, android.content.Context.MODE_PRIVATE)

    /**
     * Run a check if one is due, and post to the inbox if the result is worth saying.
     *
     * Every early return is silent BY DESIGN — this runs at launch, and an install with the toggle off
     * (the default) must produce no line, no request and no trace. The manual button remains the loud
     * path: it reports "couldn't check", because there a human is waiting on an answer.
     *
     * [nowMs] is injected so the caller's clock is the only one, and tests need no real one.
     */
    suspend fun runIfDue(
        context: android.content.Context,
        currentVersion: String,
        nowMs: Long = System.currentTimeMillis(),
    ) {
        val p = prefs(context)
        // Runs before every guard below, including the toggle: a stale announcement must not outlive the
        // feature that posted it (see [UpdateAvailability.shouldPruneAnnouncement]).
        if (UpdateAvailability.shouldPruneAnnouncement(
                p.getString(KEY_LAST_POSTED_VERSION, null), currentVersion)
        ) {
            val store = com.noop.ui.UpdateStore.from(context)
            store.items.filter { it.kind == com.noop.ui.UpdateKind.NEW_VERSION }
                .forEach { store.remove(it.id) }
            p.edit().remove(KEY_LAST_POSTED_VERSION).apply()
        }
        if (!UpdateAvailability.shouldCheckNow(
                enabled = isEnabled(context),
                lastCheckedAtMs = p.getLong(KEY_LAST_CHECKED_AT, 0L),
                nowMs = nowMs,
            )
        ) return
        // Stamped BEFORE the result is examined, and deliberately: a failed or unparseable read must still
        // consume the day's slot. Stamping only on success would retry every launch for as long as GitHub
        // is unreachable, which is the one shape a background check must never take.
        p.edit().putLong(KEY_LAST_CHECKED_AT, nowMs).apply()
        val result = runCatching { UpdateCheck.check(currentVersion) }.getOrNull()
        val available = result as? UpdateCheck.Result.Available ?: return
        if (!UpdateAvailability.shouldPost(
                latest = available.version,
                current = currentVersion,
                lastPostedVersion = p.getString(KEY_LAST_POSTED_VERSION, null),
            )
        ) return
        p.edit().putString(KEY_LAST_POSTED_VERSION, available.version).apply()
        // Localized HERE, at the platform edge, so the row reads in the user's language; composeMessage
        // only assembles what it is handed. No sideload sentence on Android: an APK has no seven-day
        // re-sign and no AltStore, so the iOS-only advice would be noise. That is the one place the
        // twins legitimately differ.
        com.noop.ui.UpdateStore.from(context).post(
            com.noop.ui.UpdateItem(
                kind = com.noop.ui.UpdateKind.NEW_VERSION,
                title = context.getString(
                    com.noop.R.string.l10n_updates_noop_1s_is_available_05d8ef55, available.version),
                message = UpdateAvailability.composeMessage(
                    body = context.getString(
                        com.noop.R.string.l10n_updates_youre_on_1s_open_settings_and_35b9e135,
                        currentVersion, available.version),
                    sideload = null,
                    notes = available.notes,
                ),
            )
        )
    }
}
