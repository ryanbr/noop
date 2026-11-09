import XCTest
@testable import Strand

/// Twin of the Android `TodayLayoutPrefsTest` (#today-layout): default order, encode/decode round-trip,
/// reorder, and the never-hide "insert missing section at its default position" invariant — pinned on both
/// platforms so the byte-identical "today.sectionOrder" wire format can't drift.
final class TodayLayoutPrefsTests: XCTestCase {

    func testEmptyOrUnsetYieldsDefaultOrder() {
        XCTAssertEqual(TodayLayoutPrefs.decodeOrder(""), TodaySection.defaultOrder)
        XCTAssertEqual(TodayLayoutPrefs.decodeOrder("   "), TodaySection.defaultOrder)
    }

    /// The user-edited Latest Workouts feed length bounds, pinned on both platforms.
    func testWorkoutsCountBoundsArePinned() {
        XCTAssertEqual(TodayLayoutPrefs.minWorkoutsCount, 1)
        XCTAssertEqual(TodayLayoutPrefs.maxWorkoutsCount, 14)
        XCTAssertEqual(TodayLayoutPrefs.defaultWorkoutsCount, 6)
        XCTAssertEqual(TodayLayoutPrefs.clampedWorkoutsCount(0), 1)
        XCTAssertEqual(TodayLayoutPrefs.clampedWorkoutsCount(15), 14)
        XCTAssertEqual(TodayLayoutPrefs.clampedWorkoutsCount(5), 5)
    }

    /// The user-edited Latest Workouts feed window options, pinned on both platforms.
    func testWorkoutsWindowOptionsArePinned() {
        XCTAssertEqual(TodayLayoutPrefs.defaultWorkoutsWindowDays, 14)
        XCTAssertEqual(TodayLayoutPrefs.workoutsWindowOptions, [14, 30, 365])
        // The snap keeps every option and rejects everything else (the header can only name options).
        XCTAssertEqual(TodayLayoutPrefs.snapWorkoutsWindowDays(45), 14)
        XCTAssertEqual(TodayLayoutPrefs.snapWorkoutsWindowDays(30), 30)
        XCTAssertEqual(TodayLayoutPrefs.snapWorkoutsWindowDays(365), 365)
    }

    func testEncodeDecodeRoundTripsAReorderedList() {
        let reordered: [TodaySection] = [
            .heartRate, .hero, .yourCards, .liveSession, .synthesis, .keyMetrics, .workouts, .recoveryVitals,
            .journal, .menstrualCycle, .addedCards,
        ]
        let encoded = TodayLayoutPrefs.encode(reordered)
        XCTAssertEqual(encoded, "heartRate,hero,yourCards,liveSession,synthesis,keyMetrics,workouts,recoveryVitals,journal,menstrualCycle,addedCards")
        XCTAssertEqual(TodayLayoutPrefs.decodeOrder(encoded), reordered)
    }

    /// The v1 upgrade path: an order saved by the FIRST cut (6 sections — no hero/liveSession, which were
    /// pinned then) must surface the two new sections at the TOP (their default position), not teleport
    /// them to the bottom of the user's saved order.
    func testSavedOrderFromFirstCutInsertsHeroAndSessionAtTheirDefaultPosition() {
        let firstCut = "synthesis,keyMetrics,workouts,heartRate,recoveryVitals,yourCards"
        XCTAssertEqual(
            TodayLayoutPrefs.decodeOrder(firstCut),
            // journal(8) follows everything saved → appended; addedCards(10) is last, appended after it.
            [.hero, .liveSession, .synthesis, .keyMetrics, .workouts, .heartRate, .recoveryVitals, .yourCards, .menstrualCycle, .journal, .addedCards]
        )
    }

    func testInsertsAnyMissingSectionAtItsDefaultPositionRelativeToSaved() {
        let partial = "heartRate,synthesis,keyMetrics,recoveryVitals"
        XCTAssertEqual(
            TodayLayoutPrefs.decodeOrder(partial),
            [.hero, .liveSession, .workouts, .heartRate, .synthesis, .keyMetrics, .recoveryVitals, .yourCards, .menstrualCycle, .journal, .addedCards]
        )
    }

    func testDropsUnknownTokensAndCollapsesDuplicates() {
        let messy = "yourCards,BOGUS,yourCards,heartRate, ,heartRate"
        XCTAssertEqual(
            TodayLayoutPrefs.decodeOrder(messy),
            [.hero, .liveSession, .synthesis, .keyMetrics, .workouts, .recoveryVitals, .yourCards, .heartRate, .menstrualCycle, .journal, .addedCards]
        )
    }

    func testAllJunkYieldsDefaultOrder() {
        XCTAssertEqual(TodayLayoutPrefs.decodeOrder("nope,,zzz"), TodaySection.defaultOrder)
    }

    func testHiddenSectionsAreExplicitReversibleAndDeduplicated() {
        let hidden = TodayLayoutPrefs.decodeHidden("workouts,BOGUS,workouts,journal")
        XCTAssertEqual(hidden, [.workouts, .journal])
        XCTAssertEqual(TodayLayoutPrefs.encodeHidden(hidden), "workouts,journal")
    }

    func testVisibleOrderFiltersHiddenWithoutChangingSavedOrder() {
        let order = "heartRate,hero,yourCards,liveSession,synthesis,keyMetrics,workouts,recoveryVitals,journal"
        XCTAssertEqual(
            TodayLayoutPrefs.visibleOrder(orderRaw: order, hiddenRaw: "hero,workouts"),
            [.heartRate, .yourCards, .liveSession, .synthesis, .keyMetrics, .recoveryVitals, .menstrualCycle, .journal, .addedCards]
        )
        XCTAssertEqual(TodayLayoutPrefs.decodeOrder(order), [
            .heartRate, .hero, .yourCards, .liveSession, .synthesis, .keyMetrics, .workouts,
            .recoveryVitals, .menstrualCycle, .journal, .addedCards,
        ])
    }

    func testNewOrPreviouslyMissingSectionsDefaultToVisible() {
        XCTAssertTrue(
            TodayLayoutPrefs.visibleOrder(
                orderRaw: "synthesis,keyMetrics,workouts,heartRate,recoveryVitals,yourCards",
                hiddenRaw: "workouts"
            ).contains(.journal)
        )
    }

    /// defaultOrder must cover EVERY case: the never-hide merge iterates it, so a case missing from the
    /// default order could otherwise be dropped from render (Android) or mis-sorted (iOS).
    func testDefaultOrderCoversEveryCase() {
        XCTAssertEqual(Set(TodaySection.defaultOrder), Set(TodaySection.allCases))
        XCTAssertEqual(TodaySection.defaultOrder.count, TodaySection.allCases.count)
    }

    func testSectionRawKeysAreStableAndUnique() {
        let raws = TodaySection.allCases.map(\.rawValue)
        XCTAssertEqual(raws.count, Set(raws).count, "raw keys must be unique (they're the persisted identity)")
        // Pin the exact wire strings — they must match the Android TodaySection byte-for-byte.
        XCTAssertEqual(
            raws,
            ["hero", "liveSession", "synthesis", "keyMetrics", "workouts", "heartRate", "recoveryVitals", "yourCards", "menstrualCycle", "journal", "addedCards"]
        )
    }

    func testEditableLayoutHidesAndRestoresWithoutDeleting() {
        var draft = EditableLayoutDraft(
            visible: TodaySection.defaultOrder,
            allItems: TodaySection.defaultOrder
        )

        draft.hide(.workouts)
        XCTAssertFalse(draft.visible.contains(.workouts))
        XCTAssertEqual(draft.hidden, [.workouts])

        draft.show(.workouts)
        XCTAssertEqual(draft.visible.last, .workouts)
        XCTAssertTrue(draft.hidden.isEmpty)
        XCTAssertEqual(Set(draft.visible), Set(TodaySection.defaultOrder))
    }

    func testEditableLayoutKeepsAtLeastOneItemVisible() {
        var draft = EditableLayoutDraft(visible: [KeyMetric.hrv], hidden: KeyMetric.defaultOrder.filter { $0 != .hrv })
        draft.hide(.hrv)
        XCTAssertEqual(draft.visible, [.hrv])
    }

    /// Unset/empty fields mean EVERY chip is enabled (the historical default — existing users see no
    /// change). Unknown tokens are ignored; an all-junk string degrades to the same default.
    func testWorkoutFieldsUnsetMeansAllEnabled() {
        // An unset default arrives as an empty string on Apple (the twin of the Kotlin `null` case).
        XCTAssertEqual(TodayLayoutPrefs.decodeWorkoutFields(""), Set(WorkoutField.allCases))
        XCTAssertEqual(TodayLayoutPrefs.decodeWorkoutFields("   "), Set(WorkoutField.allCases))
        XCTAssertEqual(TodayLayoutPrefs.decodeWorkoutFields("nope,,zzz"), Set(WorkoutField.allCases))
    }

    /// The stored string is the deterministic canonical-order encoding — a Set toggle order can never
    /// produce two spellings of the same chip set.
    func testWorkoutFieldsEncodeIsCanonicalOrder() {
        let fields: Set<WorkoutField> = [.calories, .strain, .duration]
        XCTAssertEqual(TodayLayoutPrefs.encodeWorkoutFields(fields), "strain,duration,calories")
        XCTAssertEqual(TodayLayoutPrefs.decodeWorkoutFields("strain,duration,calories"), fields)
    }

    /// A partial set round-trips; unknown tokens are dropped and duplicates collapsed.
    func testWorkoutFieldsDecodeDropsUnknownAndDedupes() {
        let decoded = TodayLayoutPrefs.decodeWorkoutFields("heartRate,BOGUS,heartRate,calories")
        XCTAssertEqual(decoded, [WorkoutField.heartRate, .calories])
    }

    /// The four chip raw keys are the persisted identity — pinned byte-identical to Android.
    func testWorkoutFieldRawKeysArePinned() {
        XCTAssertEqual(
            WorkoutField.allCases.map(\.rawValue),
            ["strain", "duration", "heartRate", "calories"]
        )
    }
}
