package com.noop.protocol

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class Whoop5RRTest {
    private fun oracle() = JSONObject(javaClass.classLoader!!.getResourceAsStream("whoop5_rr_oracle.json")!!
        .bufferedReader().use { it.readText() })

    @Test fun allUnsignedWordsMatchExecutedSwiftOracle() {
        val o = oracle()
        var hash = 14695981039346656037uL
        for (ticks in 0..65535) {
            val ms = Whoop5RR.milliseconds(ticks)
            for (byte in listOf(ms and 255, ms shr 8)) hash = (hash xor byte.toULong()) * 1099511628211uL
        }
        assertEquals(o.getString("milliseconds_u16le_fnv1a64"), hash.toString(16).padStart(16, '0'))
        val cases = o.getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            assertEquals(c.getInt("milliseconds"), Whoop5RR.milliseconds(c.getInt("ticks")))
        }
        val policies = o.getJSONArray("policy_cases")
        for (i in 0 until policies.length()) {
            val c = policies.getJSONObject(i)
            fun nullable(key: String) = if (c.isNull(key)) null else c.getString(key)
            assertEquals(c.toString(), c.getBoolean("strict"), Whoop5RR.usesCanonicalSource(
                nullable("model"), nullable("brand"), c.getBoolean("tagged")))
        }
    }

    @Test fun wireBoundsRawUnitsAndExtractedProvenance() {
        val cases = oracle().getJSONArray("wire_cases")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val name = c.getString("name")
            fun ints(key: String): List<Int> = c.getJSONArray(key).let { a -> (0 until a.length()).map { a.getInt(it) } }
            val bytes = c.getString("hex").chunked(2).map { it.toInt(16).toByte() }.toByteArray()
            val f = Framing.parseFrame(bytes, DeviceFamily.WHOOP5)
            assertTrue(name, f.ok)
            assertEquals(name, true, f.crcOk)
            val parsed = if (c.getInt("channel") == 5) decodeHistorical(bytes, DeviceFamily.WHOOP5)!! else f.parsed
            assertEquals(name, ints("raw"), parsed["rr_raw_ticks"])
            assertEquals(name, ints("ms"), parsed["rr_intervals"])
            assertEquals(name, c.getInt("channel"), parsed["rr_source_channel"])
            val rows = if (c.getInt("channel") == 5)
                extractHistoricalStreams(listOf(bytes), 0, 0, DeviceFamily.WHOOP5).rr.map { it.rrMs to it.srcChannel?.code }
            else extractStreams(listOf(f), 0, 0).rr.map { it.rrMs to it.srcChannel?.code }
            assertEquals(name, ints("ms"), rows.map { it.first })
            assertEquals(name, ints("ms").map { c.getInt("channel") }, rows.map { it.second })
        }
    }

    @Test fun pairedCapturedWordsMatchIndependentStandardBleParser() {
        val fixture = JSONObject(javaClass.classLoader!!.getResourceAsStream("whoop5_rr_paired_capture.json")!!
            .bufferedReader().use { it.readText() })
        assertEquals("50.41.1.0", fixture.getString("firmware"))
        val cases = fixture.getJSONArray("cases")
        assertEquals(2, cases.length())
        for (i in 0 until cases.length()) {
            val pair = cases.getJSONObject(i)
            fun bytes(key: String) = pair.getString(key).chunked(2).map { it.toInt(16).toByte() }.toByteArray()
            val standardBytes = bytes("standard_hex")
            assertEquals(0x10, standardBytes[0].toInt())
            val raw = (2 until standardBytes.size step 2).map {
                (standardBytes[it].toInt() and 255) or ((standardBytes[it + 1].toInt() and 255) shl 8)
            }
            assertEquals(pair.getInt("rr_count"), raw.size)
            val standard = com.noop.ble.StandardHeartRate.parse(standardBytes)!!
            val nativeBytes = bytes("native_hex")
            val frame = Framing.parseFrame(nativeBytes, DeviceFamily.WHOOP5)
            assertTrue(frame.ok)
            assertEquals(true, frame.crcOk)
            val historical = pair.getString("kind") == "v18"
            val parsed = if (historical) decodeHistorical(nativeBytes, DeviceFamily.WHOOP5)!! else frame.parsed
            assertEquals(raw, parsed["rr_raw_ticks"])
            assertNotEquals(raw, standard.rr)
            assertEquals(standard.rr, parsed["rr_intervals"])
            val intervals = if (historical)
                extractHistoricalStreams(listOf(nativeBytes), 0, 0, DeviceFamily.WHOOP5).rr.map { it.rrMs }
            else extractStreams(listOf(frame), 0, 0).rr.map { it.rrMs }
            assertEquals(standard.rr, intervals)
        }
    }

    @Test fun transportCodes() {
        assertEquals((1..7).toList(), RrSourceChannel.entries.map { it.code })
    }

    /**
     * The parity contract for the "this night cannot be scored" explanation. The Swift
     * `testLegacyUnscorableNight` carries the SAME rows, so the two platforms cannot start explaining a
     * different set of nights to the wearer.
     */
    @Test fun legacyUnscorableNight() {
        // (name, strictWhoop5, day, firstRecordedDay, firstScorableDay, avgHrv, totalSleepMin, claimed)
        val cases = listOf(
            // A confirmed WHOOP 5 recording since the 1st, labelled era starting on the 10th: the 9th is
            // the case this explains.
            Case("W5, staged night inside the unlabelled era", true, "2026-08-09", "2026-08-01", "2026-08-10", null, 431.0, true),
            // The same night once it scored: there is nothing to explain.
            Case("W5, that night scored", true, "2026-08-09", "2026-08-01", "2026-08-10", 48.0, 431.0, false),
            // Nothing staged, so an empty HRV is far more likely an unworn strap. Never blame the units.
            Case("W5, no night staged", true, "2026-08-09", "2026-08-01", "2026-08-10", null, 0.0, false),
            Case("W5, sleep unknown", true, "2026-08-09", "2026-08-01", "2026-08-10", null, null, false),
            // On and after the first scorable day the general statement stops being true.
            Case("W5, the labelled day itself", true, "2026-08-10", "2026-08-01", "2026-08-10", null, 431.0, false),
            Case("W5, inside the labelled era", true, "2026-08-11", "2026-08-01", "2026-08-10", null, 431.0, false),
            // BEFORE the strap ever recorded: imported history, which never had beats to lose.
            Case("W5, imported night predating the strap", true, "2026-07-30", "2026-08-01", "2026-08-10", null, 431.0, false),
            Case("W5, the first recorded day itself", true, "2026-08-01", "2026-08-01", "2026-08-10", null, 431.0, true),
            // A device that has banked no beats at all can never have lost any to the units.
            Case("W5, nothing recorded", true, "2026-08-09", null, null, null, 431.0, false),
            Case("W5, nothing recorded, empty key", true, "2026-08-09", "", null, null, 431.0, false),
            // Recording, but never synced since the units were corrected: every staged night in the era.
            Case("W5, nothing labelled banked", true, "2026-08-09", "2026-08-01", null, null, 431.0, true),
            Case("W5, nothing labelled, empty key", true, "2026-08-09", "2026-08-01", "", null, 431.0, true),
            // The policy is not applied to this device, so the explanation would be a lie.
            Case("WHOOP 4 night", false, "2026-08-09", "2026-08-01", "2026-08-10", null, 431.0, false),
            // Day keys are yyyy-MM-dd, so string order is date order across a month and a year boundary.
            Case("W5, previous month", true, "2026-07-31", "2026-07-01", "2026-08-01", null, 400.0, true),
            Case("W5, next year", true, "2027-01-01", "2026-01-01", "2026-12-31", null, 400.0, false),
        )
        for (c in cases) {
            assertEquals(
                c.name,
                c.want,
                Whoop5RR.legacyUnscorableNight(c.strict, c.day, c.recorded, c.scorable, c.hrv, c.sleep),
            )
        }
    }

    private data class Case(
        val name: String,
        val strict: Boolean,
        val day: String,
        val recorded: String?,
        val scorable: String?,
        val hrv: Double?,
        val sleep: Double?,
        val want: Boolean,
    )
}
