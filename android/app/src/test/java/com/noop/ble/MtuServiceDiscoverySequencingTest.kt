package com.noop.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Regression coverage for delayed MTU -> service-discovery sequencing on Android 14/Saga. */
class MtuServiceDiscoverySequencingTest {

    @Test
    fun currentConnectedGatt_isAllowedAfterSettleWindow() {
        assertTrue(
            WhoopBleClient.serviceDiscoveryAttemptAllowed(
                expectedGeneration = 7,
                currentGeneration = 7,
                isCurrentGatt = true,
                connected = true,
                hasGattOps = true,
            ),
        )
    }

    @Test
    fun staleGeneration_isRejectedAfterReconnect() {
        assertFalse(
            WhoopBleClient.serviceDiscoveryAttemptAllowed(
                expectedGeneration = 7,
                currentGeneration = 8,
                isCurrentGatt = true,
                connected = true,
                hasGattOps = true,
            ),
        )
    }

    @Test
    fun replacedGatt_isRejectedEvenAtSameGeneration() {
        assertFalse(
            WhoopBleClient.serviceDiscoveryAttemptAllowed(
                expectedGeneration = 7,
                currentGeneration = 7,
                isCurrentGatt = false,
                connected = true,
                hasGattOps = true,
            ),
        )
    }

    @Test
    fun disconnectedOrMissingOps_isRejected() {
        assertFalse(
            WhoopBleClient.serviceDiscoveryAttemptAllowed(7, 7, true, false, true),
        )
        assertFalse(
            WhoopBleClient.serviceDiscoveryAttemptAllowed(7, 7, true, true, false),
        )
    }
}
