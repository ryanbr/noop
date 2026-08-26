package com.noop.testcentre

import com.noop.ble.redactStrapLogPii
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #453: the strap-log HEADER is built from diagnostics lines that never pass through
 * `WhoopBleClient.log()`'s scrub, so the export sites must redact them themselves.
 *
 * This pins the property that matters — a device id embedding a BLE address does not survive into a
 * shareable header — rather than the call sites, which a refactor may legitimately move. It matters now
 * that the header enumerates EVERY paired device: a single-strap install is "my-whoop" and carries no
 * address, but a re-added or second strap is "whoop-<MAC>".
 */
class HeaderRedactionTest {

    private val rawMac = Regex("[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}")

    @Test
    fun `a device-id line carrying a BLE address is masked`() {
        val line = "  device id=whoop-F1:D4:F7:24:53:DE status=paired brand=WHOOP model=WHOOP 4.0 lastSeen=10m ago"
        val safe = redactStrapLogPii(line)
        assertFalse("raw MAC survived: $safe", rawMac.containsMatchIn(safe))
        // Still identifiable enough to tell two straps apart in a shared log.
        assertTrue(safe.contains("whoop-F1:"))
        assertTrue(safe.endsWith(":DE status=paired brand=WHOOP model=WHOOP 4.0 lastSeen=10m ago"))
    }

    @Test
    fun `the funnel's orphan line is masked too`() {
        // The line #1620 added prints ids for every id holding samples — the same exposure.
        val line = "(no raw biometric samples under the ACTIVE id 'my-whoop' for this night — they are under " +
            "'whoop-F1:D4:F7:24:53:DE' (4213 rows) instead."
        assertFalse(rawMac.containsMatchIn(redactStrapLogPii(line)))
    }

    @Test
    fun `an id with no address is untouched`() {
        val line = "  device id=my-whoop status=ACTIVE brand=WHOOP model=WHOOP 4.0 lastSeen=3h 10m ago"
        assertTrue(redactStrapLogPii(line) == line)
    }
}
