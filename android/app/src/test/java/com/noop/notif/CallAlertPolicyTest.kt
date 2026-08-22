package com.noop.notif

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CallAlertPolicyTest {
    private val policy = CallAlertPolicy(repeatIntervalMs = 6_000L, maxBuzzes = 6)

    @Test
    fun defaultsAreSuitableForIncomingCalls() {
        val defaults = CallAlertPolicy()
        assertEquals(6_000L, defaults.repeatIntervalMs)
        assertEquals(6, defaults.maxBuzzes)
    }

    @Test
    fun buzzesImmediatelyForActiveCall() {
        assertTrue(policy.shouldBuzz(active = true, buzzCount = 0, lastBuzzAtMs = null, nowMs = 1_000L))
    }

    @Test
    fun throttlesUntilRepeatInterval() {
        assertFalse(policy.shouldBuzz(active = true, buzzCount = 1, lastBuzzAtMs = 1_000L, nowMs = 6_999L))
        assertTrue(policy.shouldBuzz(active = true, buzzCount = 1, lastBuzzAtMs = 1_000L, nowMs = 7_000L))
    }

    @Test
    fun stopsAfterMaxBuzzesOrInactiveCall() {
        assertFalse(policy.shouldBuzz(active = true, buzzCount = 6, lastBuzzAtMs = 1_000L, nowMs = 20_000L))
        assertFalse(policy.shouldBuzz(active = false, buzzCount = 0, lastBuzzAtMs = null, nowMs = 1_000L))
        assertEquals(null, policy.nextDelayMs(buzzCount = 6))
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsZeroRepeatInterval() {
        CallAlertPolicy(repeatIntervalMs = 0L)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsZeroBuzzLimit() {
        CallAlertPolicy(maxBuzzes = 0)
    }
}
