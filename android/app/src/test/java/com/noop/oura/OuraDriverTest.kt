package com.noop.oura

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * OuraDriver flow tests: the transport-agnostic state machine drives scan -> auth -> enable -> stream
 * purely from transitions (no BLE), and ingest(record:) decodes records (with Tier-B gating). Kotlin
 * twin of the Swift OuraDriverTests.swift.
 *
 * PARITY NOTE: the deterministic 16-byte app key (0..15), the rt anchor (0x00010002), and every
 * fixture hex string match the Swift OuraDriverTests fixtures byte-for-byte, so the same transitions
 * and the same record bytes drive the same commands/events across both ports.
 */
class OuraDriverTest {
    private val key: IntArray = IntArray(16) { it }   // deterministic 16-byte app key (0..15)
    private val rt: Long = 0x0001_0002

    private fun bytes(s: String) = OuraTestHex.bytes(s)

    @Test
    fun testIsPlausibleAnchorEpochBounds() {
        // The anchor plausibility window is [2020-01-01, 2035-01-01] UTC. OuraLiveSource reads this same
        // predicate to log WHY an anchor was rejected (#91), so the boundaries are pinned here. Twin of the
        // Swift OuraDriverTests.testIsPlausibleAnchorEpochBounds.
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        assertTrue(d.isPlausibleAnchorEpoch(1_577_836_800L))    // 2020-01-01, inclusive min
        assertTrue(d.isPlausibleAnchorEpoch(2_051_222_400L))    // 2035-01-01, inclusive max
        assertTrue(d.isPlausibleAnchorEpoch(1_700_000_000L))    // ~2023, mid-window
        assertFalse(d.isPlausibleAnchorEpoch(1_577_836_799L))   // one second before min
        assertFalse(d.isPlausibleAnchorEpoch(2_051_222_401L))   // one second past max
        assertFalse(d.isPlausibleAnchorEpoch(0L))               // epoch 0 — the ~1970 anchor #91 must avoid
    }

    // MARK: - Full happy-path step sequence (auth -> enable triplet -> streaming)

    @Test
    fun testFullEnableSequence() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        assertEquals(OuraDriverPhase.Idle, d.phase)

        // ready -> enable notifications + request nonce.
        val onReady = d.nextStep(OuraTransition.Ready)
        assertEquals(OuraDriverPhase.Authenticating, d.phase)
        assertEquals(listOf("notify_all", "get_nonce"), onReady.map { it.label })
        assertArrayEquals(intArrayOf(0x2F, 0x01, 0x2B), onReady[1].bytes)

        // nonce -> submit proof.
        val nonce = bytes("0102030405060708090a0b0c0d0e0f")
        val onNonce = d.nextStep(OuraTransition.NonceReceived(nonce))
        assertEquals(1, onNonce.size)
        assertArrayEquals(intArrayOf(0x2F, 0x11, 0x2D), onNonce[0].bytes.copyOfRange(0, 3))
        // The proof body matches the known vector.
        assertArrayEquals(bytes("c49fb9e83c46087a555183a9dc511ee9"), onNonce[0].bytes.copyOfRange(3, onNonce[0].bytes.size))

        // auth success -> first live-HR enable step (read DHR status).
        val onAuth = d.nextStep(OuraTransition.AuthCompleted(OuraAuthStatus.SUCCESS))
        assertEquals(OuraDriverPhase.EnablingLiveHR, d.phase)
        assertEquals(listOf("dhr_read"), onAuth.map { it.label })
        assertArrayEquals(intArrayOf(0x2F, 0x02, 0x20, 0x02), onAuth[0].bytes)

        // ack 1 -> enable ; ack 2 -> subscribe ; ack 3 -> streaming (no more commands).
        val step2 = d.nextStep(OuraTransition.EnableAckReceived)
        assertEquals(listOf("dhr_enable"), step2.map { it.label })
        assertArrayEquals(intArrayOf(0x2F, 0x03, 0x22, 0x02, 0x03), step2[0].bytes)

        val step3 = d.nextStep(OuraTransition.EnableAckReceived)
        assertEquals(listOf("dhr_subscribe"), step3.map { it.label })
        assertArrayEquals(intArrayOf(0x2F, 0x03, 0x26, 0x02, 0x02), step3[0].bytes)

        val done = d.nextStep(OuraTransition.EnableAckReceived)
        assertTrue(done.isEmpty())
        assertEquals(OuraDriverPhase.Streaming, d.phase)
    }

    // MARK: - Honest pairing path when no key

    @Test
    fun testNoKeyDrivesNeedsKeyInstall() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = null)
        val cmds = d.nextStep(OuraTransition.Ready)
        assertTrue("without an app key we cannot authenticate; emit no commands", cmds.isEmpty())
        assertEquals(OuraDriverPhase.NeedsKeyInstall, d.phase)
    }

    @Test
    fun testFactoryResetStatusDrivesNeedsKeyInstall() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        d.nextStep(OuraTransition.Ready)
        val cmds = d.nextStep(OuraTransition.AuthCompleted(OuraAuthStatus.IN_FACTORY_RESET))
        assertTrue(cmds.isEmpty())
        assertEquals(OuraDriverPhase.NeedsKeyInstall, d.phase)
    }

    @Test
    fun testAuthErrorIsSurfacedNotRetriedBlindly() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        d.nextStep(OuraTransition.Ready)
        d.nextStep(OuraTransition.AuthCompleted(OuraAuthStatus.AUTH_ERROR))
        assertEquals(OuraDriverPhase.AuthFailed(OuraAuthStatus.AUTH_ERROR), d.phase)
    }

    // MARK: - Post-factory-reset key install sequencing (s3.2), gated on allowKeyInstall

    /**
     * With allowKeyInstall == true the adopt flow sequences NeedsKeyInstall -> InstallingKey ->
     * (on the 0x25 ack) re-auth, and the post-install re-auth uses the freshly-provisioned key. Kotlin
     * twin of the Swift testKeyInstallSequencesReauthWhenAllowed (same key, nonce, proof vector).
     */
    @Test
    fun testKeyInstallSequencesReauthWhenAllowed() {
        // No injected key -> the honest needs-pairing path; the transport will provision one.
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = null, allowKeyInstall = true)
        val onReady = d.nextStep(OuraTransition.Ready)
        assertTrue(onReady.isEmpty())
        assertEquals(OuraDriverPhase.NeedsKeyInstall, d.phase)

        // The transport generates + persists a fresh 16-byte key and asks the driver for the install
        // command. It must be the DANGEROUS `24 10 <key>` write (s3.2) and advance to InstallingKey.
        val install = d.beginKeyInstall(key)
        assertTrue(install != null)
        assertEquals("DANGEROUS_install_key", install!!.label)
        assertArrayEquals(intArrayOf(0x24, 0x10) + key, install.bytes)
        assertEquals(OuraDriverPhase.InstallingKey, d.phase)

        // The ring acks with `25 01 00`; the transport calls back and the driver drives re-auth.
        val onAck = d.keyInstallAcknowledged()
        assertEquals(listOf("notify_all", "get_nonce"), onAck.map { it.label })
        assertArrayEquals(intArrayOf(0x2F, 0x01, 0x2B), onAck[1].bytes)
        assertEquals(OuraDriverPhase.Authenticating, d.phase)

        // Re-auth uses the freshly-installed key: the proof matches the known vector for that key.
        val nonce = bytes("0102030405060708090a0b0c0d0e0f")
        val onNonce = d.nextStep(OuraTransition.NonceReceived(nonce))
        assertEquals(1, onNonce.size)
        assertArrayEquals(intArrayOf(0x2F, 0x11, 0x2D), onNonce[0].bytes.copyOfRange(0, 3))
        assertArrayEquals(
            bytes("c49fb9e83c46087a555183a9dc511ee9"),
            onNonce[0].bytes.copyOfRange(3, onNonce[0].bytes.size),
        )
    }

    /**
     * With allowKeyInstall == false (the default) the driver MUST NOT sequence an install: it stays at
     * NeedsKeyInstall, emits no command, and a stray 0x25 ack cannot advance the flow.
     */
    @Test
    fun testNoKeyInstallSequencedWhenNotAllowed() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = null)   // allowKeyInstall defaults to false
        d.nextStep(OuraTransition.Ready)
        assertEquals(OuraDriverPhase.NeedsKeyInstall, d.phase)

        val install = d.beginKeyInstall(key)
        assertTrue("no dangerous 0x24 write may be produced without an opt-in adopt flow", install == null)
        assertEquals(OuraDriverPhase.NeedsKeyInstall, d.phase)

        // A stray ack must be ignored too (no install was sequenced, so there is nothing to acknowledge).
        val onAck = d.keyInstallAcknowledged()
        assertTrue(onAck.isEmpty())
        assertEquals(OuraDriverPhase.NeedsKeyInstall, d.phase)
    }

    /**
     * Even with allowKeyInstall == true, beginKeyInstall only fires from NeedsKeyInstall; a call from
     * another phase is a no-op (the gate is BOTH the flag and the phase).
     */
    @Test
    fun testKeyInstallIgnoredOutsideNeedsKeyInstallPhase() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key, allowKeyInstall = true)
        d.nextStep(OuraTransition.Ready)        // -> Authenticating (a real key is present)
        assertEquals(OuraDriverPhase.Authenticating, d.phase)
        assertTrue("install must not fire outside NeedsKeyInstall", d.beginKeyInstall(key) == null)
        assertEquals(OuraDriverPhase.Authenticating, d.phase)
    }

    // MARK: - History fetch loop

    @Test
    fun testHistoryFetchFlushesThenFetchesThenContinues() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        val start = d.nextStep(OuraTransition.StartHistoryFetch(cursor = 0L))
        assertEquals(OuraDriverPhase.FetchingHistory, d.phase)
        assertEquals(listOf("flush_buffer", "get_events"), start.map { it.label })
        // get_events cursor 0, max 255, flags FFFFFFFF.
        assertArrayEquals(
            intArrayOf(0x10, 0x09, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF),
            start[1].bytes,
        )

        // More data -> continuation fetch at the ADVANCED cursor, SAME shape as the initial request
        // (max 255, open_oura drain_events). The old max=0 "ack" made the ring restart its serve.
        val cont = d.nextStep(OuraTransition.HistoryCursorAdvanced(cursor = 0x12345678L, moreData = true))
        assertEquals(1, cont.size)
        assertArrayEquals(
            intArrayOf(0x10, 0x09, 0x78, 0x56, 0x34, 0x12, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF),
            cont[0].bytes,
        )

        // No more -> back to streaming.
        val stop = d.nextStep(OuraTransition.HistoryCursorAdvanced(cursor = 0x12345678L, moreData = false))
        assertTrue(stop.isEmpty())
        assertEquals(OuraDriverPhase.Streaming, d.phase)
    }

    @Test
    fun testSyncTimeCommandIsU64SecondsPlusTz() {
        // 12 09 <unix_seconds:8 LE> <tz:1> (s5.4, ringverse/open_oura layout — on-device proven; the
        // old open_ring token/counter/0xF6 guess never anchored on real hardware).
        val cmd = OuraCommands.syncTime(0x1061BCL, tzHalfHours = 4)
        assertEquals("sync_time", cmd.label)
        assertArrayEquals(
            intArrayOf(0x12, 0x09, 0xBC, 0x61, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04),
            cmd.bytes,
        )
    }

    // MARK: - Ring-time -> UTC anchor (s5.5)

    /**
     * Little-endian bytes of the RAW 0x42 wire value the decoder reads into [OuraTimeSync.epochMs]. The
     * wire value is unix SECONDS (s6.11), despite the field's "epochMs" name (which reflects what
     * OURA_PROTOCOL.md s6.11 claims, not what the driver now does with it), so tests build this from a
     * seconds value. Byte-for-byte identical to the Swift OuraDriverTests `le8` helper.
     */
    private fun le8(v: Long): IntArray = IntArray(8) { ((v ushr (8 * it)) and 0xFFL).toInt() }

    @Test
    fun testNoAnchorBeforeAnyTimeSyncOrBeacon() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        assertNull(d.unixSeconds(forRingTimestamp = rt))
    }

    @Test
    fun testTimeSyncSetsAnchorAndConvertsPastAndFutureRingTimes() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        val anchorEpochSeconds = 1_700_000_000L   // the wire's raw value (seconds, not ms)
        val anchorRt = 10_000L
        val payload = le8(anchorEpochSeconds) + intArrayOf(0x00)   // raw wire epoch (8B) + tz offset (0 half-hours)
        val rec = OuraRecord(type = OuraEventTag.TIME_SYNC.raw, ringTimestamp = anchorRt, payload = payload)
        val events = d.ingest(rec)
        assertEquals(
            listOf(
                OuraEvent.TimeSyncEvent(
                    OuraTimeSync(ringTimestamp = anchorRt, epochMs = anchorEpochSeconds, tzOffsetSeconds = 0),
                ),
            ),
            events,
        )

        // Exactly at the anchor: the driver applies the x1000 seconds->ms correction internally, so
        // unixSeconds recovers the ORIGINAL seconds value.
        assertEquals(anchorEpochSeconds, d.unixSeconds(forRingTimestamp = anchorRt))
        // 100 ticks (10s at the default 100ms/tick) BEFORE the anchor -> 10s earlier (a past/historical
        // record, e.g. from a GetEvents history fetch).
        assertEquals(anchorEpochSeconds - 10, d.unixSeconds(forRingTimestamp = anchorRt - 100))
        // 100 ticks AFTER the anchor -> 10s later.
        assertEquals(anchorEpochSeconds + 10, d.unixSeconds(forRingTimestamp = anchorRt + 100))
    }

    @Test
    fun testRtcBeaconOnlyAnchorsWhenNoTimeSyncSeenYet() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        val beaconRt = 5_000L
        val beaconUnixSeconds = 1_700_000_500L
        // 0x85 rtc_beacon_ind: unix_s u32 LE + trailer (payload just needs >= 4 bytes).
        val beaconPayload = intArrayOf(
            (beaconUnixSeconds and 0xFF).toInt(), ((beaconUnixSeconds shr 8) and 0xFF).toInt(),
            ((beaconUnixSeconds shr 16) and 0xFF).toInt(), ((beaconUnixSeconds shr 24) and 0xFF).toInt(),
        )
        val beaconRec = OuraRecord(type = OuraEventTag.RTC_BEACON.raw, ringTimestamp = beaconRt, payload = beaconPayload)
        d.ingest(beaconRec)
        assertEquals(beaconUnixSeconds, d.unixSeconds(forRingTimestamp = beaconRt))

        // A later, more precise 0x42 time-sync must override the coarser beacon anchor.
        val syncEpochSeconds = 1_700_001_000L
        val syncRt = 6_000L
        val syncPayload = le8(syncEpochSeconds) + intArrayOf(0x00)
        val syncRec = OuraRecord(type = OuraEventTag.TIME_SYNC.raw, ringTimestamp = syncRt, payload = syncPayload)
        d.ingest(syncRec)
        assertEquals(syncEpochSeconds, d.unixSeconds(forRingTimestamp = syncRt))

        // A SECOND beacon after a time-sync anchor is already set must NOT override it (secondary only
        // fills a gap, never displaces the primary source).
        val laterBeaconRec = OuraRecord(
            type = OuraEventTag.RTC_BEACON.raw, ringTimestamp = syncRt + 100, payload = beaconPayload,
        )
        d.ingest(laterBeaconRec)
        assertEquals(
            "a later RTC beacon must not displace an already-set time-sync anchor",
            syncEpochSeconds, d.unixSeconds(forRingTimestamp = syncRt),
        )
    }

    @Test
    fun testStopClearsTheAnchor() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        val payload = le8(1_700_000_000L) + intArrayOf(0x00)
        val rec = OuraRecord(type = OuraEventTag.TIME_SYNC.raw, ringTimestamp = 1_000L, payload = payload)
        d.ingest(rec)
        assertNotNull(d.unixSeconds(forRingTimestamp = 1_000L))
        d.stop()
        assertNull("a stale anchor must not survive stop()/a new session", d.unixSeconds(forRingTimestamp = 1_000L))
    }

    /**
     * Regression test for the crash-safety rule (s6.11): a full cursor=0 history dump can hit a 0x42
     * record deep in the backlog with an implausible raw value that would overflow Long on the naive
     * seconds->ms `* 1000` conversion. The plausibility gate must reject it WITHOUT crashing and WITHOUT
     * setting a garbage anchor. Kotlin twin of Swift's testImplausibleTimeSyncNeverCrashesOrAnchors.
     */
    @Test
    fun testImplausibleTimeSyncNeverCrashesOrAnchors() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        val hugePayload = le8(Long.MAX_VALUE) + intArrayOf(0x00)   // the exact class of value that overflows the multiply
        val hugeRec = OuraRecord(type = OuraEventTag.TIME_SYNC.raw, ringTimestamp = 1_000L, payload = hugePayload)
        d.ingest(hugeRec)   // must not throw
        assertNull("an implausible epoch must never become the anchor", d.unixSeconds(forRingTimestamp = 1_000L))

        // A negative epoch (int64 sign bit set on a misaligned record) must be equally rejected.
        val negativePayload = le8(-1L) + intArrayOf(0x00)
        val negativeRec = OuraRecord(type = OuraEventTag.TIME_SYNC.raw, ringTimestamp = 2_000L, payload = negativePayload)
        d.ingest(negativeRec)   // must not throw
        assertNull(d.unixSeconds(forRingTimestamp = 2_000L))

        // A GOOD time-sync arriving afterward must still anchor normally (the gate doesn't wedge the driver).
        val goodPayload = le8(1_700_000_000L) + intArrayOf(0x00)
        val goodRec = OuraRecord(type = OuraEventTag.TIME_SYNC.raw, ringTimestamp = 3_000L, payload = goodPayload)
        d.ingest(goodRec)
        assertEquals(1_700_000_000L, d.unixSeconds(forRingTimestamp = 3_000L))
    }

    // MARK: - ingest(record:) decoding

    @Test
    fun testIngestDecodesTierARecord() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        // 0x7B SpO2 stable record -> one spo2 event (970, BE).
        val rec = OuraFraming.parseRecord(bytes("7b060200010003ca"))!!
        val events = d.ingest(rec)
        assertEquals(listOf(OuraEvent.Spo2(OuraSpO2(ringTimestamp = rt, value = 970))), events)
    }

    @Test
    fun testIngestUnknownTagYieldsNothing() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        // 0x99 is not in the dictionary -> [] (never a guessed value).
        val rec = OuraRecord(type = 0x99, ringTimestamp = rt, payload = intArrayOf(0x01, 0x02))
        assertEquals(emptyList<OuraEvent>(), d.ingest(rec))
    }

    // MARK: - Tier-B gating

    @Test
    fun testTierBDroppedByDefault() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)   // allowTierB defaults to false
        // 0x49 sleep_summary_1 is Tier B (UNVERIFIED).
        val rec = OuraFraming.parseRecord(bytes("49080200010001020304"))!!
        assertEquals(
            "Tier-B must not feed values when not explicitly allowed",
            emptyList<OuraEvent>(),
            d.ingest(rec),
        )
    }

    @Test
    fun testTierBEmittedOnlyWhenAllowed() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key, allowTierB = true)
        val rec = OuraFraming.parseRecord(bytes("49080200010001020304"))!!
        val events = d.ingest(rec)
        assertEquals(1, events.size)
        assertTrue(events[0].isTierB)
        val ev = events[0]
        assertTrue("expected a tierB event", ev is OuraEvent.TierB)
        ev as OuraEvent.TierB
        assertEquals(0x49, ev.value.tag)
        assertEquals("sleep_summary", ev.value.kind)
        assertArrayEquals(bytes("01020304"), ev.value.rawPayload)
    }

    // MARK: - #287: 0x71 green_ibi_and_amp demoted to Tier B (twin of the Swift OuraDriverTests)

    @Test
    fun testGreenIBIAmp0x71TierIsB() {
        // TIER_A == corpus-verified; no captured 0x71 fixture + §6.2 documents a different layout than the
        // 0x60 decoder it was wired to, so it must NOT be Tier A.
        assertEquals(TrustTier.TIER_B, OuraEventTag.GREEN_IBI_AMP.tier)
    }

    @Test
    fun testGreenIBIAmp0x71GatedOutOfLiveEmission() {
        // The SAME body the 0x60 decoder turns into IBIs, but tagged 0x71. Under the old Tier-A routing it
        // fed fabricated R-R into HRV; now Tier B → by default it yields NOTHING.
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)   // allowTierB defaults to false
        val rec = OuraFraming.parseRecord(bytes("7112020001007d10000000000000000000000007"))!!
        assertEquals(
            "0x71 must not emit IBIs - it is not corpus-verified (#287)",
            emptyList<OuraEvent>(), d.ingest(rec),
        )
        // Control: the same bytes ARE otherwise decodable, so the [] above is the tier gate, not a short body.
        assertNotNull("0x60 decoder still yields IBIs for these bytes", OuraDecoders.decodeIBIAmplitude(rec))
    }

    @Test
    fun testGreenIBIAmp0x71EmitsRawSummaryNotIBIUnderAllowTierB() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key, allowTierB = true)
        val rec = OuraFraming.parseRecord(bytes("7112020001007d10000000000000000000000007"))!!
        val events = d.ingest(rec)
        assertEquals(1, events.size)
        assertTrue(events[0].isTierB)
        val ev = events[0]
        assertTrue("expected a tierB raw-bytes summary, not a fabricated IBI", ev is OuraEvent.TierB)
        ev as OuraEvent.TierB
        assertEquals(0x71, ev.value.tag)
        assertEquals("green_ibi_amp", ev.value.kind)
        for (e in events) assertFalse("0x71 must never emit Ibi (#287)", e is OuraEvent.Ibi)
    }

    // MARK: - Activity info (0x50, Tier B, third-party formula) - real Gen 3 captures (PR #960)
    //
    // PARITY: the six payloads below are byte-for-byte the real Gen 3 captures pinned in the Swift
    // OuraDriverTests (PR #960 investigation, 2026-07-02): three short static captures, then a full day
    // from steady resting (~0.9 MET) through a vigorous-activity burst (7.4 MET). The ringTimestamp was
    // not part of the captures, so the fixture `rt` stamps them - the pinned evidence is the decoded
    // state/MET values, each RECOMPUTED from the s6.13 formula (met = byte*0.1 below 0x80), not copied
    // blind (the v8.0.1 Oura SpO2 bug was a wrong-decode that asserted constants would have hidden).

    @Test
    fun testActivityInfoDecodesRealCapture1() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key, allowTierB = true)
        // Raw payload 41 12 13 13 20: state 0x41=65; MET 18*0.1, 19*0.1, 19*0.1, 32*0.1.
        val rec = OuraRecord(type = OuraEventTag.ACTIVITY_INFO.raw, ringTimestamp = rt,
                             payload = bytes("4112131320"))
        val events = d.ingest(rec)
        assertEquals(
            listOf<OuraEvent>(
                OuraEvent.ActivityInfo(
                    OuraActivityInfo(ringTimestamp = rt, state = 0x41, met = listOf(1.8, 1.9, 1.9, 3.2)),
                ),
            ),
            events,
        )
        assertTrue("activityInfo must still report isTierB - the formula is UNVERIFIED", events[0].isTierB)
    }

    @Test
    fun testActivityInfoDecodesRealCapture2() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key, allowTierB = true)
        // Raw payload 37 21 17 0e 0e 0d 0f 11: state 0x37=55; MET 3.3, 2.3, 1.4, 1.4, 1.3, 1.5, 1.7.
        val rec = OuraRecord(type = OuraEventTag.ACTIVITY_INFO.raw, ringTimestamp = rt,
                             payload = bytes("3721170e0e0d0f11"))
        assertEquals(
            listOf<OuraEvent>(
                OuraEvent.ActivityInfo(
                    OuraActivityInfo(ringTimestamp = rt, state = 0x37,
                                     met = listOf(3.3, 2.3, 1.4, 1.4, 1.3, 1.5, 1.7)),
                ),
            ),
            d.ingest(rec),
        )
    }

    @Test
    fun testActivityInfoDecodesRealCapture3() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key, allowTierB = true)
        // Raw payload 4a 19 20 0e 18: state 0x4a=74; MET 2.5, 3.2, 1.4, 2.4.
        val rec = OuraRecord(type = OuraEventTag.ACTIVITY_INFO.raw, ringTimestamp = rt,
                             payload = bytes("4a19200e18"))
        assertEquals(
            listOf<OuraEvent>(
                OuraEvent.ActivityInfo(
                    OuraActivityInfo(ringTimestamp = rt, state = 0x4a, met = listOf(2.5, 3.2, 1.4, 2.4)),
                ),
            ),
            d.ingest(rec),
        )
    }

    @Test
    fun testActivityInfoDecodesRealCapture4Resting() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key, allowTierB = true)
        // Full-day session, steady resting: state 0, MET 1.1 then 12 x 0.9 (bytes 0x0B, 0x09 x 12).
        val rec = OuraRecord(type = OuraEventTag.ACTIVITY_INFO.raw, ringTimestamp = rt,
                             payload = bytes("000b090909090909090909090909"))
        assertEquals(
            listOf<OuraEvent>(
                OuraEvent.ActivityInfo(
                    OuraActivityInfo(ringTimestamp = rt, state = 0,
                                     met = listOf(1.1, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9)),
                ),
            ),
            d.ingest(rec),
        )
    }

    @Test
    fun testActivityInfoDecodesRealCapture5ModerateActivity() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key, allowTierB = true)
        // Light/moderate period: state 0x2E=46, 13 MET samples 1.2-2.3.
        val rec = OuraRecord(type = OuraEventTag.ACTIVITY_INFO.raw, ringTimestamp = rt,
                             payload = bytes("2e1711110e0d110d0d0d0e0e0c13"))
        assertEquals(
            listOf<OuraEvent>(
                OuraEvent.ActivityInfo(
                    OuraActivityInfo(ringTimestamp = rt, state = 46,
                                     met = listOf(2.3, 1.7, 1.7, 1.4, 1.3, 1.7, 1.3, 1.3, 1.3, 1.4, 1.4, 1.2, 1.9)),
                ),
            ),
            d.ingest(rec),
        )
    }

    @Test
    fun testActivityInfoDecodesRealCapture6ExerciseBurst() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key, allowTierB = true)
        // Vigorous burst: state 0x8B=139 (high bit set on the STATE byte, which is NOT MET-encoded),
        // MET 1.8 and 7.4 (0x4A=74 -> 7.4, the highest real value seen). Also the shortest real payload
        // (2 samples), consistent with more frequent flushes during a high-variability period.
        val rec = OuraRecord(type = OuraEventTag.ACTIVITY_INFO.raw, ringTimestamp = rt,
                             payload = bytes("8b124a"))
        assertEquals(
            listOf<OuraEvent>(
                OuraEvent.ActivityInfo(
                    OuraActivityInfo(ringTimestamp = rt, state = 139, met = listOf(1.8, 7.4)),
                ),
            ),
            d.ingest(rec),
        )
    }

    @Test
    fun testActivityInfoHighByteBranchUsesCoarseSlope() {
        // No real capture has hit the >= 0x80 MET branch yet (nothing above 7.4 MET seen), so pin it
        // with SYNTHETIC vectors recomputed from the s6.13 formula: met = 12.8 + (byte - 128) * 0.2.
        //   0x80 = 128 -> 12.8  |  0x90 = 144 -> 12.8 + 16*0.2 = 16.0  |  0xFF = 255 -> 12.8 + 127*0.2 = 38.2
        val rec = OuraRecord(type = OuraEventTag.ACTIVITY_INFO.raw, ringTimestamp = rt,
                             payload = bytes("018090ff"))
        assertEquals(
            OuraActivityInfo(ringTimestamp = rt, state = 1, met = listOf(12.8, 16.0, 38.2)),
            OuraDecoders.decodeActivityInfo(rec),
        )
    }

    @Test
    fun testActivityInfoDroppedByDefaultLikeOtherTierB() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)   // allowTierB defaults to false
        val rec = OuraRecord(type = OuraEventTag.ACTIVITY_INFO.raw, ringTimestamp = rt,
                             payload = bytes("4112131320"))
        assertEquals(
            "the Tier-B gate must cover ActivityInfo too",
            emptyList<OuraEvent>(),
            d.ingest(rec),
        )
    }

    @Test
    fun testActivityInfoEmptyPayloadDecodesToNull() {
        // No state byte at all -> honest null, never a guessed state.
        assertNull(
            OuraDecoders.decodeActivityInfo(
                OuraRecord(type = OuraEventTag.ACTIVITY_INFO.raw, ringTimestamp = rt, payload = intArrayOf()),
            ),
        )
    }

    // MARK: - Live-HR push routing + decode

    @Test
    fun testHandleSecureFrameRoutesNonceStatusAndPush() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        val nonceFrame = OuraSecureFrame(subop = 0x2C, subBody = bytes("0102030405060708090a0b0c0d0e0f"))
        assertEquals(
            OuraDriver.SecureRouting.Nonce(bytes("0102030405060708090a0b0c0d0e0f")),
            d.handleSecureFrame(nonceFrame),
        )

        val statusFrame = OuraSecureFrame(subop = 0x2E, subBody = intArrayOf(0x00))
        assertEquals(OuraDriver.SecureRouting.AuthStatus(OuraAuthStatus.SUCCESS), d.handleSecureFrame(statusFrame))

        val ackFrame = OuraSecureFrame(subop = 0x23, subBody = intArrayOf(0x02, 0x00))
        assertEquals(OuraDriver.SecureRouting.EnableAck, d.handleSecureFrame(ackFrame))

        // s5.6 step 1: the dhr_read feature-read ACK (`2f 06 21 02 01 11 02 00`) is subop 0x21 with body
        // `02 01 11 02 00`. It must route to EnableAck or the enable triplet stalls at step 0 (#900).
        val dhrReadAck = OuraSecureFrame(subop = 0x21, subBody = bytes("0201110200"))
        assertEquals(OuraDriver.SecureRouting.EnableAck, d.handleSecureFrame(dhrReadAck))

        // The push subBody is the 14 bytes AFTER `2f 0f 28` from the s5.6 wire frame (IBI at [5..6]).
        val pushBody = bytes("020002000001040000000000007f")
        assertEquals(14, pushBody.size)
        assertEquals(
            OuraDriver.SecureRouting.LiveHRPush(pushBody),
            d.handleSecureFrame(OuraSecureFrame(subop = 0x28, subBody = pushBody)),
        )
    }

    @Test
    fun testLiveHRPushIngestStampsLastRingTime() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        // Ingest a TLV record first so the driver learns a ring time to stamp the push with.
        val rec = OuraFraming.parseRecord(bytes("420d0200010000d2dd639001000002"))!!
        d.ingest(rec)
        // The push body is the 14-byte s5.6 subBody (after `2f 0f 28`); IBI at [5..6] = 01 04 -> 1025 ms.
        val push = bytes("020002000001040000000000007f")
        val events = d.ingestLiveHRPush(push)
        assertEquals(
            listOf(
                OuraEvent.Hr(OuraHR(ringTimestamp = rt, bpm = 59, ibiMs = 1025)),
                OuraEvent.Ibi(OuraIBI(ringTimestamp = rt, ibiMs = 1025)),
            ),
            events,
        )
    }

    // MARK: - Notification-level ingest (one-packet-per-notification, twin of Swift dae3d7a4)

    @Test
    fun testIngestNotificationParsesOnePacketPerValue() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        val reassembler = OuraReassembler()
        // A second record packed behind the first is padding under the one-packet model: only the
        // FIRST record decodes (the old buffering loop minted phantom records from such tails).
        val value = bytes("7b060200010003ca" + "460802000100420e470e")
        val events = d.ingest(notification = value, reassembler = reassembler)
        assertEquals(1, events.size)
        assertEquals(OuraEvent.Spo2(OuraSpO2(ringTimestamp = rt, value = 970)), events[0])
        // Each notification decodes on its own: the temp record in its OWN value decodes fully.
        val tempEvents = d.ingest(notification = bytes("460802000100420e470e"), reassembler = reassembler)
        assertEquals(2, tempEvents.size)
        assertEquals(36.50, (tempEvents[0] as OuraEvent.Temp).value.celsius, 1e-9)
        assertEquals(36.55, (tempEvents[1] as OuraEvent.Temp).value.celsius, 1e-9)
    }

    // MARK: - Generation-driven command set / MTU

    @Test
    fun testRingGenMtuAndCaps() {
        assertEquals(203, OuraRingGen.GEN3.mtu)
        assertEquals(247, OuraRingGen.GEN5.mtu)
        assertTrue(OuraRingGen.GEN5.hasExtraNotifyChars)
        assertTrue(!OuraRingGen.GEN3.hasExtraNotifyChars)
        assertEquals(OuraRingGen.GEN5, OuraRingGen.from("Oura Ring 5"))
        assertEquals(OuraRingGen.GEN3, OuraRingGen.from("Oura Ring 3"))
        assertTrue(OuraRingGen.GEN3.capabilities.contains(OuraMetric.HRV))
    }

    // MARK: - Dangerous commands are isolated and labelled

    @Test
    fun testDangerousCommandsAreClearlyNamed() {
        assertArrayEquals(intArrayOf(0x0E, 0x01, 0xFF), OuraDangerousCommands.softReset().bytes)
        assertTrue(OuraDangerousCommands.softReset().label.startsWith("DANGEROUS_"))
        assertTrue(OuraDangerousCommands.factoryReset().label.startsWith("DANGEROUS_"))
        // The normal command builders never produce a reboot/reset opcode.
        assertTrue(OuraCommands.getBattery().bytes[0] != 0x0E)
        assertTrue(OuraCommands.getBattery().bytes[0] != 0x1A)
    }

    /**
     * #1073: a banked sample that converts to the future is rejected (the caller falls back to arrival
     * time), while a historical sample still converts. "now" is injected so the test does not touch the
     * wall clock. Byte-parity with Swift `testSampleConvertingToFutureIsRejected`.
     */
    @Test
    fun sampleConvertingToFutureIsRejected() {
        val anchorSeconds = 1_700_000_000L               // 2023-11-14, mid anchor window
        val anchorRt = 1_000_000L
        // Freeze "now" AT the anchor instant, so any sample after the anchor is "in the future".
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key, nowMsProvider = { anchorSeconds * 1000 })
        assertTrue(d.adoptSyncTimeAnchor(ringTimestamp = anchorRt, unixSeconds = anchorSeconds))

        // Historical (10s before now) and exactly-now still convert.
        assertEquals(anchorSeconds - 10, d.unixSeconds(forRingTimestamp = anchorRt - 100))
        assertEquals(anchorSeconds, d.unixSeconds(forRingTimestamp = anchorRt))
        // Inside the 300s skew tolerance (+200s) still converts.
        assertEquals(anchorSeconds + 200, d.unixSeconds(forRingTimestamp = anchorRt + 2_000))
        // Just past the tolerance (+301s) is rejected as future/corrupt.
        assertNull(d.unixSeconds(forRingTimestamp = anchorRt + 3_010))
        // The regression #1073 is about: a sample ~1 year ahead (inside the OLD 2020-2035 window, so the
        // old gate banked it) is now rejected because it is after `now`.
        assertNull(d.unixSeconds(forRingTimestamp = anchorRt + 315_360_000))
    }

    /**
     * The two gates are decoupled (#1073): anchor ADOPTION still uses the full 2020-2035 window even when
     * "now" is frozen years earlier — only per-sample conversion is bounded by now. Byte-parity with Swift
     * `testAnchorAdoptionStillUsesFullWindowIndependentOfNow`.
     */
    @Test
    fun anchorAdoptionStillUsesFullWindowIndependentOfNow() {
        val futureAnchorSeconds = 2_020_000_000L         // 2034, inside the 2020-2035 anchor window
        val anchorRt = 500L
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key, nowMsProvider = { 1_700_000_000L * 1000 })
        assertTrue("a 2034 anchor is still adopted — adoption uses the window, not now",
            d.adoptSyncTimeAnchor(ringTimestamp = anchorRt, unixSeconds = futureAnchorSeconds))
        assertNull("but converting a 2034 sample is rejected because it is after now (2023)",
            d.unixSeconds(forRingTimestamp = anchorRt))
    }
}
