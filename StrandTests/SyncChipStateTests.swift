import XCTest
@testable import Strand

/// #245: `SyncChipState.resolve` is the one place both the classic `SyncStatusChip` and the Liquid
/// header's `LiquidSyncChip` decide which of the three sync states to show, so a mistake here would
/// desync the two headers. Covers priority order (backfilling wins over a stale last-sync, which wins
/// over the 5/MG experimental fallback) and the cold-start `.hidden` case.
@MainActor
final class SyncChipStateTests: XCTestCase {

    func testBackfilling_isSyncingWithChunkCount() {
        let live = LiveState()
        live.backfilling = true
        live.syncChunksThisSession = 7
        XCTAssertEqual(SyncChipState.resolve(live: live), .syncing(chunks: 7))
    }

    func testLastSyncedAt_isSyncedWithAgeText() {
        let live = LiveState()
        live.lastSyncedAt = Date().timeIntervalSince1970 - 65
        XCTAssertEqual(SyncChipState.resolve(live: live), .synced(agoText: "1m"))
    }

    /// #1472 regression guard. The sub-minute token is wrapped by `DevicesView` in "Synced %@ ago" and
    /// "Strap history synced %@ ago", so it must compose with a trailing "ago". It used to be the word
    /// "now", which rendered the user-visible "Synced now ago" for the first minute after every sync;
    /// "<1m" is the fix and this pins it. Twin of the Android `lastSyncedUnderAMinute_usesSubMinuteToken`.
    func testLastSyncedUnderAMinute_usesSubMinuteToken() {
        let live = LiveState()
        live.lastSyncedAt = Date().timeIntervalSince1970 - 5
        XCTAssertEqual(SyncChipState.resolve(live: live), .synced(agoText: "<1m"))
    }

    func testHistorySyncExperimental_withNoLastSync_isExperimentalLive() {
        let live = LiveState()
        live.historySyncExperimental = true
        XCTAssertEqual(SyncChipState.resolve(live: live), .experimentalLive)
    }

    func testColdStart_noBackfillNoSyncNoExperimental_isHidden() {
        let live = LiveState()
        XCTAssertEqual(SyncChipState.resolve(live: live), .hidden)
    }

    func testBackfilling_takesPriorityOverLastSyncedAt() {
        let live = LiveState()
        live.backfilling = true
        live.syncChunksThisSession = 2
        live.lastSyncedAt = Date().timeIntervalSince1970 - 5
        XCTAssertEqual(SyncChipState.resolve(live: live), .syncing(chunks: 2))
    }

    func testLastSyncedAt_takesPriorityOverHistorySyncExperimental() {
        let live = LiveState()
        live.lastSyncedAt = Date().timeIntervalSince1970 - 5
        live.historySyncExperimental = true
        if case .synced = SyncChipState.resolve(live: live) {
            // expected
        } else {
            XCTFail("A known last-sync should win over the experimental fallback")
        }
    }
}
