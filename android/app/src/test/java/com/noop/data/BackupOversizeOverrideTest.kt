package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The oversize restore override (#1807).
 *
 * The cap itself cannot be exercised end-to-end here — proving it needs a >2 GiB fixture — so what is
 * pinned is the decision that governs it, plus the shape of the result the UI keys on. The behaviour
 * these guard is not cosmetic: NOOP wrote archives it then refused to read, and the refusal arrived at
 * the one moment the original was already gone.
 */
class BackupOversizeOverrideTest {

    /** Default enforces the guard; the override lifts it entirely, for a file the user chose. */
    @Test
    fun `the cap is enforced by default and lifted only on request`() {
        assertEquals(DataBackup.MAX_BACKUP_SQLITE_BYTES, DataBackup.sqliteCap(false))
        assertEquals(Long.MAX_VALUE, DataBackup.sqliteCap(true))
    }

    /** 2 GiB exactly. Pinned because it is `2^31`, so moving it may not be free. */
    @Test
    fun `the ceiling is two gibibytes`() {
        assertEquals(2_147_483_648L, DataBackup.MAX_BACKUP_SQLITE_BYTES)
    }

    /**
     * `TooLarge` is a separate result from `Failed` so the caller can offer a way through rather than
     * ending on a message the user can do nothing about, and it carries the limit so the caller never
     * has to restate the number.
     */
    @Test
    fun `a size refusal is its own result and carries the limit`() {
        val r: DataBackup.ImportResult =
            DataBackup.ImportResult.TooLarge("too large", DataBackup.MAX_BACKUP_SQLITE_BYTES)
        assertTrue("must not be indistinguishable from a generic failure",
            r !is DataBackup.ImportResult.Failed)
        assertEquals(DataBackup.MAX_BACKUP_SQLITE_BYTES, (r as DataBackup.ImportResult.TooLarge).limitBytes)
    }

    /** An export past the ceiling reports it; one under it does not, and neither is a failure. */
    @Test
    fun `export outcome flags only a database past the ceiling`() {
        val cap = DataBackup.MAX_BACKUP_SQLITE_BYTES
        assertTrue(DataBackup.ExportOutcome(cap + 1, cap + 1 > cap, cap).overRestoreCeiling)
        assertTrue(!DataBackup.ExportOutcome(cap, cap > cap, cap).overRestoreCeiling)
    }
}
