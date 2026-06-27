package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure snapshot-naming/selection logic behind Backup & Sync (Phase 1). Mirror of the Swift BackupSyncTests. */
class BackupSyncTest {

    @Test fun nameRoundTripsToUtcSecond() {
        val ms = 1_782_000_000_000L // whole-second instant (UTC)
        val name = BackupSync.snapshotName(ms)
        assertTrue(name.startsWith("noop-backup-"))
        assertTrue(name.endsWith(".noopbak"))
        assertEquals(ms, BackupSync.snapshotTimeMs(name)) // second-resolution round-trip
    }

    @Test fun isSnapshotRejectsNonBackups() {
        assertTrue(BackupSync.isSnapshot(BackupSync.snapshotName(1_782_000_000_000L)))
        assertFalse(BackupSync.isSnapshot("photo.jpg"))
        assertFalse(BackupSync.isSnapshot("noop-backup-notadate.noopbak"))
        assertFalse(BackupSync.isSnapshot("noop-backup-20260627-123456.zip"))
        assertNull(BackupSync.snapshotTimeMs("random.txt"))
    }

    @Test fun latestPicksNewest() {
        val older = BackupSync.snapshotName(1_782_000_000_000L)
        val newer = BackupSync.snapshotName(1_782_000_600_000L) // +10 min
        assertEquals(newer, BackupSync.latestSnapshot(listOf(older, "junk.txt", newer)))
        assertNull(BackupSync.latestSnapshot(listOf("a.txt", "b.bin")))
    }

    @Test fun pruneKeepsNewestN() {
        val names = (0L until 5L).map { BackupSync.snapshotName(1_782_000_000_000L + it * 60_000L) }
        // keep 2 newest -> the 3 oldest are pruned
        val pruned = BackupSync.snapshotsToPrune(names + "keepme.txt", keep = 2)
        assertEquals(3, pruned.size)
        assertTrue(pruned.contains(names[0]))   // oldest pruned
        assertFalse(pruned.contains(names[4]))  // newest kept
        assertFalse(pruned.contains("keepme.txt")) // non-snapshots never pruned
    }

    @Test fun pruneNoOpWithinBudget() {
        val names = listOf(BackupSync.snapshotName(1_782_000_000_000L))
        assertTrue(BackupSync.snapshotsToPrune(names, keep = 10).isEmpty())
    }
}
