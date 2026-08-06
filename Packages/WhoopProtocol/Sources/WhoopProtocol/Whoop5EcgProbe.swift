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
        /// The ARGUMENT byte this command was sent with, when it is known.
        ///
        /// `label` carries only the opcode, because it is also the key the inbound handler matches a
        /// COMMAND_RESPONSE against and the reply echoes no argument — so the argument cannot live in
        /// the label without breaking that match. It is recorded separately instead, because two runs
        /// of the same opcode can differ only in this byte: `mainControlECGDataGeneration` takes
        /// `stop`/`start`/`restart` (0/1/2), so a start run and a restart run render identically
        /// without it and a future reader of a copied report cannot tell which one produced the
        /// verdict.
        ///
        /// Reported as the RAW NUMBER, never a token name, for the same reason the classifier byte is:
        /// the number is lossless and cannot drift from the bytes actually put on the wire.
        ///
        /// `nil` is "not known", which is the honest value for an UNSOLICITED reply — nothing here
        /// sent it. It is display-only and feeds no verdict, so unlike `requestsRealtimeData` a
        /// default is safe: an omission loses an annotation, never changes a claim.
        public let sentArgument: UInt8?
        /// The reply frame as hex, when one arrived.
        public let replyHex: String?

        public init(label: String,
                    outcome: CommandOutcome,
                    requestsRealtimeData: Bool,
                    sentArgument: UInt8? = nil,
                    replyHex: String? = nil) {
            self.label = label
            self.outcome = outcome
            self.requestsRealtimeData = requestsRealtimeData
            self.sentArgument = sentArgument
            self.replyHex = replyHex
        }

        /// How the report annotates the step, so a reader can see WHY the verdict is what it is.
        public var roleNote: String {
            requestsRealtimeData ? "asks for realtime ECG data"
                                 : "cannot produce ECG data (configuration or OFF)"
        }

        /// The `label`, plus the argument when it is known — what every report line leads with.
        public var labelWithArgument: String {
            guard let sentArgument else { return label }
            return "\(label) arg=\(sentArgument)"
        }
    }

    // MARK: - Unclassified-frame census

    /// A bounded census of EVERY unclassified 5/MG frame seen while a probe run is armed — the ones the
    /// structural triage rejected as well as the ones it accepted.
    ///
    /// ## Why the rejects are the point
    ///
    /// The packet TYPE byte the Labrador records arrive under is NOT attested (see `Whoop5Ecg`'s file
    /// header), so the probe hunts for it with a shape heuristic. Logging only the heuristic's HITS makes
    /// that hunt unfalsifiable: when the heuristic is wrong, the frame it was wrong about is discarded,
    /// the report truthfully says "no frame passed the structural triage", and the bytes that would have
    /// shown the mistake are gone. That is exactly what a hardcoded 2-bytes-per-sample length agreement
    /// did to every 3-byte frame before `Whoop5Ecg.filteredWidthCandidates` widened it — and the next
    /// wrong assumption will be invisible the same way unless the raw census exists beside the verdict.
    ///
    /// So this records the type byte, the frame and payload lengths, `numberOfECGSamples` when the header
    /// parses, which sample widths the length agreed with, and the frame's opening bytes as hex. It makes
    /// no claim about any of them: it is a census, and every line in it is a frame the probe could not
    /// classify.
    ///
    /// ## Bounds
    ///
    /// A 5/MG link carries ordinary live traffic at ~1 Hz, and a report is a copyable string, so the
    /// census is capped in both directions: at most `maxSamplesPerType` (3) recorded frames per distinct
    /// type byte, and at most `maxTypes` (16) distinct type bytes. Everything past a cap is COUNTED, never
    /// silently dropped — `count` per type keeps rising after its samples are full, and frames whose type
    /// byte arrives after the 16th distinct one land in `framesBeyondTypeCap`. Worst case is 48 recorded
    /// frames × 64 hex-rendered bytes, which is bounded regardless of what the strap does.
    public struct FrameCensus: Equatable, Sendable {

        /// Recorded frames per distinct type byte. Small on purpose: three examples of a type byte answer
        /// "what does this look like", and the running count answers "how often".
        public static let maxSamplesPerType = 3
        /// Distinct type bytes tracked. A type byte is one octet, so 256 buckets are possible in theory;
        /// 16 is well past what a live link actually shows and keeps the report readable.
        public static let maxTypes = 16
        /// Leading bytes of each recorded frame rendered as hex. Enough to carry the whole envelope plus
        /// the 17-byte status header and the first samples.
        public static let headBytes = 64

        /// One recorded frame. Nothing here is interpreted — these are measurements of the buffer.
        public struct Sample: Equatable, Sendable {
            public let frameLength: Int
            /// Length of the inner record's payload, or nil when the frame did not yield one (it failed a
            /// CRC or was too short for the envelope).
            public let payloadLength: Int?
            /// `numberOfECGSamples` as the status header would read it, or nil when the payload is too
            /// short to hold a header. Reading it does NOT claim this frame is an ECG record.
            public let numberOfECGSamples: Int?
            /// The bytes-per-sample widths the payload's length agreed with, per
            /// `Whoop5Ecg.filteredBytesPerSampleCandidates`. Empty means the triage rejected the frame,
            /// which is the case this census exists to preserve.
            public let widths: [Int]
            /// The frame's first `headBytes` bytes, lowercase hex.
            public let headHex: String

            public init(frameLength: Int, payloadLength: Int?, numberOfECGSamples: Int?,
                        widths: [Int], headHex: String) {
                self.frameLength = frameLength
                self.payloadLength = payloadLength
                self.numberOfECGSamples = numberOfECGSamples
                self.widths = widths
                self.headHex = headHex
            }

            public var line: String {
                let payload = payloadLength.map(String.init) ?? "?"
                let samples = numberOfECGSamples.map(String.init) ?? "?"
                let widthText = widths.isEmpty ? "none" : widths.map(String.init).joined(separator: ",")
                return "len=\(frameLength) payload=\(payload) samples=\(samples) widths=\(widthText) head=\(headHex)"
            }
        }

        /// Everything seen under one type byte.
        public struct Bucket: Equatable, Sendable {
            public let typeByte: UInt8
            /// Every frame seen with this type byte, including the ones past the per-type sample cap.
            public var count: Int
            public var samples: [Sample]

            public init(typeByte: UInt8, count: Int, samples: [Sample]) {
                self.typeByte = typeByte
                self.count = count
                self.samples = samples
            }
        }

        /// Buckets in FIRST-SEEN order, which is the order the report prints them in. Insertion order is
        /// kept rather than sorted by count so the census reads as a timeline of what the link did.
        public private(set) var buckets: [Bucket] = []
        /// Every frame offered to the census, including those past a cap.
        public private(set) var framesSeen = 0
        /// Frames dropped because their type byte was the 17th distinct one. Counted, not hidden.
        public private(set) var framesBeyondTypeCap = 0

        public init() {}

        /// Fold one frame into the census.
        ///
        /// The caller CRC-gates the frame first (the BLE safety contract's inbound rule); this reads the
        /// type byte directly and gets the payload through `Whoop5Ecg.innerPayload`, which re-checks both
        /// CRCs itself, so a frame that somehow arrives unverified yields `payloadLength == nil` rather
        /// than a decoded field. Frames with no type byte at all (fewer than 9 bytes — shorter than the
        /// puffin envelope's minimum) are not records and are ignored.
        public mutating func record(frame: [UInt8],
                                    payloadStart: Int = Whoop5Ecg.puffinPayloadStart,
                                    maxPadding: Int = Whoop5Ecg.defaultMaxPadding) {
            guard frame.count > 8 else { return }
            framesSeen += 1
            let typeByte = frame[8]
            guard let index = buckets.firstIndex(where: { $0.typeByte == typeByte }) else {
                guard buckets.count < FrameCensus.maxTypes else {
                    framesBeyondTypeCap += 1
                    return
                }
                buckets.append(Bucket(typeByte: typeByte,
                                      count: 1,
                                      samples: [FrameCensus.sample(frame: frame,
                                                                   payloadStart: payloadStart,
                                                                   maxPadding: maxPadding)]))
                return
            }
            buckets[index].count += 1
            guard buckets[index].samples.count < FrameCensus.maxSamplesPerType else { return }
            buckets[index].samples.append(FrameCensus.sample(frame: frame,
                                                            payloadStart: payloadStart,
                                                            maxPadding: maxPadding))
        }

        /// Measure one frame. Public so a test can build a `Sample` without a census.
        public static func sample(frame: [UInt8],
                                  payloadStart: Int = Whoop5Ecg.puffinPayloadStart,
                                  maxPadding: Int = Whoop5Ecg.defaultMaxPadding) -> Sample {
            let payload = Whoop5Ecg.innerPayload(frame, payloadStart: payloadStart)
            let widths = payload.map {
                Whoop5Ecg.filteredBytesPerSampleCandidates($0, maxPadding: maxPadding)
            } ?? []
            let samples = payload.flatMap { EcgStatusHeader(payload: $0) }
                .map { Int($0.numberOfECGSamples) }
            let head = frame.prefix(headBytes).map { String(format: "%02x", $0) }.joined()
            return Sample(frameLength: frame.count,
                          payloadLength: payload?.count,
                          numberOfECGSamples: samples,
                          widths: widths,
                          headHex: head)
        }

        public var isEmpty: Bool { framesSeen == 0 }

        /// The census as report lines, already indented for `report`.
        public var lines: [String] {
            var out: [String] = []
            for bucket in buckets {
                out.append(String(format: "  type=0x%02x  frames=%d", Int(bucket.typeByte), bucket.count))
                for sample in bucket.samples { out.append("    \(sample.line)") }
                if bucket.count > bucket.samples.count {
                    out.append("    (+\(bucket.count - bucket.samples.count) more of this type, not recorded)")
                }
            }
            if framesBeyondTypeCap > 0 {
                out.append("  (\(framesBeyondTypeCap) frame(s) of further type bytes past the "
                    + "\(FrameCensus.maxTypes)-type cap, counted only)")
            }
            return out
        }
    }

    /// The gate verdict, kept separate from the report text so it is assertable in a test.
    public enum Verdict: Equatable, Sendable {
        /// Frames that PASS THE STRUCTURAL TRIAGE arrived. Not proof: the triage is a heuristic over
        /// four booleans, three enum ranges and a length agreement (see
        /// `Whoop5Ecg.plausibleFilteredPayload`), run against ordinary live 5/MG traffic, so an
        /// unrelated packet can match. The verdict says "candidate", and confirming it needs the raw
        /// bytes in the log — never this count alone.
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
                return "\(packets) frame(s) matched the ECG structural triage. That is a CANDIDATE, not proof: "
                    + "the triage is a shape heuristic and unrelated traffic can match it. Confirm against the "
                    + "raw bytes below before concluding anything about whether the feature is blocked."
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
            let dataFailures = failures.filter(\.requestsRealtimeData).map(\.labelWithArgument)
            if !dataFailures.isEmpty { return .dataRequestRefused(commands: dataFailures) }
            return .commandRefused(commands: failures.map(\.labelWithArgument))
        }
        let unsupported = steps.filter { $0.outcome == .unsupported }.map(\.labelWithArgument)
        if !unsupported.isEmpty { return .opcodeUnsupported(commands: unsupported) }
        if ecgPacketsSeen > 0 { return .ecgCandidatesArrived(packets: ecgPacketsSeen) }
        guard !steps.isEmpty else { return .noReplies }
        if steps.allSatisfy({ $0.outcome == .noReply }) { return .noReplies }
        // Past this point the verdict INTERPRETS SILENCE, which only carries information about the ECG
        // data path when the run asked that path for something and the strap said yes.
        let requests = steps.filter(\.requestsRealtimeData)
        guard !requests.isEmpty else { return .noDataRequested(commands: steps.map(\.labelWithArgument)) }
        guard requests.contains(where: { $0.outcome == .success }) else {
            return .dataRequestNotAccepted(commands: requests.map(\.labelWithArgument))
        }
        if steps.allSatisfy({ $0.outcome == .success }) {
            return .acceptedButSilent(windowSeconds: windowSeconds)
        }
        return .inconclusive
    }

    /// The full report: verdict, per-command outcomes, the ECG-packet tally, and the raw replies.
    ///
    /// `candidateFrames` are the type/length lines for frames that passed the structural triage in
    /// `Whoop5Ecg.plausibleFilteredPayload` — the empirical answer to "which packet type do these arrive
    /// under", which no table in this repo yet holds.
    ///
    /// `census` is the same question asked WITHOUT the heuristic: every unclassified frame the run saw,
    /// bucketed by type byte, hits and misses alike. It defaults to empty so a caller that has none still
    /// renders, but a live run always passes one — see `FrameCensus` for why the misses matter more than
    /// the hits.
    public static func report(steps: [Step],
                              ecgPacketsSeen: Int,
                              candidateFrames: [String],
                              windowSeconds: Int,
                              census: FrameCensus = FrameCensus()) -> String {
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
                sb += "  \(step.labelWithArgument): \(step.outcome.token) — \(step.roleNote)\n"
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
            sb += "Candidate packet types: none — no frame passed the structural triage.\n"
        } else {
            sb += "Candidate packet types (structural triage only, NOT a confirmed mapping):\n"
            for line in candidateFrames { sb += "  \(line)\n" }
        }
        // The census goes IMMEDIATELY under the triage result, because it is the check on it: "no frame
        // passed the structural triage" is only informative next to what the frames actually were.
        if census.isEmpty {
            sb += "Unclassified-frame census: no unclassified frame arrived at all — the triage had "
                + "nothing to reject.\n"
        } else {
            sb += "Unclassified-frame census — EVERY frame this run could not classify, triage hits and "
                + "misses alike, bucketed by the inner record's type byte. The ECG type byte is not "
                + "attested, so this, not the triage, is the record of what arrived. widths= are the "
                + "bytes-per-sample the payload length agreed with; none = the triage rejected it. "
                + "Recorded: \(census.framesSeen) frame(s), first \(FrameCensus.maxSamplesPerType) per "
                + "type byte, first \(FrameCensus.maxTypes) type bytes, first \(FrameCensus.headBytes) "
                + "bytes each:\n"
            for line in census.lines { sb += "\(line)\n" }
        }
        let replies = steps.compactMap { step in step.replyHex.map { "  \(step.labelWithArgument): \($0)" } }
        if !replies.isEmpty {
            sb += "\nRaw replies:\n"
            sb += replies.joined(separator: "\n") + "\n"
        }
        sb += "\nThis is unvalidated instrumentation, not a medical measurement or a diagnosis.\n"
        return sb
    }
}
