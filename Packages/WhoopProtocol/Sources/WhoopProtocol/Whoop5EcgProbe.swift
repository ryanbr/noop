import Foundation

/// Formats the WHOOP MG ECG ("Labrador") turn-on attempt into one readable, copyable report — the
/// per-command COMMAND_RESPONSE result codes, whether any ECG-shaped packet actually arrived, and a
/// verdict that describes WHAT THE RUN OBSERVED rather than naming a mechanism behind it.
///
/// Pure + deterministic, so `swift test` covers it with no strap. Structurally the twin of
/// `BodyLocationProbe` / `ExtendedBatteryProbe`.
///
/// Mirrored in Kotlin as `com.noop.protocol.Whoop5EcgProbe` even though the Android client has no ECG
/// app layer to drive it. The classification below decides how a null result gets reported, which is
/// the claim this probe exists to make — a rule that important is worth two independent
/// implementations and two test suites, and both suites pin the same runs.
///
/// ## The verdicts name observations, not mechanisms
///
/// An earlier version of this type reported a silent run as *"consistent with a device-flag block
/// applied as a silent no-op"* and a refusal as `blockedByDeviceFlagsLikely`. **Both named a mechanism
/// this probe cannot observe and the protocol does not carry.** `blockedByDeviceFlags` is a
/// CLIENT-SIDE construct: it is never transmitted to a strap, no command in `whoop_protocol.json`'s
/// `CommandNumber` table reads or writes such a flag, and nothing in this repo implements one. It is
/// not a strap capability gate, so a probe that only ever sees result codes and packet counts is in no
/// position to attribute silence to it.
///
/// That mattered in practice. #891 tested the leading named candidate for a firmware-side gate
/// (`enable_raw_data_w_ecg`, written to `'1'` and read back through `GET_DEVICE_CONFIG_VALUE(121)`)
/// and still got zero packets in 30 s with the electrodes held — so the flag-block reading is not
/// where the evidence points, and it was the probe's own wording that kept lending it weight. Five
/// other explanations fit the same silence: banked to flash rather than streamed, a wrong opcode
/// mapping, no actual start verb among three `TOGGLE_*` commands, an entitlement gate, or an
/// electrode circuit that never closed.
///
/// So the three signals below are reported as themselves, and the report states which one fired:
///
///   1. `UNSUPPORTED(3)` — the firmware does not implement the opcode at all. A different, and more
///      final, answer than a refusal.
///   2. `FAILURE(0)` — the firmware KNOWS the opcode and REFUSES to run it. That is a fact about the
///      opcode; WHY it refused is not on the wire.
///   3. `SUCCESS(1)` on every command, but ZERO ECG packets across the capture window — acknowledged
///      and then not honoured. That is the reason this probe counts arriving packets instead of
///      trusting the acks. It does not identify what suppressed them.
///
/// Nothing is ever inferred from silence alone: no reply at all is reported as exactly that, because
/// an in-flight sync or a dropped notification produces the same silence.
///
/// ## What a run has to contain before silence means anything
///
/// Signal 3 above reads SILENCE as evidence. Silence only carries information when the run actually
/// **asked the strap for data**: a wrist selection changes no data path, and the OFF sequence asks for
/// the silence it gets. So every step records whether the command — *with the argument it was sent
/// with* — could have produced realtime ECG data (`Whoop5Ecg.requestsRealtimeData`), and the two
/// verdicts that interpret silence are unreachable without one:
///
/// - `acceptedButSilent` needs a data request that came back `SUCCESS`. Requested-but-unacknowledged is
///   `dataRequestNotAccepted`; nothing requested at all is `noDataRequested`.
/// - `dataRequestRefused` needs the refused command to be a data request. A `FAILURE` on a
///   configuration write is reported as `commandRefused` — the firmware refused *that write*, which is
///   a fact about that opcode and not about whether ECG generation is gated.
///
/// Both defects were live: a `SELECT_WRIST`-only run on a WHOOP 5 MG rendered "Accepted but SILENT …
/// consistent with a device-flag block" having sent no data-generation command at all, and a second
/// `SELECT_WRIST`-only run that came back `FAILURE` rendered "LIKELY blockedByDeviceFlags". Both
/// manufactured evidence for hypothesis (e) of #891 out of runs that could not speak to it.
public enum Whoop5EcgProbe {

    /// The 5/MG COMMAND_RESPONSE result code, at frame[12] — the same offset `BodyLocationProbe` reads.
    public static let resultCodeOffset = 12

    public enum CommandOutcome: Equatable, Sendable {
        case success
        case failure
        case pending
        case unsupported
        case unmapped(Int)
        /// No COMMAND_RESPONSE arrived inside the probe window.
        case noReply

        public var token: String {
            switch self {
            case .success: return "SUCCESS(1)"
            case .failure: return "FAILURE(0)"
            case .pending: return "PENDING(2)"
            case .unsupported: return "UNSUPPORTED(3)"
            case .unmapped(let v): return "result\(v)"
            case .noReply: return "no reply"
            }
        }
    }

    /// Read the result code out of a 5/MG COMMAND_RESPONSE frame. nil when the frame is too short.
    public static func outcome(frame: [UInt8]) -> CommandOutcome? {
        guard frame.count > resultCodeOffset else { return nil }
        switch Int(frame[resultCodeOffset]) {
        case 0: return .failure
        case 1: return .success
        case 2: return .pending
        case 3: return .unsupported
        case let other: return .unmapped(other)
        }
    }

    /// One command in the turn-on sequence and what came back.
    public struct Step: Equatable, Sendable {
        public let label: String
        public let outcome: CommandOutcome
        /// Whether this command, with the argument it was actually sent with, could have made the strap
        /// emit realtime ECG data — `Whoop5Ecg.requestsRealtimeData(cmd:arg:)`.
        ///
        /// Deliberately has NO default: every construction site must state it, because the verdicts that
        /// read silence as evidence turn on this flag and a silently-omitted `true` is exactly the bug
        /// this field exists to prevent.
        public let requestsRealtimeData: Bool
        /// The reply frame as hex, when one arrived.
        public let replyHex: String?

        public init(label: String,
                    outcome: CommandOutcome,
                    requestsRealtimeData: Bool,
                    replyHex: String? = nil) {
            self.label = label
            self.outcome = outcome
            self.requestsRealtimeData = requestsRealtimeData
            self.replyHex = replyHex
        }

        /// How the report annotates the step, so a reader can see WHY the verdict is what it is.
        public var roleNote: String {
            requestsRealtimeData ? "asks for realtime ECG data"
                                 : "cannot produce ECG data (configuration or OFF)"
        }
    }

    /// The gate verdict, kept separate from the report text so it is assertable in a test.
    public enum Verdict: Equatable, Sendable {
        /// Revision-17 Labrador records arrived. Stronger than it used to be: the old structural
        /// heuristic could match an unrelated packet, whereas `Whoop5Ecg.isLabradorR17Frame` requires
        /// both CRCs, `inner[0] == 43`, `inner[1] == 17` and a sample block that fits. Still called a
        /// candidate, because what the samples MEAN remains unvalidated here — and confirming a run
        /// needs the raw bytes in the log, never this count alone.
        case ecgCandidatesArrived(packets: Int)
        /// At least one command that ASKED FOR DATA came back FAILURE: the opcode exists and execution
        /// was refused. WHY it was refused is not on the wire — the reply carries a result code and
        /// nothing that names a cause.
        case dataRequestRefused(commands: [String])
        /// A command that asks for no data came back FAILURE. The firmware refused THAT WRITE, which is
        /// a fact about that opcode and says nothing about whether ECG generation is gated.
        case commandRefused(commands: [String])
        /// Everything acked SUCCESS, at least one of them a data request, and nothing ever arrived.
        case acceptedButSilent(windowSeconds: Int)
        /// The run sent nothing that could produce realtime ECG data, so its silence is the expected
        /// outcome and is evidence of nothing.
        case noDataRequested(commands: [String])
        /// Data WAS requested, but the strap never returned SUCCESS for the request — so the silence
        /// cannot be read as "accepted, then not honoured".
        case dataRequestNotAccepted(commands: [String])
        /// The firmware rejected an opcode as unimplemented.
        case opcodeUnsupported(commands: [String])
        /// Nothing replied at all.
        case noReplies
        /// A mixed or unmapped set of codes that none of the above describes.
        case inconclusive

        public var headline: String {
            switch self {
            case .ecgCandidatesArrived(let packets):
                return "\(packets) revision-17 ECG packet(s) decoded. The strap IS producing the filtered "
                    + "trace: each one arrived as type 43 revision 17 with both CRCs intact. What the samples "
                    + "MEAN is still unvalidated here — check the per-packet progress and presence below to see "
                    + "whether a reading actually advanced, rather than reading the count alone."
            case .dataRequestRefused(let commands):
                return "DATA REQUEST REFUSED — the firmware returned FAILURE for \(commands.joined(separator: ", ")), "
                    + "which asked it to produce ECG data: it knows the opcode and refused to run it. "
                    + "The reply says THAT it refused, not WHY — no cause is carried on the wire."
            case .commandRefused(let commands):
                return "REFUSED — the firmware returned FAILURE for \(commands.joined(separator: ", ")). "
                    + "That command asks for no ECG data, so this is a fact about that write and NOT evidence "
                    + "that ECG generation is blocked. Nothing here speaks to the block question."
            case .acceptedButSilent(let windowSeconds):
                return "Accepted but SILENT — a command that asks for realtime ECG data returned SUCCESS, every "
                    + "other command did too, yet no ECG packet arrived in \(windowSeconds)s. "
                    + "That is the observation; it does not identify a cause. Data banked to flash rather than "
                    + "streamed, a wrong opcode mapping, no start verb among these commands, an entitlement gate "
                    + "and an open electrode circuit all produce this same silence."
            case .noDataRequested(let commands):
                return "NOT A TEST of whether ECG is blocked — this run sent no command that could produce "
                    + "realtime ECG data (\(commands.joined(separator: ", "))), so zero packets is the EXPECTED "
                    + "outcome and says nothing either way. Run the turn-on sequence to test the block question."
            case .dataRequestNotAccepted(let commands):
                return "INCONCLUSIVE — data was requested (\(commands.joined(separator: ", "))) but the strap never "
                    + "returned SUCCESS for it, so the silence cannot be read as 'accepted, then not honoured'. "
                    + "Retry idle."
            case .opcodeUnsupported(let commands):
                return "Opcode UNSUPPORTED on this firmware for \(commands.joined(separator: ", ")) — "
                    + "the command is not implemented, which is a different and more final answer than a refusal."
            case .noReplies:
                return "No COMMAND_RESPONSE at all — the strap answered nothing. Silence is not evidence of a block "
                    + "(a mid-flight sync or a missed notification looks identical); retry idle."
            case .inconclusive:
                return "INCONCLUSIVE — the result codes do not match a known pattern. The raw replies below are the record."
            }
        }
    }

    /// How long one run listens, in seconds, chosen by what started it.
    ///
    /// `capture` is 60 rather than 30 because of @meta1971's field timing in #891: across five MG
    /// sessions the strap's terminal frame (classifier state 2, progress 100) landed 38 to 39 s after the
    /// first live frame, so a 30 s window could not reach a completed reading on ANY strap or firmware.
    /// The verdict sheet landing at 30 s made that worse than a missed deadline: Stop is the next control
    /// a person reaches for, so the window trained people to end the session 8 to 9 s before the
    /// classifier would have answered, and the probe then reported the silence it had caused.
    ///
    /// `selectOrStop` stays at 30. Those runs wait for a COMMAND_RESPONSE rather than for a reading, so
    /// the longer window would be dead time in front of an answer that already arrived.
    ///
    /// `terminalGrace` is how long a run keeps listening AFTER the terminal frame instead of ending on
    /// it. @meta1971 measured the variability field sitting at `0xffff` for 2 to 9 s past that frame
    /// before it settled, so a probe that stopped on the terminal frame would pin the unset value as the
    /// reading's own. It also means a run that ends early reports early: a terminal frame at 12 s renders
    /// the verdict at 22 s rather than holding the sheet for the rest of the window.
    public enum Window {
        public static let selectOrStop = 30
        public static let capture = 60
        public static let terminalGrace = 10
    }

    /// Cap on the per-packet candidate lines one run records. Each line is rendered into both the report
    /// and the strap log, so a chatty stream must not grow either without bound.
    public static let maxCandidateLines = 12

    /// Slots a run keeps in reserve for TERMINAL frames once `maxCandidateLines` is spent.
    ///
    /// R17 arrives at about one frame a second, so a flat cap keeps seconds 1 to 12 and discards
    /// everything after. Per #891 the result, average HR and reason mask populate only on the terminal
    /// frame, which means the flat cap threw away the single frame carrying the answer and kept twelve
    /// that could not. A reserve rather than a bigger cap: the point is not more evidence, it is the RIGHT
    /// evidence, and the ceiling stays bounded at `maxCandidateLines + maxTerminalCandidateLines`.
    public static let maxTerminalCandidateLines = 4

    /// Whether a decoded frame's line is kept, given what the run has already recorded.
    ///
    /// A terminal frame inside the first `maxCandidateLines` is kept by the ordinary rule and still spends
    /// one reserve slot, so a run can never record more than the ceiling either way.
    ///
    /// Kotlin twin: `Whoop5EcgProbe.retainsCandidate`.
    public static func retainsCandidate(linesKept: Int,
                                        terminalLinesKept: Int,
                                        isTerminal: Bool) -> Bool {
        if linesKept < maxCandidateLines { return true }
        return isTerminal && terminalLinesKept < maxTerminalCandidateLines
    }

    /// Seconds to wait before rendering the verdict once a terminal frame lands, or nil to leave the
    /// run's existing deadline alone.
    ///
    /// ONCE per run (`alreadyExtended`), because the strap sends more than one terminal frame: extending
    /// on each would let a terminal stream push the verdict out indefinitely and the report would never
    /// render.
    ///
    /// Kotlin twin: `Whoop5EcgProbe.terminalGraceSeconds`.
    public static func terminalGraceSeconds(isTerminal: Bool, alreadyExtended: Bool) -> Int? {
        guard isTerminal, !alreadyExtended else { return nil }
        return Window.terminalGrace
    }

    /// Classify the run.
    ///
    /// Order matters, and it puts the ATTESTED signals first: the COMMAND_RESPONSE result codes are
    /// real wire semantics (the same 0/1/2/3 the haptics rejection capture pinned in #48), whereas the
    /// packet count comes from a shape heuristic that unrelated traffic can trip. So an explicit
    /// FAILURE or UNSUPPORTED from the firmware outranks a candidate count, and candidates are the
    /// fallback rather than an override. Nothing is lost either way — `report` always prints the
    /// candidate count alongside the verdict.
    ///
    /// "Unsupported" is reported as itself rather than folded into the block case, and silence is never
    /// reported as a block.
    ///
    /// The SECOND rule the order encodes is SCOPE: a claim about "is the ECG feature blocked" is only
    /// made when the run exercised the ECG data path. A `FAILURE` on a command that asks for no data is
    /// a refusal of that write; silence after a run that asked for no data is the expected outcome. Both
    /// get their own verdict rather than being folded into the block case — see the type doc.
    public static func verdict(steps: [Step], ecgPacketsSeen: Int, windowSeconds: Int) -> Verdict {
        let failures = steps.filter { $0.outcome == .failure }
        if !failures.isEmpty {
            // A refusal is only evidence about the BLOCK question when what was refused asked for data.
            let dataFailures = failures.filter(\.requestsRealtimeData).map(\.label)
            if !dataFailures.isEmpty { return .dataRequestRefused(commands: dataFailures) }
            return .commandRefused(commands: failures.map(\.label))
        }
        let unsupported = steps.filter { $0.outcome == .unsupported }.map(\.label)
        if !unsupported.isEmpty { return .opcodeUnsupported(commands: unsupported) }
        if ecgPacketsSeen > 0 { return .ecgCandidatesArrived(packets: ecgPacketsSeen) }
        guard !steps.isEmpty else { return .noReplies }
        if steps.allSatisfy({ $0.outcome == .noReply }) { return .noReplies }
        // Past this point the verdict INTERPRETS SILENCE, which only carries information about the ECG
        // data path when the run asked that path for something and the strap said yes.
        let requests = steps.filter(\.requestsRealtimeData)
        guard !requests.isEmpty else { return .noDataRequested(commands: steps.map(\.label)) }
        guard requests.contains(where: { $0.outcome == .success }) else {
            return .dataRequestNotAccepted(commands: requests.map(\.label))
        }
        if steps.allSatisfy({ $0.outcome == .success }) {
            return .acceptedButSilent(windowSeconds: windowSeconds)
        }
        return .inconclusive
    }

    /// The full report: verdict, per-command outcomes, the ECG-packet tally, and the raw replies.
    ///
    /// `candidateFrames` are the per-packet lines for frames `Whoop5Ecg.r17FromFrame` decoded — the
    /// sequence, progress and presence of each accepted record, which is what tells a clean run apart
    /// from one the electrodes kept dropping.
    public static func report(steps: [Step],
                              ecgPacketsSeen: Int,
                              candidateFrames: [String],
                              windowSeconds: Int) -> String {
        var sb = ""
        sb += "WHOOP MG ECG (Labrador) TURN-ON PROBE\n"
        sb += "Verdict: \(verdict(steps: steps, ecgPacketsSeen: ecgPacketsSeen, windowSeconds: windowSeconds).headline)\n"
        sb += "\nCommands sent:\n"
        if steps.isEmpty {
            sb += "  (none)\n"
        } else {
            // Each step carries WHY it does or does not bear on the block question, so the verdict above
            // can be checked against its own inputs without reading the source.
            for step in steps {
                sb += "  \(step.label): \(step.outcome.token) — \(step.roleNote)\n"
            }
        }
        sb += "\nECG-shaped packets seen in \(windowSeconds)s: \(ecgPacketsSeen)\n"
        if !steps.isEmpty, !steps.contains(where: \.requestsRealtimeData) {
            sb += "Zero is the EXPECTED result here: nothing in this run asked the strap for realtime ECG data.\n"
        }
        // The ELECTRODE CIRCUIT is the one confound this probe cannot see and the runner can. An MG's ECG
        // needs a closed loop: the wrist electrode plus the two clasp indents held with the OPPOSITE hand.
        // Nothing on the wire reports lead state, so a run where the clasp was never touched is
        // indistinguishable here from a run the firmware ignored — and #891 asks other MG owners to run
        // this, who have no reason to know that. Reported as a QUESTION about the run, never as a finding:
        // it does not claim the leads were open, only that this report cannot rule it out.
        if ecgPacketsSeen == 0, steps.contains(where: \.requestsRealtimeData) {
            sb += "Were the leads closed? An MG measures across the wrist electrode AND the two indents on "
                + "the clasp, held with the fingers of your OTHER hand for the whole window. Lead state is "
                + "not on the wire, so this report cannot tell an open circuit from a strap that ignored "
                + "the command — if the clasp was not held, re-run holding it before reading anything into "
                + "the zero.\n"
        }
        if candidateFrames.isEmpty {
            sb += "Revision-17 packets decoded: none — no frame arrived as type 43 revision 17.\n"
        } else {
            sb += "Revision-17 packets decoded (type 43, revision 17, both CRCs checked):\n"
            for line in candidateFrames { sb += "  \(line)\n" }
        }
        let replies = steps.compactMap { step in step.replyHex.map { "  \(step.label): \($0)" } }
        if !replies.isEmpty {
            sb += "\nRaw replies:\n"
            sb += replies.joined(separator: "\n") + "\n"
        }
        sb += "\nThis is unvalidated instrumentation, not a medical measurement or a diagnosis.\n"
        return sb
    }
}
