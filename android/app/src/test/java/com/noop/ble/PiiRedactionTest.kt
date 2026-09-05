package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Strap-log PII redaction ([redactStrapLogPii]).
 *
 * Regression guard for #421: the MAC scrubber regex has exactly two capture groups (first + last
 * octet), so the replacement must reference $1/$2. A stray `$3` made `replace()` throw
 * IndexOutOfBoundsException("No group 3") the instant a raw MAC was logged — which happened the
 * moment a generic-HR strap (Polar H10 etc.) was activated, since StandardHrSource logs
 * `device.address`. The thrown exception aborted the strap's activation, so the strap never streamed.
 */
class PiiRedactionTest {

    /**
     * #1833: the serial that arrives as HEX. The event census (#1825) dumps `payload=<hex>` for every
     * pushed event, and event 109 on a 5/MG carries the strap serial as plain ASCII inside that payload.
     * The text rules cannot see it — they are reading hex digits — so it walked past every one of them
     * into the log people paste into public issues. This is the exact payload from that PR's own sample.
     */
    @Test fun masksAWhoopSerialHiddenInsideAHexPayload() {
        val line = "[event] 0x6D(109) payload=142e1c0001d36e3d1c12a3574242354150303533393835320000"
        val out = redactStrapLogPii(line)
        // "WBB5AP0539852" as hex is 5742423541503035333938353 2 — none of it may survive.
        assertFalse("serial must not survive as hex: $out", out.contains("4242354150303533393835"))
        assertTrue("the dump must still be recognisable", out.startsWith("[event] 0x6D(109) payload="))
        // The non-serial bytes are the reason the dump exists — they must be untouched.
        assertTrue("leading bytes must survive: $out", out.contains("142e1c0001d36e3d1c12a3"))
    }

    /** The rule is deliberately not keyed on `payload=`: Apple labels the same dumps `[raw …]` and the
     *  #900 whole-frame dump has no label at all. A serial must not survive by arriving under a
     *  different word. */
    @Test fun masksASerialUnderAnyLabelIncludingNone() {
        val hex = "142e1c0001d36e3d1c12a3574242354150303533393835320000"
        for (line in listOf("[raw $hex]", "(raw $hex)", "raw frame (#900) $hex", hex)) {
            val out = redactStrapLogPii(line)
            assertFalse("serial survived under this label: $out", out.contains("4242354150303533393835"))
        }
    }

    @Test fun leavesAHexPayloadWithNoSerialAlone() {
        // The charging payloads from the same capture carry no ASCII run — they must pass through whole.
        for (p in listOf("707d0000", "b87e0000", "00000000")) {
            assertEquals("payload=$p", redactStrapLogPii("payload=$p"))
        }
    }

    /** Odd-length or non-hex content must return unchanged rather than throwing — redaction failing
     *  open would withhold the whole line ("[redaction error - line withheld]"). */
    @Test fun malformedHexIsLeftAloneRatherThanThrowing() {
        assertEquals("payload=zzzzzzzzz", redactStrapLogPii("payload=zzzzzzzzz"))
    }

    @Test fun masksMacKeepingFirstAndLastOctet() {
        // The exact line that triggered #421 (a generic-HR strap's address being logged).
        val out = redactStrapLogPii("HR-strap: connecting to A1:B2:C3:D4:E5:F6")
        assertEquals("HR-strap: connecting to A1:••:••:••:••:F6", out)
    }

    @Test fun doesNotThrowOnAnyMac() {
        // The whole bug was a thrown exception, not a wrong string — assert it completes.
        for (mac in listOf("00:11:22:33:44:55", "AA:bb:CC:dd:EE:ff", "de:ad:be:ef:12:34")) {
            val out = redactStrapLogPii("connecting to $mac now")
            assertFalse("middle octets must be masked: $out", out.contains(mac))
        }
    }

    @Test fun masksWhoopSerial() {
        assertEquals("Discovered WHOOP <serial> (rssi -63)",
            redactStrapLogPii("Discovered WHOOP 4C1594026 (rssi -63)"))
    }

    /**
     * #1303: once a strap ADOPTS its serial, its device id IS the serial, and the strap log prints device
     * ids in the Devices list, every `dayOwner` line and the per-source counts. Before adoption existed no
     * id could contain a serial, so neither older rule covers this shape.
     */
    @Test fun masksAnAdoptedSerialDeviceId() {
        val out = redactStrapLogPii("device id=whoop-MGB1234567 status=ACTIVE brand=WHOOP")
        assertEquals("device id=whoop-MGB… status=ACTIVE brand=WHOOP", out)
        assertFalse("the serial must not survive anywhere", out.contains("1234567"))
    }

    /**
     * The `-noop` suffix is NOT identifying and is load-bearing for reading a log: it is what separates
     * derived rows from measured ones in the "Days:"/"Stored:" lines. Masking it away would take a
     * diagnostic with it.
     */
    @Test fun keepsTheComputedSiblingMarker() {
        assertEquals("Days: whoop-MGB…-noop=25",
                     redactStrapLogPii("Days: whoop-MGB1234567-noop=25"))
    }

    /**
     * The forms that must survive untouched: the legacy seed and its computed sibling are not serials, and
     * the provisional MAC id is already masked by the MAC rule before this one sees it.
     */
    @Test fun leavesTheLegacySeedAndMaskedMacFormAlone() {
        assertEquals("readId=my-whoop writeActiveId=my-whoop-noop",
                     redactStrapLogPii("readId=my-whoop writeActiveId=my-whoop-noop"))
        // A raw MAC id goes through the MAC rule first and must not then be re-mangled.
        assertEquals("device id=whoop-FD:••:••:••:••:4A",
                     redactStrapLogPii("device id=whoop-FD:A1:B2:C3:D4:4A"))
    }

    /**
     * Six characters is the floor, matching WhoopSerialIdentity.minSerialLength: anything shorter is
     * refused as a serial upstream, so it must not be mistaken for one here either.
     */
    @Test fun ignoresIdsTooShortToBeASerial() {
        assertEquals("id=whoop-ABCDE", redactStrapLogPii("id=whoop-ABCDE"))
        assertEquals("id=whoop-ABC…", redactStrapLogPii("id=whoop-ABCDEF"))
    }

    @Test fun leavesModelNamesAndPlainTextAlone() {
        // "WHOOP 4.0" is a dotted model name, not a serial — must not be scrubbed.
        assertEquals("Auto-reconnecting to your saved WHOOP 4.0…",
            redactStrapLogPii("Auto-reconnecting to your saved WHOOP 4.0…"))
        assertEquals("Backfill: session ended — reason=HISTORY_COMPLETE",
            redactStrapLogPii("Backfill: session ended — reason=HISTORY_COMPLETE"))
    }

    /**
     * Regression for #453: a WHOOP 5/MG reconnect logs a frame line containing a MAC; redaction must
     * mask it WITHOUT throwing. The $3 bug here crashed the whole app on every Bluetooth-on reconnect.
     */
    @Test fun frameLineWithMacIsRedactedNotCrashed() {
        val out = redactStrapLogPii("handleFrame from AA:BB:CC:DD:EE:FF — 24 bytes")
        assertEquals("handleFrame from AA:••:••:••:••:FF — 24 bytes", out)
    }

    /** Defense-in-depth (#453): redaction is TOTAL — it never throws, on any input, ever. */
    @Test fun neverThrowsOnAdversarialInput() {
        val nasty = listOf(
            "", "no pii here",
            "literal dollar \$3 and \${0} and \\1 in the text",
            "AA:BB:CC:DD:EE:FF WHOOP 4C1594026 mixed $ \\ ${'$'}{",
            "x".repeat(20000),
            "00:11:22:33:44:55 ".repeat(500),
        )
        for (s in nasty) {
            // The contract is "returns a String, never throws" — assert it completes for every input.
            val out = redactStrapLogPii(s)
            assertTrue("must return a value, got null", out.isNotEmpty() || s.isEmpty())
        }
    }

    /**
     * The account holder's name, which WHOOP writes into the advertised local name and the scan path
     * logs on every discovery. Nothing here could see it before: the other rules key on MAC shape, a
     * "WHOOP " + digit serial, or a "whoop-" id. Swift twin in `PiiRedactionTests`.
     */
    @Test fun personalNameInDiscoveryLineIsRedacted() {
        assertEquals(
            "Discovered <name>'s Whoop (rssi -55) - connecting",
            redactStrapLogPii("Discovered Ryan's Whoop (rssi -55) - connecting"),
        )
    }

    /** Apple platforms write U+2019 into default device names, so the straight quote is not enough. */
    @Test fun curlyApostropheNameIsRedacted() {
        assertEquals(
            "Discovered <name>\u2019s Whoop (rssi -55)",
            redactStrapLogPii("Discovered Ryan\u2019s Whoop (rssi -55)"),
        )
    }

    /** The MODEL after the possessive is diagnostic and identifies nobody, so it must survive. */
    @Test fun modelSurvivesNameRedaction() {
        assertEquals("<name>'s WHOOP 4.0", redactStrapLogPii("Ryan's WHOOP 4.0"))
    }

    /** The documented gap, pinned so it is visible rather than assumed: ONE token before the possessive. */
    @Test fun multiTokenNameKeepsTheLeadingToken() {
        assertEquals("Ryan <name>'s Whoop", redactStrapLogPii("Ryan B's Whoop"))
    }

    /** The rule must not touch ids or ordinary text that merely contain "whoop". */
    @Test fun nameRuleLeavesIdsAndPlainTextAlone() {
        assertEquals("my-whoop and my-whoop-noop", redactStrapLogPii("my-whoop and my-whoop-noop"))
        assertEquals("no pii here", redactStrapLogPii("no pii here"))
    }


    /**
     * The name never reaches a shared log at all. The sink rule below is defence-in-depth; this is the
     * real guarantee, and it is an ALLOWLIST so an unanticipated naming shape is dropped by default.
     */
    @Test fun logSafeDeviceNameKeepsOnlyTheModel() {
        assertEquals("<name> Whoop", logSafeDeviceName("Ryan's Whoop"))
        assertEquals("<name> WHOOP 4.0", logSafeDeviceName("Ryan B's WHOOP 4.0"))
        assertEquals("<name> WHOOP 5.0 MG", logSafeDeviceName("Ryan\u2019s WHOOP 5.0 MG"))
    }

    /** A fully custom name has no model token to keep, so nothing of it survives. */
    @Test fun logSafeDeviceNameDropsAWhollyCustomName() {
        assertEquals("<name>", logSafeDeviceName("Dad's spare"))
        assertEquals("<name>", logSafeDeviceName("Sarah"))
    }

    /** "We saw no name" and "we removed a name" are different facts to a reader, so the sentinel stays. */
    @Test fun logSafeDeviceNameKeepsTheNoNameSentinel() {
        assertEquals("unknown", logSafeDeviceName("unknown"))
        assertEquals("unknown", logSafeDeviceName(null))
        assertEquals("unknown", logSafeDeviceName("   "))
    }


    /** Third-party straps: the MODEL is the diagnostic, so a name carrying no person survives intact. */
    @Test fun logSafeDeviceNameKeepsAnUnrenamedThirdPartyModel() {
        assertEquals("Polar H10", logSafeDeviceName("Polar H10"))
        assertEquals("TICKR", logSafeDeviceName("TICKR"))
        assertEquals("WHOOP 4.0", logSafeDeviceName("WHOOP 4.0"))
    }

    /** ...but a renamed one loses the person and keeps the model. */
    @Test fun logSafeDeviceNameStripsThePersonFromARenamedThirdPartyStrap() {
        assertEquals("<name> Polar H10", logSafeDeviceName("Ryan's Polar H10"))
        assertEquals("<name> TICKR", logSafeDeviceName("Sarah TICKR"))
    }


    /**
     * The hole a model-code PATTERN opened, pinned shut. "[a-z]{1,4}\\d{1,3}" was meant to admit "H10"
     * and admitted "Ryan1" and "Sam99" with it, passing a first name through untouched. Model codes are
     * listed one by one for this reason; if a pattern is ever reintroduced, these fail.
     */
    @Test fun aNameWithDigitsIsNotMistakenForAModelCode() {
        assertEquals("<name>", logSafeDeviceName("Ryan1"))
        assertEquals("<name>", logSafeDeviceName("Anna2"))
        assertEquals("<name>", logSafeDeviceName("Bob12"))
        assertEquals("<name> Whoop", logSafeDeviceName("Sam99 Whoop"))
    }

    /** The listed codes still survive, so the tightening did not cost the diagnostic. */
    @Test fun listedModelCodesStillSurvive() {
        assertEquals("Polar H10", logSafeDeviceName("Polar H10"))
        assertEquals("Polar OH1", logSafeDeviceName("Polar OH1"))
    }


    /**
     * Field evidence (a 2026-09-05 staging log): serials beginning with a LETTER walked straight through
     * the old rule, which demanded a digit after "WHOOP ". Both spellings must mask.
     */
    @Test fun `masks a serial whatever character it starts with`() {
        assertEquals("Discovered WHOOP <serial> (rssi -48) - connecting",
            redactStrapLogPii("Discovered WHOOP MGB0779473 (rssi -48) - connecting"))
        assertEquals("Discovered WHOOP <serial> (rssi -63)",
            redactStrapLogPii("Discovered WHOOP 4C1594026 (rssi -63)"))
        assertEquals("WHOOP <serial>", redactStrapLogPii("WHOOP 5AG0393796"))
    }

    /**
     * The digit requirement earns its keep here. "WHOOP PUFFIN service 1150" is a real diagnostic line
     * from the same log, and PUFFIN is six alnum characters - a length-only rule would mask it and
     * destroy the meaning of the line.
     */
    @Test fun `does not mask a WHOOP-prefixed WORD`() {
        val line = "WHOOP PUFFIN service 1150 detected but unsupported"
        assertEquals(line, redactStrapLogPii(line))
    }

    /**
     * A bare serial with no "WHOOP " in front of it is NOT covered here, and deliberately so: the only
     * rule that could catch it keys on shape alone and would mask ordinary prose. Discovery lines - where
     * this actually occurred - are handled at the call site by [logSafeDeviceName] instead.
     */
    @Test fun `a bare serial is left to the call site, not guessed at here`() {
        assertEquals("Discovered WBB5BP1174092 (rssi -64)",
            redactStrapLogPii("Discovered WBB5BP1174092 (rssi -64)"))
        assertEquals("<name>", logSafeDeviceName("WBB5BP1174092"))
    }

}
