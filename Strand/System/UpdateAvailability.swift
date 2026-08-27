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

    /// OFF by default, and that is a deliberate reading of a hard project rule rather than timidity.
    /// "Fully offline, on-device, no telemetry" is the headline promise, and both update checkers
    /// currently justify themselves in their own doc comments as running ONLY on a tap. A check that
    /// phones GitHub on launch without being asked would contradict that, however harmless the request
    /// is. Flip this ONE constant to make it default-on; everything else about the feature is unchanged.
    static let defaultEnabled = false

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

    /// Inbox row title. Byte-identical to the Kotlin twin.
    static func inboxTitle(version: String) -> String {
        "NOOP \(version) is available"
    }

    /// Inbox row body.
    ///
    /// Says where to go, because the row cannot take them there: the inbox's deep links address
    /// `NavRouter.Destination` cases and Settings is not one, so a tappable row would need a new route for
    /// a one-line payoff. Naming the path is honest and costs nothing.
    ///
    /// [sideloadHint] is passed IN rather than compiled in with `#if os(iOS)`, so this stays pure and both
    /// branches are testable on whichever platform runs the tests. It is the one place the platforms
    /// legitimately differ: only iOS has an install path the app cannot drive itself.
    static func inboxMessage(version: String, current: String, notes: String, sideloadHint: Bool) -> String {
        var s = "You're on \(current). Open Settings and use Check for updates to see what's new and download \(version)."
        if sideloadHint {
            s += " AltStore or SideStore can install it for you automatically if you added NOOP's source; a direct .ipa still has to be signed on your device."
        }
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
        /// Opt-in. See `UpdateAvailability.defaultEnabled` for why this is off until asked for.
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
            UpdateStore.shared.post(UpdateItem(
                kind: .newVersion,
                title: UpdateAvailability.inboxTitle(version: release.version),
                message: UpdateAvailability.inboxMessage(version: release.version,
                                                         current: currentVersion,
                                                         notes: release.notes,
                                                         sideloadHint: sideloadHint)))
        }
    }
}
