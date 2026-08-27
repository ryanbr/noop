import XCTest
@testable import Strand

/// The #1659 automatic update check.
///
/// iOS cannot auto-update a sideloaded build — no API lets an app install or re-sign an `.ipa` — so the
/// most NOOP can do is notice a release and say so. These rules decide when it may look, and when the
/// result is worth a row in the Updates inbox.
final class UpdateAvailabilityTests: XCTestCase {

    private let day = UpdateAvailability.checkInterval

    // MARK: - when it may look

    /// Off by default, and off means SILENT: no request, no line, no trace. That is what keeps the
    /// feature compatible with the project's offline promise.
    func testDisabledNeverChecks() {
        XCTAssertFalse(UpdateAvailability.shouldCheckNow(enabled: false, lastCheckedAt: 0, now: 1_000_000))
        XCTAssertFalse(UpdateAvailability.shouldCheckNow(enabled: false, lastCheckedAt: 1, now: 1_000_000))
    }

    /// Turning the toggle on should answer during THAT session, not tomorrow.
    func testANeverCheckedInstallIsDueImmediately() {
        XCTAssertTrue(UpdateAvailability.shouldCheckNow(enabled: true, lastCheckedAt: 0, now: 1_000_000))
    }

    func testItWaitsOutTheInterval() {
        let t = 1_000_000.0
        XCTAssertFalse(UpdateAvailability.shouldCheckNow(enabled: true, lastCheckedAt: t, now: t + day - 1))
        XCTAssertTrue(UpdateAvailability.shouldCheckNow(enabled: true, lastCheckedAt: t, now: t + day))
        XCTAssertTrue(UpdateAvailability.shouldCheckNow(enabled: true, lastCheckedAt: t, now: t + day * 3))
    }

    /// A clock that moves BACKWARDS — timezone edit, NTP correction, a restored backup — would otherwise
    /// park the next check arbitrarily far in the future. Treating it as due self-heals on the next write.
    func testAClockGoingBackwardsDoesNotStrandTheCheck() {
        let t = 1_000_000.0
        XCTAssertTrue(UpdateAvailability.shouldCheckNow(enabled: true, lastCheckedAt: t, now: t - 5))
        XCTAssertTrue(UpdateAvailability.shouldCheckNow(enabled: true, lastCheckedAt: t, now: t - day * 400))
    }

    // MARK: - when it is worth saying

    func testItPostsOnlyForANewerVersion() {
        XCTAssertTrue(UpdateAvailability.shouldPost(latest: "10.7.0", current: "10.6.0", lastPostedVersion: nil))
        XCTAssertFalse(UpdateAvailability.shouldPost(latest: "10.6.0", current: "10.6.0", lastPostedVersion: nil))
        XCTAssertFalse(UpdateAvailability.shouldPost(latest: "10.5.0", current: "10.6.0", lastPostedVersion: nil))
    }

    /// ONCE PER VERSION. On iOS acting means AltStore or a re-sign, so a user may reasonably read the row
    /// and do nothing — and an app that repeats itself daily about something the user has already seen
    /// teaches people to ignore the bell, which costs more than the feature is worth.
    func testItNeverNagsAboutAVersionAlreadyPosted() {
        XCTAssertFalse(UpdateAvailability.shouldPost(latest: "10.7.0", current: "10.6.0",
                                                     lastPostedVersion: "10.7.0"))
        // …but the NEXT release is new news again.
        XCTAssertTrue(UpdateAvailability.shouldPost(latest: "10.8.0", current: "10.6.0",
                                                    lastPostedVersion: "10.7.0"))
    }

    /// The counters are versions, not booleans: a user who skipped 10.7.0 and is still on 10.6.0 must
    /// still hear about 10.8.0.
    func testSkippingAReleaseDoesNotSilenceTheNextOne() {
        XCTAssertTrue(UpdateAvailability.shouldPost(latest: "11.0.0", current: "10.6.0",
                                                    lastPostedVersion: "10.7.0"))
    }

    // MARK: - the inbox row

    /// `.newVersion` must be INFORMATIONAL so it dedupes and can be evicted. It cannot spam on its own,
    /// but a user who ignores several releases should not have them crowd out the actionable rows.
    func testTheRowIsInformationalAndDistinctFromWhatsNew() {
        let item = UpdateItem(kind: .newVersion, title: "t", message: "m")
        XCTAssertEqual(item.kind, .newVersion)
        XCTAssertNotEqual(item.kind, .whatsNew)
        // Round-trips through the persisted store's Codable rawValue.
        XCTAssertEqual(UpdateItem.Kind(rawValue: "newVersion"), .newVersion)
    }

    // MARK: - pruning a stale announcement

    /// The row says "10.7.0 is available". Once the user installs 10.7.0 that sentence is false, and it
    /// sits beside the What's New row for the same version — an app telling you to get what you have.
    func testTheAnnouncementIsPrunedOnceInstalled() {
        XCTAssertTrue(UpdateAvailability.shouldPruneAnnouncement(lastPostedVersion: "10.7.0", current: "10.7.0"))
        // Overshot it (a user who jumped straight to 10.8.0) — equally stale.
        XCTAssertTrue(UpdateAvailability.shouldPruneAnnouncement(lastPostedVersion: "10.7.0", current: "10.8.0"))
    }

    /// Still behind: the row is still TRUE and must survive, or the announcement would delete itself on
    /// the very next launch and the feature would do nothing at all.
    func testAnAnnouncementStillAheadSurvives() {
        XCTAssertFalse(UpdateAvailability.shouldPruneAnnouncement(lastPostedVersion: "10.7.0", current: "10.6.0"))
    }

    func testNothingAnnouncedIsNothingToPrune() {
        XCTAssertFalse(UpdateAvailability.shouldPruneAnnouncement(lastPostedVersion: nil, current: "10.6.0"))
        XCTAssertFalse(UpdateAvailability.shouldPruneAnnouncement(lastPostedVersion: "", current: "10.6.0"))
    }

    // MARK: - assembling the row body

    /// The COPY is localized at the platform edge now, so what is pinned here is the ASSEMBLY: order, the
    /// single space between sentences, the blank line before notes, and the trimming. A first cut tested
    /// the English strings byte-for-byte against Kotlin — the wrong property, and one that would have
    /// stayed green while the row rendered in English inside a translated inbox.
    func testComposeJoinsSentencesWithASingleSpace() {
        XCTAssertEqual(UpdateAvailability.composeMessage(body: "A.", sideload: "B.", notes: ""), "A. B.")
    }

    func testComposeOmitsAnAbsentOrEmptySideloadSentence() {
        XCTAssertEqual(UpdateAvailability.composeMessage(body: "A.", sideload: nil, notes: ""), "A.")
        XCTAssertEqual(UpdateAvailability.composeMessage(body: "A.", sideload: "", notes: ""), "A.")
    }

    /// Release notes are a block, not a sentence: blank line before, and trimmed — GitHub bodies arrive
    /// with padding.
    func testComposeAppendsTrimmedNotesAfterABlankLine() {
        XCTAssertEqual(UpdateAvailability.composeMessage(body: "A.", sideload: nil, notes: "  N.  "),
                       "A.\n\nN.")
        XCTAssertEqual(UpdateAvailability.composeMessage(body: "A.", sideload: "B.", notes: "N."),
                       "A. B.\n\nN.")
    }

    /// Whitespace-only notes must not leave a trailing blank line hanging in the row.
    func testComposeTreatsBlankNotesAsNone() {
        XCTAssertEqual(UpdateAvailability.composeMessage(body: "A.", sideload: nil, notes: "   \n  "), "A.")
    }

    // MARK: - the default

    /// An UNSET pref must resolve to the same answer the Settings toggle shows. The launch check reads
    /// UserDefaults directly and the toggle reads @AppStorage; both fall back to `defaultEnabled`, and if
    /// one were changed without the other the switch would say one thing while the app did another.
    func testAnUnsetPrefMatchesWhatTheToggleWouldShow() {
        let key = UpdateWatch.Keys.enabled
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(UpdateWatch.isEnabled, UpdateAvailability.defaultEnabled)
    }

    /// An explicit choice always wins over the default, in BOTH directions — otherwise flipping the
    /// shipped default would silently override people who had already opted out.
    func testAnExplicitChoiceOverridesTheDefault() {
        let key = UpdateWatch.Keys.enabled
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(UpdateWatch.isEnabled)
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(UpdateWatch.isEnabled)
    }
}

