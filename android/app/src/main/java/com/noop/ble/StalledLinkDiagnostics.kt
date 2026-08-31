package com.noop.ble

/**
 * Why a 5/MG link reaches "live HR works, nothing ever syncs" — said once, in the log, instead of left
 * to be reconstructed from four separate lines that each state only part of it.
 *
 * The field log that motivated this file contained every fact needed to explain a strap that had not
 * banked a row in three days, and none of them said so. `Backfill: deferred — connect handshake not done
 * yet` repeated with no state; the hello's absence was visible only as a line that never appeared; and
 * the deferral that caused it returned silently. Reading it required knowing that `connectHandshakeDone`
 * is gated on `didBond` for WHOOP5 and not for WHOOP4, that the handshake tail is what sends SET_CLOCK,
 * and that an un-clocked 5/MG discards its own sensor data. That is too much reconstruction to ask of a
 * capture, and it is the reconstruction that has to happen fastest when someone reports lost data.
 *
 * These builders are pure so the wording is testable and cannot drift from what the counters mean. The
 * counters they render live in `WhoopBleClient` and are per app process — the honest limit of an
 * in-memory bound, and the same one [overrideHelloStillAllowed] documents. The loops these describe run
 * within one process; a restart is not the failure mode.
 */

/**
 * The hello was not written on this link because a `createBond()` was asked for first.
 *
 * [ExplicitBond] already explains why that deferral never resolves on a strap answering SMP 0x05: the
 * next connect requests a bond too, and defers again. What it could not do is say so at runtime — the
 * deferral branch returns without a word, so a capture shows a hello that simply never happens, with the
 * reason inferable only from an `explicitBondRequestLine` promising a "next connect" that reads
 * identically on the first deferral and the fiftieth.
 *
 * [consecutive] is what makes it diagnosable. One deferral is the experiment working as designed; a
 * number climbing across every connect is the permanent state, and the difference between those two is
 * the entire question. Printing the count converts "why is there no hello" into one line.
 *
 * The override's state rides along because it is the only thing that breaks the cycle, and a reader who
 * sees the deferral will immediately want to know whether the escape hatch is on and whether it has
 * budget left. Naming a spent override explicitly stops it reading as an untried option.
 */
internal fun helloDeferredByExplicitBondLine(
    consecutive: Int,
    overrideOptedIn: Boolean,
    overrideAttempts: Int,
    full: Boolean = true,
    cap: Int = HELLO_OVERRIDE_MAX_ATTEMPTS,
): String {
    // Both switches named explicitly. The first cut printed a bare "(override off)" one clause after the
    // words "the pairing experiment", and a reader reasonably took it to mean the EXPERIMENT was off -
    // costing a real debugging session, because the experiment was on the whole time. A parenthetical
    // reporting one setting's state while the sentence names a different setting has to say which is which.
    val override = when {
        !overrideOptedIn -> "experiment ON, hello override off"
        overrideHelloStillAllowed(overrideAttempts, cap) -> "experiment ON, hello override on ($overrideAttempts/$cap used)"
        else -> "experiment ON, hello override SPENT ($overrideAttempts/$cap)"
    }
    val tail = if (consecutive >= 2 && !full) {
        // The guidance is a paragraph and this fires once per CONNECT, on a path documented to loop —
        // HelloSuppression records 57 reconnect cycles in an hour. Printing the paragraph 57 times would
        // bury the rest of the capture under advice already given, so the full text is one-shot (the
        // same latch idiom as helloOverrideExhaustedLine) and later occurrences stay countable but terse.
        " $consecutive consecutive connects deferred, still no bond and no hello written — see the first" +
            " occurrence above for what to do."
    } else if (consecutive >= 2) {
        // Observed here vs cited from elsewhere, kept apart on purpose: the deferral count and the
        // absent bond ARE measured on this link; SMP 0x05 is not, and cannot be without an HCI capture.
        // Stating the cited cause as this strap's would be the #1635 mistake of a diagnostic claiming
        // more than it observed.
        " Observed on this link: $consecutive consecutive connects deferred, no bond completed, and no" +
            " hello written on any of them — so the \"next connect\" this waits for is not arriving." +
            " A 5/MG answering Pairing Request with SMP 0x05 produces exactly this and is the known" +
            " cause (#1635), but only an HCI capture can confirm it HERE. Either way the consequence is" +
            " local and certain: didBond stays false, so SET_CLOCK never runs, and an un-clocked 5/MG" +
            " does not persist its own sensor data to flash. Turn the pairing experiment OFF, or the" +
            " hello override ON."
    } else {
        " Deferred once so far — expected on the connect that asks."
    }
    return "WHOOP 5/MG: CLIENT_HELLO deferred by the pairing experiment ($override).$tail (#1635)"
}

/**
 * `beginBackfill` declined, with the state that decided it.
 *
 * The bare line named the gate and nothing else, so every occurrence looked the same whether the
 * handshake was seconds from completing or structurally unreachable. These five fields separate those:
 * a WHOOP5 with `didBond=false` and no hello ever written is the unreachable case, and it reads that way
 * at a glance rather than after a code trace.
 *
 * [helloEverWrittenThisLink] earns its place by distinguishing the two ways to arrive here that need
 * opposite fixes — a hello that was written and went unanswered (a strap or timing problem) from one that
 * was never written at all (a local decision, and the one this log's field capture actually hit).
 */
internal fun backfillDeferredLine(
    family: String?,
    didBond: Boolean,
    helloEverWrittenThisLink: Boolean,
    explicitBondRequestedThisLink: Boolean,
    deferralsThisLink: Int,
    msSinceConnect: Long,
): String {
    val since = if (msSinceConnect >= 0L) "${msSinceConnect / 1000}s" else "?"
    // NULL means service discovery has not established the family yet. `connectedFamily` defaults to
    // WHOOP4 and otherwise holds the PREVIOUS link's value, so printing it unconditionally would put a
    // guess in the log — and a guess of WHOOP4 would suppress the explanation below on exactly the 5/MG
    // this exists for. The caller reads `familyEstablished` FIRST for the happens-before it carries.
    val fam = family ?: "unestablished"
    val why = if (family == "WHOOP5" && !didBond && !helloEverWrittenThisLink) {
        // A structural claim, not a guess about the strap: didBond is set only by the hello's own ack,
        // so no hello written means this gate cannot open on this link no matter what the strap does.
        " No hello was written on this link, so didBond cannot become true and this gate cannot open" +
            " for the rest of it. SET_CLOCK rides the same handshake tail, and an un-clocked 5/MG is" +
            " hardware-known not to persist sensor data to flash (#78 fork) — so there may also be" +
            " nothing banked to offload."
    } else {
        ""
    }
    return "Backfill: deferred — connect handshake not done yet (family=$fam didBond=$didBond" +
        " helloWrittenThisLink=$helloEverWrittenThisLink bondRequestedThisLink=" +
        "$explicitBondRequestedThisLink deferrals=$deferralsThisLink sinceConnect=$since).$why"
}

/**
 * Standard-HR (0x2A37) transport-state lines — the Kotlin twins of Swift's `LivePersistTrace`
 * (`Packages/StrandAnalytics`), byte-identical so an Android and an Apple log of the same stall compare
 * directly. They live here, beside their caller, for the same reason [liveInsertFailedLine] does.
 *
 * They describe host observation and buffer/persistence state only. Nothing here carries a physiological
 * measurement, and nothing claims a sensor-origin time: the BLE Heart Rate Measurement characteristic
 * does not provide one, so a receipt time is the host's observation and is labelled as such.
 *
 * The pair that matters is offered vs inserted. [standardHrFlushAttemptLine] reports what was handed to
 * the store and [standardHrFlushSucceededLine] what the store actually took, because a batch that is
 * offered in full and inserted as zero is precisely the failure that otherwise reads like success.
 */
internal fun standardHrFlushAttemptLine(
    reason: String,
    offeredHrRows: Int,
    offeredRrRows: Int,
): String =
    "standard-hr transport flush-attempt reason=$reason" +
        " offeredHRRows=$offeredHrRows offeredRRRows=$offeredRrRows"

/** Twin of Swift `LivePersistTrace.standardHRFlushSucceededLine`. */
internal fun standardHrFlushSucceededLine(
    reason: String,
    offeredHrRows: Int,
    offeredRrRows: Int,
    insertedHrRows: Int,
    insertedRrRows: Int,
): String =
    "standard-hr transport flush-succeeded reason=$reason" +
        " offeredHRRows=$offeredHrRows offeredRRRows=$offeredRrRows" +
        " insertedHRRows=$insertedHrRows insertedRRRows=$insertedRrRows"

/** Twin of Swift `LivePersistTrace.standardHRRebufferedForRetryLine`. */
internal fun standardHrRebufferedForRetryLine(
    reason: String,
    attemptedHrRows: Int,
    attemptedRrRows: Int,
    pendingHrRows: Int,
    pendingRrRows: Int,
    consecutiveFailures: Int,
): String =
    "standard-hr transport rebuffered-for-retry reason=$reason" +
        " attemptedHRRows=$attemptedHrRows attemptedRRRows=$attemptedRrRows" +
        " pendingHRRows=$pendingHrRows pendingRRRows=$pendingRrRows" +
        " consecutiveFailures=$consecutiveFailures"

/**
 * Why a standard-HR flush ran. Twin of Swift's `LivePersistTrace.StandardHRFlushReason`, and the raw
 * values must stay identical because they are what the log line carries.
 *
 * `background` and `termination` are Apple-only today: iOS suspends a connected strap without a
 * disconnect edge, which Android's foreground service does not do. They exist here so the two enums do
 * not drift, and so an Android answer to "should an OEM kill flush this buffer?" has a name already.
 */
internal enum class StandardHrFlushReason(val raw: String) {
    CADENCE("cadence"),
    DISCONNECT("disconnect"),
    BACKGROUND("background"),
    TERMINATION("termination"),
    EXPLICIT("explicit"),
}

/**
 * A live HR/R-R batch failed to persist and was re-buffered.
 *
 * The catch that owns this re-queues the frames and swallows the throwable, so a store that is failing
 * every insert produces a log full of `rr emit … offered=13` and no indication that none of it landed.
 * That is the worst shape a diagnostic gap can take: the instrumentation that exists reads like success.
 *
 * [transport] is named because there are TWO live paths — the standard 0x2A37 reading and the puffin
 * REALTIME_DATA batch (#1118) — and they fail independently. A line that did not say which would leave a
 * reader unable to tell one dead transport from a dead store, which is the first fork in the diagnosis.
 *
 * [consecutiveFailures] matters more than any single throwable. One failure is a transient the re-buffer
 * exists to absorb; a climbing count is a store that is never going to accept these rows, and only the
 * count separates them. The message is included because the useful cases — a full disk, a corrupted
 * database, a schema mismatch — are distinguished by it rather than by the class.
 */
internal fun liveInsertFailedLine(
    transport: String,
    throwableName: String,
    message: String?,
    hrFrames: Int,
    rrFrames: Int,
    consecutiveFailures: Int,
): String {
    val detail = message?.takeIf { it.isNotBlank() }?.let { ": ${it.take(200)}" } ?: ""
    val run = if (consecutiveFailures >= 2) {
        " $consecutiveFailures consecutive failures — these rows are not landing and the re-buffer is" +
            " not recovering them."
    } else {
        " Re-buffered for the next cadence."
    }
    return "Live persist FAILED on $transport — $throwableName$detail (hr=$hrFrames rr=$rrFrames).$run"
}

/**
 * Rate-limit for [liveInsertFailedLine].
 *
 * The live cadence is seconds, so an unconditional log would bury the rest of the capture under a
 * failure it has already reported. The gap is deliberately long: this line exists to establish THAT
 * inserts are failing and roughly for how long, which one line a minute answers as well as sixty.
 *
 * A zero [lastEmitMs] must emit — the first failure is the one most worth having, and treating "never
 * emitted" as "just emitted" would silence exactly the case this was built for.
 *
 * A BACKWARDS clock emits too. `System.currentTimeMillis()` is wall time and can step back — an NTP
 * correction, a timezone-adjacent settings change, or the strap-clock skew this log family already
 * tracks. Comparing only forwards would leave `lastEmitMs` stranded in the future and silence the line
 * until real time caught up, which for a large step is indefinitely. Emitting on the step costs one
 * extra line and cannot latch.
 */
internal fun shouldEmitLiveInsertFailure(
    lastEmitMs: Long,
    nowMs: Long,
    minGapMs: Long = 60_000L,
): Boolean = lastEmitMs <= 0L || nowMs < lastEmitMs || nowMs - lastEmitMs >= minGapMs
