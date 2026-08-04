package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset

/**
 * #1002 - which local civil day an imported Health Connect record is keyed under.
 *
 * The importer bucketed every record with `ZoneId.systemDefault()`, the phone's zone at import time,
 * and never read the `startZoneOffset` / `zoneOffset` the record carries. `WINDOW_YEARS` is 10, so a
 * single import keys a decade of history that way.
 *
 * These pin BOTH halves of that, because the two are easy to conflate and only one was ever broken:
 *
 *  - DST was already correct and must stay correct. `ZoneId.systemDefault()` returns a REGION id, and
 *    `LocalDate.ofInstant` resolves it with the rules in force AT THE INSTANT — so a January instant
 *    is keyed with January's offset even when the import runs in July. A fix that reached for a fixed
 *    current offset would BREAK this, so it is pinned as a regression guard rather than as a bug.
 *  - Travel and relocation were broken, and are what the offset actually fixes.
 */
class HealthConnectZoneOffsetTest {

    private val london = ZoneId.of("Europe/London")   // region id: +00:00 winter, +01:00 summer
    private val tokyo = ZoneOffset.ofHours(9)

    // --- the half that was never broken -----------------------------------------------------------

    /**
     * A winter instant keyed while the phone sits in summer. 23:30 UTC in January is 23:30 local in
     * London (UTC+0), so it belongs to the 15th. Pinning the current +01:00 instead would call it the
     * 16th — the failure this test exists to prevent a "fix" from introducing.
     */
    @Test fun regionZoneKeysAWinterInstantWithTheWinterOffset() {
        val winter = Instant.parse("2026-01-15T23:30:00Z")
        assertEquals("2026-01-15", HealthConnectImporter.localDayKey(winter, null, london))
        // What pinning the July offset would have produced, stated explicitly so the contrast is legible.
        assertEquals("2026-01-16", HealthConnectImporter.localDayKey(winter, ZoneOffset.ofHours(1), london))
    }

    /** The same clock time in July IS +01:00, so 23:30 UTC is 00:30 local and rolls to the next day. */
    @Test fun regionZoneKeysASummerInstantWithTheSummerOffset() {
        val summer = Instant.parse("2026-07-15T23:30:00Z")
        assertEquals("2026-07-16", HealthConnectImporter.localDayKey(summer, null, london))
    }

    // --- the half that was broken -----------------------------------------------------------------

    /**
     * The regression itself. A drink logged at 01:30 on the 16th in Tokyo is the 16th to the person who
     * logged it. Re-resolved in London it is 16:30 on the 15th, so the record lands a day early.
     */
    @Test fun aRecordFromAnotherZoneKeepsItsOwnDay() {
        val recordedInTokyo = Instant.parse("2026-01-15T16:30:00Z")   // 2026-01-16 01:30 +09:00
        assertEquals("2026-01-16", HealthConnectImporter.localDayKey(recordedInTokyo, tokyo, london))
        // The old behaviour, for contrast: the phone's zone wins and the day moves.
        assertEquals("2026-01-15", HealthConnectImporter.localDayKey(recordedInTokyo, null, london))
    }

    /**
     * The offset only matters where it changes the civil day. A midday record is the same day in both
     * zones, so the fix must be a no-op there rather than shifting well-keyed history around.
     */
    @Test fun aMiddayRecordIsUnaffectedByWhichZoneResolvesIt() {
        val midday = Instant.parse("2026-01-15T12:00:00Z")
        assertEquals("2026-01-15", HealthConnectImporter.localDayKey(midday, null, london))
        assertEquals("2026-01-15", HealthConnectImporter.localDayKey(midday, ZoneOffset.UTC, london))
    }

    /**
     * Health Connect's offset fields are optional and many writers leave them null. A null must fall
     * back to the phone's zone, i.e. behave exactly as the importer did before — otherwise the change
     * would alter every record that carries no offset, which is most of them.
     */
    @Test fun aNullOffsetFallsBackToThePhoneZone() {
        // 23:30 UTC on 1 June is 00:30 on the 2nd in London (+01:00 in summer). Asserting the rolled
        // day proves the fallback really applies the phone's zone, rather than quietly keying in UTC.
        val t = Instant.parse("2026-06-01T23:30:00Z")
        assertEquals("2026-06-02", HealthConnectImporter.localDayKey(t, null, london))
    }

    /**
     * A negative offset, since the fix must not assume the traveller went east. 02:00 UTC is still the
     * previous evening in Los Angeles.
     */
    @Test fun aWesternOffsetKeysToThePreviousDay() {
        val t = Instant.parse("2026-01-16T02:00:00Z")               // 2026-01-15 18:00 -08:00
        assertEquals("2026-01-15", HealthConnectImporter.localDayKey(t, ZoneOffset.ofHours(-8), london))
        assertEquals("2026-01-16", HealthConnectImporter.localDayKey(t, null, london))
    }

    /**
     * The re-import symptom from the report: the same record keyed from two different phone zones gives
     * two different days when the offset is ignored, and one stable day when it is not. That instability
     * is what surfaces as a doubled day beside a gap rather than as a visibly wrong timestamp.
     */
    @Test fun theRecordsOwnOffsetIsStableAcrossPhoneRelocation() {
        val t = Instant.parse("2026-01-15T16:30:00Z")
        val sydney = ZoneId.of("Australia/Sydney")
        assertEquals(
            HealthConnectImporter.localDayKey(t, tokyo, london),
            HealthConnectImporter.localDayKey(t, tokyo, sydney),
        )
        // Without the offset the same instant keys differently depending on where the phone is.
        assertEquals("2026-01-15", HealthConnectImporter.localDayKey(t, null, london))
        assertEquals("2026-01-16", HealthConnectImporter.localDayKey(t, null, sydney))
    }
}
