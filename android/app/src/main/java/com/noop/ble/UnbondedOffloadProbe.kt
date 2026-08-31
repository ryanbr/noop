package com.noop.ble

/**
 * Should NOOP try the historical offload on a WHOOP 5/MG that has NOT bonded?
 *
 * The offload has always been gated on the CLIENT_HELLO ack — `beginBackfill` refuses while
 * `connectHandshakeDone` is false, and for a 5/MG that flag is set in exactly one place, behind `didBond`.
 * On a strap that answers SMP with `Pairing Not Supported` (#1635) the ack can never arrive, so the gate
 * can never open, and the app never asks the strap for history at all.
 *
 * What makes that worth re-examining is that the gate is OURS, not the strap's, and the link underneath it
 * is not the broken thing it was assumed to be. With the hello suppressed the link is stable for tens of
 * minutes (a field capture holds one up for 2431s), live HR streams over the standard profile the whole
 * time, the unbonded DIS identity read succeeds (#490/#1455), and puffin commands — DISABLE_ALARM,
 * TOGGLE_REALTIME_HR — are written to fd4b0002 without the stack objecting. Every bounce in the capture
 * traces to the bond watchdog after an unanswered hello, never to the link itself.
 *
 * What is NOT established is the part that matters, and it is important to be exact about why. Those
 * puffin writes go out WITHOUT response, so their `GATT_SUCCESS` is Android reporting a Write Command
 * handed to the controller — a local fact that says nothing about whether the strap parsed it. And the
 * offload does not arrive on fd4b0002 at all: it arrives on the puffin NOTIFY characteristics
 * (fd4b0003/4/5/7), which this app has never once subscribed on a healthy unbonded link. The single
 * attempt on record (28 Aug, 13:25:00) rode a FALSE bond — a DISABLE_ALARM completion misread as a hello
 * ack, the bug #1635 fixed — and produced `writeDescriptor busy; retry 1/8`, an Android queue error,
 * before the link died 4s later with the hello still outstanding. No answer was ever obtained.
 *
 * The belief that it cannot work is a comment, not a measurement: `BLEManager.swift` records that the
 * strap rejects those subscriptions with "Authentication is insufficient", from a 5/MG that was still
 * bonded to the official WHOOP app (issue #17). That may well be right. It has never been tested against
 * a strap in this state, on a link that stays up long enough to hear the answer.
 *
 * So this probe asks, in stages, each one falsifying the next:
 *
 *  1. subscribe the four puffin notify characteristics. An insufficient-authentication status here is the
 *     whole answer — the offload needs an encrypted link, and #1635 is a wall rather than a gate.
 *  2. if they subscribe, send GET_CLOCK. Read-only on purpose: it changes nothing on the strap, and a
 *     COMMAND_RESPONSE to it is the first hard evidence that puffin commands are acted on unbonded.
 *  3. only then SET_CLOCK and the ordinary offload, which is the existing hardware-proven sequence.
 *
 * Self-limiting the same way [shouldReadDisUnbonded] is: opt-in, once per link, and never again after a
 * refusal is latched for that device. This area has a habit of producing "keeps retrying something that
 * cannot work", and the point of a probe is to stop being one after it has its answer.
 *
 * A refusal is a RESULT. Either outcome closes the last open question on #1635.
 */
internal fun shouldProbeUnbondedOffload(
    isWhoop5: Boolean,
    optedIn: Boolean,
    bonded: Boolean,
    helloWrittenThisLink: Boolean,
    alreadyProbedThisLink: Boolean,
    previouslyRefused: Boolean,
    silentLinksSoFar: Int,
): Boolean {
    if (!isWhoop5) return false
    if (!optedIn) return false
    // A bonded strap reaches the offload through the proven post-hello handshake; this exists only for the
    // straps that path never reaches.
    if (bonded) return false
    // The hello is what drops the link. On a link carrying one, the bond watchdog has ~5s to bounce us, so
    // a refusal here would be unattributable — exactly the ambiguity that made the hello unreadable for
    // eleven weeks. Only the stable no-hello link can answer this question.
    if (helloWrittenThisLink) return false
    if (alreadyProbedThisLink) return false
    if (previouslyRefused) return false
    return unbondedProbeStillWorthAsking(silentLinksSoFar)
}

/**
 * How many links may end in SILENCE before the probe retires itself.
 *
 * A refusal is the strap's verdict and latches outright; silence is weaker evidence — the subscriptions
 * were accepted, and one quiet link says little — so it spends a budget instead. But weaker evidence
 * cannot mean unbounded: the probe re-runs on every reconnect, and a strap that reconnects often would
 * re-ask a question already answered the same way three times, which is the exact shape of the retry this
 * whole area keeps producing.
 *
 * Counted PER DEVICE and persisted ([unbondedProbeSilentLinksPrefKey]), not per process. It was per
 * process, and that was wrong in the field: the foreground service restarts often, every restart re-armed
 * three more links, and each of those links is torn down ~4.8s after the subscriptions reach the air. One
 * capture caught 18 probe starts across 24 connects — the unbounded retry this budget exists to prevent,
 * surviving it by outliving the only thing that bounded it. Bounded within a process and endless across
 * them is not bounded.
 *
 * Cleared by a genuine answer, and by turning the experiment off and on — see [PuffinExperiment].
 */
internal const val UNBONDED_PROBE_MAX_SILENT_LINKS = 3

/** Has the probe any budget left after [silentLinksSoFar] links that ended without an answer — whether
 *  they subscribed and stayed quiet, or were torn down while being asked? */
internal fun unbondedProbeStillWorthAsking(
    silentLinksSoFar: Int,
    cap: Int = UNBONDED_PROBE_MAX_SILENT_LINKS,
): Boolean = silentLinksSoFar < cap

/**
 * The line printed when the probe retires, so the log says why it stopped rather than leaving a reader to
 * notice its absence — the same failure the CLIENT_HELLO's silent suppression caused.
 *
 * It must NOT claim the strap served the subscriptions. It said so, and that was only ever true of the
 * links that subscribed and then stayed quiet. Since #1749 a link LOST mid-probe charges the same budget,
 * and those links confirm no subscribes at all — so on the 31 Aug capture, where every charge was a lost
 * link, this line would have recorded "serves those characteristics unbonded" about a strap that had
 * demonstrated the opposite. Overclaiming from the weaker evidence is the mistake this file is built to
 * avoid, and the retirement line is exactly where a future reader goes looking. The per-link lines
 * ([unbondedProbeLinkLostLine], [unbondedProbeSilentLine]) already say which happened each time; this one
 * states only what holds either way.
 */
internal fun unbondedProbeGaveUpLine(silentLinks: Int): String =
    "Unbonded offload probe: $silentLinks links have ended with no COMMAND_RESPONSE — this strap either" +
        " does not act on puffin commands written over an unencrypted link, or does not hold the link up" +
        " long enough to answer one; the per-link lines above say which happened each time." +
        " Not asking this strap again — turn the experiment off and on to retry." +
        " History offload is unavailable until the strap" +
        " completes a handshake (#1635)."

/**
 * Does opting into the unbonded offload probe replace the handshake attempt on this connect?
 *
 * Found in the field, and it is the difference between the probe running and never running at all.
 * [shouldProbeUnbondedOffload] requires a link carrying NO hello, because a refusal on a link the bond
 * watchdog is about to bounce is unattributable. But the probe is only SCHEDULED from the two no-hello
 * branches, and on this strap neither is reached in practice: across 41 captures the suppression latch
 * fired in three, all on one day, and never since — while the explicit-bond deferral yields after its
 * first connect by design (#1642), so every subsequent link writes a hello. The probe would have sat
 * behind a state the app almost never enters.
 *
 * The resolution is not to loosen the attributability gate, which is what makes the answer worth having.
 * It is to notice that these are MUTUALLY EXCLUSIVE experiments: "does the hello work" and "is the hello
 * needed at all" cannot both be asked of one link, because asking the first is what destroys the second's
 * link. Turning this switch on is choosing the second question, so it supersedes the handshake for that
 * connect — both the explicit pairing request and the hello itself.
 *
 * [userInitiated] still wins, exactly as it does for the suppression latch. Pressing Connect is an
 * explicit request for the handshake, and it must never be answered with a different experiment.
 *
 * Narrow on purpose: 5/MG only, never on a strap that has already bonded (that one reaches the offload the
 * proven way and has nothing to prove), and default off, so no one who has not asked for this is affected.
 */
internal fun unbondedProbeSupersedesHandshake(
    optedIn: Boolean,
    isWhoop5: Boolean,
    appLevelBonded: Boolean,
    userInitiated: Boolean,
): Boolean = optedIn && isWhoop5 && !appLevelBonded && !userInitiated

/**
 * Said once per superseded connect, because a hello that is absent looks identical to one that failed
 * silently — the ambiguity that made #1635 unreadable for eleven weeks.
 *
 * Names the explicit-bond switch when it is also on. The two do not conflict fatally, but a pairing in
 * flight makes a subscribe refusal unattributable to the strap, so the probe declines to latch it and the
 * capture is weaker for no gain.
 */
internal fun unbondedProbeSupersedesLine(explicitBondOptedIn: Boolean): String =
    "WHOOP 5/MG: handshake skipped for this connect — \"try history sync without pairing\" is on, and it" +
        " asks whether the offload needs a bond at all. That question needs a link with no CLIENT_HELLO on" +
        " it, so the hello is not written here (press Connect to try the handshake instead)." +
        (if (explicitBondOptedIn)
            " \"Ask Android to pair\" is on but is ALSO skipped on this connect — this branch returns" +
                " before the pairing request, so no SMP is in flight and a refusal here is attributable" +
                " to the strap."
        else "") +
        " (#1635, experimental)"

/** Persisted key for "this strap refused the unbonded puffin subscriptions". Per device and lowercased,
 *  for the same reason [firmwarePrefKey] is. */
internal fun unbondedOffloadRefusedPrefKey(peripheralId: String?): String? =
    peripheralId?.trim()?.takeIf { it.isNotEmpty() }?.let { "noop.unbondedOffloadRefused.${it.lowercase()}" }

/**
 * Does writing [PuffinExperiment.unbondedOffload] hand every strap's silence budget back?
 *
 * The off->ON EDGE, and not merely "on". A setter that cleared on every true would return the budget to
 * any caller that rewrites the current value, and the budget's whole job is to stop a retry that takes the
 * link down with it. Only the two switches write it today; making this the setter's property rather than
 * its callers' is what keeps that true.
 */
internal fun unbondedProbeBudgetRearms(optedInNow: Boolean, optedInBefore: Boolean): Boolean =
    optedInNow && !optedInBefore

/** Prefix of every persisted silence budget, so opting back in can clear them all without knowing which
 *  straps have one. Sole reason it is a constant rather than an inlined string. */
internal const val UNBONDED_PROBE_SILENT_LINKS_KEY_PREFIX = "noop.unbondedOffloadSilentLinks."

/**
 * Persisted key for "how many links on this strap subscribed the puffin characteristics and drew no
 * answer" — the silence budget of [UNBONDED_PROBE_MAX_SILENT_LINKS], per device and lowercased for the
 * same reason [firmwarePrefKey] is.
 *
 * Deliberately NOT [unbondedOffloadRefusedPrefKey], though a spent budget stops the probe just as a
 * refusal does. A refusal is the strap's answer and is final; a spent budget is ours — we stopped asking —
 * and the user can hand it back. Sharing one key would have the log report a refusal that never happened,
 * which is precisely the conflation [UnbondedProbeEvidence] exists to prevent.
 */
internal fun unbondedProbeSilentLinksPrefKey(peripheralId: String?): String? =
    peripheralId?.trim()?.takeIf { it.isNotEmpty() }
        ?.let { UNBONDED_PROBE_SILENT_LINKS_KEY_PREFIX + it.lowercase() }

/**
 * What a frame arriving on a puffin notify characteristic proves about an unbonded link.
 *
 * The distinction is the whole point of the probe and is easy to lose. A frame — any frame — proves the
 * strap SERVES those characteristics without encryption, which is what the offload transport needs. It
 * does not prove the strap ACTED on anything we wrote, because a stream it would have sent anyway looks
 * identical from here. Only a reply to a command we issued shows the command channel is live, and that is
 * the finding the offload actually depends on.
 *
 * Treating the weaker evidence as the stronger one is how the false bond of 28 Aug happened: an unrelated
 * completion on a shared characteristic was read as an answer to a question nobody had been asked.
 */
internal enum class UnbondedProbeEvidence {
    /** Nothing decodable has arrived. */
    NONE,

    /** A valid frame arrived on a puffin notify characteristic: the strap serves them unbonded. */
    SERVES_NOTIFICATIONS,

    /** A COMMAND_RESPONSE arrived: the strap parsed a puffin command written over an unencrypted link and
     *  answered it. This is the evidence the offload needs. */
    ANSWERS_COMMANDS,
}

/** The COMMAND_RESPONSE type name as `Framing.parseFrame` reports it. */
internal const val COMMAND_RESPONSE_TYPE_NAME = "COMMAND_RESPONSE"

/**
 * Classify one parsed puffin frame as probe evidence.
 *
 * CRC-gated, and deliberately strict about it. A frame whose CRC does not verify is noise on a link we are
 * testing precisely because we do not know whether it is allowed to carry this traffic, and counting noise
 * as proof would let the probe conclude the opposite of the truth. `crcOk == null` (no CRC to check) is
 * not a pass either — [ok] alone is an envelope check.
 */
internal fun unbondedProbeEvidenceOf(
    ok: Boolean,
    crcOk: Boolean?,
    typeName: String?,
): UnbondedProbeEvidence = when {
    !ok || crcOk != true || typeName.isNullOrBlank() -> UnbondedProbeEvidence.NONE
    typeName == COMMAND_RESPONSE_TYPE_NAME -> UnbondedProbeEvidence.ANSWERS_COMMANDS
    else -> UnbondedProbeEvidence.SERVES_NOTIFICATIONS
}

/**
 * Keep the strongest evidence seen on this link.
 *
 * The probe's verdict must not depend on which frame happened to arrive last. A REALTIME_DATA burst
 * following the COMMAND_RESPONSE would otherwise walk the conclusion back down to the weaker finding.
 */
internal fun strongerProbeEvidence(
    a: UnbondedProbeEvidence,
    b: UnbondedProbeEvidence,
): UnbondedProbeEvidence = if (b.ordinal > a.ordinal) b else a

/** Announced before stage 1 so a capture shows the probe starting, not just its outcome. */
internal fun unbondedProbeStartLine(): String =
    "Unbonded offload probe: subscribing the puffin notify chars (fd4b0003/4/5/7) on a link with no" +
        " CLIENT_HELLO. Never attempted on a healthy link before — an insufficient-authentication status" +
        " here means the offload requires an encrypted bond and #1635 ends it (experimental, #1635)."

/**
 * Stage 1's refusal — the answer the probe exists to get.
 *
 * Named as a finding rather than an error: it settles for Android what only a comment has claimed, and it
 * is latched per device so the strap says it once instead of on every reconnect.
 */
internal fun puffinSubscribeRefusedLine(uuid: String, status: String): String =
    "Unbonded offload probe: subscribe of $uuid failed $status. If this is an insufficient-authentication" +
        " or -encryption status, the puffin notify chars need an encrypted link, the historical offload" +
        " cannot be reached without a bond, and a 5/MG that refuses SMP can never sync history (#1635)."

/**
 * Stage 1 ended because the LINK did, before any subscribe was confirmed or refused.
 *
 * The outcome the probe had no verdict for, and the field capture is unambiguous about how much that
 * matters: 16 probe starts, 0 verdicts of any kind, 0 confirmed subscribes, 0 refusals, and the link
 * dying 10.8s into every connect — roughly three seconds after the CCCD writes went out. With no verdict
 * the silence budget never advanced, so the probe re-ran on every reconnect indefinitely. That is exactly
 * the unbounded retry [shouldProbeUnbondedOffload]'s own doc claims this design prevents, reintroduced by
 * an unhandled exit.
 *
 * It is also a FINDING, not just a gap. No callback and no ATT error, then a teardown about three seconds
 * later, is the CLIENT_HELLO's signature — the same silent elevate-and-drop, on the same service. It does
 * not prove the puffin characteristics require encryption, but it is what that would look like from here,
 * and it says plainly that the offload is not reachable on this strap without a bond.
 *
 * Charged to the silence budget, because "the link will not survive being asked" is a stronger reason to
 * stop asking than a strap that merely stayed quiet.
 */
internal fun unbondedProbeLinkLostLine(
    uptimeMs: Long,
    confirmedSubscribes: Int,
    total: Int,
): String =
    "Unbonded offload probe: the link dropped ${uptimeMs}ms into this connect with $confirmedSubscribes" +
        " of $total puffin subscribes confirmed and no refusal — no callback and no ATT error, then a" +
        " teardown. That is the CLIENT_HELLO's own signature on the same service, so the offload is not" +
        " reachable on this strap without a bond (#1635)."

/**
 * Stage 2 ended because the link did, with GET_CLOCK already on the wire.
 *
 * Deliberately NOT the same line as [unbondedProbeLinkLostLine], and that distinction is the whole point.
 * A stage-1 link loss carries a finding — the subscribes drew no callback and no ATT error before the drop,
 * which is the CLIENT_HELLO's signature. A stage-2 link loss carries none: the subscribes LANDED, the
 * transport was open, and the strap was still within its window to answer when the link went. Reporting
 * that as evidence the strap will not answer would be the same conflation this probe keeps having to
 * unpick.
 *
 * It still spends a budget attempt, because an inconclusive link is not a reason to retry forever — that
 * is the hole this exists to close, and leaving stage 2 uncounted would reopen it one stage later.
 */
internal fun unbondedProbeLinkLostAskingLine(uptimeMs: Long, waitedMs: Long): String =
    "Unbonded offload probe: the link dropped ${uptimeMs}ms into this connect, ${waitedMs}ms after" +
        " GET_CLOCK went out. The subscribes had landed, so the transport was open and the strap was still" +
        " inside its window to answer — this link settles nothing either way (#1635)."

/**
 * How many times the probe may stand aside for the DIS chain before going anyway.
 *
 * A cap rather than an open wait, because the chain has exits that never reach its terminal — a refused
 * read, or a strap that stops answering part-way — and a probe waiting on a flag nobody will clear would
 * simply never run. Eight checks at a second each, then it takes its chances and the trace says which
 * happened.
 */
internal const val UNBONDED_PROBE_MAX_DEFERRALS = 8

/**
 * Should the probe wait rather than start?
 *
 * Pure so the decision is testable without a GATT stack, like every other judgement in this file. It was
 * briefly inline in the client, which is how the same class of gap reached #1755: the behaviour was
 * argued for in a comment and asserted nowhere.
 */
internal fun unbondedProbeShouldWaitForDis(
    disChainInFlight: Boolean,
    deferralsSoFar: Int,
    cap: Int = UNBONDED_PROBE_MAX_DEFERRALS,
): Boolean = disChainInFlight && deferralsSoFar < cap

/**
 * The probe is holding off because the unbonded DIS chain still has the GATT queue.
 *
 * Logged once per link rather than per deferral: the useful fact is that it waited at all, and a line a
 * second for eight seconds would bury it. Without this the probe simply appears late in a capture with
 * no reason given, which is the shape of problem this whole area keeps producing.
 */
internal fun unbondedProbeWaitingForDisLine(): String =
    "Unbonded offload probe: waiting for the DIS read chain to finish — they share one GATT queue, and" +
        " starting on top of it makes every CCCD write come back busy (#1635)."

/**
 * The wait ran out and the probe went anyway.
 *
 * Not a failure. The DIS chain has exits that never reach its terminal — a refused read, or a strap that
 * stops answering part-way — so a probe that waited on the flag forever would never run at all. Saying
 * which of the two happened is the point: a probe that waited the full budget and then found a busy queue
 * is a different capture from one that started cleanly.
 */
internal fun unbondedProbeStoppedWaitingLine(deferrals: Int): String =
    "Unbonded offload probe: the DIS chain has not finished after $deferrals checks — starting anyway." +
        " If the subscribes come back busy, that queue is why, not the strap (#1635)."

/**
 * Stage 2's question, logged so the wait that follows is attributable to it.
 *
 * Carries the CONFIRMED count, not the attempted one. A CCCD write can also end by being abandoned after
 * its busy retries, which reaches the same completion path as four clean subscribes — so a line that said
 * "subscribed" flatly would overstate a partial result in the one log this experiment exists to produce.
 */
internal fun unbondedProbeAskingLine(subscribed: Int, total: Int, waitMs: Long): String =
    "Unbonded offload probe: $subscribed of $total puffin notify chars subscribed — the strap serves them" +
        " on an unencrypted link. Sending GET_CLOCK (read-only, changes nothing on the strap) and" +
        " listening ${waitMs}ms for a COMMAND_RESPONSE, which would be the first proof it acts on puffin" +
        " commands unbonded (#1635)."

/**
 * Stage 1 ended with nothing confirmed and no refusal to name.
 *
 * Distinct from both other stage-1 outcomes on purpose. A refusal is the strap's answer; this is the
 * absence of one — every write was abandoned by our own stack before the strap ever ruled — and reporting
 * it as either a refusal or a success would put a fact in the capture that was never established.
 */
internal fun unbondedProbeNoSubscriptionsLine(total: Int): String =
    "Unbonded offload probe: none of the $total puffin notify chars completed their subscribe, and none" +
        " was refused either — the writes were abandoned locally, so the strap never ruled on them. No" +
        " question asked; this link proves nothing either way (#1635)."

/**
 * Stage 2's silence.
 *
 * Distinguished from a refusal on purpose: the subscriptions landed, so the transport is open and the
 * strap simply did not answer. That is a different fact about the strap than "it declined the link", and a
 * capture that conflated them would send the next reader after the wrong thing.
 */
internal fun unbondedProbeSilentLine(waitedMs: Long, sawNotifications: Boolean): String =
    "Unbonded offload probe: no COMMAND_RESPONSE after ${waitedMs}ms. The subscriptions were accepted" +
        (if (sawNotifications) " and frames did arrive on them," else " but nothing arrived on them,") +
        " so the transport is open and the strap is not answering commands on an unencrypted link." +
        " Not retrying on this strap (#1635)."

/** Stage 2's success — the finding that unlocks the rest. */
internal fun unbondedProbeAnsweredLine(): String =
    "Unbonded offload probe: COMMAND_RESPONSE received — the strap ACTS on puffin commands over an" +
        " unencrypted link. Clocking the strap and requesting the historical offload (#1635)."

/**
 * The expectation to set the moment the probe succeeds, not after the offload returns empty.
 *
 * An un-clocked 5/MG is hardware-known not to persist sensor data to flash at all ("RTC timestamp … is
 * invalid; not saving data to flash", #78 fork). A strap that has never completed a handshake has never
 * been clocked by NOOP, so the honest expectation is that an offload which finally runs may find little or
 * nothing banked — and that this buys FUTURE syncing rather than recovering the backlog. GET_DATA_RANGE
 * answers it directly, which is why it is the stage before the transfer rather than after it.
 */
internal fun unbondedProbeBacklogCaveatLine(): String =
    "Unbonded offload probe: note that this strap has never been clocked by NOOP, and an un-clocked 5/MG" +
        " does not save sensor data to flash — so GET_DATA_RANGE may legitimately report little or nothing" +
        " banked. That would mean history works from now on, not that the probe failed (#1635)."
