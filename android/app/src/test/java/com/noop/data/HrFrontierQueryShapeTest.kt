package com.noop.data

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * #908 — `latestHrSampleTs` must keep the per-arm `SELECT MAX(ts)` shape that lets SQLite's MIN/MAX
 * optimization fire.
 *
 * The old form asked for one `MAX(ts)` over a `UNION ALL` of the two timestamp columns. That is the same
 * answer and a very different plan: the optimization only applies to a bare `SELECT MAX(col)` that can
 * seek the last matching index entry, so wrapping the columns in a compound subquery makes the planner
 * materialize it and walk every index entry for the device. Measured on the Apple twin at 4.3–5.8 s
 * against a 746 MB store versus 0.01–0.07 s for the per-arm form.
 *
 * That is invisible to every behavioural test — both shapes return the identical value, including for a
 * device with no rows — so the only thing standing between this and a well-meaning "simplification" back
 * to the readable one-liner is a test that reads the query itself.
 *
 * It has to audit the SOURCE rather than reflect over the annotation: Room's `@Query` is `CLASS`-retention,
 * so it is not visible at runtime. The behavioural half is the Swift twin's `LatestSampleTests`, which CI
 * runs against a real SQLite; this side has no driver on the unit-test classpath (see
 * [DeepCaptureMigrationTest]). Follows the source-locating pattern of
 * [com.noop.ui.ResolvedSeriesCallSiteAuditTest].
 */
class HrFrontierQueryShapeTest {

    /**
     * The DAO source, tolerant of the test host's working dir — verified to resolve from the module dir
     * (Gradle's default), the `android/` project dir, and the repo root.
     *
     * FAILS rather than skipping when it cannot be found, which is the opposite of what a source audit
     * usually does. [com.noop.ui.ResolvedSeriesCallSiteAuditTest] assumes-and-skips so an unlocatable tree
     * does not green-wash its census, and that is right for a census: skipping says "not checked this run".
     * Here it would say something else. This test is the ONLY thing standing between the query and a
     * silent revert — both shapes return the same value, so no behavioural test can tell them apart — and
     * a skip is reported by JUnit as a pass. Verified: with no source on the path the assume form printed
     * `OK (2 tests)`, indistinguishable from the guard actually holding. A loud failure is the honest
     * signal that the guard is not guarding.
     */
    private fun daoSource(): String {
        val userDir = File(System.getProperty("user.dir") ?: ".")
        val rel = "src/main/java/com/noop/data/WhoopDao.kt"
        val found = listOf(File(userDir, rel), File(userDir, "app/$rel"), File(userDir, "android/app/$rel"))
            .firstOrNull { it.isFile }
        assertNotNull(
            "WhoopDao.kt not found from user.dir=$userDir — this guard cannot run, and a skip here reads " +
                "as a pass. Add this host's working dir to the list rather than letting it slide.",
            found,
        )
        return found!!.readText()
    }

    /** The `@Query` body attached to `latestHrSampleTs`, string fragments joined, comments excluded. */
    private fun latestHrQuery(src: String): String {
        val decl = src.indexOf("suspend fun latestHrSampleTs(")
        assertTrue("latestHrSampleTs not found — was it renamed?", decl > 0)
        val annotationStart = src.lastIndexOf("@Query(", decl)
        assertTrue("no @Query above latestHrSampleTs", annotationStart > 0)
        val block = src.substring(annotationStart, decl)
        return Regex("\"([^\"]*)\"").findAll(block).joinToString("") { it.groupValues[1] }
    }

    @Test
    fun latestHrSampleTsKeepsThePerArmMaxShape() {
        val q = latestHrQuery(daoSource()).replace(Regex("\\s+"), " ")

        // Each stream gets its own seekable MAX...
        assertTrue(
            "hrSample arm must be its own SELECT MAX(ts): $q",
            q.contains("(SELECT MAX(ts) FROM hrSample WHERE deviceId = :deviceId)"),
        )
        assertTrue(
            "ppgHrSample arm must be its own SELECT MAX(ts): $q",
            q.contains("(SELECT MAX(ts) FROM ppgHrSample WHERE deviceId = :deviceId)"),
        )
        // ...and neither may go back to feeding a bare column into the compound select, which is the
        // exact shape that defeats the optimization.
        assertFalse(
            "a bare `SELECT ts FROM <table>` arm defeats the MIN/MAX optimization: $q",
            Regex("SELECT ts FROM (hrSample|ppgHrSample)").containsMatchIn(q),
        )
    }

    /**
     * Both arms carry `AS m`. Only the first arm's column names survive a compound select in SQLite, so
     * the second alias is redundant to the engine — it is there because Room verifies queries at compile
     * time and an unnamed second arm is the kind of thing that fails the build rather than a test.
     */
    @Test
    fun bothArmsAreAliasedForRoomsCompileTimeVerifier() {
        val q = latestHrQuery(daoSource()).replace(Regex("\\s+"), " ")
        assertTrue("outer aggregate must select the alias: $q", q.contains("SELECT MAX(m) FROM"))
        assertTrue("both arms should be aliased AS m: $q", Regex("AS m\\b").findAll(q).count() == 2)
    }
}
