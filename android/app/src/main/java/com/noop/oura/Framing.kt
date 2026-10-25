package com.noop.oura

// Framing: the two framing layers that ride on the same characteristics (OURA_PROTOCOL.md s2). Kotlin
// twin of Framing.swift.
//   - Outer command / command-response frame:  op(1) len(1) body(len)        (s2.1)
//   - Extended / secure-session frame (0x2F):   2F len subop subop-body       (s2.2)
//   - Inner event record (TLV):                 type(1) len(1) rt:u32LE payload (s2.3)
// All multi-byte integers are little-endian unless a decoder states otherwise (OURA_PROTOCOL.md s2.1).
//
// The first byte disambiguates layers: a value present in the opcode table (s4) is an outer frame;
// otherwise it is an inner event record. The OuraDriver routes on this; Framing exposes pure parsers
// plus a defensive Reassembler that buffers partial trailing bytes across notifications (s2.4).
//
// DIVERGENCE FROM SWIFT (deliberate): the Swift port uses [UInt8]. Kotlin's signed Byte makes the
// bit-math noisy, so this twin carries unsigned bytes as IntArray values 0..255. The wire layout,
// offsets, and arithmetic are byte-for-byte identical to the Swift version; only the storage type
// differs. The OuraReassembler.feed entry point accepts a ByteArray (the BLE callback type) and
// widens to unsigned internally.
//
// Platform-pure, value types only. Facts cited per OURA_PROTOCOL.md s2.

/**
 * A parsed outer frame: `op len body` (OURA_PROTOCOL.md s2.1). `body` is the `len` bytes after the
 * header. Multiple outer frames may be packed into one notification; the consumer loops 2+len.
 */
data class OuraOuterFrame(val op: Int, val body: IntArray) {
    /** Total wire length of this frame (header + body). */
    val totalLength: Int get() = 2 + body.size

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is OuraOuterFrame) return false
        return op == other.op && body.contentEquals(other.body)
    }

    override fun hashCode(): Int = 31 * op + body.contentHashCode()
}

/**
 * A parsed secure-session sub-frame: the first body byte of a 0x2F frame is the sub-op
 * (OURA_PROTOCOL.md s2.2 / s4.2). `subBody` is the remaining body bytes after the sub-op.
 */
data class OuraSecureFrame(val subop: Int, val subBody: IntArray) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is OuraSecureFrame) return false
        return subop == other.subop && subBody.contentEquals(other.subBody)
    }

    override fun hashCode(): Int = 31 * subop + subBody.contentHashCode()
}

/**
 * A parsed TLV inner event record (OURA_PROTOCOL.md s2.3):
 *   type(1) len(1) ctr:u16LE ses:u16LE payload(len-4)
 * `ringTimestamp` is stored as a single u32 LE = (session << 16) | counter (the two views are
 * equivalent per the s2.3 note). `payload` is the `len-4` bytes after the 4 timestamp bytes.
 *
 * `ringTimestamp` is kept as a Long holding the unsigned 32-bit value (0..0xFFFFFFFF), the Kotlin
 * stand-in for Swift's UInt32.
 */
data class OuraRecord(val type: Int, val ringTimestamp: Long, val payload: IntArray) {
    /** Low 16 bits = the per-record counter. Per OURA_PROTOCOL.md s2.3. */
    val counter: Int get() = (ringTimestamp and 0xFFFFL).toInt()

    /** High 16 bits = the session id. Per OURA_PROTOCOL.md s2.3. */
    val session: Int get() = ((ringTimestamp shr 16) and 0xFFFFL).toInt()

    /** Total wire length of this record = len + 2 (header byte + len byte). Per OURA_PROTOCOL.md s2.3. */
    val totalLength: Int get() = payload.size + 4 + 2

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is OuraRecord) return false
        return type == other.type && ringTimestamp == other.ringTimestamp &&
            payload.contentEquals(other.payload)
    }

    override fun hashCode(): Int {
        var h = type
        h = 31 * h + ringTimestamp.hashCode()
        h = 31 * h + payload.contentHashCode()
        return h
    }
}

/**
 * The parsed result of a 0x11 GetEvents response (OURA_PROTOCOL.md s5.2), per open_oura's
 * `EventBatchSummary`. Kotlin twin of the Swift `(eventsReceived: UInt8, bytesLeft: UInt32,
 * moreData: Bool)` tuple. The summary carries **no cursor** — the resume position is a CLIENT-managed
 * event-envelope ring-time (see OuraHistoryDrain), never read back from here.
 *
 * #91 (fixed here in parity with Swift): an earlier revision decoded bytes 2–5 as a
 * `last_ring_timestamp` cursor and body[0] as a status. Both are wrong: body[0] is `events_received`
 * (a batch COUNT — treating 0 as "done" stopped a drain with data still banked), and bytes 2–5 are
 * `bytes_left` (a remaining-BYTE count — persisting it as a cursor minted a phantom "ring-time
 * regression" → reset-to-0 → full history re-dump on every connect).
 */
data class GetEventsSummary(val eventsReceived: Int, val bytesLeft: Long, val moreData: Boolean)

/**
 * The parsed result of a 0x13 SyncTime response (OURA_PROTOCOL.md s5.4, [ringverse BLE.md]):
 * `current_device_timestamp:4 LE  status:1`. The device timestamp is the ring's own clock counter AT
 * THE MOMENT it processed our SyncTime — paired with the host wall-clock at receipt it forms a
 * deterministic ring-time→UTC anchor available at EVERY connect (the 0x42 record is only logged when
 * the ring actually adjusts its clock). Kotlin twin of Swift's parseSyncTimeResponse tuple.
 */
data class SyncTimeResponse(val deviceTimestamp: Long, val status: Int)

object OuraFraming {
    /** The secure-session / extended opcode. Per OURA_PROTOCOL.md s2.2 / s4.1. */
    const val secureSessionOp = 0x2F

    /**
     * The GetEvents response / summary outer opcode (OURA_PROTOCOL.md s5.2). Below the event-tag range
     * (tags are >= 0x41), so a caller that fails to special-case it and lets it fall through to the TLV
     * decoder gets a safe no-op ("unknown tag") with correct byte accounting, never a misdecode. Kotlin
     * twin of Swift's getEventsResponseOp.
     */
    const val getEventsResponseOp = 0x11

    /**
     * The GetBattery response outer opcode (OURA_PROTOCOL.md s4.1/s6.10). Below the event-tag range
     * (tags are >= 0x41), so it round-trips safely through the TLV decoder as an "unknown tag" no-op if a
     * caller fails to special-case it. Kotlin twin of Swift's batteryResponseOp.
     */
    const val batteryResponseOp = 0x0D

    /**
     * The SyncTime response outer opcode (OURA_PROTOCOL.md s5.4, [ringverse BLE.md]). Below the
     * event-tag range, so it round-trips safely through the TLV decoder as an "unknown tag" no-op if a
     * caller fails to special-case it. Kotlin twin of Swift's syncTimeResponseOp.
     */
    const val syncTimeResponseOp = 0x13

    /** The minimum legal TLV `len` field: it must cover the 4 timestamp bytes. Per OURA_PROTOCOL.md s2.3. */
    const val minRecordLen = 4

    /**
     * The largest notification value the one-packet framing can carry: 20 bytes (the default 23-byte
     * ATT MTU minus its 3-byte notification header). A value of AT MOST this length is a single packet,
     * so reading one lenient packet from it is the whole value; a LONGER value is one the ring packed,
     * and reading one packet from that keeps only its first record. Used solely to decide whether a
     * tiling failure is worth reporting ([OuraReassembler.takePackedTilingFailures]), never to parse.
     * Per OURA_PROTOCOL.md s2.3. Twin of Swift's singlePacketNotificationMaxLen.
     */
    const val singlePacketNotificationMaxLen = 20

    /**
     * Parse a 0x11 GetEvents response body per open_oura's `EventBatchSummary`:
     * `events_received:1  sleep_analysis_progress:1  bytes_left:4LE  [pad:2]` (OURA_PROTOCOL.md s5.2).
     * The drain loop runs until `bytes_left == 0`; there is NO resume cursor in this packet. Returns
     * null on a short body. Byte-identical twin of Swift's parseGetEventsResponse (#91 fix).
     */
    fun parseGetEventsResponse(body: IntArray): GetEventsSummary? {
        if (body.size < 6) return null
        val eventsReceived = body[0] and 0xFF
        val bytesLeft = (body[2].toLong() and 0xFFL) or
            ((body[3].toLong() and 0xFFL) shl 8) or
            ((body[4].toLong() and 0xFFL) shl 16) or
            ((body[5].toLong() and 0xFFL) shl 24)
        return GetEventsSummary(eventsReceived = eventsReceived, bytesLeft = bytesLeft, moreData = bytesLeft > 0)
    }

    /**
     * Parse a 0x13 SyncTime response body: `current_device_timestamp:4 LE  status:1` (s5.4,
     * [ringverse BLE.md]). ringverse labels the field "seconds" but the tick unit is unconfirmed; the
     * caller disambiguates against the persisted resume cursor (OuraDriver.syncTimeAnchorCandidate).
     * Returns null on a short body. Byte-identical twin of Swift's parseSyncTimeResponse.
     */
    fun parseSyncTimeResponse(body: IntArray): SyncTimeResponse? {
        if (body.size < 5) return null
        val ts = (body[0].toLong() and 0xFFL) or
            ((body[1].toLong() and 0xFFL) shl 8) or
            ((body[2].toLong() and 0xFFL) shl 16) or
            ((body[3].toLong() and 0xFFL) shl 24)
        return SyncTimeResponse(deviceTimestamp = ts, status = body[4] and 0xFF)
    }

    /**
     * Parse one outer frame from the front of `bytes`. Returns null on a short buffer (header or body
     * not fully present), so a caller can wait for more bytes. Per OURA_PROTOCOL.md s2.1.
     */
    fun parseOuterFrame(bytes: IntArray): OuraOuterFrame? {
        if (bytes.size < 2) return null
        val op = bytes[0]
        val len = bytes[1]
        if (bytes.size < 2 + len) return null
        return OuraOuterFrame(op = op, body = bytes.copyOfRange(2, 2 + len))
    }

    /**
     * Split a notification value that may pack several outer frames back to back. Stops and returns
     * what it parsed when a trailing partial frame is found (the Reassembler handles re-buffering for
     * the stream case). Per OURA_PROTOCOL.md s2.1 (loop consume(2+len)).
     */
    fun parseOuterFrames(bytes: IntArray): List<OuraOuterFrame> {
        val out = ArrayList<OuraOuterFrame>()
        var i = 0
        while (i + 2 <= bytes.size) {
            val len = bytes[i + 1]
            val total = 2 + len
            if (i + total > bytes.size) break
            out.add(OuraOuterFrame(op = bytes[i], body = bytes.copyOfRange(i + 2, i + total)))
            i += total
        }
        return out
    }

    /**
     * Interpret an outer frame whose op is 0x2F as a secure-session sub-frame (OURA_PROTOCOL.md s2.2).
     * Returns null when the op is not 0x2F or the body is empty.
     */
    fun parseSecureFrame(frame: OuraOuterFrame): OuraSecureFrame? {
        if (frame.op != secureSessionOp || frame.body.isEmpty()) return null
        return OuraSecureFrame(subop = frame.body[0], subBody = frame.body.copyOfRange(1, frame.body.size))
    }

    /**
     * Parse one TLV inner record LENIENTLY, per open_oura's `Packet::parse` (protocol.rs): the payload
     * is whatever bytes are present up to `min(2 + len, bytes.size)`. The `len` field is NOT required
     * to equal the notification length; open_oura tolerates that disagreement, and honoring it is what
     * keeps NOOP from (a) minting phantom records out of a "too-small" len's leftover bytes or (b)
     * swallowing the next notification on a "too-big" len. Returns null only when the 4 timestamp
     * bytes are not even present (`size < 6`) or `len < 4` — a genuinely unusable frame, never a guess
     * (honest-data invariant). Byte-identical twin of Swift's lenient parseRecord. Per s2.3.
     */
    fun parseRecord(bytes: IntArray): OuraRecord? {
        if (bytes.size < 6) return null   // 2 header + 4 timestamp bytes, the record floor
        val type = bytes[0]
        val len = bytes[1]
        if (len < minRecordLen) return null
        // ringTimestamp is the 4 bytes at offset 2 as a u32 LE (counter low, session high).
        val rt = (bytes[2].toLong() and 0xFFL) or
            ((bytes[3].toLong() and 0xFFL) shl 8) or
            ((bytes[4].toLong() and 0xFFL) shl 16) or
            ((bytes[5].toLong() and 0xFFL) shl 24)
        // Lenient payload: min(declared end, notification end). Trailing bytes beyond `len` are
        // ignored; a truncated payload uses what arrived. Never waits for a next notification.
        val end = minOf(2 + len, bytes.size)
        val payload = if (end > 6) bytes.copyOfRange(6, end) else IntArray(0)
        return OuraRecord(type = type, ringTimestamp = rt, payload = payload)
    }

    /**
     * The records of a notification that tiles EXACTLY into consecutive `tag | len | payload`
     * packets — every packet with `len >= minRecordLen`, every declared end inside the value, and
     * the last one ending on the value's last byte — or null when it does not. The strict
     * counterpart of the lenient single-packet [parseRecord]: never clamps, never guesses, and a
     * value that fails the tiling at any packet is rejected whole (the caller then falls back to
     * the one lenient packet). Byte-identical twin of Swift `OuraFraming.tiledRecords`.
     */
    fun tiledRecords(bytes: IntArray): List<OuraRecord>? {
        val out = ArrayList<OuraRecord>()
        var i = 0
        while (i < bytes.size) {
            if (i + 2 > bytes.size) return null
            val len = bytes[i + 1]
            val end = i + 2 + len
            if (len < minRecordLen || end > bytes.size) return null
            val rec = parseRecord(bytes.copyOfRange(i, end)) ?: return null
            out.add(rec)
            i = end
        }
        return if (out.isEmpty()) null else out
    }
}

/**
 * One notification that was LONGER than a single BLE packet and that the strict tiling rejected, so
 * [OuraReassembler.feed] fell back to the one lenient packet and no record was read from the rest of
 * the value. Observability only - never produced on a path that changes what is parsed.
 *
 * It reports what it can attribute and nothing more: how long the notification was, its first few
 * bytes, and how many of its bytes no record covered. [head] is capped at
 * [OuraReassembler.tilingFailureHeadBytes] (4) deliberately: tag, `len` and the first two timestamp
 * bytes are enough to recognise the shape, and they carry no payload, so a strap log that prints this
 * line carries no measurement of the wearer. The Apple side carries the same value type as the
 * OuraPackedTilingFailure struct in Framing.swift.
 *
 * @property length the notification's byte count.
 * @property head its first [OuraReassembler.tilingFailureHeadBytes] bytes (fewer only if it is
 *   shorter). A `List<Int>` rather than this file's usual `IntArray`: structural equality comes free,
 *   and nothing here is a wire buffer on a hot path.
 * @property unreadBytes how many of its bytes no record was read from: everything past the lenient
 *   packet's declared end, or the whole value when not even one packet could be parsed.
 * @property count this reassembler's running count of such notifications since the last
 *   [OuraReassembler.reset], INCLUDING this one. Carried here so one log line is self-describing and
 *   cannot disagree with a second read of the counter.
 */
data class OuraPackedTilingFailure(
    val length: Int,
    val head: List<Int>,
    val unreadBytes: Int,
    val count: Int,
)

/**
 * Turn each BLE notification into its TLV inner record(s): ONE lenient packet per notification,
 * matching open_oura's `Packet::parse` (protocol.rs), with NO cross-notification buffering and NO
 * byte-drop resync — plus the one case the ring has been seen to send that the one-packet model
 * loses: a notification that tiles EXACTLY into several complete packets (see [feed]).
 *
 * WHY (parity with Swift `dae3d7a4`, the phantom-storm fix): the previous model treated the byte
 * stream as continuous — it buffered partial trailing bytes and looped extracting `2+len` records.
 * Whenever a packet's `len` disagreed with the notification length — which open_oura explicitly
 * tolerates — a too-small `len` made the loop mint phantom records from the leftover bytes (aliased
 * `0x42`/`0x85`/`0x57`/`0x70` tags → the reject/drop storm), and a too-big `len` made it wait and
 * swallow the following notification. Parsing exactly one lenient packet per notification removes
 * both failure modes at the source.
 *
 * The type name and `feed`/`reset` API are kept so the driver call sites are unchanged; no PARSING
 * state is carried. The only state here is the non-tiling counter and its pending reports
 * ([takePackedTilingFailures]), which nothing reads to decide what to parse. Platform-pure.
 * Byte-identical twin of Swift's OuraReassembler.
 */
class OuraReassembler {
    companion object {
        /**
         * How many leading bytes of a non-tiling packed notification are reported (tag, `len`, and the
         * first two timestamp bytes). Enough to recognise the shape, and short enough to carry no
         * payload. Twin of Swift's tilingFailureHeadBytes.
         */
        const val tilingFailureHeadBytes = 4

        /**
         * How many non-tiling packed notifications are reported in full before the per-decade rule
         * below takes over. Twin of Swift's tilingFailureReportCap.
         */
        const val tilingFailureReportCap = 5

        /**
         * Whether the [n]-th non-tiling packed notification of a session is reported. The first
         * [tilingFailureReportCap] are, and after that one per decade (10, 100, 1000, ...). A ring that
         * packs nothing we can read would otherwise flood the ring-buffered strap log and destroy the
         * rest of the evidence; this keeps the line count at `cap + log10(n)` while still putting the
         * session's final magnitude on record within a factor of ten. Byte-identical twin of Swift
         * `shouldReportTilingFailure`.
         */
        fun shouldReportTilingFailure(n: Int): Boolean {
            if (n <= tilingFailureReportCap) return true
            var decade = 10
            while (decade < n) decade *= 10
            return decade == n
        }
    }

    /**
     * This session's running count of notifications LONGER than one BLE packet that the strict tiling
     * rejected - every one of them a value [feed] read one record from and dropped the rest of. Reset
     * by [reset], so it counts per connection. Observability only: nothing reads it to decide what to
     * parse. Twin of Swift's packedTilingFailureCount.
     */
    var packedTilingFailureCount = 0
        private set

    /** The failures recorded but not yet reported, oldest first. */
    private val pendingTilingFailures = ArrayList<OuraPackedTilingFailure>()

    /**
     * Hand the caller the non-tiling packed notifications recorded since the last call, and forget them
     * - the transport logs each one on an ALWAYS-ON line (not Test-Centre-gated: it costs a line only
     * when it happens, and it is exactly what is missing when someone reports thin history with no Test
     * Centre enabled). Byte-identical twin of Swift `takePackedTilingFailures`.
     */
    fun takePackedTilingFailures(): List<OuraPackedTilingFailure> {
        val out = ArrayList(pendingTilingFailures)
        pendingTilingFailures.clear()
        return out
    }

    /**
     * Record a notification [feed] could not read whole, when it was longer than one BLE packet.
     * [read] is how many of its bytes a record did cover (0 when not even one packet parsed). A value
     * of at most [OuraFraming.singlePacketNotificationMaxLen] is a single packet, so the lenient read
     * was the whole value and there is nothing to report. Byte-identical twin of Swift
     * `noteTilingFailure`.
     */
    private fun noteTilingFailure(bytes: IntArray, read: Int) {
        if (bytes.size <= OuraFraming.singlePacketNotificationMaxLen) return
        packedTilingFailureCount += 1
        if (!shouldReportTilingFailure(packedTilingFailureCount)) return
        val headLen = minOf(tilingFailureHeadBytes, bytes.size)
        pendingTilingFailures.add(
            OuraPackedTilingFailure(
                length = bytes.size,
                head = bytes.copyOfRange(0, headLen).toList(),
                unreadBytes = bytes.size - read,
                count = packedTilingFailureCount,
            )
        )
    }

    /** Feed one notification value (BLE callback ByteArray). Convenience over [feed]. */
    fun feed(fragment: ByteArray): List<OuraRecord> =
        feed(IntArray(fragment.size) { fragment[it].toInt() and 0xFF })

    /**
     * Parse one notification value into at most one record (open_oura `Packet::parse`, lenient).
     * Returns `[]` when the notification is not a usable TLV record (too short, or `len < 4`). Never
     * buffers, never spans, never resyncs — a garbled notification is dropped whole, not walked
     * byte-by-byte.
     */
    fun feed(fragment: IntArray): List<OuraRecord> {
        val rec = OuraFraming.parseRecord(fragment)
        if (rec == null) {
            // Nothing parsed at all. Harmless on a short notification, but a LONG one means the whole
            // packed value was dropped, which noteTilingFailure reports (read = 0 bytes covered).
            noteTilingFailure(fragment, read = 0)
            return emptyList()
        }
        // A PACKED notification carries several complete packets back to back. Every NOOP drain
        // captured to date arrives one packet per <= 20-byte notification, but the same ring serving
        // the official app on the same link (same MTU, same get_events bytes) packs ~10 packets into
        // each 196-200-byte notification (2026-09-15: 38,136 packets in 3,613 notifications, every
        // value tiling exactly) and the one-packet read kept one in ten. Walk the packets ONLY when
        // the whole value tiles into two or more well-formed ones; anything else is the single
        // lenient packet, byte-identical to before, so a lone packet whose `len` disagrees with the
        // notification length still yields exactly that packet. Twin of Swift `OuraReassembler.feed`.
        val packed = OuraFraming.tiledRecords(fragment)
        if (packed != null && packed.size >= 2) return packed
        // `packed == null` is the strict walk REJECTING the value. Under the `3f` mask that was the
        // correct answer, because a notification was one <= 20-byte packet; under the official app's
        // `ff` the ring packs 10-17 records per notification, so the same fallback now drops 9-16 of
        // them (OURA_PROTOCOL.md s2.3) and the loss is invisible in a drain that otherwise looks like it
        // worked. Record it so the transport can say so on an always-on line. A non-null `packed` of
        // size 1 is the value tiling exactly into ONE packet: nothing is dropped, nothing to report.
        if (packed == null) {
            noteTilingFailure(fragment, read = minOf(2 + fragment[1], fragment.size))
        }
        return listOf(rec)
    }

    /**
     * Clear the per-session observability state (disconnect teardown). No PARSING state exists to clear
     * in the one-packet-per-notification model - a half-record can never bleed across sessions - so this
     * only resets the non-tiling counter and drops any failure not yet taken, which is what makes
     * [packedTilingFailureCount] a per-connection figure.
     */
    fun reset() {
        packedTilingFailureCount = 0
        pendingTilingFailures.clear()
    }

    /** Always 0: no bytes are ever buffered between notifications (observability only). */
    val bufferedByteCount: Int get() = 0
}
