package com.noop.data

import androidx.sqlite.db.SupportSQLiteDatabase
import java.lang.reflect.Proxy
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * #2371: the WHOOP 5 500 ms fill beat is MARKED `tsSuspect = 1` when the strap's heart rate in its second is
 * under 100 bpm. The statement text is the cross-platform contract, pinned here by the same literals as the
 * Swift `Whoop5RrFillTests`; the rows it marks are tested against SQLite in [Whoop5RRSqliteTest].
 */
class Whoop5RrFillTest {

    @Test
    fun fillStatementsArePinned() {
        val condition = "rrMs = 500 AND srcChannel IN (5, 7) AND tsSuspect IS NULL AND EXISTS (SELECT 1 FROM " +
            "hrSample h WHERE h.deviceId = rrInterval.deviceId AND h.ts = rrInterval.ts AND h.bpm < 100)"
        assertEquals("UPDATE rrInterval SET tsSuspect = 1 WHERE deviceId = " +
            ":deviceId AND ts >= :fromTs AND ts <= :toTs AND " + condition, WHOOP5_RR_FILL_FLAG_SQL)
        assertEquals("UPDATE rrInterval SET tsSuspect = 1 WHERE " + condition, WHOOP5_RR_FILL_MIGRATION_SQL)
    }

    /** The migration runs exactly the pinned statement, and nothing else: data only, no schema change. */
    @Test
    fun migration40to41RunsOnlyTheFillStatement() {
        val executed = mutableListOf<String>()
        val db = Proxy.newProxyInstance(
            SupportSQLiteDatabase::class.java.classLoader,
            arrayOf(SupportSQLiteDatabase::class.java),
        ) { _, method, args ->
            if (method.name == "execSQL" && args?.size == 1) executed += args[0] as String
            else error("unexpected call during the migration: ${method.name}")
            Unit
        } as SupportSQLiteDatabase

        WhoopDatabase.MIGRATION_40_41.migrate(db)

        assertEquals(40, WhoopDatabase.MIGRATION_40_41.startVersion)
        assertEquals(41, WhoopDatabase.MIGRATION_40_41.endVersion)
        assertEquals(listOf(WHOOP5_RR_FILL_MIGRATION_SQL), executed)
    }
}
