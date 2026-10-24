package com.noop.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Test
import java.security.MessageDigest

/**
 * Parity tests for [BackfillPolicy] — the port of the Swift `BackfillPolicy`
 * (Strand/BLE/BackfillPolicy.swift). They pin the empty-streak backoff curve and the per-trigger floors
 * so Android and macOS throttle historical offloads identically (the cross-platform parity contract),
 * and cover the battery point this port exists for: a not-banking strap stops being re-offloaded every
 * 15 min.
 */
class BackfillPolicyTest {

    /** Verbatim SHA-256 from the compiled production Swift helper over these 5,760 decisions. */
    @Test
    fun powerSavingDecisionOracle() {
        val times = listOf(-1.0, 0.0, 89.0, 90.0, 479.0, 480.0, 899.0, 900.0,
            1799.0, 1800.0, 2699.0, 2700.0, 3599.0, 3600.0, 7199.0, 7200.0)
        val bits = StringBuilder()
        for (trigger in BackfillTrigger.values()) {
            for (last in listOf(null, 0.0)) {
                for (now in times) {
                    for (streak in listOf(0, 2, 3, 4, 99)) {
                        for (untrusted in listOf(false, true)) {
                            for (floor in listOf(0.0, 2700.0, 3600.0)) {
                                val run = BackfillPolicy.shouldRun(trigger, now, last, streak, untrusted, floor)
                                bits.append(if (run) '1' else '0')
                            }
                        }
                    }
                }
            }
        }
        assertEquals(5760, bits.length)
        val digest = MessageDigest.getInstance("SHA-256").digest(bits.toString().toByteArray(Charsets.US_ASCII))
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
        assertEquals("66d75a86f19bc42e51993cc47554f4cc514267e071953b79670a3b771c3766f9", digest)
    }

    @Test
    fun lowRefreshCannotBeBypassedByStrapEvents() {
        var last = 0.0
        val starts = mutableListOf<Int>()
        for (now in 90..7200 step 90) {
            if (BackfillPolicy.shouldRun(BackfillTrigger.STRAP, now.toDouble(), last,
                    automaticFloorSeconds = 3600.0)) {
                starts.add(now)
                last = now.toDouble()
            }
        }
        assertEquals(listOf(3600, 7200), starts)
    }

    @Test
    fun powerSavingFloorsBothAutomaticTriggersAtTheBoundary() {
        for (trigger in listOf(BackfillTrigger.STRAP, BackfillTrigger.PERIODIC)) {
            for (floor in listOf(2700.0, 3600.0)) {
                assertFalse(BackfillPolicy.shouldRun(trigger, floor - 1, 0.0, automaticFloorSeconds = floor))
                assertTrue(BackfillPolicy.shouldRun(trigger, floor, 0.0, automaticFloorSeconds = floor))
            }
        }
        assertTrue(BackfillPolicy.shouldRun(BackfillTrigger.MANUAL, 600.0, 0.0, automaticFloorSeconds = 3600.0))
        assertFalse(BackfillPolicy.shouldRun(BackfillTrigger.STRAP, 3600.0, 600.0, automaticFloorSeconds = 3600.0))
        assertTrue(BackfillPolicy.shouldRun(BackfillTrigger.STRAP, 4200.0, 600.0, automaticFloorSeconds = 3600.0))
    }

    @Test
    fun powerSavingNeverDelaysRecoveryOrAnActiveDrain() {
        for (trigger in listOf(BackfillTrigger.CONNECT, BackfillTrigger.FOREGROUND,
                BackfillTrigger.MANUAL, BackfillTrigger.AUTO_CONTINUE)) {
            assertTrue(BackfillPolicy.shouldRun(trigger, 90.0, 0.0, emptyStreak = 99,
                clockUntrusted = true, automaticFloorSeconds = 3600.0))
        }
        assertTrue(BackfillPolicy.shouldRun(BackfillTrigger.STRAP, 1.0, null, automaticFloorSeconds = 3600.0))
    }

    @Test
    fun powerSavingComposesWithEmptyBackoffAndUntrustedClock() {
        assertFalse(BackfillPolicy.shouldRun(BackfillTrigger.PERIODIC, 2700.0, 0.0,
            emptyStreak = 5, automaticFloorSeconds = 2700.0))
        assertTrue(BackfillPolicy.shouldRun(BackfillTrigger.PERIODIC, 3600.0, 0.0,
            emptyStreak = 5, automaticFloorSeconds = 2700.0))
        assertTrue(BackfillPolicy.shouldRun(BackfillTrigger.STRAP, 3600.0, 0.0,
            emptyStreak = 99, automaticFloorSeconds = 3600.0))
        assertFalse(BackfillPolicy.shouldRun(BackfillTrigger.STRAP, 7200.0, 0.0,
            clockUntrusted = true, automaticFloorSeconds = 3600.0))
    }

    // The first-ever call (no prior backfill) always runs, whatever the trigger.
    @Test
    fun nullLastAlwaysRuns() {
        for (t in BackfillTrigger.values()) {
            assertTrue(t.name, BackfillPolicy.shouldRun(t, nowSeconds = 1000.0, lastBackfillAtSeconds = null))
        }
    }

    // MANUAL + AUTO_CONTINUE are never floored (run even 1s after the last kick), and are immune to the
    // empty-streak backoff and the untrusted-clock skip — a user or an active drain is never delayed.
    @Test
    fun manualAndAutoContinueBypassEverything() {
        assertTrue(BackfillPolicy.shouldRun(BackfillTrigger.MANUAL, 1001.0, 1000.0))
        assertTrue(BackfillPolicy.shouldRun(BackfillTrigger.AUTO_CONTINUE, 1001.0, 1000.0))
        assertTrue(
            BackfillPolicy.shouldRun(
                BackfillTrigger.MANUAL, 1001.0, 1000.0, emptyStreak = 9, clockUntrusted = true,
            ),
        )
        assertTrue(
            BackfillPolicy.shouldRun(
                BackfillTrigger.AUTO_CONTINUE, 1001.0, 1000.0, emptyStreak = 9, clockUntrusted = true,
            ),
        )
    }

    // CONNECT/FOREGROUND use the 90s event floor and NEVER back off on empties.
    @Test
    fun connectUsesEventFloorNoBackoff() {
        assertFalse(BackfillPolicy.shouldRun(BackfillTrigger.CONNECT, 1089.0, 1000.0)) // 89s < 90
        assertTrue(BackfillPolicy.shouldRun(BackfillTrigger.CONNECT, 1090.0, 1000.0)) // 90s
        assertTrue(BackfillPolicy.shouldRun(BackfillTrigger.FOREGROUND, 1090.0, 1000.0))
        // A big empty streak does NOT stretch the event floor for CONNECT/FOREGROUND.
        assertTrue(BackfillPolicy.shouldRun(BackfillTrigger.CONNECT, 1090.0, 1000.0, emptyStreak = 9))
    }

    // PERIODIC: 900s base floor, no backoff below the threshold.
    @Test
    fun periodicBaseFloor() {
        assertFalse(BackfillPolicy.shouldRun(BackfillTrigger.PERIODIC, 1899.0, 1000.0)) // 899s < 900
        assertTrue(BackfillPolicy.shouldRun(BackfillTrigger.PERIODIC, 1900.0, 1000.0)) // 900s
        // streak 2 is below EMPTY_BACKOFF_THRESHOLD (3) => still the 1x (900s) floor.
        assertTrue(BackfillPolicy.shouldRun(BackfillTrigger.PERIODIC, 1900.0, 1000.0, emptyStreak = 2))
    }

    // PERIODIC empty-streak backoff curve: streak 3 -> 2x (1800s), streak 4 -> 4x (3600s), streak>=4 capped.
    @Test
    fun periodicBackoffCurveMatchesSwift() {
        // streak 3 => 2x => floor 1800s
        assertFalse(BackfillPolicy.shouldRun(BackfillTrigger.PERIODIC, 1000.0 + 1799.0, 1000.0, emptyStreak = 3))
        assertTrue(BackfillPolicy.shouldRun(BackfillTrigger.PERIODIC, 1000.0 + 1800.0, 1000.0, emptyStreak = 3))
        // streak 4 => 4x => floor 3600s (1 hr)
        assertFalse(BackfillPolicy.shouldRun(BackfillTrigger.PERIODIC, 1000.0 + 3599.0, 1000.0, emptyStreak = 4))
        assertTrue(BackfillPolicy.shouldRun(BackfillTrigger.PERIODIC, 1000.0 + 3600.0, 1000.0, emptyStreak = 4))
        // streak 9 => 2^7 capped at 4x => still 3600s, not runaway.
        assertFalse(BackfillPolicy.shouldRun(BackfillTrigger.PERIODIC, 1000.0 + 3599.0, 1000.0, emptyStreak = 9))
        assertTrue(BackfillPolicy.shouldRun(BackfillTrigger.PERIODIC, 1000.0 + 3600.0, 1000.0, emptyStreak = 9))
    }

    // STRAP mirrors PERIODIC's backoff but off the 90s event floor: streak 4 => 4x => 360s (~6 min).
    @Test
    fun strapEventFloorBacksOff() {
        assertTrue(BackfillPolicy.shouldRun(BackfillTrigger.STRAP, 1090.0, 1000.0)) // 90s, no streak
        assertFalse(BackfillPolicy.shouldRun(BackfillTrigger.STRAP, 1000.0 + 359.0, 1000.0, emptyStreak = 4))
        assertTrue(BackfillPolicy.shouldRun(BackfillTrigger.STRAP, 1000.0 + 360.0, 1000.0, emptyStreak = 4))
    }

    // An untrusted (future-dated) clock SKIPS the automatic triggers entirely, but never the event/manual
    // ones — so the per-connection pass still re-checks and a self-corrected clock resumes.
    @Test
    fun untrustedClockSkipsAutomaticOnly() {
        assertFalse(BackfillPolicy.shouldRun(BackfillTrigger.PERIODIC, 100_000.0, 1000.0, clockUntrusted = true))
        assertFalse(BackfillPolicy.shouldRun(BackfillTrigger.STRAP, 100_000.0, 1000.0, clockUntrusted = true))
        assertTrue(BackfillPolicy.shouldRun(BackfillTrigger.CONNECT, 1090.0, 1000.0, clockUntrusted = true))
        assertTrue(BackfillPolicy.shouldRun(BackfillTrigger.FOREGROUND, 1090.0, 1000.0, clockUntrusted = true))
        assertTrue(BackfillPolicy.shouldRun(BackfillTrigger.MANUAL, 1001.0, 1000.0, clockUntrusted = true))
    }
}
