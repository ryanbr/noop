package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The probe's whole value is that it stops. Every gate below is one of the ways this area has previously
 * produced a loop that retries something which cannot work, so they are pinned individually rather than
 * through one happy-path case.
 */
class UnbondedOffloadProbeTest {

    private fun probe(
        isWhoop5: Boolean = true,
        optedIn: Boolean = true,
        bonded: Boolean = false,
        helloWrittenThisLink: Boolean = false,
        alreadyProbedThisLink: Boolean = false,
        previouslyRefused: Boolean = false,
        silentLinksSoFar: Int = 0,
    ) = shouldProbeUnbondedOffload(
        isWhoop5 = isWhoop5,
        optedIn = optedIn,
        bonded = bonded,
        helloWrittenThisLink = helloWrittenThisLink,
        alreadyProbedThisLink = alreadyProbedThisLink,
        previouslyRefused = previouslyRefused,
        silentLinksSoFar = silentLinksSoFar,
    )

    @Test
    fun `an opted-in 5MG on a stable unbonded link is exactly the case this exists for`() {
        assertTrue(probe())
    }

    @Test
    fun `a WHOOP4 is never probed`() {
        // 4.0 bonds normally and reaches the offload through the proven path; there is nothing to ask it.
        assertFalse(probe(isWhoop5 = false))
    }

    @Test
    fun `it is off unless the user opted in`() {
        assertFalse(probe(optedIn = false))
    }

    @Test
    fun `a bonded strap uses the proven handshake instead`() {
        assertFalse(probe(bonded = true))
    }

    /**
     * The gate that keeps the ANSWER attributable. On a link carrying a hello the bond watchdog has about
     * five seconds before it bounces us, so a subscribe failure there could be the strap's policy or could
     * be our own teardown landing mid-write — indistinguishable, which is precisely the ambiguity that made
     * the CLIENT_HELLO unreadable for eleven weeks. The one attempt on record (28 Aug 13:25:00) failed this
     * way and proved nothing.
     */
    @Test
    fun `a link that carries a hello cannot answer this question`() {
        assertFalse(probe(helloWrittenThisLink = true))
    }

    @Test
    fun `it runs once per link, not once per keep-alive tick`() {
        // enableLiveNotifications drains the same CCCD queue every 30s, so without this the probe would
        // re-enter its own completion branch on every keep-alive for the life of the connection.
        assertFalse(probe(alreadyProbedThisLink = true))
    }

    @Test
    fun `a refusal is remembered, so the strap says no once`() {
        assertFalse(probe(previouslyRefused = true))
    }

    /**
     * Silence is not latched per device, so once-per-link does NOT bound it — the probe re-runs on every
     * reconnect, and a strap that reconnects often would re-ask a question already answered the same way.
     * That is the unbounded retry this whole area keeps producing, so silence spends a per-process budget.
     */
    @Test
    fun `repeated silence retires the probe`() {
        assertTrue(probe(silentLinksSoFar = UNBONDED_PROBE_MAX_SILENT_LINKS - 1))
        assertFalse(probe(silentLinksSoFar = UNBONDED_PROBE_MAX_SILENT_LINKS))
        assertFalse(probe(silentLinksSoFar = UNBONDED_PROBE_MAX_SILENT_LINKS + 5))
    }

    @Test
    fun `the give-up line says why it stopped, not merely that it did`() {
        // The CLIENT_HELLO's suppression stopped silently and cost eleven weeks of unreadable captures.
        val line = unbondedProbeGaveUpLine(3)
        assertTrue(line.contains("serves those characteristics unbonded"))
        assertTrue(line.contains("does not act on commands"))
    }

    @Test
    fun `the refusal key is per device and case-insensitive`() {
        // The same strap presents its address in different cases across sessions; a case-sensitive key
        // would latch a second time under a second name and re-ask a strap that already refused.
        assertEquals(
            unbondedOffloadRefusedPrefKey("AA:BB:CC:DD:EE:FF"),
            unbondedOffloadRefusedPrefKey("aa:bb:cc:dd:ee:ff"),
        )
        assertNull(unbondedOffloadRefusedPrefKey(null))
        assertNull(unbondedOffloadRefusedPrefKey("   "))
    }

    /**
     * The distinction the whole probe turns on. A frame proves the strap SERVES the puffin characteristics
     * unbonded; only a reply proves it ACTS on what we write. Collapsing the two is how the false bond of
     * 28 Aug read an unrelated DISABLE_ALARM completion as an answer to the hello.
     */
    @Test
    fun `only a command response proves the command channel`() {
        assertEquals(
            UnbondedProbeEvidence.ANSWERS_COMMANDS,
            unbondedProbeEvidenceOf(ok = true, crcOk = true, typeName = "COMMAND_RESPONSE"),
        )
        assertEquals(
            UnbondedProbeEvidence.SERVES_NOTIFICATIONS,
            unbondedProbeEvidenceOf(ok = true, crcOk = true, typeName = "REALTIME_DATA"),
        )
    }

    /**
     * Noise must never be read as proof. The probe runs on a link whose right to carry this traffic is the
     * open question, so a frame that fails its CRC could as easily be the stack handing us a fragment as
     * the strap answering — and counting it would let the probe conclude the opposite of the truth.
     */
    @Test
    fun `an unverified frame is not evidence of anything`() {
        assertEquals(
            UnbondedProbeEvidence.NONE,
            unbondedProbeEvidenceOf(ok = true, crcOk = false, typeName = "COMMAND_RESPONSE"),
        )
        // No CRC to check is not a pass either: `ok` alone is only an envelope check.
        assertEquals(
            UnbondedProbeEvidence.NONE,
            unbondedProbeEvidenceOf(ok = true, crcOk = null, typeName = "COMMAND_RESPONSE"),
        )
        assertEquals(
            UnbondedProbeEvidence.NONE,
            unbondedProbeEvidenceOf(ok = false, crcOk = true, typeName = "COMMAND_RESPONSE"),
        )
        assertEquals(
            UnbondedProbeEvidence.NONE,
            unbondedProbeEvidenceOf(ok = true, crcOk = true, typeName = "   "),
        )
    }

    /**
     * The verdict must not depend on arrival order. Once realtime HR is streaming, REALTIME_DATA frames
     * follow the COMMAND_RESPONSE continuously, and a last-one-wins reading would walk the conclusion back
     * down to the weaker finding and report "not answering" on a strap that had just answered.
     */
    @Test
    fun `the strongest evidence on the link is what stands`() {
        val answered = strongerProbeEvidence(
            UnbondedProbeEvidence.ANSWERS_COMMANDS,
            UnbondedProbeEvidence.SERVES_NOTIFICATIONS,
        )
        assertEquals(UnbondedProbeEvidence.ANSWERS_COMMANDS, answered)
        assertEquals(
            UnbondedProbeEvidence.ANSWERS_COMMANDS,
            strongerProbeEvidence(UnbondedProbeEvidence.NONE, UnbondedProbeEvidence.ANSWERS_COMMANDS),
        )
        assertEquals(
            UnbondedProbeEvidence.SERVES_NOTIFICATIONS,
            strongerProbeEvidence(UnbondedProbeEvidence.SERVES_NOTIFICATIONS, UnbondedProbeEvidence.NONE),
        )
    }

    /**
     * The silence line has to say which of the two silences this was. "Subscribed but nothing arrived" and
     * "subscribed and frames arrived, but no reply" are different facts about the strap, and a capture that
     * blurred them would send the next reader after the wrong thing.
     */
    @Test
    fun `the silent verdict distinguishes an idle transport from an unanswering strap`() {
        assertTrue(unbondedProbeSilentLine(5_000L, sawNotifications = true).contains("frames did arrive"))
        assertTrue(unbondedProbeSilentLine(5_000L, sawNotifications = false).contains("nothing arrived"))
        // Both must carry the wait, or the line cannot be judged against the capture's timestamps.
        assertTrue(unbondedProbeSilentLine(5_000L, sawNotifications = true).contains("5000ms"))
    }

    /**
     * The asking line must report what was CONFIRMED, not what was attempted. A CCCD write abandoned after
     * its busy retries reaches the same completion path as four clean subscribes, so a flat "subscribed"
     * would put a partial result in the capture as a whole one.
     */
    @Test
    fun `the asking line reports the confirmed count, not the attempted one`() {
        assertTrue(unbondedProbeAskingLine(3, 4, 8_000L).contains("3 of 4"))
        assertTrue(unbondedProbeAskingLine(4, 4, 8_000L).contains("4 of 4"))
    }

    /**
     * The third stage-1 outcome, and the one easiest to mis-file. Nothing confirmed AND nothing refused is
     * the absence of an answer, not an answer — reporting it as either would put a fact in the capture that
     * the link never established.
     */
    @Test
    fun `nothing confirmed and nothing refused is neither a yes nor a no`() {
        val line = unbondedProbeNoSubscriptionsLine(4)
        assertTrue(line.contains("none was refused"))
        assertTrue(line.contains("proves nothing"))
    }

    /**
     * The expectation has to be set BEFORE the transfer, not after an empty one comes back. A strap that
     * has never been clocked has never been told to persist to flash, so "nothing banked" is a plausible
     * SUCCESS of the probe, and a reader who has not been told that will read it as a failure.
     */
    @Test
    fun `the backlog caveat names the un-clocked strap, not a broken probe`() {
        val line = unbondedProbeBacklogCaveatLine()
        assertTrue(line.contains("never been clocked"))
        assertTrue(line.contains("from now on"))
    }

    @Test
    fun `every probe line names the issue it belongs to`() {
        // A capture line without its issue number costs the next reader the search that this whole thread
        // has already paid for repeatedly.
        val lines = listOf(
            unbondedProbeStartLine(),
            puffinSubscribeRefusedLine("fd4b0003", "GATT_INSUFFICIENT_AUTHENTICATION(5)"),
            unbondedProbeAskingLine(subscribed = 4, total = 4, waitMs = 5_000L),
            unbondedProbeNoSubscriptionsLine(4),
            unbondedProbeGaveUpLine(3),
            unbondedProbeSilentLine(5_000L, sawNotifications = false),
            unbondedProbeAnsweredLine(),
            unbondedProbeBacklogCaveatLine(),
        )
        for (line in lines) assertTrue(line, line.contains("#1635"))
    }
}
