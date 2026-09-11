package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * #1014 defence-in-depth: golden vectors for the pure quick_check verdict, mirrored byte-for-byte
 * by the Apple side's `DatabaseIntegrityTests.testVerdictGoldenVectors` (WhoopStore package), so
 * both platforms agree on what "healthy" means. The `PRAGMA quick_check(1)` execution itself needs
 * a real Android SQLite (android.database.sqlite is a throwing stub on the plain JVM) and lives
 * behind [DataBackup]'s private read-only wrapper; the classification pinned here is the part that
 * decides accept vs refuse for the import/export integrity gates, so it is what gets the
 * cross-platform vectors.
 */
class DataBackupIntegrityTest {

    @Test fun healthySingleOkRowPasses() {
        // SQLite emits the canonical row lowercase; accept any case (matches the Apple side).
        assertNull(DataBackup.quickCheckVerdict(listOf("ok")))
        assertNull(DataBackup.quickCheckVerdict(listOf("OK")))
    }

    @Test fun complaintRowComesBackVerbatim() {
        // Never a fabricated summary - the caller surfaces SQLite's own words.
        assertEquals(
            "*** in database main ***\nPage 5 is never used",
            DataBackup.quickCheckVerdict(listOf("*** in database main ***\nPage 5 is never used")),
        )
        assertEquals(
            "row 12 missing from index sleepIdx",
            DataBackup.quickCheckVerdict(listOf("row 12 missing from index sleepIdx")),
        )
    }

    @Test fun silenceIsNotHealth() {
        // quick_check always answers; an empty result means the query was swallowed - refuse.
        assertEquals("quick_check returned no verdict", DataBackup.quickCheckVerdict(emptyList()))
    }

    @Test fun multipleRowsCanNeverMeanHealthy() {
        assertEquals(
            "Page 9 is never used",
            DataBackup.quickCheckVerdict(listOf("ok", "Page 9 is never used")),
        )
    }

    // ── readableComplaint: the verdict is forensic, this is what a person is shown ──

    /** The reported shape. The verdict is ONE row carrying SQLite's banner, a newline, and then the
     *  only half that says anything. Shown whole it spends the line on the banner, which is what a
     *  truncating Toast displayed. */
    @Test fun theBannerIsDroppedAndTheDiagnosisKept() {
        assertEquals(
            "Page 5 is never used",
            DataBackup.readableComplaint("*** in database main ***\nPage 5 is never used"),
        )
    }

    /** Captured from a REAL corrupted SQLite file (pages scribbled over, header left intact) rather
     *  than invented: quick_check(1) answers with ONE row holding the banner, a newline, and the
     *  diagnosis. This is the exact shape the reported Toast was truncating. */
    @Test fun theRealQuickCheckShapeYieldsItsDiagnosis() {
        assertEquals(
            "Tree 2 page 7: btreeInitPage() returns error code 11",
            DataBackup.readableComplaint("*** in database main ***\nTree 2 page 7: btreeInitPage() returns error code 11"),
        )
    }

    /** An attached database names itself in the banner, so the match cannot be on "main" alone. */
    @Test fun anyDatabaseNameInTheBannerIsDropped() {
        assertEquals(
            "Page 9 is never used",
            DataBackup.readableComplaint("*** in database temp ***\nPage 9 is never used"),
        )
    }

    /** Banner and nothing else: showing an empty parenthesis would be worse than showing the banner,
     *  so the raw verdict survives as the fallback. */
    @Test fun aVerdictOfNothingButBannerIsStillShown() {
        assertEquals("*** in database main ***", DataBackup.readableComplaint("*** in database main ***"))
    }

    /** A verdict with no banner at all is already the diagnosis and passes through untouched. */
    @Test fun aPlainVerdictIsUnchanged() {
        assertEquals(
            "row 12 missing from index sleepIdx",
            DataBackup.readableComplaint("row 12 missing from index sleepIdx"),
        )
    }

    @Test fun severalComplaintsAreJoinedOntoOneLine() {
        assertEquals(
            "Page 5 is never used; Page 9 is never used",
            DataBackup.readableComplaint("*** in database main ***\nPage 5 is never used\nPage 9 is never used"),
        )
    }

    /** A nonsense limit must not throw: take(-1) is an exception in Kotlin and prefix(-1) traps in
     *  Swift, and a display helper is the last place that should be able to crash a failure path. */
    @Test fun adegenerateLimitStillReturnsSomething() {
        assertEquals(1, DataBackup.readableComplaint("*** in database main ***\nPage 5", limit = 0).length)
        assertEquals(1, DataBackup.readableComplaint("*** in database main ***\nPage 5", limit = -5).length)
    }

    /** Capped, because this rides inside a sentence that has to stay readable. */
    @Test fun anOverlongComplaintIsCappedWithAnEllipsis() {
        val out = DataBackup.readableComplaint("*** in database main ***\n" + "x".repeat(500), limit = 40)
        assertEquals(40, out.length)
        assertTrue(out.endsWith("\u2026"))
    }
}
