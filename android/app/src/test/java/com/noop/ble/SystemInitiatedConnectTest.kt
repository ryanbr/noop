package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * #1635: only a USER gesture may grant the one-shot CLIENT_HELLO retry.
 *
 * This reads the source rather than calling the client, because the rule is about which ENTRY POINT a
 * caller picks — there is no return value to assert on, and the client needs a radio. The regression it
 * exists for already happened once: the stale-OS-bond fallback scheduled its reconnect through the
 * user-facing `connect()`, so on a suppressed strap a scan-driven retry wrote a second unanswered hello
 * and paid a second ~4.8s drop nobody asked for (field log 260901-1022, gen=3).
 *
 * Nothing else would have caught it. Every line that path produces is identical to a real user tap, the
 * BLE path has no CI, and a unit test of the client cannot reach it. Apple has kept the two entries apart
 * since #78 hole-2 and says so in `BLEManager.connect`'s doc; this is Android's version of that rule
 * being enforced rather than remembered.
 */
class SystemInitiatedConnectTest {

    /**
     * Deliberately FAILS rather than skipping when the source cannot be found.
     *
     * The nearby [com.noop.protocol.CommandCatalogueTest] uses `Assume` for its schema, and that is right
     * there: it reads a file from a SIBLING Swift package that a stripped checkout may genuinely not have.
     * This one reads the file its own module is compiled from, so "not found" means the search is wrong,
     * not that the environment is thin — and a regression gate that quietly declines to run is worse than
     * no gate, because the green tick then means nothing. Walk the parents so any working directory
     * resolves, and if none does, say so loudly.
     */
    private fun clientSource(): String {
        val rel = "android/app/src/main/java/com/noop/ble/WhoopBleClient.kt"
        val start = File(System.getProperty("user.dir") ?: ".").absoluteFile
        val f = generateSequence(start) { it.parentFile }
            .map { File(it, rel) }
            .firstOrNull { it.isFile }
        assertTrue(
            "WhoopBleClient.kt not found walking up from user.dir=$start — this gate cannot run, and a " +
                "gate that silently skips is worse than none. Fix the path, do not re-add an Assume.",
            f != null,
        )
        return f!!.readText()
    }

    @Test
    fun `a deferred reconnect never routes through the user-facing connect`() {
        val offenders = Regex("""scheduleReconnect\([^)]*\)\s*\{\s*connect\(""")
            .findAll(clientSource()).map { it.value }.toList()
        assertEquals(
            "a timer firing is not the user asking to retry the handshake — use connectFromSystem(...): " +
                offenders,
            0, offenders.size,
        )
    }

    /**
     * Deliberately "no internal caller uses the user entry" rather than "the system entry is used N
     * times". A count would fail the day someone adds a FIFTH system path correctly, which trains people
     * to edit the number instead of thinking; this phrasing passes for any correct addition and fails for
     * any incorrect one. The client never needs to call its own public user entry — every internal path
     * is by definition system-initiated.
     */
    @Test
    fun `no internal path calls the user-facing connect`() {
        val src = clientSource()
        assertTrue("connectFromSystem must exist as the system-initiated entry",
                   src.contains("fun connectFromSystem("))
        val offenders = Regex("""(?<![A-Za-z])connect\((selectedModel|model|persistedWhoopModel\(\))\)""")
            .findAll(src).map { it.value }.toList()
        assertEquals(
            "an internal caller is by definition not the user — use connectFromSystem(...): $offenders",
            0, offenders.size,
        )
    }

    @Test
    fun `only the user entry grants the hello retry`() {
        val src = clientSource()
        val grants = Regex("""helloRetryRequested\s*=\s*true""").findAll(src).count()
        assertEquals("the retry is granted in exactly one place, behind the userInitiated flag", 1, grants)
        assertTrue("that one place must be gated on userInitiated",
                   src.contains("if (userInitiated) helloRetryRequested = true"))
    }
}
