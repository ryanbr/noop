package com.noop.ble

import android.content.Context
import com.noop.data.DynAccelDiag
import com.noop.data.InsertCounts
import com.noop.data.StreamBatch
import com.noop.data.WhoopRepository
import com.noop.protocol.BadClockDiagnostics
import com.noop.protocol.DeviceFamily
import com.noop.protocol.Framing
import com.noop.protocol.HistoricalMeta
import com.noop.protocol.classifyHistoricalMeta
import com.noop.protocol.decodeHistorical
import com.noop.protocol.extractHistoricalStreams
import com.noop.protocol.isEmptyRecordFrame
import com.noop.protocol.rejectedHistoricalRecords
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Historical-offload state machine (idle / backfilling).
 *
 * Direct port of the macOS Swift `Backfiller` (Strand/Collect/Backfiller.swift). It consumes the
 * METADATA frames of an offload — HISTORY_START / repeated HISTORY_END / HISTORY_COMPLETE —
 * accumulating the type-47 records between them into chunks and committing each chunk durably.
 *
 * Per-chunk local safe-trim invariant (unchanged from Swift):
 *   decode known -> persist decoded (durable) -> persist the strap_trim cursor -> ack the trim to
 *   the strap (link-layer confirmed write).
 * A chunk is forgotten by the strap only after its decoded rows are locally durable AND the trim
 * cursor is persisted AND the ack write is confirmed. The phone NEVER waits on a server (there is
 * none — Strand is fully on-device).
 *
 * CRITICAL behaviour preserved from Swift: a high-freq-sync offload sends ONE HISTORY_START then
 * REPEATED HISTORY_ENDs (a chunk-close every ~50 records). So we ack EVERY end and keep
 * accumulating afterwards — we snapshot+clear the accumulated frames on each END but leave the
 * chunk OPEN so subsequent records become the next chunk. An END with no accumulated records is
 * still acked (it advances the strap's trim) — that is how the offload progresses.
 *
 * CONCURRENCY: [ingest] is `suspend` and serialised by [mutex] so START/data/END chunk assembly is
 * never reordered, matching the Swift serial-drain task. The owning [WhoopBleClient] feeds frames
 * in arrival order from a single drain coroutine.
 *
 * RAW CAPTURE: the Swift Backfiller optionally persists ALL raw frames (research toggle, default OFF);
 * the Android data layer has no raw-frame outbox table, so that bulk capture is intentionally omitted
 * here — decoded rows are the product of record and are still durably committed before the trim is
 * advanced, exactly as in the Swift default (raw-off) configuration. The ONE exception is the
 * undecodable-record archive (#77 / #91): record frames that fail decode are persisted via
 * [rejectedSink] BEFORE the trim is acked, because the strap frees acked history and those bytes would
 * otherwise be the user's permanently-lost only copy. See the FLAG in the port notes.
 */
class Backfiller(
    private val repository: WhoopRepository,
    /** The device id every offloaded row is stamped with (read at finishChunk). MUTABLE so a
     *  WHOOP→WHOOP active-device switch re-points it via [WhoopBleClient.setActiveDeviceId] and the
     *  next chunk attributes to the new id; the single-WHOOP path never reassigns it ("my-whoop"). */
    var deviceId: String,
    private val cursorStore: TrimCursorStore,
    /**
     * Confirms one HISTORY_END chunk to the strap. Carries both the trim cursor (first u32 of
     * end_data, persisted as the `strap_trim` cursor) and the verbatim 8-byte `end_data` (the raw
     * HISTORY_END metadata.data[10:18]) the high-freq-sync ack form requires.
     */
    private val ackTrim: (trim: Long, endData: ByteArray) -> Unit,
    /**
     * Fires after a chunk's decoded rows are durably committed AND acked — i.e. real new data just
     * landed. Lets the client schedule on-device scoring right away instead of leaving fresh history
     * invisible until the next 15-min analysis tick. Empty chunks (metadata-only ENDs) don't fire.
     * (#78 fork)
     */
    private val onChunkCommitted: (StreamBatch) -> Unit = {},
    /**
     * Per-console-only chunk hook (#77 family): a chunk arrived with frames but decoded no rows and
     * held no genuine rejects — pure diagnostic/console output. Lets the client tally a completed-but-
     * empty offload (the strap isn't banking) without false-positiving a normal caught-up sync.
     */
    private val onConsoleChunk: () -> Unit = {},
    /**
     * Diagnostic sink into the strap log. Lets [finishChunk] surface a chunk that arrived with frames
     * but decoded to ZERO rows — the otherwise-invisible silent-data-loss case (frames failing CRC /
     * an unmapped layout are dropped, the chunk looks empty, the trim acks past them). Without this a
     * "zero data" strap log shows healthy "acked chunk" lines while data is being discarded (#77). */
    private val log: (String) -> Unit = {},
    /**
     * Durable archive for HISTORICAL_DATA record frames that FAILED decode, called BEFORE the chunk
     * is acked. The strap frees acked history, so these raw bytes are the user's ONLY remaining copy
     * of an unmapped firmware's records — archiving them preserves the data for a later release that
     * maps the layout AND provides the corpus that mapping needs (#77 / #91). Return false ONLY when
     * the archive could not be made durable (a write failure — NOT the archive-full case): finishChunk
     * then does NOT advance the cursor or ack, so the strap keeps the records and re-sends them (same
     * invariant as a failed repository insert). The default keeps old behaviour for tests/callers that
     * do not wire an archive (no archive → nothing to preserve → proceed).
     */
    private val rejectedSink: (frames: List<ByteArray>, trim: Long) -> Boolean = { _, _ -> true },
    /**
     * The (device, wall) clock reference. type-47 records carry their OWN real unix timestamp so
     * the offset is a no-op for them; this is supplied only for the REALTIME_RAW_DATA fallback and
     * to mirror the Swift signature. Defaults to an identity ref (device == wall == now): the Swift
     * Backfiller falls back to exactly this when GET_CLOCK is silent, and type-47 still decodes to
     * correct wall time. Settable by [WhoopBleClient] if a real correlation lands.
     */
    var clockRef: ClockRef = ClockRef.identityNow(),
    /**
     * Connection & Sync test mode (Test Centre): the cheap gate + tagged sink for the .connection
     * diagnostic lines (offload progress / firmware layout / trim sentinel). [connectionActive] is one
     * SharedPreferences bool read; it is ALWAYS checked BEFORE building any connection line, so the
     * Backfiller pays nothing when the mode is off. [connectionLog] appends the already-built line tagged
     * .connection. Both default inert (always-off / no-op) so tests get the byte-identical untraced path.
     * Mirrors the Swift Backfiller's connectionActive / connectionLog.
     */
    private val connectionActive: () -> Boolean = { false },
    private val connectionLog: (String) -> Unit = {},
    /**
     * Opt-in "HR-from-PPG sub-lag interpolation" (Test Centre → Experimental algorithms, default OFF).
     * Read as a live provider so a toggle flip mid-session takes effect on the next decoded chunk. Passed
     * straight into [extractHistoricalStreams] so the pure decoder never reaches for prefs. Default inert
     * (always-off) keeps the untraced/test path byte-identical. Mirrors the Swift Backfiller extract seam.
     */
    private val ppgHrSubLagInterp: () -> Boolean = { false },
    /** Live UI/export observation of the historical record layout (`hist_version`). */
    private val firmwareLayout: (Int) -> Unit = {},
) {

    /**
     * Emit one Connection & Sync test-mode line iff the mode is on. The cheap [connectionActive] gate is
     * checked BEFORE [build] runs, so the line string is never constructed when the mode is off. Diagnostic
     * only - it never changes the offload path. Mirrors the Swift Backfiller.emitConnection.
     */
    private inline fun emitConnection(build: () -> String) {
        if (!connectionActive()) return
        connectionLog(build())
    }

    /**
     * #547 SESSION-RELATIVE gate: the strap's own GET_DATA_RANGE oldest/newest banked-record markers for
     * the CURRENT offload, set by [WhoopBleClient] when the range reply lands. A record dated months outside
     * this window is wandering-clock pollution even if it clears the absolute 2023-11 floor, so the ingest
     * gate rejects it. null (both) until the range is known — the gate then falls back to the absolute floor
     * only, so behaviour is unchanged on the no-range / replay paths. Cleared in [begin]. Volatile because
     * it's written from the BLE callback thread and read in [finishChunk]. Mirrors Swift Backfiller fields.
     */
    @Volatile
    var sessionOldestUnix: Long? = null

    @Volatile
    var sessionNewestUnix: Long? = null

    /**
     * Strap family for the CURRENT offload, set at [begin] — drives the family-aware frame parse
     * (5/MG inner record is +4) and the +4 end_data slice. The Backfiller is constructed once at
     * client init (before the family is known), so this is settable per-offload rather than a
     * constructor arg. Mirrors Swift `Backfiller.family` set in `begin(family:)`. (#78)
     */
    private var family: DeviceFamily = DeviceFamily.WHOOP4

    /** True while a historical offload session is active. */
    @Volatile
    var isBackfilling = false
        private set

    /** Serialises the suspend [ingest] calls so chunk boundaries are never crossed concurrently. */
    private val mutex = Mutex()

    /** Guards the [chunk]/[chunkOpen] mutations (the only cross-thread state: ingest vs begin/timeout). */
    private val chunkLock = Any()

    /** Buffered data frames for the current open chunk (between START and the next END). */
    private val chunk = ArrayList<ByteArray>()

    /** Whether a START has been received and we're accumulating a chunk. */
    private var chunkOpen = false

    /**
     * Per-session persistence tally — the success-side observability flagged as the forensics blind spot
     * (#150): NOOP logged FAILURES (decoded-to-0) but never SUCCESSES, so a strap log couldn't tell a
     * banking strap from a broken one. Reset in [begin]; read by [WhoopBleClient] at session end to emit
     * "persisted N rows (M with motion) across K night(s)". Nights are day-keys (ts / 86400). Mirrors the
     * Swift Backfiller.
     */
    var sessionRowsPersisted = 0
        private set
    /** #42: set by [begin] when this session continues an auto-continue burst (#364) that already banked
     *  rows in an earlier session, so a trim=0xFFFFFFFF END here reads as "caught up", not "no history".
     *  Without it, the fresh session's `sessionRowsPersisted` is 0 and the scary "charge to 100%" line
     *  false-fires on the empty tail of a sync that just offloaded real records. */
    var continuedAfterRows = false
        private set
    /** #57: set true the moment ANY chunk's persist (decoded rows / reject archive / trim cursor) fails
     *  this session. While set, [finishChunk] must NOT ack — not even a subsequent EMPTY/metadata END, which
     *  skips the insert and would otherwise advance the strap's trim PAST the held records-carrying chunks,
     *  freeing history we never stored (the closed-DB-after-restore data-loss in #57). The offload stalls
     *  safely (strap keeps everything past the last GOOD ack); a fresh session ([begin]) clears it.
     *  Exposed read-only so the client can surface a "history isn't persisting" signal in the debug export
     *  (#57 was invisible to a report — the UI just showed "0 synced"). */
    var persistStalled = false
        private set
    var sessionMotionRows = 0
        private set
    /**
     * #727: skin-temp samples banked this session. WHOOP 4.0 carries skin temp (and the raw SpO2 channel)
     * ONLY in its full DSP sleep records; a strap banking HR/RR-only records reports 0 here even on a
     * healthy-looking sync, so surfacing it makes "skin temp never appears" reports self-diagnosing. Mirrors
     * the Swift Backfiller.
     */
    var sessionSkinTempRows = 0
        private set
    private val sessionNightKeys = HashSet<Long>()
    val sessionNights: Int get() = sessionNightKeys.size

    /**
     * Logged once per session when the strap reports trim=0xFFFFFFFF — the "no valid flash cursor"
     * sentinel: it has no banked history to offload (a clock/charge state, not a decode bug).
     */
    private var loggedNoCursor = false

    /**
     * #773: logged once per session the first time a HISTORY_END's own timestamp is dated implausibly far
     * in the FUTURE (a corrupt strap RTC). Distinct from #547's per-record drop tally: this fires on the
     * chunk metadata's own clock, the earliest visible tell that the strap's RTC is bogus. Reset in [begin].
     */
    private var loggedFutureRtc = false

    /**
     * The trim cursor of the LAST chunk this Backfiller acked (durably persisted + confirmed to the
     * strap). Survives across sessions on the same connection so the auto-continue gate (#364) can ask
     * "did the offload actually advance the strap's trim this session?" — the spin-detector signal that
     * stops it re-kicking forever when the cursor is frozen. null until the first ack. NOT reset in
     * [begin] (it's a cross-session high-water mark, not a per-session tally). Mirrors Swift
     * `Backfiller.lastAckedTrim`.
     */
    @Volatile
    var lastAckedTrim: Long? = null
        private set

    /**
     * Distinct historical record-layout versions logged this session. Before this, only the unmapped/
     * reject path surfaced a version, so a HEALTHY log never revealed which layout the strap emits
     * (v24/v25 on 4.0, v18/v26 on 5/MG) — exactly the firmware→layout signal triage needs. Reset in
     * [begin]; each distinct layout is logged once per session. (PR #241, ryanbr.)
     */
    private val loggedLayoutVersions = HashSet<Int>()

    /** SpO2 RE dump (PR #945, reimplemented): how many full-record dumps this session emitted, bounded by
     *  [com.noop.analytics.Spo2ReTrace.MAX_SAMPLES]. Session-scoped so the cap spans chunks; reset in begin. */
    private var spo2Dumped = 0

    /**
     * #547: logged once per session the first time the #547 ingest gate drops an implausible-timestamp
     * record (a bad strap clock/flash emitting far-past / year-2027-spike / future-dated `unix` values).
     * Surfaces a bad-clock strap in the shared log without spamming a line per chunk. Reset in [begin].
     */
    private var loggedImplausibleClock = false

    /**
     * #547 RE-POLLUTION signal: running count of records this session the ingest gate dropped for an
     * implausible timestamp (a bad/wandering strap clock). Read by [WhoopBleClient.exitBackfilling] to arm a
     * heal re-run — if the strap is bad-clock THIS session it may have banked similar garbage on an OLDER
     * build whose gate was weaker. Reset in [begin]. Mirrors Swift `Backfiller.sessionDroppedImplausible`.
     */
    var sessionDroppedImplausible = 0

    /**
     * #891 diagnostic: packet types this session's offload carried that the decoder has no rows for, folded
     * across batches. Each type is logged the FIRST time it appears — a 30k-record offload must not emit 30k
     * lines. Reset in [begin]. Twin of Swift `Backfiller.sessionUnhandledPacketTypes`.
     */
    val sessionUnhandledPacketTypes = mutableMapOf<String, Int>()

    /**
     * #520 diagnostic: `dynamic_acceleration` folded across every batch of this session, logged once at the
     * session boundary. Session-scoped rather than per-batch because a batch is an arbitrary slice of an
     * offload — a still-fraction only means something over a whole night's worth of records. Twin of Swift
     * `Backfiller.sessionDynAccel`.
     */
    var sessionDynAccel = DynAccelDiag()
        private set

    /**
     * Called by [WhoopBleClient] when the strap signals a historical offload is beginning.
     * chunkOpen starts TRUE: the biometric replay streams records immediately and sends one
     * HISTORY_START then repeated HISTORY_ENDs, so we must accumulate from the outset.
     * Port of Swift `begin()`.
     */
    fun begin(family: DeviceFamily = DeviceFamily.WHOOP4, continuedAfterRows: Boolean = false) {
        this.family = family
        this.continuedAfterRows = continuedAfterRows
        isBackfilling = true
        sessionRowsPersisted = 0
        sessionMotionRows = 0
        sessionSkinTempRows = 0
        sessionNightKeys.clear()
        persistStalled = false   // #57: fresh session starts un-stalled
        loggedNoCursor = false
        loggedFutureRtc = false
        loggedLayoutVersions.clear()
        spo2Dumped = 0
        loggedImplausibleClock = false
        sessionDroppedImplausible = 0
        sessionUnhandledPacketTypes.clear()   // #891: a second offload must re-log its first sighting
        sessionDynAccel = DynAccelDiag()
        // #547: the range markers belong to a connection's GET_DATA_RANGE, which the client re-sets per
        // connect; clear them so a fresh session never reuses a previous strap's window (the client
        // re-publishes them as soon as the range reply arrives).
        sessionOldestUnix = null
        sessionNewestUnix = null
        synchronized(chunkLock) {
            chunk.clear()
            chunkOpen = true
        }
    }

    /**
     * Feed one complete (reassembled) BLE frame into the state machine. Suspends while a chunk is
     * persisted so chunk boundaries are never crossed concurrently. Port of Swift `ingest(_:)`.
     */
    suspend fun ingest(frame: ByteArray) {
        mutex.withLock {
            when (val meta = classifyHistoricalMeta(Framing.parseFrame(frame, family))) {
                is HistoricalMeta.Start -> {
                    isBackfilling = true
                    synchronized(chunkLock) {
                        chunk.clear()
                        chunkOpen = true
                    }
                }
                is HistoricalMeta.End -> finishChunk(meta.unix, meta.trim, frame)
                is HistoricalMeta.Complete -> {
                    isBackfilling = false
                    synchronized(chunkLock) {
                        chunk.clear()
                        chunkOpen = false
                    }
                }
                is HistoricalMeta.Other -> synchronized(chunkLock) { if (chunkOpen) chunk.add(frame) }
            }
        }
    }

    /**
     * Commit one HISTORY_END chunk: persist decoded -> persist strap_trim cursor -> ack the trim.
     * Early-returns on any failure to preserve the safe-trim invariant (never ack data we failed to
     * store). Port of Swift `finishChunk(unix:trim:endFrame:)`.
     *
     * We snapshot+clear the accumulated frames but leave [chunkOpen] TRUE so the records following
     * this END become the next chunk. An END with no records is still acked (advances the trim).
     */
    private suspend fun finishChunk(unix: Long, trim: Long, endFrame: ByteArray) {
        val endData = endData(endFrame, family) ?: return

        // #773: corrupt future-RTC detection. A HISTORY_END carries the strap's own clock; a genuine offload
        // is always PAST-dated (it's banked history), so an end dated days into the future can only be a
        // corrupt strap RTC. Surface it ONCE per session with a recovery hint so the cause (the strap clock,
        // not a NOOP bug) is named and the fix (charge + reconnect re-syncs the RTC) is given. Observability
        // only - the ack still proceeds and the #547 ingest gate already keeps the bad-dated rows out of the
        // DB. The 0xFFFFFFFF sentinel above is a different state (it isn't a real date), so skip it here.
        if (trim != 0xFFFFFFFFL && !loggedFutureRtc) {
            val wallNow = System.currentTimeMillis() / 1000L
            if (isCorruptFutureRtc(unix, wallNow)) {
                loggedFutureRtc = true
                log(futureRtcLine(unix, wallNow))
            }
        }

        val frames = synchronized(chunkLock) {
            val snapshot = ArrayList(chunk)
            chunk.clear() // next records accumulate into the next chunk
            snapshot
        }

        var committed: StreamBatch? = null
        if (frames.isNotEmpty()) {
            val ref = clockRef
            val decoded = extractHistoricalStreams(
                frames, ref.device, ref.wall, family,
                sessionOldestUnix = sessionOldestUnix, sessionNewestUnix = sessionNewestUnix,
                ppgHrSubLagInterp = ppgHrSubLagInterp(),
            )
            // Observability (PR #241): which historical layout does this strap emit? Only the unmapped/
            // reject path logged a version before, so a healthy sync never revealed v24/v25 (4.0) or
            // v18/v26 (5/MG). Sample the chunk's first genuine record (null ⇒ console/CRC-fail); log
            // each distinct layout once per session.
            frames.firstNotNullOfOrNull { decodeHistorical(it, family)?.get("hist_version") as? Int }
                ?.let { v ->
                    if (loggedLayoutVersions.add(v)) {
                        log("Backfill: historical records use layout v$v")
                        firmwareLayout(v)
                        // Connection test mode: the firmware layout as a compact tagged line. A layout that
                        // decoded a signature field (heart_rate / gravity_x / ppg_waveform) is decodable.
                        // Gated zero-cost. Twin of the Swift Backfiller emit.
                        emitConnection {
                            val decodable = frames.any {
                                val d = decodeHistorical(it, family)
                                d != null && (d.containsKey("heart_rate") || d.containsKey("gravity_x") ||
                                    d.containsKey("ppg_waveform"))
                            }
                            com.noop.analytics.ConnectionTrace.firmwareLine(v, decodable)
                        }
                    }
                }
            // SpO2 RE dump (PR #945, reimplemented): while the Connection test mode is on, dump a few FULL
            // historical records + their mapped raw SpO2 channels so an offline pass can tell whether the
            // strap banks a COMPUTED SpO2 (a byte tracking the WHOOP app's nightly %) vs only the raw
            // red/IR ADC we already decode. Log-only and bounded per session across chunks ([spo2Dumped],
            // reset in begin); zero-cost when the mode is off (one Bool short-circuit). Only genuine
            // historical records (decodeHistorical returns a map with `unix`) spend the sample budget -
            // the strap's type-50 console frames carry no record bytes to correlate. Records dump whether
            // or not they carry SpO2 channels, so "nothing banked" is provable too. Never a user-facing
            // number (never-fabricate; the #194 lesson). Twin of the Swift Backfiller emit.
            if (spo2Dumped < com.noop.analytics.Spo2ReTrace.MAX_SAMPLES && connectionActive()) {
                for (f in frames) {
                    if (spo2Dumped >= com.noop.analytics.Spo2ReTrace.MAX_SAMPLES) break
                    val d = decodeHistorical(f, family) ?: continue
                    val recUnix = d["unix"] as? Int ?: continue
                    connectionLog(
                        com.noop.analytics.Spo2ReTrace.recordLine(
                            frame = f,
                            version = d["hist_version"] as? Int,
                            unix = recUnix,
                            red = d["spo2_red"] as? Int,
                            ir = d["spo2_ir"] as? Int,
                            skinRaw = d["skin_temp_raw"] as? Int,
                        ),
                    )
                    spo2Dumped++
                }
            }
            // #520: accumulate the motion-magnitude diagnostic across the session; logged once at the
            // session boundary, never per batch.
            sessionDynAccel.merge(decoded.dynAccel)
            // #547: the strap is emitting records with implausible timestamps (a bad clock/flash —
            // far-past, a year-2027 spike, or future-dated `unix`). The ingest gate dropped them so they
            // can't pollute the day-windowed analytics; surface it ONCE per session so a bad-clock strap
            // is visible in a shared log (the strap clock is genuinely bad — this is NOOP being robust).
            sessionDroppedImplausible += decoded.droppedImplausibleTs
            if (decoded.droppedImplausibleTs > 0 && !loggedImplausibleClock) {
                loggedImplausibleClock = true
                // #324: append the epoch SPAN of the dropped block + how far off it sits, so the strap log
                // shows WHETHER the whole banked range is future-dated (safe to fast-forward-discard) or a slice.
                val span = BadClockDiagnostics.droppedSpanClause(
                    decoded.droppedImplausibleOldestTs,
                    decoded.droppedImplausibleNewestTs,
                    System.currentTimeMillis() / 1000L,
                )
                log(
                    "Backfill: WARNING dropped ${decoded.droppedImplausibleTs} record(s) with an " +
                        "implausible timestamp$span (bad strap clock — far-past or future-dated); they are " +
                        "excluded so they can't misdate history.",
                )
            }
            // #891: packet types this batch carried that the decoder has no branch for. Logged the first
            // time each type appears so a long offload stays readable. This is the only place such a record
            // becomes visible: the `else` branch drops it and rejectedHistoricalRecords archives only
            // type-47, so without this line an offload full of an unmapped type reports a clean sync.
            // Mirrors the Swift Backfiller.
            for ((typeName, n) in decoded.unhandledPacketTypes.toSortedMap()) {
                val firstSighting = typeName !in sessionUnhandledPacketTypes
                sessionUnhandledPacketTypes[typeName] =
                    (sessionUnhandledPacketTypes[typeName] ?: 0) + n
                if (firstSighting) {
                    log(
                        "Backfill: the strap sent $n record(s) of packet type $typeName, which this " +
                            "decoder has no rows for — they are being dropped. If $typeName is not a name " +
                            "you recognise, this is a firmware record type NOOP has never mapped: please " +
                            "report it on #891 with the strap model and firmware build.",
                    )
                }
            }
            // #324: the strap RTC-state events (RTC_LOST / BOOT / SET_RTC) the #547 gate dropped for a bad
            // own-timestamp — the GROUND TRUTH that the clock reset. Sparse (not per-record), so log each as
            // it appears; the bad rawTs is the future/past base the RTC jumped to.
            if (decoded.droppedRtcEvents.isNotEmpty()) {
                val nowForRtc = System.currentTimeMillis() / 1000L
                for (ev in decoded.droppedRtcEvents) {
                    log(
                        "Backfill: strap reported ${ev.kind} with an implausible own-timestamp " +
                            "${BadClockDiagnostics.isoDay(ev.rawTs)} (${BadClockDiagnostics.hoursOffset(ev.rawTs, nowForRtc)} " +
                            "vs now) — the strap's RTC reset to a wrong base (#324/#928); this is the ground-truth " +
                            "cause of the future-dated banking, not a NOOP decode bug.",
                    )
                }
            }
            // #77 / #91: HISTORICAL_DATA record frames that fail decode (CRC failure, or an unmapped
            // layout the v24 fallback's plausibility gate also rejects) used to be acked anyway — the
            // strap trims acked history, so the user's ONLY copy of those records was permanently
            // destroyed while the UI reported "History synced". Classify PER FRAME (a type-50 console
            // frame decodes to 0 rows BY DESIGN and must not raise the alarm — the old chunk-level
            // isEmpty check counted it and could waste the hex sample on it; it also missed mixed chunks
            // where one good row hid the losses). The rejects are archived durably AFTER the decoded
            // insert below but ALWAYS before the ack (#1006, Swift-order parity — see the archive block
            // for why insert goes first). The WHOOP4 happy path (zero rejects) is unchanged.
            val rejected = rejectedHistoricalRecords(frames, family)
            // #77 family: decoded no rows AND no genuine rejects ⇒ pure console output. Tally it so a
            // completed-but-empty offload (strap not banking) is distinguishable from a caught-up sync.
            if (decoded.isEmpty && rejected.isEmpty()) onConsoleChunk()
            if (rejected.isNotEmpty()) {
                log(
                    "Backfill: WARNING ${rejected.size} record frame(s) decoded to 0 rows " +
                        "(trim=$trim) — archiving raw bytes before ack (CRC/unmapped layout)",
                )
                // #91 / #30: a hex sample in the strap log so an unmapped firmware's record layout can
                // be mapped from a shared log. Dump the FULL frame (not a 64-byte prefix — v25/v26
                // records run ~84 B and the truncated tail is exactly where the unmapped motion/HR
                // fields sit), and sample a few more so one log carries enough records to triangulate
                // offsets. These only ever fire for unmapped firmware.
                val sample = rejected.take(8)
                var emptySkipped = 0
                sample.forEachIndexed { i, f ->
                    // #1007: an all-zero frame has no record layout to map, so its hex dump is pure log
                    // bloat (a strap emitting these produced ~4 MB of all-00). Keep the WARNING count above.
                    if (isEmptyRecordFrame(f)) { emptySkipped++; return@forEachIndexed }
                    val hex = f.joinToString("") { "%02x".format(it) }
                    log("Backfill: rejected frame[$i] ${f.size}B: $hex")
                }
                if (emptySkipped > 0) {
                    log("Backfill: #1007 $emptySkipped/${sample.size} sampled frame(s) all-zero (empty payload) - hex dump skipped")
                }
            }
            // Commit the decoded rows FIRST (durable) — BEFORE the reject archive (#1006, matching the
            // Swift twin). Insert-first means a rare insert failure — which returns below and re-sends
            // the whole chunk next session — can't have already appended this chunk's reject frames to
            // the append-only #91/#30 archive, so the retry can't leave duplicate lines in the corpus
            // later firmware-layout mapping triangulates against. (The old archive-first order was a
            // port slip: no data loss either way, but the insert-failure retry archived twice.)
            try {
                val counts = repository.insert(decoded, deviceId)
                committed = decoded
                // Success-side observability (#150): tally what actually persisted so the session can emit
                // "persisted N rows (M with motion) across K night(s)" — the win-rate signal we never logged.
                val (rows, motion, nights) = chunkTally(counts, decoded.gravity.map { it.ts } + decoded.hr.map { it.ts })
                sessionRowsPersisted += rows
                sessionMotionRows += motion
                sessionSkinTempRows += counts.skinTemp
                sessionNightKeys.addAll(nights)
                // Connection test mode: per-chunk offload PROGRESS (running session totals). Gated zero-cost.
                // Twin of the Swift Backfiller emit.
                emitConnection {
                    "offload progress trim=$trim chunkRows=$rows " +
                        "sessionRows=$sessionRowsPersisted sessionMotion=$sessionMotionRows nights=$sessionNights"
                }
            } catch (t: Throwable) {
                // Diag (#601 / #13): the decoded rows couldn't be written, the "history stalls but live HR
                // works" class. We return WITHOUT acking so the strap keeps this chunk and re-sends it next
                // session (no data loss), but a silent return left a strap log with no trace of the stall.
                // Mirrors the Swift twin's log so a write-stall is falsifiable here too.
                log("Backfill: failed to persist decoded rows (trim=$trim): $t, holding ack so the strap re-sends this chunk; history won't advance until the write succeeds.")
                persistStalled = true   // #57: stall ALL further acks so an empty END can't advance past this
                return // do NOT advance/ack, chunk was never durably committed
            }
            // #77 / #91: any genuinely-undecodable record in this chunk must be ARCHIVED durably before
            // we ack — the ack frees the strap's copy, so the archive is the only remaining copy of an
            // unmapped firmware's records. Runs AFTER the decoded insert (#1006, Swift-order parity; see
            // the insert comment above). A false return means a genuine write failure (NOT the
            // archive-full case, which returns true) — hold the cursor/ack so the strap re-sends the
            // chunk next offload. The decoded rows are already durable, so that re-send's insert is an
            // idempotent no-op while the archive retries. No data loss either way.
            if (rejected.isNotEmpty() && !rejectedSink(rejected, trim)) {
                log("Backfill: rejected-frame archive failed (trim=$trim) — holding ack so the strap re-sends.")
                persistStalled = true   // #57
                return
            }
        }

        // #150 / #783 / #1: trim=0xFFFFFFFF is the strap's "no valid flash cursor" sentinel. Its MEANING
        // depends on whether this run already banked anything. On the FIRST end of a fresh offload it means
        // "no banked history" (a clock/charge state). But the auto-continuation (#364) re-kicks
        // SEND_HISTORICAL after a run that DID persist rows, and the very next end then carries 0xFFFFFFFF
        // to mean "you are caught up, nothing left past the last trim", NOT "no history". Emitting the scary
        // "fully charge it" line there was wrong and alarmed users whose strap had just synced fine (#783).
        // We gate this AFTER the persist block (#1): a bad-clock/flash strap can emit records on the SAME
        // 0xFFFFFFFF END, so sessionRowsPersisted must already include THIS end's own rows before the pick,
        // otherwise a records-bearing no-cursor END false-alarms "no banked history". So gate on
        // sessionRowsPersisted == 0 HERE: if rows landed (this run or this END) log the neutral caught-up
        // line; a genuinely empty session (0 rows) still gets the real no-history guidance. Logs once per
        // session (loggedNoCursor) and the ack still proceeds below.
        if (trim == 0xFFFFFFFFL && !loggedNoCursor) {
            loggedNoCursor = true
            log(noCursorLine(sessionRowsPersisted, continuedAfterRows))
            // Connection test mode: the no-cursor sentinel as a compact tagged line (gated zero-cost).
            emitConnection { com.noop.analytics.ConnectionTrace.noCursorLine() }
        }

        // #57: if an EARLIER chunk this session failed to persist, do NOT advance the cursor or ack — not
        // even for this (possibly empty/metadata) END. `insert` short-circuits empty batches without
        // touching the store, so an empty END never throws; acking it would trim the strap PAST the held
        // records-carrying chunks, freeing history we never stored (the closed-DB-after-restore loss). Stall
        // the whole offload until a fresh session with a working store re-offers everything past the last
        // GOOD ack.
        if (persistStalled) {
            log("Backfill: persist stalled earlier this session — NOT acking trim=$trim so the strap can't trim past un-stored history. Reconnect once the store is healthy (a backup restore needs an app restart, #57).")
            return
        }

        // Persist the trim cursor BEFORE acking (so a crash between persist and ack still resumes
        // from the right place). Stored via [TrimCursorStore] because the Room schema has no cursor
        // table — see the port FLAG. trim is a u32 carried as Long (unsigned-safe).
        try {
            cursorStore.set(STRAP_TRIM_CURSOR, trim)
        } catch (t: Throwable) {
            // Diag (#601 / #13): decoded rows are durable but the strap_trim cursor write failed. We return
            // WITHOUT acking, acking now would let the strap trim past records the cursor hasn't recorded, so
            // on reconnect the offload could replay or skip. Holding the ack keeps it safe; the strap re-offers
            // this chunk next session. A silent return here was a prime "history won't advance" suspect with
            // nothing in the log to confirm it. Mirrors the Swift twin's log.
            log("Backfill: failed to write strap_trim cursor (trim=$trim): $t, holding ack so the strap re-sends this chunk; history won't advance until the cursor write succeeds.")
            persistStalled = true   // #57
            return
        }

        ackTrim(trim, endData)
        lastAckedTrim = trim   // #364: record the advanced cursor for the auto-continue spin-detector
        committed?.takeIf { !it.isEmpty }?.let(onChunkCommitted)
    }

    /**
     * Called when a backfill watchdog timer fires (strap went silent mid-offload). Clears state
     * WITHOUT acking — the open chunk was never durably committed. Port of Swift `timeoutFired()`.
     */
    fun timeoutFired() {
        isBackfilling = false
        synchronized(chunkLock) {
            chunk.clear()
            chunkOpen = false
        }
    }

    companion object {
        /** Cursor name for the strap's safe-trim watermark. Matches the Swift `setCursor("strap_trim", ...)`. */
        const val STRAP_TRIM_CURSOR = "strap_trim"

        /**
         * The 8-byte `end_data` the high-freq-sync ack requires: metadata.data[10:18]. The inner
         * record begins at frame[7] on WHOOP4 (end_data = frame[17:25]) and at frame[11] on WHOOP5/MG
         * (the +4 puffin envelope → end_data = frame[21:29]). The trim cursor is the first u32 of
         * end_data. Returns null if the frame is too short. Verified against a real WHOOP5 HISTORY_END
         * (trim=112193 at frame[21:25]); port of Swift `Backfiller.endData(from:family:)`. (#78)
         */
        fun endData(frame: ByteArray, family: DeviceFamily): ByteArray? {
            val start = if (family == DeviceFamily.WHOOP5) 21 else 17
            if (frame.size < start + 8) return null
            return frame.copyOfRange(start, start + 8)
        }

        /**
         * Pure per-chunk persistence tally (#150). [rows] = biometric rows inserted (HR, R-R, SpO2,
         * skin-temp, resp, gravity — battery/events/steps are housekeeping, NOT biometric history, so
         * they must not inflate the count; matches the Swift tuple, which has no steps). [motion] =
         * gravity rows (the sleep-critical signal). nights = distinct day-keys (ts / 86400). Summed
         * across a session by [finishChunk] to drive the success summary line.
         */
        fun chunkTally(counts: InsertCounts, timestamps: List<Long>): Triple<Int, Int, Set<Long>> {
            val rows = counts.hr + counts.rr + counts.spo2 + counts.skinTemp + counts.resp + counts.gravity
            return Triple(rows, counts.gravity, timestamps.map { it / 86400L }.toSet())
        }

        /**
         * The one-line session success summary (#150) — the success-side log that never existed. Null
         * when nothing persisted, so a console-only / caught-up session stays quiet and the existing
         * empty-banking diagnostics speak instead.
         */
        fun sessionSummaryLine(rows: Int, motion: Int, skinTemp: Int, nights: Int): String? =
            if (rows <= 0) null
            else "Backfill: session persisted $rows rows ($motion with motion, $skinTemp skin-temp) across $nights night(s)."

        /**
         * The trim=0xFFFFFFFF sentinel line (#783). 0xFFFFFFFF means two different things depending on
         * whether THIS run already banked rows. On the first end of a fresh offload it's the "no valid flash
         * cursor" state (no banked history, a clock/charge problem). But the #364 auto-continuation re-kicks
         * SEND_HISTORICAL after a run that DID persist rows, and the next end then carries 0xFFFFFFFF to mean
         * "caught up, nothing left past the last trim", NOT "no history". Emitting the alarming "fully charge
         * it" line there falsely scared users whose strap had just synced fine. So pick by [rowsPersisted]:
         * > 0 gives a neutral caught-up line; 0 gives the genuine no-history guidance. Pure so a fixture pins both.
         * Twin of the Swift `Backfiller.noCursorLine(rowsPersisted:)`.
         */
        fun noCursorLine(rowsPersisted: Int, continuedAfterRows: Boolean = false): String =
            when {
                rowsPersisted > 0 ->
                    "Backfill: reached the end of available history (trim=0xFFFFFFFF) - caught up after " +
                        "persisting $rowsPersisted row(s) this run. Nothing more to offload."
                // #42: the empty tail of an auto-continue burst (#364) that banked rows in an EARLIER
                // session. The strap synced fine — this pass just confirms we're caught up — so DON'T
                // false-alarm "no banked history / charge to 100%".
                continuedAfterRows ->
                    "Backfill: reached the end of available history (trim=0xFFFFFFFF) - caught up; the " +
                        "strap handed over its banked history earlier this sync. Nothing more to offload."
                else ->
                    "Backfill: strap reported no flash cursor (trim=0xFFFFFFFF) - it has no banked history " +
                        "to offload. This is a clock/charge state on the strap, not a decode problem; fully " +
                        "charge it and reconnect so it starts banking."
            }

        /**
         * #773: how far ahead of the wall clock a HISTORY_END's own timestamp may sit before we call the
         * strap RTC corrupt. The strap RTC and the phone normally agree within seconds; a genuine offload is
         * always dated in the PAST (it's banked history). A timestamp dated days into the FUTURE can only be
         * a corrupt strap clock. Generous (1 day) so ordinary skew or a timezone confusion never trips it.
         * Twin of the Swift `Backfiller.futureRtcToleranceSeconds`.
         */
        const val FUTURE_RTC_TOLERANCE_SECONDS = 86_400L

        /**
         * #773: is this HISTORY_END timestamp an implausible FUTURE date (a corrupt strap RTC)? [endUnix] and
         * [wallNowUnix] are unix seconds in the same wall domain. Pure so a fixture pins the boundary. Twin of
         * the Swift `Backfiller.isCorruptFutureRtc`.
         */
        fun isCorruptFutureRtc(endUnix: Long, wallNowUnix: Long): Boolean =
            endUnix > wallNowUnix + FUTURE_RTC_TOLERANCE_SECONDS

        /**
         * #773: the recovery-hint line for a corrupt future-dated strap RTC. Names the cause plainly (the
         * strap's clock, not a NOOP bug) and gives the fix (charge + reconnect re-syncs the RTC). Byte-
         * identical to the Swift `Backfiller.futureRtcLine`. No em-dash (project rule).
         */
        fun futureRtcLine(endUnix: Long, wallNowUnix: Long): String {
            val aheadDays = maxOf(0L, endUnix - wallNowUnix) / 86_400L
            return "Backfill: the strap reported a record dated about $aheadDays day(s) in the FUTURE - " +
                "its clock (RTC) is corrupt, not a NOOP problem. Those records can't be filed onto the " +
                "right day. Fully charge the strap to 100% and reconnect so it re-syncs its clock; if it " +
                "persists, forget and re-pair the strap."
        }
    }
}

/**
 * A (device-epoch, wall-clock) correlation in unix seconds. Android analog of the Swift `ClockRef`.
 * type-47 historical records carry real unix timestamps, so the identity ref (device == wall) makes
 * the offset math a no-op while still decoding correct wall time — the same fallback the Swift
 * Backfiller uses when GET_CLOCK is silent.
 */
data class ClockRef(val device: Int, val wall: Int) {
    companion object {
        fun identityNow(): ClockRef {
            val now = (System.currentTimeMillis() / 1000L).toInt()
            return ClockRef(device = now, wall = now)
        }
    }
}

/**
 * Durable key/value cursor store. The macOS Backfiller persists `strap_trim` via the GRDB store's
 * cursor table; the Android Room schema has no cursor table (see Entities.kt — no cursor entity),
 * so this small SharedPreferences-backed store provides the equivalent durability WITHOUT touching
 * the Room schema or the build/manifest.
 *
 * FLAG (uncertain / divergence from macOS): on the Swift side the cursor lives in the same SQLite
 * file as the decoded rows, so cursor and rows commit/back-up atomically together. Here the cursor
 * lives in SharedPreferences, separate from the Room DB. The safe-trim ORDERING is preserved
 * (decoded rows are inserted and durable before the cursor is written, and the cursor is written
 * before the ack), so the worst case is a redundant re-offload of an already-stored chunk after a
 * crash — never data loss — because the decoded inserts are idempotent by natural key. If a Room
 * `cursor` table is later added, swap this implementation for a DAO-backed one.
 */
interface TrimCursorStore {
    suspend fun set(name: String, value: Long)
    suspend fun get(name: String): Long?
}

/** Default [TrimCursorStore] backed by a private SharedPreferences file. */
class PrefsTrimCursorStore(context: Context) : TrimCursorStore {
    private val prefs = context.applicationContext
        .getSharedPreferences("noop_backfill_cursors", Context.MODE_PRIVATE)

    override suspend fun set(name: String, value: Long) {
        // commit() (synchronous) so durability is established before we ack the strap.
        prefs.edit().putLong(name, value).commit()
    }

    override suspend fun get(name: String): Long? =
        if (prefs.contains(name)) prefs.getLong(name, 0L) else null
}
