import XCTest
@testable import Strand

/// Pure-logic coverage for the Sleep card-order persistence (#sleep-layout): default order, encode/decode
/// round-trip, reorder, and the never-hide "insert missing card at its default position" invariant. These
/// are the pure functions the Arrange editor + Sleep render rely on. Mirrors the Android
/// `SleepLayoutPrefsTest` and the sibling `TodayLayoutPrefsTests`.
final class SleepLayoutPrefsTests: XCTestCase {

    func testEmptyOrUnsetYieldsDefaultOrder() {
        XCTAssertEqual(SleepLayoutPrefs.decodeOrder(""), SleepSection.defaultOrder)
        XCTAssertEqual(SleepLayoutPrefs.decodeOrder("   "), SleepSection.defaultOrder)
    }

    func testEncodeDecodeRoundTripsAReorderedList() {
        let reordered: [SleepSection] = [
            .nightDetail, .sleepMarks, .asleepDuration, .stages, .naps, .sleepDebt, .stagesVsTypical,
        ]
        let encoded = SleepLayoutPrefs.encode(reordered)
        XCTAssertEqual(encoded, "nightDetail,sleepMarks,asleepDuration,stages,naps,sleepDebt,stagesVsTypical")
        XCTAssertEqual(SleepLayoutPrefs.decodeOrder(encoded), reordered)
    }

    /// A saved order that explicitly ends on `sleepMarks` and leads with `asleepDuration` must keep those
    /// two placements while every card missing from the save inserts at its default position (all before
    /// asleepDuration, since each has a lower default index).
    func testDecodeInsertsMissingCardsAtDefaultPositionNeverHides() {
        let decoded = SleepLayoutPrefs.decodeOrder("asleepDuration,sleepMarks")
        XCTAssertEqual(decoded.count, SleepSection.allCases.count)
        XCTAssertEqual(decoded, [
            .stages, .naps, .nightDetail, .sleepDebt, .stagesVsTypical, .asleepDuration, .sleepMarks,
        ])
    }

    func testDecodeDropsUnknownTokensAndCollapsesDuplicates() {
        let decoded = SleepLayoutPrefs.decodeOrder("nightDetail,BOGUS,nightDetail,naps, ,naps")
        XCTAssertEqual(decoded.count, SleepSection.allCases.count)
        XCTAssertEqual(decoded, [
            .sleepMarks, .stages, .nightDetail, .naps, .sleepDebt, .stagesVsTypical, .asleepDuration,
        ])
    }

    func testAllJunkYieldsDefaultOrder() {
        XCTAssertEqual(SleepLayoutPrefs.decodeOrder("nope,,zzz"), SleepSection.defaultOrder)
    }

    func testHiddenSectionsAreExplicitReversibleAndDeduplicated() {
        let hidden = SleepLayoutPrefs.decodeHidden("naps,BOGUS,naps,sleepDebt")
        XCTAssertEqual(hidden, [.naps, .sleepDebt])
        XCTAssertEqual(SleepLayoutPrefs.encodeHidden(hidden), "naps,sleepDebt")
    }

    func testVisibleOrderFiltersHiddenWithoutChangingSavedOrder() {
        let order = "nightDetail,sleepMarks,asleepDuration,stages,naps,sleepDebt,stagesVsTypical"
        XCTAssertEqual(
            SleepLayoutPrefs.visibleOrder(orderRaw: order, hiddenRaw: "asleepDuration,naps"),
            [.nightDetail, .sleepMarks, .stages, .sleepDebt, .stagesVsTypical]
        )
        XCTAssertEqual(SleepLayoutPrefs.decodeOrder(order).count, SleepSection.allCases.count)
    }

    func testNewOrPreviouslyMissingCardsDefaultToVisible() {
        let visible = SleepLayoutPrefs.visibleOrder(orderRaw: "stages,nightDetail,sleepDebt", hiddenRaw: "nightDetail")
        XCTAssertTrue(visible.contains(.naps))
        XCTAssertTrue(visible.contains(.sleepMarks))
    }

    /// defaultOrder must cover EVERY case: the never-hide merge sorts by default index, so a case missing
    /// from the default order could otherwise be dropped or mis-sorted. Twin of the Kotlin test.
    func testDefaultOrderCoversEveryCase() {
        XCTAssertEqual(Set(SleepSection.defaultOrder), Set(SleepSection.allCases))
        XCTAssertEqual(SleepSection.defaultOrder.count, SleepSection.allCases.count)
    }

    func testSectionRawKeysAreStableAndUnique() {
        let raws = SleepSection.allCases.map(\.rawValue)
        XCTAssertEqual(raws.count, Set(raws).count)
        // Pin the exact wire strings — they cross the .noopbak boundary and must match Android byte-for-byte.
        XCTAssertEqual(raws, [
            "sleepMarks", "stages", "naps", "nightDetail", "sleepDebt", "stagesVsTypical", "asleepDuration",
        ])
    }
}
