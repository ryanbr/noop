package com.noop.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The "Sync now" gate (#93). The manual button forwards to the SAME [WhoopBleClient.requestSync]
 * guard the auto-kick and the 900s periodic timer use, so a manual sync can never bypass the
 * connected+bonded+not-already-backfilling precondition. These pin that pure predicate
 * ([WhoopBleClient.canRequestSync]) so the no-op behaviour the button relies on can't silently
 * regress — the full kick path needs a live GATT stack, but the decision to kick is pure.
 */
class SyncNowGateTest {

    @Test
    fun allowsSync_whenConnectedAndBondedAndIdle() {
        assertTrue(WhoopBleClient.canRequestSync(connected = true, bonded = true, backfilling = false))
    }

    @Test
    fun blocksSync_whenNotConnected() {
        // Disconnected: the command channel is gone — a kick would just be dropped by send().
        assertFalse(WhoopBleClient.canRequestSync(connected = false, bonded = true, backfilling = false))
    }

    @Test
    fun blocksSync_whenNotBonded() {
        // Connected but unbonded (e.g. 5/MG live-HR shortcut): the offload command needs the bonded
        // channel, so a manual tap must no-op rather than fire a doomed request.
        assertFalse(WhoopBleClient.canRequestSync(connected = true, bonded = false, backfilling = false))
    }

    @Test
    fun blocksSync_whenAlreadyBackfilling() {
        // THE reason the button is disabled mid-session: a second kick during an in-flight offload
        // would fight the running session. The gate is the real enforcement; the disabled UI mirrors it.
        assertFalse(WhoopBleClient.canRequestSync(connected = true, bonded = true, backfilling = true))
    }

    @Test
    fun blocksSync_whenDisconnectedMidBackfill() {
        // A dropout mid-backfill: every precondition that matters is false — still a no-op.
        assertFalse(WhoopBleClient.canRequestSync(connected = false, bonded = false, backfilling = true))
    }
}

/**
 * #ABORT: the mirror of [WhoopBleClient.canRequestSync]. A sync may only be STOPPED while one is
 * actually running, and — unlike starting one — stopping deliberately does not require a live link:
 * the local teardown is the point, and a strap that never hears the opcode simply keeps streaming
 * into a session NOOP no longer treats as active.
 */
class AbortSyncGateTest {

    @Test
    fun abortIsOfferedOnlyWhileAnOffloadIsRunning() {
        assertTrue(WhoopBleClient.canAbortSync(backfilling = true))
        assertFalse(WhoopBleClient.canAbortSync(backfilling = false))
    }

    @Test
    fun startAndStopGatesAreMutuallyExclusive() {
        // Whatever the link state, exactly one of "you may start a sync" and "you may stop one" holds
        // for a bonded, connected strap — they must never both be true or both be false.
        for (backfilling in listOf(true, false)) {
            val canStart = WhoopBleClient.canRequestSync(
                connected = true, bonded = true, backfilling = backfilling,
            )
            val canStop = WhoopBleClient.canAbortSync(backfilling = backfilling)
            assertNotEquals(
                "start and stop gates disagree for backfilling=$backfilling", canStart, canStop,
            )
        }
    }
}
