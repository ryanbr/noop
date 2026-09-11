package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * The WRITE side of #1014: what `exportTo` checks about the file it just produced.
 *
 * This existed as `isWrittenBackupIntact` and was called from exactly one place, the scheduled folder
 * sync, so the manual Settings export never ran it; and nothing on either platform tested it. Both are
 * addressed now, and these are the tests that were missing.
 *
 * Plain JVM: the two halves take a stream and a byte array rather than a Context, so they can be driven
 * without Robolectric. The Uri-taking wrapper is the thin part.
 */
class DataBackupWriteIntegrityTest {

    private val sqliteMagic = "SQLite format 3\u0000".toByteArray(Charsets.ISO_8859_1)

    /** Incompressible body, so the archive has a realistic size to truncate rather than deflating away. */
    private fun incompressible(n: Int): ByteArray {
        val rng = java.util.Random(42)
        return ByteArray(n).also { rng.nextBytes(it) }
    }

    /** A `.noopbak` shaped like the real one: the DB entry FIRST, then settings, as the container
     *  contract requires (older importers stop at the first `.sqlite` entry). */
    private fun backupZip(
        dbBody: ByteArray = sqliteMagic + incompressible(8_192),
        comment: String? = null,
    ): ByteArray {
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zip ->
            if (comment != null) zip.setComment(comment)
            zip.putNextEntry(ZipEntry("noop-backup.sqlite"))
            zip.write(dbBody)
            zip.closeEntry()
            zip.putNextEntry(ZipEntry("noop-settings.json"))
            zip.write("{}".toByteArray())
            zip.closeEntry()
        }
        return out.toByteArray()
    }

    @Test
    fun `a whole backup passes both halves`() {
        val bytes = backupZip()
        assertTrue(DataBackup.backupStreamIsIntact(ByteArrayInputStream(bytes)))
        assertTrue(DataBackup.hasEndOfCentralDirectory(bytes))
    }

    /**
     * The case the write-side check exists for, and the reason it needed a second half.
     *
     * A ZIP's index lives at its END, so a write cut short loses it. `ZipInputStream` never looks for
     * that index: it walks LOCAL entry headers front to back, so a file truncated to a fraction of its
     * length still presents a DB entry whose first sixteen bytes are a perfect SQLite header, and sails
     * through. Asserted in BOTH directions here, because the passing half is the point: the entry check
     * alone would have called this torn file a good backup.
     */
    @Test
    fun `a truncated backup is caught by the tail and missed by the entry check`() {
        val whole = backupZip()
        val torn = whole.copyOfRange(0, whole.size / 3)
        assertTrue(
            "precondition: the entry check cannot see truncation, which is why the tail check exists",
            DataBackup.backupStreamIsIntact(ByteArrayInputStream(torn)),
        )
        assertFalse(DataBackup.hasEndOfCentralDirectory(torn))
    }

    /** Truncation that lands inside the central directory itself still loses the EOCD record. */
    @Test
    fun `a backup missing only its final record is still caught`() {
        val whole = backupZip()
        assertFalse(DataBackup.hasEndOfCentralDirectory(whole.copyOfRange(0, whole.size - 1)))
    }

    /** Not a backup at all: the DB entry is there but holds something that is not a database. */
    @Test
    fun `an entry that is not a database is refused`() {
        val bytes = backupZip(dbBody = "this is not a database".toByteArray())
        assertFalse(DataBackup.backupStreamIsIntact(ByteArrayInputStream(bytes)))
    }

    /** An empty DB entry cannot even hold the magic, so it can never look like a database. */
    @Test
    fun `an empty database entry is refused`() {
        val bytes = backupZip(dbBody = ByteArray(0))
        assertFalse(DataBackup.backupStreamIsIntact(ByteArrayInputStream(bytes)))
    }

    /** A well-formed ZIP carrying everything EXCEPT the database. */
    @Test
    fun `a zip without the database entry is refused`() {
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zip ->
            zip.putNextEntry(ZipEntry("noop-settings.json"))
            zip.write("{}".toByteArray())
            zip.closeEntry()
        }
        val bytes = out.toByteArray()
        assertFalse(DataBackup.backupStreamIsIntact(ByteArrayInputStream(bytes)))
        // Still a valid archive, so the tail half has no complaint. Each half answers its own question.
        assertTrue(DataBackup.hasEndOfCentralDirectory(bytes))
    }

    /** Garbage that was never an archive: refused without throwing, which is the contract. */
    @Test
    fun `something that is not a zip is refused rather than thrown`() {
        val junk = ByteArray(4_096) { it.toByte() }
        assertFalse(DataBackup.backupStreamIsIntact(ByteArrayInputStream(junk)))
        assertFalse(DataBackup.hasEndOfCentralDirectory(junk))
    }

    // ── The verdict table ──────────────────────────────────────────────────────────────────────
    //
    // Separated from the file reading so every branch is pinned here rather than left to a device.

    @Test
    fun `a readable tail with no end record is torn whatever the entry says`() {
        val torn = backupZip().let { it.copyOfRange(0, it.size / 3) }
        assertEquals(DataBackup.BackupWriteVerdict.TORN, DataBackup.writeVerdict(torn, true))
        assertEquals(DataBackup.BackupWriteVerdict.TORN, DataBackup.writeVerdict(torn, false))
        assertEquals(DataBackup.BackupWriteVerdict.TORN, DataBackup.writeVerdict(torn, null))
    }

    /**
     * The reason the verdict is three-valued rather than a Boolean.
     *
     * Failing to READ a file back says nothing about the file. The caller DELETES a torn backup, so
     * answering "torn" here would let a storage provider having a bad moment destroy a backup that was
     * perfectly good. Unverifiable has to be its own answer.
     */
    @Test
    fun `a backup that could not be read back is unverifiable rather than torn`() {
        assertEquals(DataBackup.BackupWriteVerdict.UNVERIFIABLE, DataBackup.writeVerdict(null, null))
        assertEquals(
            DataBackup.BackupWriteVerdict.UNVERIFIABLE,
            DataBackup.writeVerdict(backupZip(), null),
        )
    }

    /** A provider that will not report a size skips the tail half rather than condemning the file. */
    @Test
    fun `an unreadable tail falls back to the entry check`() {
        assertEquals(DataBackup.BackupWriteVerdict.INTACT, DataBackup.writeVerdict(null, true))
        assertEquals(DataBackup.BackupWriteVerdict.TORN, DataBackup.writeVerdict(null, false))
    }

    @Test
    fun `a whole tail and a good entry is the only intact answer`() {
        assertEquals(DataBackup.BackupWriteVerdict.INTACT, DataBackup.writeVerdict(backupZip(), true))
        assertEquals(DataBackup.BackupWriteVerdict.TORN, DataBackup.writeVerdict(backupZip(), false))
    }

    /** Shorter than the signature it is looking for: answers false rather than reading off the end. */
    @Test
    fun `a tail shorter than the signature is refused`() {
        assertFalse(DataBackup.hasEndOfCentralDirectory(ByteArray(0)))
        assertFalse(DataBackup.hasEndOfCentralDirectory(byteArrayOf(0x50, 0x4B)))
    }

    /**
     * The record sits 22 bytes from the end only when the archive carries no comment, so the search
     * scans rather than checking a fixed offset. A comment is legal in any ZIP we might be handed back.
     */
    @Test
    fun `the record is found behind a trailing comment`() {
        assertTrue(DataBackup.hasEndOfCentralDirectory(backupZip(comment = "x".repeat(300))))
    }

    /** Bytes merely APPENDED to a finished archive are not a comment: the record's own length field
     *  still says zero, so it no longer accounts for what follows and the file is refused. */
    @Test
    fun `bytes appended after the record are not a comment`() {
        assertFalse(DataBackup.hasEndOfCentralDirectory(backupZip() + ByteArray(300) { 0x41 }))
    }
}
