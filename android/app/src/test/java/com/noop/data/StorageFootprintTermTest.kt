package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1911: the per-column size expression and the table list, pinned without a Room runtime.
 *
 * The estimate itself needs an open database and the JVM unit tests have none, so what is reachable here
 * is the part that actually drifts: the SQL shape, and the key set that has to match Apple's verbatim for
 * the two meta.json blocks to be comparable at all.
 */
class StorageFootprintTermTest {

    /**
     * `typeof()` at runtime, not the declared type, and byte length via `CAST(... AS BLOB)`.
     *
     * Both matter and both are easy to "simplify" away. SQLite is dynamically typed, so a column declared
     * INTEGER can hold text; and `length()` on text counts CHARACTERS while the store spends bytes, so a
     * multi-byte value would be under-counted by exactly the amount that makes it worth counting.
     */
    @Test fun `the term measures bytes at runtime, not declared width`() {
        val term = StorageFootprint.rowSizeTerm("samples")
        assertTrue(term, term.contains("typeof(`samples`)"))
        assertTrue(term, term.contains("length(CAST(`samples` AS BLOB))"))
        assertTrue(term, term.contains("IS NULL THEN 0"))
        assertTrue("a numeric column still costs something", term.contains("ELSE 8"))
    }

    /**
     * The key set is a cross-platform contract: Apple pins it in `WhoopStoreTests.ReadTests`, and the two
     * meta.json blocks are only comparable while both sides report the same keys.
     */
    @Test fun `the table list matches the Apple key set`() {
        val expected = listOf(
            "hr", "rr", "events", "battery", "spo2", "skinTemp", "resp", "gravity",
            "steps", "ppgHr", "sleepState", "ppgWaveform", "ecgWaveform", "v18Aux",
        )
        assertEquals(expected.sorted(), StorageFootprint.STORAGE_TABLES.map { it.first }.sorted())
        // BOTH blob tables, named rather than counted: a footprint that omits one cannot attribute the
        // bytes it was collected to explain, and the ECG table (#2847) is the wider miss of the two.
        for (blob in listOf("ppgWaveformSample", "ecgWaveformSample")) {
            assertTrue("the blob table $blob must be in the list at all",
                       StorageFootprint.STORAGE_TABLES.any { it.second == blob })
        }
    }
}
