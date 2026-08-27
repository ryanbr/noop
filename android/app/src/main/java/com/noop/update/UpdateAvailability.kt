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
     * OFF by default, and that is a deliberate reading of a hard project rule rather than timidity.
     * "Fully offline, on-device, no telemetry" is the headline promise, and both update checkers
     * currently justify themselves in their own doc comments as running ONLY on a tap. A check that
     * phones GitHub on launch without being asked would contradict that, however harmless the request
     * is. Flip this ONE constant to make it default-on; everything else about the feature is unchanged.
     */
    const val DEFAULT_ENABLED = false

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

    /** Inbox row title. Byte-identical to the Swift twin. */
    fun inboxTitle(version: String): String = "NOOP $version is available"

    /**
     * Inbox row body.
     *
     * Says where to go, because the row cannot take them there. [sideloadHint] is passed IN rather than
     * branched on the platform, so this stays pure and both branches are testable — it is the one place
     * the platforms legitimately differ: only iOS has an install path the app cannot drive itself.
     */
    fun inboxMessage(version: String, current: String, notes: String, sideloadHint: Boolean): String {
        var s = "You're on $current. Open Settings and use Check for updates to see what's new and download $version."
        if (sideloadHint) {
            s += " AltStore or SideStore can install it for you automatically if you added NOOP's source;" +
                " a direct .ipa still has to be signed on your device."
        }
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

    /** Opt-in. See [UpdateAvailability.DEFAULT_ENABLED] for why this is off until asked for. */
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
        com.noop.ui.UpdateStore.from(context).post(
            com.noop.ui.UpdateItem(
                kind = com.noop.ui.UpdateKind.NEW_VERSION,
                title = UpdateAvailability.inboxTitle(available.version),
                // No sideload sentence on Android: an APK has no seven-day re-sign and no AltStore, so the
                // iOS-only advice would be noise here. This is the one place the twins legitimately differ.
                message = UpdateAvailability.inboxMessage(
                    version = available.version,
                    current = currentVersion,
                    notes = available.notes,
                    sideloadHint = false,
                ),
            )
        )
    }
}
