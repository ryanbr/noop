package com.noop.ble

import com.noop.protocol.DeviceFamily
import org.junit.Assert.*
import org.junit.Test

class OffloadSessionTest {
    @Test fun irrelevantTrafficCannotKeepWhoop4Alive() {
        val session = OffloadSession(60_000)
        val token = session.begin(0, null)!!
        // Received frames (including EVENT/CONSOLE/data) have not committed a durable cursor.
        for (now in 1_000L..120_000L step 1_000) {
            session.frameReceived(token, now, DeviceFamily.WHOOP4)
            assertEquals((60_000L - now).coerceAtLeast(0), session.remainingMs(token, now))
        }
    }

    @Test fun productiveOffloadCanRunForHours() {
        val session = OffloadSession(60_000)
        val token = session.begin(0, null)!!
        for (chunk in 1L..10_000L) {
            val now = chunk * 10_000
            assertTrue(session.remainingMs(token, now)!! > 0)
            session.cursorCommitted(token, chunk, now)
        }
        assertEquals(60_000L, session.remainingMs(token, 100_000_000))
    }

    @Test fun replayedCursorAndNoCursorSentinelDoNotExtendDeadline() {
        val session = OffloadSession(60_000)
        val token = session.begin(0, 42)!!
        session.cursorCommitted(token, 42, 30_000)
        session.cursorCommitted(token, 0xFFFFFFFFL, 59_000)
        assertEquals(0L, session.remainingMs(token, 60_000))
    }

    @Test fun retiredPersistBlocksReplacementUntilItFinishes() {
        val session = OffloadSession(60_000)
        val old = session.begin(0, 10)!!
        assertTrue(session.enter(old))
        session.retire()
        assertNull(session.begin(60_000, 10))
        assertFalse(session.enter(old))
        session.leave()
        val replacement = session.begin(61_000, 10)!!
        assertFalse(session.isCurrent(old)) // timeout, completion and queued ACK all use this fence
        assertNull(session.remainingMs(old, 200_000))
        session.cursorCommitted(old, 999, 200_000)
        assertEquals(50_000L, session.remainingMs(replacement, 71_000))
    }

    @Test fun resetInvalidatesDeferredRetryBeforeAnotherSessionStarts() {
        val session = OffloadSession(60_000)
        session.begin(0, null)
        session.retire()
        val deferredGeneration = session.generation()
        session.retire()
        assertNotEquals(deferredGeneration, session.generation())
    }

    @Test fun whoop5RetainsFrameIdlePolicy() {
        val session = OffloadSession(60_000)
        val token = session.begin(0, null)!!
        session.frameReceived(token, 59_000, DeviceFamily.WHOOP5)
        assertEquals(59_000L, session.remainingMs(token, 60_000))
    }

    @Test fun progressTimeoutReadoutDoesNotClaimTheStrapWentQuiet() {
        val error = WhoopBleClient.timeoutSyncError(null, false, durableProgressDeadline = true)!!
        assertTrue(error.contains("stopped advancing"))
        assertFalse(error.contains("went quiet"))
        assertNull(WhoopBleClient.timeoutSyncError(null, true, durableProgressDeadline = true))
        assertEquals("future clock", WhoopBleClient.timeoutSyncError("future clock", false, true))
    }

    @Test fun reconnectDoesNotRenewRecoveryBudgetButUserConnectDoes() {
        val budget = OffloadRecoveryBudget()
        val session = OffloadSession(60_000)
        repeat(2) {
            session.begin(it * 60_000L, null)
            session.retire()
            assertTrue(budget.take())
        }
        repeat(100) { assertFalse(budget.take()) }
        budget.resetByUser()
        assertTrue(budget.take())
        assertTrue(budget.take())
        assertFalse(budget.take())
    }
}
