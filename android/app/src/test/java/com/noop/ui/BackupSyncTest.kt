package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure snapshot-naming / selection / schedule logic behind Backup & Sync (Phase 1). Mirror of the
 * Swift BackupSyncTests so both platforms agree byte-for-byte on filenames, newest-pick, prune and the
 * catch-up cadence (must-fix #6: identical behaviour across Swift + Android).
 */
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

    @Test fun defaultKeepIsAWeek() {
        // Fork choice: a week of daily rollback points. (Apple twin still defaults to 10; the keep-count
        // is now user-adjustable via the Backup & Sync dropdown regardless.)
        assertEquals(7, BackupSync.DEFAULT_KEEP)
    }

    @Test fun backupDelayLandsAtOneAm() {
        // The daily snapshot is anchored to 01:00 local: from any instant, the delay must put the next
        // fire at hour 01:00, within the next 24h. TZ-agnostic (checks the resolved wall-clock).
        val now = 1_700_000_000_000L
        val delay = BackupSync.delayToNextBackupMs(now)
        assertTrue(delay in 1..(24L * 60 * 60 * 1000))
        val fire = java.util.Calendar.getInstance().apply { timeInMillis = now + delay }
        assertEquals(1, fire.get(java.util.Calendar.HOUR_OF_DAY))
        assertEquals(0, fire.get(java.util.Calendar.MINUTE))
    }

    @Test fun backupDelayHonoursAChosenTime() {
        // A configured time (06:30 = 390 min) must land the next fire at 06:30, within the next 24h.
        val now = 1_700_000_000_000L
        val delay = BackupSync.delayToNextBackupMs(now, minuteOfDay = 6 * 60 + 30)
        assertTrue(delay in 1..(24L * 60 * 60 * 1000))
        val fire = java.util.Calendar.getInstance().apply { timeInMillis = now + delay }
        assertEquals(6, fire.get(java.util.Calendar.HOUR_OF_DAY))
        assertEquals(30, fire.get(java.util.Calendar.MINUTE))
    }

    @Test fun catchUpDueOnlyAfterADay() {
        val last = 1_782_000_000_000L
        assertFalse(BackupSync.isCatchUpDue(last, last))                       // same instant
        assertFalse(BackupSync.isCatchUpDue(last, last + 23 * 3_600_000L))     // 23h: not yet
        assertTrue(BackupSync.isCatchUpDue(last, last + 24 * 3_600_000L))      // exactly a day
        assertTrue(BackupSync.isCatchUpDue(last, last + 48 * 3_600_000L))      // well past
        assertTrue(BackupSync.isCatchUpDue(0L, last))                          // never-backed-up: due
    }

    @Test fun isBackupStaleAfterThreshold() {
        val last = 1_782_000_000_000L
        val day = 24L * 3_600_000L
        assertFalse(BackupSync.isBackupStale(last, last))            // same instant
        assertFalse(BackupSync.isBackupStale(last, last + 2 * day))  // 2 days: still fresh
        assertTrue(BackupSync.isBackupStale(last, last + 3 * day))   // 3 days: stale (threshold)
        assertTrue(BackupSync.isBackupStale(last, last + 10 * day))  // well past
        assertTrue(BackupSync.isBackupStale(0L, last))              // never backed up: stale
    }

    // Restore listing accepts ANY .noopbak, including date-only manual names (#852).

    @Test fun isBackupFileAcceptsAnyNoopbakExtension() {
        assertTrue(BackupSync.isBackupFile("noop-backup-2026-06-30.noopbak"))       // date-only manual name
        assertTrue(BackupSync.isBackupFile(BackupSync.snapshotName(1_782_000_000_000L)))
        assertTrue(BackupSync.isBackupFile("whatever-i-named-it.noopbak"))          // arbitrary name
        assertTrue(BackupSync.isBackupFile("BACKUP.NOOPBAK"))                       // case-insensitive
        assertFalse(BackupSync.isBackupFile("noop-backup-20260630-120000.zip"))     // wrong extension
        assertFalse(BackupSync.isBackupFile("photo.jpg"))
    }

    @Test fun restorablesIncludeDateOnlyNamesAndOrderNewestFirst() {
        // The reporter's exact folder: a date-only manual export plus a canonical timestamped one (#852).
        val canonical = BackupSync.snapshotName(1_782_000_600_000L) // has an embedded stamp
        val dateOnly = "noop-backup-2026-06-30.noopbak"            // no parseable stamp
        // dateOnly's file date is NEWER than the canonical's embedded stamp, so it must sort first.
        val fileDates = mapOf(
            dateOnly to 1_782_000_600_000L + 60_000L,
            canonical to 0L,
            "notes.txt" to 999L,
        )
        val out = BackupSync.restorablesNewestFirst(
            listOf(canonical, dateOnly, "notes.txt"),
        ) { fileDates[it] ?: 0L }
        // Both .noopbak files present, .txt dropped, newest-first by resolved time.
        assertEquals(listOf(dateOnly, canonical), out.map { it.name })
        // Canonical keeps its embedded stamp; date-only takes the supplied file date.
        assertEquals(1_782_000_600_000L, out.first { it.name == canonical }.timeMs)
        assertEquals(1_782_000_600_000L + 60_000L, out.first { it.name == dateOnly }.timeMs)
    }

    @Test fun restorablesDoNotWidenPrune() {
        // A hand-named .noopbak is restorable but must NEVER become a prune candidate.
        val dateOnly = "noop-backup-2026-06-30.noopbak"
        val canon = (0L until 12L).map { BackupSync.snapshotName(1_782_000_000_000L + it * 60_000L) }
        val pruned = BackupSync.snapshotsToPrune(canon + dateOnly, keep = 10)
        assertFalse(pruned.contains(dateOnly)) // hand-named backup never auto-deleted
    }

    // ── restorableDocsNewestFirst preserves duplicate display names (#852 MAJOR regression) ──

    /**
     * A stand-in for the SAF cursor row. The pure ordering never touches a real [android.net.Uri]
     * (no Robolectric in this project), so a distinct [id] plays the "keeps them apart" role the Uri
     * plays in production [BackupSync.BackupDoc]s.
     */
    private data class FakeDoc(val id: String, val docName: String, val modified: Long)

    @Test fun restorableDocsPreserveTwoDocsSharingADateOnlyName() {
        // SAF trees can hold two DIFFERENT documents with the SAME display name (Drive duplicates, a sync
        // client or a second device dropping the same date-only file twice). Both must survive the listing.
        val a = FakeDoc(id = "docA", docName = "noop-backup-2026-06-30.noopbak", modified = 1_782_000_500_000L)
        val b = FakeDoc(id = "docB", docName = "noop-backup-2026-06-30.noopbak", modified = 1_782_000_600_000L)
        val txt = FakeDoc(id = "note", docName = "notes.txt", modified = 1_782_000_900_000L)
        val out = BackupSync.restorableDocsNewestFirst(
            listOf(a, txt, b),
            { it.docName },
            { it.modified },
        )
        // Both duplicate-named .noopbak docs survive (neither collapsed away), the .txt is dropped, and they
        // sort newest-first by their own modified date - so the newer real backup can never silently vanish.
        assertEquals(listOf("docB", "docA"), out.map { it.id })
    }

    @Test fun restorableDocsTieBreakOnNameWhenTimesEqual() {
        // Equal resolved time (here: two hand-named files sharing a modified ms) orders deterministically by
        // name asc - the same tie-break Swift uses - so the two platforms list identical rows.
        val z = FakeDoc(id = "z", docName = "zeta.noopbak", modified = 1_782_000_000_000L)
        val a = FakeDoc(id = "a", docName = "alpha.noopbak", modified = 1_782_000_000_000L)
        val out = BackupSync.restorableDocsNewestFirst(listOf(z, a), { it.docName }, { it.modified })
        assertEquals(listOf("a", "z"), out.map { it.id })
    }
}
