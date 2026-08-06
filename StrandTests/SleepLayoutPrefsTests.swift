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
            .nightDetail, .sleepMarks, .asleepDuration, .stages, .sleepDebt, .stagesVsTypical,
        ]
        let encoded = SleepLayoutPrefs.encode(reordered)
        XCTAssertEqual(encoded, "nightDetail,sleepMarks,asleepDuration,stages,sleepDebt,stagesVsTypical")
        XCTAssertEqual(SleepLayoutPrefs.decodeOrder(encoded), reordered)
    }

    /// A saved order that leads with `asleepDuration` and ends on `sleepMarks` keeps those two placements
    /// while every card missing from the save inserts at its default position (all before asleepDuration,
    /// since each has a lower default index).
    func testDecodeInsertsMissingCardsAtDefaultPositionNeverHides() {
        let decoded = SleepLayoutPrefs.decodeOrder("asleepDuration,sleepMarks")
        XCTAssertEqual(decoded.count, SleepSection.allCases.count)
        XCTAssertEqual(decoded, [
            .stages, .nightDetail, .sleepDebt, .stagesVsTypical, .asleepDuration, .sleepMarks,
        ])
    }

    /// Whatever the input, every card always renders — unknown tokens dropped, duplicates collapsed, and
    /// no card is ever hidden by a partial/messy save.
    func testDecodeAlwaysReturnsEveryCard() {
        for input in ["nightDetail,BOGUS,nightDetail, ,stages", "sleepDebt", "zzz,stages,,stages"] {
            let decoded = SleepLayoutPrefs.decodeOrder(input)
            XCTAssertEqual(Set(decoded), Set(SleepSection.allCases))
            XCTAssertEqual(decoded.count, SleepSection.allCases.count)
        }
    }

    func testAllJunkYieldsDefaultOrder() {
        XCTAssertEqual(SleepLayoutPrefs.decodeOrder("nope,,zzz"), SleepSection.defaultOrder)
    }

    func testHiddenSectionsAreExplicitReversibleAndDeduplicated() {
        let hidden = SleepLayoutPrefs.decodeHidden("stages,BOGUS,stages,sleepDebt")
        XCTAssertEqual(hidden, [.stages, .sleepDebt])
        XCTAssertEqual(SleepLayoutPrefs.encodeHidden(hidden), "stages,sleepDebt")
    }

    func testVisibleOrderFiltersHiddenWithoutChangingSavedOrder() {
        let order = "nightDetail,sleepMarks,asleepDuration,stages,sleepDebt,stagesVsTypical"
        XCTAssertEqual(
            SleepLayoutPrefs.visibleOrder(orderRaw: order, hiddenRaw: "asleepDuration,sleepDebt"),
            [.nightDetail, .sleepMarks, .stages, .stagesVsTypical]
        )
        XCTAssertEqual(SleepLayoutPrefs.decodeOrder(order).count, SleepSection.allCases.count)
    }

    func testNewOrPreviouslyMissingCardsDefaultToVisible() {
        let visible = SleepLayoutPrefs.visibleOrder(orderRaw: "stages,nightDetail", hiddenRaw: "nightDetail")
        XCTAssertTrue(visible.contains(.sleepMarks))
        XCTAssertTrue(visible.contains(.asleepDuration))
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
            "sleepMarks", "stages", "nightDetail", "sleepDebt", "stagesVsTypical", "asleepDuration",
        ])
    }
}
