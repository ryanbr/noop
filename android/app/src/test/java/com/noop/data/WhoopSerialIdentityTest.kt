package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Twin of the Swift WhoopSerialIdentityTests. The REFUSALS matter more than the composition: adoption
 * migrates every device-scoped row onto the id this returns, so a junk serial must yield null and leave
 * the strap on its existing id rather than move a history onto a garbage key (#1303).
 */
class WhoopSerialIdentityTest {

    @Test fun composesTheSerialId() {
        assertEquals("whoop-5AG12345678", WhoopSerialIdentity.adoptedId("5AG12345678"))
    }

    @Test fun upperCasesSoOneStrapCannotBecomeTwoIds() {
        assertEquals(
            WhoopSerialIdentity.adoptedId("5ag12345678"),
            WhoopSerialIdentity.adoptedId("5AG12345678"),
        )
    }

    @Test fun trimsSurroundingWhitespaceFromTheGattString() {
        assertEquals("whoop-5AG12345678", WhoopSerialIdentity.adoptedId("  5AG12345678\n"))
    }

    @Test fun refusesBlankOrMissing() {
        assertNull(WhoopSerialIdentity.adoptedId(null))
        assertNull(WhoopSerialIdentity.adoptedId(""))
        assertNull(WhoopSerialIdentity.adoptedId("   \n "))
    }

    @Test fun refusesATruncatedRead() {
        // A partial GATT response must not become an id: it would collide across straps.
        assertNull(WhoopSerialIdentity.adoptedId("5AG"))
    }

    @Test fun refusesADescriptiveStringThatIsNotASerial() {
        // Some peripherals answer DIS with prose. Never let that become a device id.
        assertNull(WhoopSerialIdentity.adoptedId("Not Available"))
        assertNull(WhoopSerialIdentity.adoptedId("serial#1234"))
    }

    @Test fun alreadyAdoptedIsTheReconnectEarlyOut() {
        assertTrue(WhoopSerialIdentity.isAlreadyAdopted("whoop-5AG12345678", "5AG12345678"))
        assertFalse(WhoopSerialIdentity.isAlreadyAdopted("whoop-ABCDEF-0123", "5AG12345678"))
        // An unusable serial is never "already adopted" — otherwise a junk read would silently
        // suppress a later good one.
        assertFalse(WhoopSerialIdentity.isAlreadyAdopted("whoop-5AG12345678", "  "))
    }

    /**
     * The guard that makes this safe to ship before #1304. Every existing single-WHOOP install is on the
     * legacy "my-whoop" seed, ~47 code paths read that literal directly, and WhoopBleClient never
     * reassigns its deviceId on the single-WHOOP path — so adopting it would migrate the history onto
     * whoop-<serial> while new samples kept landing under "my-whoop". A split history reads as data loss.
     */
    @Test fun refusesToAdoptTheLegacySingleWhoopSeed() {
        assertFalse(WhoopSerialIdentity.mayAdopt("my-whoop"))
        // A provisional pairing id IS adoptable — that is the multi-strap case this ships for.
        assertTrue(WhoopSerialIdentity.mayAdopt("whoop-6B9F2C11-0000-4000-8000-0000000000AA"))
        // An already-adopted serial id stays adoptable; the equality check upstream stops the re-migration.
        assertTrue(WhoopSerialIdentity.mayAdopt("whoop-5AG12345678"))
        // Another brand's id is never touched by the WHOOP path.
        assertFalse(WhoopSerialIdentity.mayAdopt("oura-2H3B2405003655"))
    }

    /**
     * The process-wide handle must follow adoption, not wait for a cold start.
     *
     * `NoopApplication.activeDeviceId` was a `by lazy`, frozen for the life of the process. Adoption
     * re-pointed the registry while every consumer of that handle kept the OLD id, so the scoring engine
     * went on deriving days under the pre-adoption id and the computed history split across both until the
     * phone was restarted. Confirmed on a real 5/MG: the registry read the serial id while the export
     * still printed the address id and the old computed bucket kept growing.
     *
     * `NoopApplication` needs a Context, so the invariant is pinned against the source the way the other
     * un-constructable callers are.
     */
    @Test fun adoptionRePointsTheProcessWideActiveIdHandle() {
        var root = java.io.File(System.getProperty("user.dir") ?: ".").canonicalFile
        var app: String? = null
        var vm: String? = null
        repeat(4) {
            val a = java.io.File(root, "android/app/src/main/java/com/noop/NoopApplication.kt")
            val v = java.io.File(root, "android/app/src/main/java/com/noop/ui/AppViewModel.kt")
            if (a.isFile && app == null) app = a.readText()
            if (v.isFile && vm == null) vm = v.readText()
            root = root.parentFile ?: root
        }
        val application = app ?: error("NoopApplication.kt not found - this test must not pass by default")
        val viewModel = vm ?: error("AppViewModel.kt not found - this test must not pass by default")

        assertFalse("activeDeviceId must not be a frozen `by lazy` again",
                    application.contains("val activeDeviceId: String by lazy"))
        assertTrue("it must expose a way to follow an adoption",
                   application.contains("fun onActiveDeviceAdopted(newId: String)"))
        assertTrue("and adoption must actually call it",
                   viewModel.contains("noopApp.onActiveDeviceAdopted(serialId)"))
    }

    @Test fun logSafeNeverLeaksTheFullSerial() {
        assertEquals("5AG…", WhoopSerialIdentity.logSafe("5AG12345678"))
        assertEquals("?", WhoopSerialIdentity.logSafe(null))
        assertFalse(WhoopSerialIdentity.logSafe("5AG12345678").contains("12345678"))
    }
}
