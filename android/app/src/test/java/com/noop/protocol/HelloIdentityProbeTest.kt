package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1303: the GET_HELLO candidate-serial probe.
 *
 * The probe exists to locate a strap serial in a block the decoder already receives and discards. Its
 * value depends entirely on two properties, and both are pinned here: it must SURFACE a serial-shaped
 * run, and it must WITHHOLD the session token that shares the block.
 *
 * Byte-parity twin of Swift `HelloIdentityProbeTests`.
 */
class HelloIdentityProbeTest {

    /** Payload with printable runs at chosen offsets, zero-filled elsewhere — zeros are the
     *  non-printable filler a real block has between its fields. */
    private fun payload(length: Int, runs: List<Pair<Int, String>>): ByteArray {
        val p = ByteArray(length)
        for ((offset, text) in runs) {
            text.toByteArray(Charsets.US_ASCII).forEachIndexed { k, b -> p[offset + k] = b }
        }
        return p
    }

    /** The point of the whole probe: a serial-shaped run away from the name is printed, so it can be
     *  matched against the serial on the strap's own casing. */
    @Test fun aSerialShapedRunIsPrinted() {
        val lines = HelloIdentityProbe.candidateLines(payload(120, listOf(40 to "3A1B2405003655")))
        assertEquals(1, lines.size)
        assertEquals("off=40 len=14 alnum \"3A1B2405003655\"", lines[0])
    }

    /** The privacy contract. A NON-alphanumeric run is described but never quoted — that is the shape
     *  a session token takes, and the decoder deliberately never reads it. */
    @Test fun aMixedRunIsDescribedButWithheld() {
        val lines = HelloIdentityProbe.candidateLines(payload(120, listOf(40 to "tok!en-{}~payload")))
        assertEquals(1, lines.size)
        assertEquals("off=40 len=17 mixed (withheld)", lines[0])
        assertFalse("a mixed run's contents must never reach the log", lines[0].contains("tok"))
    }

    /** Length is a filter too: an alphanumeric run far longer than any serial is withheld. A long
     *  alphanumeric blob is much more likely to be a token than an id. */
    @Test fun anOverlongAlnumRunIsWithheld() {
        val lines = HelloIdentityProbe.candidateLines(payload(200, listOf(40 to "a".repeat(64))))
        assertEquals("off=40 len=64 alnum (withheld)", lines[0])
    }

    /** The device name is already surfaced by the decoder, so it is labelled rather than quoted. */
    @Test fun theKnownNameRunIsLabelledNotQuoted() {
        val lines = HelloIdentityProbe.candidateLines(payload(120, listOf(16 to "WHOOP-FAKE01")))
        assertEquals("off=16 len=12 mixed (device name, already decoded)", lines[0])
    }

    /**
     * The known-name offset must LABEL, not suppress.
     *
     * [HelloIdentityProbe.candidateLines]'s knownNameOffset is an assumption from one firmware capture.
     * If a firmware moved the name and the serial landed at 16, suppressing the value would hide the
     * exact thing this probe exists to find — and it would look like a clean negative rather than a miss.
     */
    @Test fun aSerialShapedRunAtTheNameOffsetIsStillPrinted() {
        val lines = HelloIdentityProbe.candidateLines(payload(120, listOf(16 to "3A1B2405003655")))
        assertEquals("off=16 len=14 alnum (device name, already decoded) \"3A1B2405003655\"", lines[0])
    }

    /** Short runs are dropped. Binary payloads throw off two- and three-byte printable sequences by
     *  chance, and reporting them would bury the real candidate. */
    @Test fun shortRunsAreIgnored() {
        assertTrue(
            HelloIdentityProbe.candidateLines(payload(60, listOf(10 to "ab", 30 to "xyz"))).isEmpty(),
        )
    }

    /** Several runs are reported in offset order, so the reader can line them up against the block. */
    @Test fun runsAreReportedInOffsetOrder() {
        val lines = HelloIdentityProbe.candidateLines(
            payload(200, listOf(16 to "WHOOP-FAKE01", 40 to "SER1234567", 80 to "zz!!zz??")),
        )
        assertEquals(
            listOf(
                "off=16 len=12 mixed (device name, already decoded)",
                "off=40 len=10 alnum \"SER1234567\"",
                "off=80 len=8 mixed (withheld)",
            ),
            lines,
        )
    }

    /** A run reaching the very end of the payload must not be lost to an off-by-one on the scan bound. */
    @Test fun aRunFlushWithTheEndIsReported() {
        val p = ByteArray(20)
        "SERIAL99".toByteArray(Charsets.US_ASCII).forEachIndexed { k, b -> p[12 + k] = b }
        assertEquals("off=12 len=8 alnum \"SERIAL99\"", HelloIdentityProbe.candidateLines(p)[0])
    }

    /** "No printable runs" is a real answer, not a failure: it says the serial is not ASCII here and
     *  the search moves on. The length still prints, so the reader knows the block was seen. */
    @Test fun anAllBinaryBlockReportsNoneWithItsLength() {
        assertEquals("HELLO(145) block len=42 runs: none", HelloIdentityProbe.report(ByteArray(42)))
    }

    /**
     * [HelloIdentityProbe.report] must THREAD its tuning through to the scan, not merely accept it.
     *
     * Every other test here calls candidateLines at its defaults, so a report that quietly dropped a
     * parameter would pass all of them. The same call with a narrowed serial length must withhold what
     * the default range prints — which is only observable if the value actually reaches the scan.
     */
    @Test fun reportThreadsItsTuningThrough() {
        val p = payload(120, listOf(40 to "3A1B2405003655"))   // 14 chars: inside the default 6..20
        assertTrue(HelloIdentityProbe.report(p).contains("\"3A1B2405003655\""))
        assertEquals(
            "HELLO(145) block len=120 runs: off=40 len=14 alnum (withheld)",
            HelloIdentityProbe.report(p, serialLenMax = 10),
        )
    }

    /** An empty payload must not crash the scan. */
    @Test fun anEmptyPayloadIsSafe() {
        assertTrue(HelloIdentityProbe.candidateLines(ByteArray(0)).isEmpty())
        assertEquals("HELLO(145) block len=0 runs: none", HelloIdentityProbe.report(ByteArray(0)))
    }
}
