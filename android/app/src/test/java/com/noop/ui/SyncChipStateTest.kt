package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #245: `SyncChipState.resolve` is the one place the Today top bar's `SyncStatusChip` decides which of
 * the four sync states to show. Mirrors the iOS `SyncChipStateTests` 1:1 — same priority order (backfilling
 * wins over a known last-sync, which wins over the 5/MG experimental fallback), same cold-start `Hidden` case.
 *
 * Every case pins [NOW] instead of reading the system clock, and passes the "now" word in as [NOW_LABEL]
 * instead of letting `resolve` resolve it: these are plain JVM tests with no Robolectric, so there is no
 * attached `NoopApplication` to read the string catalog from. That is what made the `< 60s` cases below
 * throw `IllegalStateException: NoopApplication is not attached` while every other case passed — only the
 * sub-minute branch of `shortSyncAgo` needs a translated word.
 */
class SyncChipStateTest {

    private companion object {
        /** Any fixed instant works now that `resolve` takes its clock as an argument. */
        const val NOW = 1_700_000_000L

        /** Stand-in for the `l10n_today_screen_sync_chip_now_*` catalog entry the composable passes in. */
        const val NOW_LABEL = "now"
    }

    @Test
    fun backfilling_isSyncingWithChunkCount() {
        val state = SyncChipState.resolve(
            backfilling = true, chunks = 7, lastSyncAtSec = null, historySyncExperimental = false,
            nowSec = NOW, nowLabel = NOW_LABEL,
        )
        assertEquals(SyncChipState.Syncing(7), state)
    }

    @Test
    fun lastSyncedAt_isSyncedWithAgeText() {
        val state = SyncChipState.resolve(
            backfilling = false, chunks = 0, lastSyncAtSec = NOW - 65, historySyncExperimental = false,
            nowSec = NOW, nowLabel = NOW_LABEL,
        )
        assertEquals(SyncChipState.Synced("1m"), state)
    }

    @Test
    fun historySyncExperimental_withNoLastSync_isExperimentalLive() {
        val state = SyncChipState.resolve(
            backfilling = false, chunks = 0, lastSyncAtSec = null, historySyncExperimental = true,
            nowSec = NOW, nowLabel = NOW_LABEL,
        )
        assertEquals(SyncChipState.ExperimentalLive, state)
    }

    @Test
    fun coldStart_noBackfillNoSyncNoExperimental_isHidden() {
        val state = SyncChipState.resolve(
            backfilling = false, chunks = 0, lastSyncAtSec = null, historySyncExperimental = false,
            nowSec = NOW, nowLabel = NOW_LABEL,
        )
        assertEquals(SyncChipState.Hidden, state)
    }

    @Test
    fun backfilling_takesPriorityOverLastSyncedAt() {
        val state = SyncChipState.resolve(
            backfilling = true, chunks = 2, lastSyncAtSec = NOW - 5, historySyncExperimental = false,
            nowSec = NOW, nowLabel = NOW_LABEL,
        )
        assertEquals(SyncChipState.Syncing(2), state)
    }

    @Test
    fun lastSyncedAt_takesPriorityOverHistorySyncExperimental() {
        val state = SyncChipState.resolve(
            backfilling = false, chunks = 0, lastSyncAtSec = NOW - 5, historySyncExperimental = true,
            nowSec = NOW, nowLabel = NOW_LABEL,
        )
        assertTrue("A known last-sync should win over the experimental fallback", state is SyncChipState.Synced)
    }

    /**
     * Regression guard for the branch that used to be unreachable from a unit test: a sub-minute sync must
     * render the caller-supplied word verbatim. This fails to even compile — let alone pass — if the string
     * lookup ever moves back inside `shortSyncAgo`, which is the whole point of keeping it out. No iOS twin:
     * Swift's `shortAgo` resolves its own clock and `String(localized:)`, and can afford to because XCTest
     * runs against a real bundle.
     */
    @Test
    fun lastSyncedUnderAMinute_isSyncedWithTheInjectedNowLabel() {
        val state = SyncChipState.resolve(
            backfilling = false, chunks = 0, lastSyncAtSec = NOW - 5, historySyncExperimental = false,
            nowSec = NOW, nowLabel = NOW_LABEL,
        )
        assertEquals(SyncChipState.Synced("now"), state)
    }
}
