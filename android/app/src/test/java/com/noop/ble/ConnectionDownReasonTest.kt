package com.noop.ble

import com.noop.analytics.ConnectionTrace
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * #1020 — the connection-down trace has to say WHICH path dropped the link.
 *
 * The report that prompted this showed nearly 2,800 reconnects, every one `reason=localTerminate`.
 * That token is GATT status 22, and at least five of NOOP's own paths produce it — the bond watchdog,
 * the keep-alive stall bounce, a user disconnect, releaseStrap, and a safeGatt teardown after a dead
 * binder. With one string for five causes the log could not be diagnosed at all; the comment beside it
 * in the source could only guess ("e.g. #971 bond watchdog").
 */
class ConnectionDownReasonTest {

    /** The regression itself: a local teardown now names its origin. */
    @Test fun aLocalTeardownNamesThePathThatCausedIt() {
        assertEquals(
            "localTerminate via=bondWatchdog",
            WhoopBleClient.connectionDownReason(22, "bondWatchdog"),
        )
        assertEquals(
            "localTerminate via=keepAliveStall",
            WhoopBleClient.connectionDownReason(22, "keepAliveStall"),
        )
    }

    /**
     * A safeGatt teardown carries the failing operation with it, so `gattThrow:requestMtu` is
     * distinguishable from `gattThrow:readRemoteRssi` — those point at different bugs.
     */
    @Test fun aGattThrowCarriesTheOperationThatFailed() {
        assertEquals(
            "localTerminate via=gattThrow:requestMtu",
            WhoopBleClient.connectionDownReason(22, "gattThrow:requestMtu"),
        )
    }

    /**
     * `unknown` is a real signal, not a fallback to ignore: the drop was local but no tagged path
     * claimed it, which means a teardown route exists that this change missed.
     */
    @Test fun anUntaggedLocalTeardownReadsAsUnknown() {
        assertEquals("localTerminate via=unknown", WhoopBleClient.connectionDownReason(22, null))
    }

    /** A remote timeout is not ours, so no origin is attached — the strap or the radio dropped it. */
    @Test fun aRemoteTimeoutIsNotAttributedToUs() {
        assertEquals("connectionTimeout", WhoopBleClient.connectionDownReason(8, "bondWatchdog"))
    }

    /** Any other status passes through verbatim, as before. */
    @Test fun otherStatusesPassThrough() {
        assertEquals("status19", WhoopBleClient.connectionDownReason(19, null))
        assertEquals("status133", WhoopBleClient.connectionDownReason(133, "userDisconnect"))
    }

    /** The session length is what separates a 7-second bond watchdog from a 120-second stall bounce. */
    @Test fun theSessionLengthIsReportedToATenthOfASecond() {
        assertEquals(" after 6.8s", ConnectionTrace.sessionHeldSuffix(6_800))
        assertEquals(" after 120.0s", ConnectionTrace.sessionHeldSuffix(120_000))
        assertEquals(" after 0.4s", ConnectionTrace.sessionHeldSuffix(432))
    }

    /**
     * Unknown session start yields no suffix rather than a misleading zero — "after 0.0s" would read as
     * an instant drop, which is a different diagnosis from "we do not know".
     */
    @Test fun anUnknownSessionStartYieldsNoSuffix() {
        assertEquals("", ConnectionTrace.sessionHeldSuffix(-1))
    }
}
