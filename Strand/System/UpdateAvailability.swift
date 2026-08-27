import Foundation
import WhoopProtocol

/// When may NOOP look for a newer release on its own, and when is that worth telling the user about?
///
/// The manual "Check for updates" button has always been deliberately user-initiated (see `UpdateChecker`).
/// This adds the automatic half, for the reason #1659 asks for it: on iOS there is NO auto-update to fall
/// back on. A sideloaded app cannot install or re-sign an `.ipa` — only AltStore/SideStore can, and only
/// for people who added the source. Everyone else has no way to learn a release happened without going
/// looking, which is exactly the state the issue describes.
///
/// So the most the app can honestly do is NOTICE and SAY SO. It posts into the Updates inbox the app
/// already has, which means no new surface and no interruption: the bell picks up an unread row, the same
/// way What's New does after an update.
///
/// Kotlin twin: `com.noop.update.UpdateAvailability`.
enum UpdateAvailability {

    /// ON by default (maintainer's call, #1659).
    ///
    /// It shipped off first, on the reading that "fully offline, on-device, no telemetry" made an
    /// unasked-for launch request wrong on principle. The counter-argument won: a sideloaded app has no
    /// store to update it, so a user who never finds this setting is a user who silently runs an old
    /// build — which is the whole problem the issue reported. A default nobody discovers is not a
    /// compromise, it is the feature not existing.
    ///
    /// What keeps it honest is what the request IS: one read of a public version number, once a day,
    /// after onboarding and the Terms gate. Nothing about the user is sent, nothing is uploaded, and no
    /// data leaves the device — the offline promise is about the user's HEALTH DATA, and that is
    /// untouched. Anyone who disagrees turns it off in Settings, and it then makes no request at all.
    static let defaultEnabled = true

    /// Once a day. The thing being watched moves on the order of days-to-weeks, so anything tighter spends
    /// requests (and a little battery) to learn nothing.
    static let checkInterval: TimeInterval = 24 * 60 * 60

    /// May a background check run now?
    ///
    /// [lastCheckedAt] is epoch seconds, 0 meaning "never checked". A never-checked install is due
    /// immediately, so turning the toggle on gives an answer during that session rather than tomorrow.
    ///
    /// A clock that has moved BACKWARDS (timezone edit, NTP correction, a restored backup) would otherwise
    /// park the next check arbitrarily far in the future — `now < lastCheckedAt` is treated as due, which
    /// self-heals on the next write.
    static func shouldCheckNow(enabled: Bool,
                               lastCheckedAt: TimeInterval,
                               now: TimeInterval,
                               interval: TimeInterval = checkInterval) -> Bool {
        guard enabled else { return false }
        if lastCheckedAt <= 0 { return true }
        if now < lastCheckedAt { return true }          // clock went backwards — don't strand the check
        return now - lastCheckedAt >= interval
    }

    /// Is this result worth a row in the inbox?
    ///
    /// ONCE PER VERSION. [lastPostedVersion] is persisted, so a user who reads the row and does nothing —
    /// which on iOS may be entirely reasonable, since acting means AltStore or a re-sign — is not told
    /// again tomorrow, and the day after. An app that nags about something the user cannot act on quickly
    /// teaches people to ignore the bell, which costs more than the feature is worth.
    static func shouldPost(latest: String, current: String, lastPostedVersion: String?) -> Bool {
        guard VersionCheck.isNewer(latest, than: current) else { return false }
        return latest != lastPostedVersion
    }

    /// Has the install CAUGHT UP with a version we previously announced?
    ///
    /// The row says "NOOP 10.7.0 is available". Once the user actually installs 10.7.0 that sentence is
    /// false, and it sits in the inbox directly beside the What's New row for the same version — an app
    /// telling you to get something you already have. Nothing else prunes it, because the row carries no
    /// version field of its own; the persisted `lastPostedVersion` is what makes this answerable without
    /// parsing the title back out.
    ///
    /// Must be evaluated even when the toggle is OFF: someone can post a row, switch the check off, then
    /// update — and the stale row would otherwise outlive the feature that made it.
    static func shouldPruneAnnouncement(lastPostedVersion: String?, current: String) -> Bool {
        guard let posted = lastPostedVersion, !posted.isEmpty else { return false }
        return !VersionCheck.isNewer(posted, than: current)
    }

    /// Assemble the row's body from ALREADY-LOCALIZED fragments.
    ///
    /// The copy itself deliberately does NOT live here any more. A first cut built these strings as a
    /// byte-identical twin, the way the BLE diagnostic lines are — but that is the wrong half of the
    /// parity contract. Analytics and stored data are byte-identical; user-facing copy is LOCALIZED per
    /// platform, and the sibling What's New row on iOS already is. An unlocalized row would have sat in a
    /// translated inbox in English, and no i18n gate would have caught it: they scan SwiftUI `Text` and
    /// `@Composable` literals, not model-layer strings.
    ///
    /// What stays twinned is the ASSEMBLY — order, the single space, the blank line before notes, and the
    /// trimming — which is real logic and is what the tests pin. The fragments are separate sentences, so
    /// joining them cannot produce the word-order damage that concatenating clauses would.
    static func composeMessage(body: String, sideload: String?, notes: String) -> String {
        var s = body
        if let sideload, !sideload.isEmpty { s += " " + sideload }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { s += "\n\n" + trimmed }
        return s
    }
}

// MARK: - The automatic check

/// Drives the #1659 automatic check: decide, fetch, post, remember. Kept out of `UpdateAvailability` so
/// that stays pure — every rule this obeys is tested there without a network or a clock.
///
/// Kotlin twin: `com.noop.update.UpdateWatch`.
enum UpdateWatch {

    enum Keys {
        /// On by default; see `UpdateAvailability.defaultEnabled` for why, and what the request is.
        static let enabled = "updates.autoCheck"
        static let lastCheckedAt = "updates.lastCheckedAt"
        static let lastPostedVersion = "updates.lastPostedVersion"
    }

    /// The real marketing version straight from the bundle (CFBundleShortVersionString, set from
    /// project.yml MARKETING_VERSION), so a check can never compare against a hand-edited constant that
    /// has gone stale — which is exactly the bug that once told v7 users they were behind. Hoisted here
    /// from SettingsView, which had it private, so the button and the automatic check cannot disagree
    /// about what version is installed.
    static var installedVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? AppChangelog.currentVersion
    }

    /// Re-entrancy guard. `runIfDue` is called from `.onAppear`, which is not guaranteed to fire once,
    /// and the day's slot is stamped INSIDE the task — so two appearances in quick succession could both
    /// pass the due check before either had written anything, and fire two requests for one answer.
    @MainActor private static var inFlight = false

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? UpdateAvailability.defaultEnabled
    }

    /// Run a check if one is due, and post to the inbox if the result is worth saying.
    ///
    /// Every early return is silent BY DESIGN — this runs at launch, and an install with the toggle off
    /// (the default) must produce no line, no request and no trace. The manual button remains the loud
    /// path: it reports "couldn't check", because there a human is waiting on an answer.
    @MainActor
    static func runIfDue(currentVersion: String, sideloadHint: Bool, now: Date = Date()) {
        let d = UserDefaults.standard
        // Runs before every guard below, including the toggle: a stale announcement must not outlive the
        // feature that posted it (see `shouldPruneAnnouncement`).
        if UpdateAvailability.shouldPruneAnnouncement(
            lastPostedVersion: d.string(forKey: Keys.lastPostedVersion), current: currentVersion) {
            for item in UpdateStore.shared.items where item.kind == .newVersion {
                UpdateStore.shared.remove(item.id)
            }
            d.removeObject(forKey: Keys.lastPostedVersion)
        }
        guard !inFlight else { return }
        guard UpdateAvailability.shouldCheckNow(enabled: isEnabled,
                                                lastCheckedAt: d.double(forKey: Keys.lastCheckedAt),
                                                now: now.timeIntervalSince1970) else { return }
        inFlight = true
        Task {
            defer { inFlight = false }
            // Stamped BEFORE the result is examined, and deliberately: a failed or unparseable read must
            // still consume the day's slot. Stamping only on success would retry every launch for as long
            // as GitHub is unreachable, which is the one shape a background check must never take.
            d.set(now.timeIntervalSince1970, forKey: Keys.lastCheckedAt)
            guard let release = await UpdateChecker.fetchLatest() else { return }
            guard UpdateAvailability.shouldPost(latest: release.version,
                                                current: currentVersion,
                                                lastPostedVersion: d.string(forKey: Keys.lastPostedVersion))
            else { return }
            d.set(release.version, forKey: Keys.lastPostedVersion)
            // Localized HERE, at the platform edge, so the row reads in the user's language like the
            // What's New row beside it. `composeMessage` only assembles what it is handed.
            let body = String(localized: "You're on \(currentVersion). Open Settings and use Check for updates to see what's new and download \(release.version).")
            let sideload = sideloadHint
                ? String(localized: "AltStore or SideStore can install it for you automatically if you added NOOP's source; a direct .ipa still has to be signed on your device.")
                : nil
            UpdateStore.shared.post(UpdateItem(
                kind: .newVersion,
                title: String(localized: "NOOP \(release.version) is available"),
                message: UpdateAvailability.composeMessage(body: body,
                                                           sideload: sideload,
                                                           notes: release.notes)))
        }
    }
}
