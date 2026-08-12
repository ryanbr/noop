import XCTest
@testable import Strand

/// Pins the #297 "recently selected activities" persistence. The behaviour that must never regress: the
/// sport pickers surface up to three distinct recents, most-recent-first, deduplicated case-insensitively,
/// updated only on a confirmed selection. These exercise the pure encode/decode/recording model the
/// UserDefaults-backed sheets read and write through, and lock it in lockstep with the Android
/// `RecentSportsPrefs` twin (same key, same comma-joined encoding, same cap/dedup/no-op rules).
final class RecentSportsPrefsTests: XCTestCase {

    func testKeyAndCapMatchAndroid() {
        // Both platforms persist "workout.recentSports", capped at three entries.
        XCTAssertEqual(RecentSportsPrefs.key, "workout.recentSports")
        XCTAssertEqual(RecentSportsPrefs.maxCount, 5)
    }

    func testEncodeDecodeRoundTrips() {
        for list in [[String](), ["Running"], ["Running", "Yoga"], ["Running", "Yoga", "Padel"]] {
            XCTAssertEqual(RecentSportsPrefs.decode(RecentSportsPrefs.encode(list)), list)
        }
    }

    func testDecodeDropsBlankAndStrayTokens() {
        XCTAssertEqual(RecentSportsPrefs.decode("Running, ,Yoga,"), ["Running", "Yoga"])
        XCTAssertEqual(RecentSportsPrefs.decode("  Padel  "), ["Padel"])
        XCTAssertEqual(RecentSportsPrefs.decode(""), [])
    }

    func testRecordingFrontInserts() {
        XCTAssertEqual(RecentSportsPrefs.recording("Running", into: []), ["Running"])
        XCTAssertEqual(RecentSportsPrefs.recording("Yoga", into: ["Running"]), ["Yoga", "Running"])
    }

    func testRecordingDedupsCaseInsensitivelyAndMovesToFront() {
        // A re-selection moves the entry to the front (no duplicate) and adopts the new casing.
        XCTAssertEqual(RecentSportsPrefs.recording("running", into: ["Yoga", "Running", "Padel"]),
                       ["running", "Yoga", "Padel"])
    }

    func testRecordingCapsAtFive() {
        // A full list of 5, recording a 6th drops the oldest.
        XCTAssertEqual(RecentSportsPrefs.recording("HIIT", into: ["Running", "Yoga", "Padel", "Boxing", "Tennis"]),
                       ["HIIT", "Running", "Yoga", "Padel", "Boxing"])
        // Under the cap, nothing is dropped.
        XCTAssertEqual(RecentSportsPrefs.recording("HIIT", into: ["Running", "Yoga", "Padel"]),
                       ["HIIT", "Running", "Yoga", "Padel"])
    }

    func testRecordingIgnoresBlankAndCommaNames() {
        // Blank can't be a sport; a comma can't ride the comma-joined encoding — both are no-ops.
        XCTAssertEqual(RecentSportsPrefs.recording("   ", into: ["Running"]), ["Running"])
        XCTAssertEqual(RecentSportsPrefs.recording("Run, walk", into: ["Running"]), ["Running"])
    }

    func testRecordingTrimsWhitespace() {
        XCTAssertEqual(RecentSportsPrefs.recording("  Yoga  ", into: []), ["Yoga"])
    }

    func testSelectionsPersistThroughUserDefaults() {
        // The end-to-end persistence the sheets rely on: recorded selections read back most-recent-first
        // (here via a throwaway UserDefaults suite, as the sheets use .standard).
        let suite = "RecentSportsPrefsTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        XCTAssertEqual(RecentSportsPrefs.recent(defaults), [])
        RecentSportsPrefs.recordSelection("Running", in: defaults)
        RecentSportsPrefs.recordSelection("Yoga", in: defaults)
        XCTAssertEqual(RecentSportsPrefs.recent(defaults), ["Yoga", "Running"])

        // Re-selecting an existing recent moves it to the front instead of duplicating.
        RecentSportsPrefs.recordSelection("Running", in: defaults)
        XCTAssertEqual(RecentSportsPrefs.recent(defaults), ["Running", "Yoga"])

        defaults.removePersistentDomain(forName: suite)
    }
}
