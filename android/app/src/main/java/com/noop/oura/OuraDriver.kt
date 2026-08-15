package com.noop.oura

// OuraDriver: the transport-agnostic protocol state machine. Kotlin twin of OuraDriver.swift. It holds
// NO BLE handle: the app's live source owns the BluetoothGatt / CBCentralManager and feeds the driver
// only bytes + transition events. This is what makes the protocol headless-testable (no
// android.bluetooth, no CoreBluetooth anywhere in this package).
//
// Two entry points:
//   - nextStep(after:) -> List<OuraCommand>   : given the last transition, return the commands to write.
//   - ingest(record:) -> List<OuraEvent>      : given a parsed TLV record, return decoded events.
//   - ingestLiveHRPush(body:) -> List<OuraEvent> : given a 0x2F sub-op 0x28 push body, return live HR.
//
// The flow mirrors OURA_PROTOCOL.md s3 (auth) + s5 (live HR / fetch): scan -> connect -> notify ->
// auth (nonce, proof) -> enable live HR (gen-appropriate triplet) -> stream. RingGen swaps the
// command set, not the code path.
//
// Tier discipline: Tier-B decoders are present but gated behind `allowTierB` (default false). When
// false, a Tier-B tag decodes to nothing (the event is dropped), so Tier-B values can never feed
// scoring silently. Per the brief's TIER DISCIPLINE and OURA_PROTOCOL.md s7.3.

/**
 * A transport-level transition the app reports to the driver to advance the flow. The driver answers
 * with the next batch of commands. This keeps all BLE specifics (peripheral, GATT callbacks) in the
 * app and all protocol specifics here. Kotlin twin of Swift's OuraTransition enum.
 */
sealed class OuraTransition {
    /** Service + characteristics discovered and notifications enabled on ...0003. Begin auth. */
    object Ready : OuraTransition()

    /** A 15-byte nonce arrived (from the GetAuthNonce response). Compute + submit the proof. */
    data class NonceReceived(val nonce: IntArray) : OuraTransition() {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is NonceReceived) return false
            return nonce.contentEquals(other.nonce)
        }
        override fun hashCode(): Int = nonce.contentHashCode()
    }

    /** The auth handshake completed with this status. On success, begin enabling live HR. */
    data class AuthCompleted(val status: OuraAuthStatus) : OuraTransition()

    /** A live-HR enable/subscribe ACK arrived; advance the triplet (or, when done, mark streaming). */
    object EnableAckReceived : OuraTransition()

    /** The app wants to fetch buffered history from this cursor (optional path). */
    data class StartHistoryFetch(val cursor: Long) : OuraTransition()

    /** The last GetEvents response advanced the cursor to this value; continue or stop. */
    data class HistoryCursorAdvanced(val cursor: Long, val moreData: Boolean) : OuraTransition()
}

/**
 * The driver's coarse phase, exposed for the app and tests to assert on. Kotlin twin of Swift's
 * OuraDriverPhase enum.
 */
sealed class OuraDriverPhase {
    object Idle : OuraDriverPhase()
    object Authenticating : OuraDriverPhase()
    object EnablingLiveHR : OuraDriverPhase()
    object Streaming : OuraDriverPhase()
    object FetchingHistory : OuraDriverPhase()

    /** Ring is in factory reset; honest pairing path (s3.5 status 0x02). */
    object NeedsKeyInstall : OuraDriverPhase()

    /** Post-factory-reset key install in flight (s3.2); awaiting the 0x25 ack. */
    object InstallingKey : OuraDriverPhase()

    data class AuthFailed(val status: OuraAuthStatus) : OuraDriverPhase()
    object Stopped : OuraDriverPhase()
}

class OuraDriver(
    val ringGen: OuraRingGen,
    /**
     * The 16-byte application auth key (injected, never hardcoded). null drives the honest
     * needs-pairing path (the app surfaces "needsPairing" instead of faking data).
     */
    private val authKey: IntArray?,
    /** When false (default), Tier-B (UNVERIFIED) tags decode to nothing so they can never feed scoring. */
    val allowTierB: Boolean = false,
    /**
     * When false (default), the driver MUST NOT sequence a post-factory-reset key install: it stays at
     * NeedsKeyInstall and writes nothing dangerous. Only an explicit opt-in adopt flow sets this true.
     * Per OURA_PROTOCOL.md s3.2 (the 0x24 SetAuthKey is a DANGEROUS, one-time provisioning write).
     */
    val allowKeyInstall: Boolean = false,
    /**
     * Wall-clock "now" in unix ms, used ONLY to reject a banked sample that converts to the future
     * (#1073). Injectable so the gate is testable without touching the system clock; defaults to the
     * real clock, so no ingest call site has to thread it. Twin of Swift's `nowMsProvider`.
     */
    private val nowMsProvider: () -> Long = { System.currentTimeMillis() },
) {
    var phase: OuraDriverPhase = OuraDriverPhase.Idle
        private set

    /** Tracks how many of the live-HR enable triplet ACKs have been seen. */
    private var liveHREnableStep = 0

    /**
     * The most recent ring time seen on any record, used to stamp live-HR pushes (which are not TLV
     * records and carry no timestamp of their own).
     */
    private var lastRingTimestamp: Long = 0

    /**
     * Ring-time -> UTC anchor (OURA_PROTOCOL.md s5.5): the ring's clock ticks at 100 ms/tick by default
     * (burst-mode 1 ms/tick, s5.5, is NOT modeled in v1). Set from the ring's own 0x42 time-sync event
     * (primary) or, only while no 0x42 has arrived yet THIS session, the coarser 1s-granularity 0x85 RTC
     * beacon (secondary). null until the first anchor event of this session: a record decoded before then
     * has no computable UTC time, and [unixSeconds] honestly returns null rather than guessing. A stale
     * anchor from a PREVIOUS session is never reused - the ring may have rebooted. Kotlin twin of Swift's
     * anchorUtcMs/anchorRingTime.
     */
    private var anchorUtcMs: Long? = null
    private var anchorRingTime: Long? = null

    /**
     * The freshly-provisioned key the transport generated during an adopt flow (s3.2). Once set by
     * beginKeyInstall it becomes the effective key for the post-install re-auth. null otherwise.
     */
    private var installedKey: IntArray? = null

    /**
     * The key the auth handshake should use: the freshly-installed key takes precedence over the
     * injected one (so re-auth after a key install uses the new key). Per OURA_PROTOCOL.md s3.2.
     */
    private val effectiveKey: IntArray?
        get() = installedKey ?: authKey

    // MARK: - Command flow

    /**
     * Given the last transport transition, return the commands the app should write next. Pure: it
     * only mutates the driver's own phase, never touches BLE. Per OURA_PROTOCOL.md s3 / s5.
     */
    fun nextStep(after: OuraTransition): List<OuraCommand> = when (after) {
        is OuraTransition.Ready -> {
            // No app key -> we cannot authenticate; surface the honest pairing path (no faked data).
            if (effectiveKey == null) {
                phase = OuraDriverPhase.NeedsKeyInstall
                emptyList()
            } else {
                phase = OuraDriverPhase.Authenticating
                // Enable notifications, then request the auth nonce. SyncTime can follow auth.
                listOf(
                    OuraCommands.enableAllNotifications(),
                    OuraCommand("get_nonce", OuraAuth.getAuthNonceCommand()),
                )
            }
        }

        is OuraTransition.NonceReceived -> {
            val key = effectiveKey
            if (key == null) {
                phase = OuraDriverPhase.NeedsKeyInstall
                emptyList()
            } else {
                // Compute the proof and submit it. On any crypto error, fail honestly (no proof sent).
                val cmd = try {
                    OuraAuth.authenticateCommand(after.nonce, key)
                } catch (e: Exception) {
                    null
                }
                if (cmd == null) {
                    phase = OuraDriverPhase.AuthFailed(OuraAuthStatus.AUTH_ERROR)
                    emptyList()
                } else {
                    listOf(OuraCommand("submit_proof", cmd))
                }
            }
        }

        is OuraTransition.AuthCompleted -> when (after.status) {
            OuraAuthStatus.SUCCESS -> {
                phase = OuraDriverPhase.EnablingLiveHR
                liveHREnableStep = 0
                // Begin the live-HR enable triplet (gen-appropriate; gen3 verified, gen4/5 same path).
                listOf(OuraCommands.liveHREnableSequence()[0])
            }
            OuraAuthStatus.IN_FACTORY_RESET -> {
                // Ring needs a key install first; this is an explicit, named provisioning step the app
                // drives, not the normal flow. Surface honestly.
                phase = OuraDriverPhase.NeedsKeyInstall
                emptyList()
            }
            OuraAuthStatus.AUTH_ERROR, OuraAuthStatus.NOT_ORIGINAL_DEVICE -> {
                phase = OuraDriverPhase.AuthFailed(after.status)
                emptyList()
            }
        }

        is OuraTransition.EnableAckReceived -> {
            if (phase != OuraDriverPhase.EnablingLiveHR) {
                emptyList()
            } else {
                liveHREnableStep += 1
                val seq = OuraCommands.liveHREnableSequence()
                if (liveHREnableStep < seq.size) {
                    listOf(seq[liveHREnableStep])
                } else {
                    // All three ACKed: HR/IBI now streams as 0x2F sub-op 0x28 pushes.
                    phase = OuraDriverPhase.Streaming
                    emptyList()
                }
            }
        }

        is OuraTransition.StartHistoryFetch -> {
            phase = OuraDriverPhase.FetchingHistory
            // Flush flash buffer first, then fetch up to 255 events from the cursor (s5.3).
            listOf(
                OuraCommands.flushBuffer(),
                OuraCommands.getEvents(cursor = after.cursor, maxEvents = 255),
            )
        }

        is OuraTransition.HistoryCursorAdvanced -> {
            if (!after.moreData) {
                phase = OuraDriverPhase.Streaming
                emptyList()
            } else {
                // Continuation fetch at the ADVANCED cursor (max seen ring-time + 1), same shape as the
                // initial request — open_oura drain_events re-issues (start, 255, -1) every batch. The
                // old open_ring "ack-fetch" (max=0 at a non-advancing cursor) made the ring RESTART its
                // serve from that cursor: the observed same-window re-serve loop (s5.3). Parity with
                // Swift 2bbdaa42.
                listOf(OuraCommands.getEvents(cursor = after.cursor, maxEvents = 255))
            }
        }
    }

    /**
     * Re-engage live HR (daytime-HR auto-reverts after ~20 s; the app calls this every ~15 s while a
     * live session is open). Per OURA_PROTOCOL.md s5.7. Returns the enable+subscribe commands.
     */
    fun reengageLiveHRCommands(): List<OuraCommand> =
        listOf(OuraCommands.liveHREnable(), OuraCommands.liveHRSubscribe())

    // MARK: - Post-factory-reset key install (adopt flow, s3.2)

    /**
     * Begin the one-time post-factory-reset key install (OURA_PROTOCOL.md s3.2). The transport in the
     * adopt flow generates a fresh 16-byte key, persists it, and calls this to obtain the dangerous
     * `24 10 <key>` write; once the ring replies `25 01 00` the transport calls keyInstallAcknowledged
     * to drive re-auth.
     *
     * SAFETY GATE: this only sequences an install when phase == NeedsKeyInstall AND allowKeyInstall is
     * true. When allowKeyInstall is false it stays at NeedsKeyInstall and returns null, so the
     * dangerous 0x24 write is never emitted outside an explicit opt-in adopt flow. Returns null (and
     * leaves phase unchanged) when not gated on, the key length is wrong, or the command cannot build.
     * Kotlin twin of Swift's beginKeyInstall.
     */
    fun beginKeyInstall(key: IntArray): OuraCommand? {
        if (!allowKeyInstall || phase != OuraDriverPhase.NeedsKeyInstall) return null
        val cmd = try {
            OuraDangerousCommands.installKey(key)
        } catch (e: Exception) {
            null
        } ?: return null
        installedKey = key                 // re-auth after the ack must use the freshly-provisioned key
        phase = OuraDriverPhase.InstallingKey
        return cmd
    }

    /**
     * Handle the ring's 0x25 SetAuthKey ack (`25 01 00`, s3.2) by driving re-auth with the freshly
     * installed key: transition InstallingKey -> Authenticating and return the same enable+nonce
     * commands the ready path uses. Returns [] (phase unchanged) when not in InstallingKey or when no
     * installed key is present, so a stray ack cannot advance the flow. Kotlin twin of Swift's
     * keyInstallAcknowledged.
     */
    fun keyInstallAcknowledged(): List<OuraCommand> {
        if (phase != OuraDriverPhase.InstallingKey || installedKey == null) return emptyList()
        phase = OuraDriverPhase.Authenticating
        return listOf(
            OuraCommands.enableAllNotifications(),
            OuraCommand("get_nonce", OuraAuth.getAuthNonceCommand()),
        )
    }

    /** Stop: reset the flow so a fresh session re-runs auth (the app key is session-scoped, s3.1). */
    fun stop() {
        phase = OuraDriverPhase.Stopped
        liveHREnableStep = 0
        lastRingTimestamp = 0
        installedKey = null
        // A stale anchor must not survive stop()/a new session - the ring may have rebooted (s5.5).
        anchorUtcMs = null
        anchorRingTime = null
    }

    // MARK: - Ring-time -> UTC anchor (s5.5)

    /**
     * Convert a record's ring-clock timestamp to unix seconds using the current session's anchor
     * (OURA_PROTOCOL.md s5.5). Returns null when no anchor has arrived yet this session, so the caller
     * can honestly fall back (e.g. to wall-clock arrival time) instead of guessing. Kotlin twin of
     * Swift's `unixSeconds(forRingTimestamp:)`. `rt` is the unsigned 32-bit ring timestamp as a Long.
     */
    fun unixSeconds(forRingTimestamp: Long): Long? {
        val anchorMs = anchorUtcMs ?: return null
        val anchorRt = anchorRingTime ?: return null
        val deltaTicks = forRingTimestamp - anchorRt
        val ms = anchorMs + deltaTicks * 100   // default 100 ms/tick (s5.5); bounded input, no overflow
        // #968: a corrupt/misaligned ring timestamp (seen on a full cursor=0 history dump) can convert to
        // an implausible epoch; return null so the caller falls back to arrival time instead of banking it.
        //
        // #1073: a banked SAMPLE is always in the past, so its upper bound is "now", NOT the 2020-2035
        // anchor window. That window is the right screen for ADOPTING a clock anchor and far too generous
        // for a sample — a corrupt ring timestamp that converts years ahead (measured on a live ring:
        // ~1,600 R-R beats stamped 2026→2034, and still accruing) passed it cleanly and got filed into a
        // future day, invisible to the night it belongs to. Gate a sample at `now + skew tolerance`
        // (minutes, absorbing ring-clock skew + anchor rounding) and keep the 2020 lower bound (the #968
        // 1970 guard). The 2020-2035 window stays in `plausibleAnchorMs`, for anchor adoption only.
        // Byte-identical to the Swift twin.
        val seconds = ms / 1000
        val nowSeconds = nowMsProvider() / 1000
        if (seconds < MIN_PLAUSIBLE_EPOCH_SECONDS || seconds > nowSeconds + SAMPLE_FUTURE_TOLERANCE_SECONDS) return null
        return seconds
    }

    /**
     * Set the session anchor from a decoded epoch (unix SECONDS on the wire, s6.11) if it is plausible.
     * `preferPrimary` is true for a 0x42 time-sync (always wins) and false for a 0x85 RTC beacon (fills a
     * gap only while no time-sync anchor exists yet). Kotlin twin of the anchor-set logic inlined in the
     * Swift driver's `.timeSync` / `.rtcBeacon` ingest cases.
     */
    private fun setAnchorIfPlausible(epochSeconds: Long, ringTimestamp: Long, preferPrimary: Boolean) {
        // A secondary (beacon) anchor never displaces an already-set primary (time-sync) anchor.
        if (!preferPrimary && anchorUtcMs != null) return
        val ms = plausibleAnchorMs(epochSeconds) ?: return
        anchorUtcMs = ms
        anchorRingTime = ringTimestamp
    }

    /**
     * Bounds-check a decoded epoch (unix seconds) and convert to ms, or null if implausible. Kotlin twin
     * of Swift's `plausibleAnchorMs(fromEpochSeconds:)`. The 2020-2035 gate rejects a corrupt/misaligned
     * 0x42/0x85 value (seen on real hardware: a full cursor=0 history dump hit one deep in the backlog) so
     * it is never trusted as an anchor (honest-data invariant). The gate ALSO bounds the input to the
     * seconds->ms `* 1000` conversion so it can never overflow Long.
     */
    private fun plausibleAnchorMs(epochSeconds: Long): Long? {
        if (epochSeconds < MIN_PLAUSIBLE_EPOCH_SECONDS || epochSeconds > MAX_PLAUSIBLE_EPOCH_SECONDS) return null
        return epochSeconds * 1000   // safe: bounded input, cannot overflow
    }

    /**
     * True when [epochSeconds] falls inside the anchor plausibility window (2020-01-01 .. 2035-01-01), i.e.
     * `setAnchorIfPlausible` would accept it. A 0x42/0x85 whose epoch is outside this is silently ignored so
     * a garbage value can't anchor history to ~1970. Exposed READ-ONLY so OuraLiveSource can log WHY an
     * anchor was rejected (#91) without duplicating the bounds or reaching into anchor state. Pure.
     */
    fun isPlausibleAnchorEpoch(epochSeconds: Long): Boolean = plausibleAnchorMs(epochSeconds) != null

    /**
     * Adopt a ring-time→UTC anchor from the 0x13 SyncTime response pair (`rt` = the ring's clock
     * counter in ticks when it processed our SyncTime, `unixSeconds` = host wall-clock at receipt).
     * Same plausibility gate as the 0x42/0x85 paths; returns whether the anchor was set. The freshest
     * possible pair, so it overwrites any earlier anchor (an in-log 0x42 from the same clock domain
     * yields the same mapping anyway). Byte-identical twin of Swift's adoptSyncTimeAnchor.
     */
    fun adoptSyncTimeAnchor(ringTimestamp: Long, unixSeconds: Long): Boolean {
        val ms = plausibleAnchorMs(unixSeconds) ?: return false
        anchorUtcMs = ms
        anchorRingTime = ringTimestamp
        return true
    }

    // MARK: - Record ingest (decode)

    /**
     * Decode one parsed TLV inner record into zero or more events. A malformed/short record (or an
     * unknown tag) yields []. Tier-B tags yield [] unless allowTierB is set. Per OURA_PROTOCOL.md s6.
     */
    fun ingest(record: OuraRecord): List<OuraEvent> {
        lastRingTimestamp = record.ringTimestamp
        val tag = OuraEventTag.fromRaw(record.type)
            // Unknown tag: decode to nothing, never a guessed value (honest-data invariant).
            ?: return emptyList()
        // Tier-B gate: when not explicitly allowed, drop the event so it cannot feed scoring.
        if (tag.tier == TrustTier.TIER_B && !allowTierB) {
            return emptyList()
        }
        return when (tag) {
            // --- Tier A: HR / IBI ---
            OuraEventTag.IBI_AMPLITUDE ->
                (OuraDecoders.decodeIBIAmplitude(record) ?: emptyList()).map { OuraEvent.Ibi(it) }
            OuraEventTag.GREEN_IBI_QUALITY ->
                (OuraDecoders.decodeGreenIBIQuality(record) ?: emptyList()).map { OuraEvent.Ibi(it) }
            OuraEventTag.SPO2_IBI_AMPLITUDE ->
                (OuraDecoders.decodeSpO2IBI(record) ?: emptyList()).map { OuraEvent.Ibi(it) }
            OuraEventTag.IBI ->
                // The bare 0x44 IBI tag shares the bit-packed layout family; route through the same
                // decoder, but stamp its OWN channel — same layout is not the same tag, and a stored beat
                // that cannot name which of the two produced it cannot answer whether they duplicate each
                // other (#1071 follow-up). Read identically to 0x60; this is a label, not a filter.
                (OuraDecoders.decodeIBIAmplitude(record, OuraIbiChannel.IBI_BARE) ?: emptyList())
                    .map { OuraEvent.Ibi(it) }

            // --- Tier A: HRV ---
            OuraEventTag.HRV_RMSSD ->
                (OuraDecoders.decodeHRV(record) ?: emptyList()).map { OuraEvent.Hrv(it) }

            // --- Tier A: SpO2 ---
            OuraEventTag.SPO2_PER_SAMPLE ->
                (OuraDecoders.decodeSpO2PerSample(record) ?: emptyList()).map { OuraEvent.Spo2(it) }
            OuraEventTag.SPO2_STABLE ->
                OuraDecoders.decodeSpO2Stable(record)?.let { listOf(OuraEvent.Spo2(it)) } ?: emptyList()
            OuraEventTag.SPO2_DC ->
                (OuraDecoders.decodeSpO2DC(record) ?: emptyList()).map { OuraEvent.Spo2(it) }

            // --- Tier A: Temperature ---
            OuraEventTag.TEMP ->
                (OuraDecoders.decodeTemp(record) ?: emptyList()).map { OuraEvent.Temp(it) }
            OuraEventTag.TEMP_PERIOD ->
                OuraDecoders.decodeTempPeriod(record)?.let { listOf(OuraEvent.Temp(it)) } ?: emptyList()
            OuraEventTag.SLEEP_TEMP ->
                (OuraDecoders.decodeSleepTemp(record) ?: emptyList()).map { OuraEvent.Temp(it) }

            // --- Tier A: Motion ---
            OuraEventTag.MOTION_PERIOD ->
                (OuraDecoders.decodeMotionPeriod(record) ?: emptyList()).map { OuraEvent.MotionEvent(it) }
            OuraEventTag.MOTION ->
                // 0x47 motion_events: the ring's averaged accel vector (orientation + avg x/y/z ×8 +
                // high_intensity), the same shape as a WHOOP 4.0 gravity sample. open_oura decode_motion,
                // OURA_PROTOCOL.md s6.13. Tier-A. Byte-identical twin of Swift.
                OuraDecoders.decodeMotionEvents(record)?.let { listOf(OuraEvent.MotionVectorEvent(it)) }
                    ?: emptyList()

            // --- Tier A: Sleep phase (2-bit codes are verified; 0x4B is the same layout, s6.12) ---
            OuraEventTag.SLEEP_PHASE_B, OuraEventTag.SLEEP_PHASE, OuraEventTag.SLEEP_PHASE_ALT ->
                (OuraDecoders.decodeSleepPhase(record) ?: emptyList()).map { OuraEvent.SleepPhaseEvent(it) }

            // --- Tier A: Lifecycle / state / time ---
            OuraEventTag.TIME_SYNC -> {
                // Primary UTC anchor (s5.5): always wins over a secondary RTC-beacon anchor already set.
                val ts = OuraDecoders.decodeTimeSync(record) ?: return emptyList()
                // UNIT CORRECTION (s6.11): the 0x42 wire value is unix SECONDS, not ms (treating it as ms
                // anchored history-fetched samples to ~1970). OuraTimeSync.epochMs still names what the doc
                // claims; the seconds->ms conversion lives in the anchor gate.
                // CRASH-SAFETY (s6.11): a full cursor=0 history dump can hit a 0x42 record with an
                // implausible raw value; plausibleAnchorMs bounds-checks BEFORE multiplying, so an
                // implausible value is safely ignored (never anchors to garbage) instead of overflowing.
                setAnchorIfPlausible(ts.epochMs, ts.ringTimestamp, preferPrimary = true)
                listOf(OuraEvent.TimeSyncEvent(ts))
            }
            OuraEventTag.RTC_BEACON -> {
                // Secondary UTC anchor (s5.5, 1s granularity): only fills in while no 0x42 anchor exists yet
                // this session, so a coarser beacon never overrides the primary time-sync anchor.
                val r = OuraDecoders.decodeRtcBeacon(record) ?: return emptyList()
                setAnchorIfPlausible(r.unixSeconds, r.ringTimestamp, preferPrimary = false)
                listOf(OuraEvent.RtcBeaconEvent(r))
            }
            OuraEventTag.STATE_CHANGE, OuraEventTag.WEAR_EVENT ->
                OuraDecoders.decodeState(record)?.let { listOf(OuraEvent.StateEvent(it)) } ?: emptyList()
            OuraEventTag.DEBUG_TEXT ->
                OuraDecoders.decodeDebugText(record)?.let {
                    listOf(OuraEvent.DebugTextEvent(ringTimestamp = record.ringTimestamp, text = it))
                } ?: emptyList()
            OuraEventTag.RING_START ->
                // 0x41 ring_start_ind: a lifecycle marker (the app uses it to invalidate the UTC anchor on
                // rt regression). It carries no biometric value, so emit nothing here. Per OURA_PROTOCOL.md
                // s5.5 / s6.15. The app observes ring-start via the record stream directly.
                emptyList()

            // --- Tier B (only reached when allowTierB == true; otherwise dropped above) ---
            OuraEventTag.GREEN_IBI_AMP ->
                // #287: 0x71 green_ibi_and_amp. Demoted from Tier A: the 0x60 decoder it used reads 6
                // ABSOLUTE IBIs, but §6.2 documents 0x71 as 5 IBI DELTAS + 6 amplitudes with a [2:0] shift,
                // so that decode fabricated a phantom R-R and corrupted HRV. With no captured 0x71 fixture we
                // cannot write a verified decoder yet, so emit the raw bytes for inspection (never folded into
                // scoring) rather than a guessed IBI. Gated above unless allowTierB. Promote on a real sample.
                listOf(
                    OuraEvent.TierB(
                        OuraTierBSummary(
                            tag = record.type, ringTimestamp = record.ringTimestamp,
                            rawPayload = record.payload, kind = "green_ibi_amp",
                        ),
                    ),
                )
            OuraEventTag.SLEEP_SUMMARY_1, OuraEventTag.SLEEP_SUMMARY_C,
            OuraEventTag.SLEEP_SUMMARY_D, OuraEventTag.SLEEP_SUMMARY_E, OuraEventTag.SLEEP_SUMMARY_F ->
                listOf(
                    OuraEvent.TierB(
                        OuraTierBSummary(
                            tag = record.type, ringTimestamp = record.ringTimestamp,
                            rawPayload = record.payload, kind = "sleep_summary",
                        ),
                    ),
                )
            OuraEventTag.ACTIVITY_INFO ->
                // Split out of the raw-bytes TierB wrapper: this ONE activity tag has a plausible decode
                // formula (OuraDecoders.decodeActivityInfo, third-party [oura-rs], PR #960 investigation).
                // Still Tier B - only reached behind allowTierB (gated above), and OuraStreamMapping never
                // folds ActivityInfo into a durable stream. 0x51/0x52 summaries stay raw below.
                OuraDecoders.decodeActivityInfo(record)?.let { listOf(OuraEvent.ActivityInfo(it)) }
                    ?: emptyList()
            OuraEventTag.ACTIVITY_SUMMARY_1, OuraEventTag.ACTIVITY_SUMMARY_2 ->
                listOf(
                    OuraEvent.TierB(
                        OuraTierBSummary(
                            tag = record.type, ringTimestamp = record.ringTimestamp,
                            rawPayload = record.payload, kind = "activity",
                        ),
                    ),
                )
            OuraEventTag.REAL_STEPS_1, OuraEventTag.REAL_STEPS_2 -> {
                // Split out of the raw-bytes TierB wrapper, same as ActivityInfo: this tag pair now has a
                // cited third-party unpack formula (OuraDecoders.decodeRealStepsFields, [oura-rs]). Still
                // Tier B - only reached behind allowTierB (gated above), and OuraStreamMapping never folds
                // RealStepsFields into a durable stream. Applies the SAME 14-field unpack to both 0x7E and
                // 0x7F bodies (the formula is generic over any 14-byte body; NOOP's own investigation
                // found the movement-correlated fields present in both).
                val fields = OuraDecoders.decodeRealStepsFields(record) ?: return emptyList()
                listOf(OuraEvent.RealStepsFields(fields))
            }
            OuraEventTag.SPO2_SMOOTHED ->
                listOf(
                    OuraEvent.TierB(
                        OuraTierBSummary(
                            tag = record.type, ringTimestamp = record.ringTimestamp,
                            rawPayload = record.payload, kind = "spo2_smoothed",
                        ),
                    ),
                )
        }
    }

    /**
     * Convenience: ingest a whole notification value by reassembling records and decoding each. The
     * caller passes a fresh notification value; the supplied reassembler buffers partial trailing
     * bytes across calls. Per OURA_PROTOCOL.md s2.4.
     */
    fun ingest(notification: IntArray, reassembler: OuraReassembler): List<OuraEvent> {
        val out = ArrayList<OuraEvent>()
        for (rec in reassembler.feed(notification)) {
            out.addAll(ingest(rec))
        }
        return out
    }

    /**
     * Decode a live-HR push (0x2F sub-op 0x28). The body is the bytes AFTER `2f 0f 28`; the push is
     * not a TLV record, so it is stamped with the last seen ring time. Per OURA_PROTOCOL.md s5.6.
     */
    fun ingestLiveHRPush(body: IntArray): List<OuraEvent> {
        val hr = OuraDecoders.decodeLiveHRPush(body, lastRingTimestamp) ?: return emptyList()
        // The push also carries the IBI; surface both so HRV analytics see the R-R.
        return listOf(
            OuraEvent.Hr(hr),
            OuraEvent.Ibi(OuraIBI(ringTimestamp = lastRingTimestamp, ibiMs = hr.ibiMs)),
        )
    }

    /**
     * Route a parsed secure sub-frame: extract the auth nonce / status, or a live-HR push body, so
     * the app does not need to know the 0x2F sub-op map. Returns the matching transition or push
     * events. Per OURA_PROTOCOL.md s4.2 / s5.6.
     */
    fun handleSecureFrame(frame: OuraSecureFrame): SecureRouting {
        OuraAuth.nonce(frame)?.let { return SecureRouting.Nonce(it) }
        OuraAuth.authStatus(frame)?.let { return SecureRouting.AuthStatus(it) }
        // Sub-op 0x28 carries the live-HR push samples (s5.6). subBody is everything after the subop.
        if (frame.subop == 0x28) {
            return SecureRouting.LiveHRPush(frame.subBody)
        }
        // Live-HR enable ACKs advance the triplet (s5.6): 0x21 is the dhr_read feature-read ACK from
        // step 1 (`2f 06 21 02 01 11 02 00`), 0x23 acks the enable write (step 2), 0x27 acks the
        // subscribe write (step 3). All three must be recognised or the sequencer stalls at step 0.
        if (frame.subop == 0x21) {
            // A 0x21 is a feature-status read reply. The daytime-HR read (feature 0x02) is step 1 of the
            // live-HR triplet and MUST advance it; a diagnostic read (SpO2 0x04 / real_steps 0x0b) instead
            // surfaces the ring's own feature report so a capture can confirm the server-flag gate.
            val st = OuraDecoders.decodeFeatureStatus(frame.subBody)
            if (st != null && st.feature != OuraCommands.featureDaytimeHR) {
                return SecureRouting.FeatureStatus(st)
            }
            return SecureRouting.EnableAck
        }
        if (frame.subop == 0x23 || frame.subop == 0x27) {
            return SecureRouting.EnableAck
        }
        return SecureRouting.Unhandled
    }

    /** What handleSecureFrame resolved a 0x2F sub-frame to. Kotlin twin of Swift's SecureRouting. */
    sealed class SecureRouting {
        data class Nonce(val nonce: IntArray) : SecureRouting() {
            override fun equals(other: Any?): Boolean {
                if (this === other) return true
                if (other !is Nonce) return false
                return nonce.contentEquals(other.nonce)
            }
            override fun hashCode(): Int = nonce.contentHashCode()
        }

        data class AuthStatus(val status: OuraAuthStatus) : SecureRouting()

        data class LiveHRPush(val body: IntArray) : SecureRouting() {
            override fun equals(other: Any?): Boolean {
                if (this === other) return true
                if (other !is LiveHRPush) return false
                return body.contentEquals(other.body)
            }
            override fun hashCode(): Int = body.contentHashCode()
        }

        object EnableAck : SecureRouting()
        data class FeatureStatus(val value: OuraFeatureStatus) : SecureRouting()
        object Unhandled : SecureRouting()
    }

    companion object {
        /**
         * Bounds for a plausible anchor epoch (unix seconds): 2020-01-01 to 2035-01-01. A decoded
         * 0x42/0x85 value outside this range is a corrupt/misaligned record (seen on real hardware: a full
         * cursor=0 history dump hit one deep in the backlog) and is never trusted as an anchor (honest-data
         * invariant). This gate ALSO bounds the input to the seconds->ms `* 1000` conversion so it can
         * never overflow Long. Byte-identical to Swift's min/maxPlausibleEpochSeconds.
         */
        private const val MIN_PLAUSIBLE_EPOCH_SECONDS = 1_577_836_800L
        private const val MAX_PLAUSIBLE_EPOCH_SECONDS = 2_051_222_400L

        /**
         * Skew allowance on the sample-side "must not be in the future" gate (#1073): a sample converting
         * up to this many seconds past `now` is still accepted, absorbing ring-clock skew and the anchor's
         * own rounding. Minutes, not the anchor window's years. Applies ONLY to [unixSeconds], never anchor
         * adoption. Byte-identical to the Swift `sampleFutureToleranceSeconds`.
         */
        private const val SAMPLE_FUTURE_TOLERANCE_SECONDS = 300L

        /**
         * Resolve the 0x13 SyncTime-response device timestamp into ring TICKS, or null when no
         * unambiguous reading exists. ringverse BLE.md labels the field "seconds" but the ring's record
         * clock runs in 100 ms ticks, so both readings are tried: the raw value (already ticks) and
         * value×10 (seconds→ticks). The ring's clock at connect must sit shortly AFTER where the last
         * drain ended, so a candidate is plausible iff it falls in `[historyCursor, historyCursor +
         * 7 days]`; exactly one must fit (ambiguity or a fresh/reset cursor → null → the caller logs
         * raw instead of guessing). Pure. Byte-identical twin of Swift's syncTimeAnchorCandidate.
         */
        fun syncTimeAnchorCandidate(responseValue: Long, historyCursor: Long): Long? {
            if (historyCursor <= 0) return null
            val lower = historyCursor
            val upper = lower + 6_048_000L   // 7 days of 100 ms ticks
            val readings = listOf(responseValue, responseValue * 10)
            val fits = readings.filter { it in lower..upper && it <= 0xFFFF_FFFFL }
            if (fits.size != 1) return null
            return fits[0]
        }
    }
}
