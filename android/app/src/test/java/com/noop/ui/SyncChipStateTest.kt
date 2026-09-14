package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #245: `SyncChipState.resolve` is the one place the Today top bar's `SyncStatusChip` decides which of
 * the four sync states to show. Mirrors the iOS `SyncChipStateTests` 1:1 — same priority order (backfilling
 * wins over a known last-sync, which wins over the 5/MG experimental fallback), same cold-start `Hidden` case.
 *
 * Every case pins [NOW] instead of reading the system clock. There used to be a `NOW_LABEL` parameter too,
 * because the sub-minute branch returned a translated word and resolving it needed an attached
 * `NoopApplication` these plain JVM tests do not have. #1472 removed the word, so the injection went with
 * it — every branch is now digits and symbols.
 */
class SyncChipStateTest {

    private companion object {
        /** Any fixed instant works now that `resolve` takes its clock as an argument. */
        const val NOW = 1_700_000_000L
    }

    @Test
    fun backfilling_isSyncingWithChunkCount() {
        val state = SyncChipState.resolve(
            backfilling = true, chunks = 7, lastSyncAtSec = null, historySyncExperimental = false,
            nowSec = NOW,
        )
        assertEquals(SyncChipState.Syncing(7), state)
    }

    @Test
    fun lastSyncedAt_isSyncedWithAgeText() {
        val state = SyncChipState.resolve(
            backfilling = false, chunks = 0, lastSyncAtSec = NOW - 65, historySyncExperimental = false,
            nowSec = NOW,
        )
        assertEquals(SyncChipState.Synced("1m"), state)
    }

    @Test
    fun historySyncExperimental_withNoLastSync_isExperimentalLive() {
        val state = SyncChipState.resolve(
            backfilling = false, chunks = 0, lastSyncAtSec = null, historySyncExperimental = true,
            nowSec = NOW,
        )
        assertEquals(SyncChipState.ExperimentalLive, state)
    }

    @Test
    fun coldStart_noBackfillNoSyncNoExperimental_isHidden() {
        val state = SyncChipState.resolve(
            backfilling = false, chunks = 0, lastSyncAtSec = null, historySyncExperimental = false,
            nowSec = NOW,
        )
        assertEquals(SyncChipState.Hidden, state)
    }

    @Test
    fun backfilling_takesPriorityOverLastSyncedAt() {
        val state = SyncChipState.resolve(
            backfilling = true, chunks = 2, lastSyncAtSec = NOW - 5, historySyncExperimental = false,
            nowSec = NOW,
        )
        assertEquals(SyncChipState.Syncing(2), state)
    }

    @Test
    fun lastSyncedAt_takesPriorityOverHistorySyncExperimental() {
        val state = SyncChipState.resolve(
            backfilling = false, chunks = 0, lastSyncAtSec = NOW - 5, historySyncExperimental = true,
            nowSec = NOW,
        )
        assertTrue("A known last-sync should win over the experimental fallback", state is SyncChipState.Synced)
    }

    /**
     * #1472 regression guard. The sub-minute token is wrapped by the chip's accessibility description,
     * "Strap history synced %1$s ago", so it must compose with a trailing "ago". It used to be the word
     * "now", which read "Strap history synced now ago"; "<1m" is the fix and this pins it. Twin of the iOS
     * `lastSyncedUnderAMinute_usesSubMinuteToken`.
     */
    @Test
    fun lastSyncedUnderAMinute_usesSubMinuteToken() {
        val state = SyncChipState.resolve(
            backfilling = false, chunks = 0, lastSyncAtSec = NOW - 5, historySyncExperimental = false,
            nowSec = NOW,
        )
        assertEquals(SyncChipState.Synced("<1m"), state)
    }

    // #689/#815: the connect-time backlog sample. Twin of the iOS cases in `SyncChipStateTests`.

    @Test
    fun backfillingWithBacklog_carriesThePagesFigure() {
        val state = SyncChipState.resolve(
            backfilling = true, chunks = 3, lastSyncAtSec = null, historySyncExperimental = false,
            nowSec = NOW, pagesBehind = 120,
        )
        assertEquals(SyncChipState.Syncing(3, 120), state)
    }

    /**
     * A zero backlog is dropped rather than rendered. The chip only exists while a sync is running, so
     * "0 pages behind at connect" next to a spinning icon contradicts itself, and a zero sample gives a
     * reader nothing to act on. Pinned because the rule lives in `resolve` precisely so both platforms
     * drop the same case rather than each deciding in its own view layer.
     */
    @Test
    fun backfillingWithZeroBacklog_dropsTheDetail() {
        val state = SyncChipState.resolve(
            backfilling = true, chunks = 3, lastSyncAtSec = null, historySyncExperimental = false,
            nowSec = NOW, pagesBehind = 0,
        )
        assertEquals(SyncChipState.Syncing(3, null), state)
    }

    /** No reply yet this session, or a frame that did not decode: the chip is exactly what it was before. */
    @Test
    fun backfillingWithoutASample_isUnchanged() {
        val state = SyncChipState.resolve(
            backfilling = true, chunks = 3, lastSyncAtSec = null, historySyncExperimental = false,
            nowSec = NOW, pagesBehind = null,
        )
        assertEquals(SyncChipState.Syncing(3, null), state)
    }

    /**
     * The backlog only qualifies an in-progress sync. Once the strap has finished, the chip reports when
     * it last synced, and a stale "behind" figure must not survive into that state.
     */
    @Test
    fun notBackfilling_ignoresTheBacklog() {
        val state = SyncChipState.resolve(
            backfilling = false, chunks = 0, lastSyncAtSec = NOW - 65, historySyncExperimental = false,
            nowSec = NOW, pagesBehind = 120,
        )
        assertEquals(SyncChipState.Synced("1m"), state)
    }
}
