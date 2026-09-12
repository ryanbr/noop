import Foundation

// Diagnosis for the frame-integrity gate: what a rejected frame still tells us, how often each reason
// occurred, and how a frame is rendered for a human. All pure and app-free, so the counters and the
// inspector's line are covered by `swift test` rather than only by running the tool.

public extension ParsedFrame {
    /// Whether the decoder got a PACKET TYPE out of this frame — the parseability question, which is
    /// NOT the integrity question `ok` answers.
    ///
    /// The two used to be the same value, so every diagnostic surface that wanted "did this decode?"
    /// read `ok`. Now `ok` means "header checksum, payload CRC32 and structural length all agree", and
    /// reading it as parseability would blank the packet type of exactly the frames a capture exists to
    /// map: a frame with a flipped header byte still decodes its type, its sequence number and its
    /// fields, and losing that in the record is losing the evidence.
    ///
    /// True when the parse produced a real type name rather than the `INVALID/FRAGMENT` placeholder the
    /// parsers return for a byte run below the family minimum or without a start-of-frame byte.
    var isParsable: Bool { typeName != ParsedFrame.unparsableTypeName }

    /// The placeholder type name both parsers use for a byte run they could not read at all.
    static var unparsableTypeName: String { "INVALID/FRAGMENT" }

    /// True for the frame class that passed the gates BEFORE this change: the payload CRC32 verified,
    /// but the envelope did not — a wrong header checksum, a declared length below the family minimum,
    /// a truncated frame or one with trailing bytes.
    ///
    /// It is deliberately read off the parse result and needs no second verification: both values are
    /// already on the frame the consumer was handed.
    var payloadCRCOKButEnvelopeRejected: Bool { !ok && crcOK == true }
}

/// Per-reason rejection counters for one connection, plus the ONE extra named counter the hardware run
/// is read from.
///
/// Why a plain per-reason count is not enough (D3): the abort criterion for the hardware run is a
/// CONJUNCTION — "header checksum or length wrong WHILE the payload CRC32 verifies" — and no single
/// reason bucket can express it. The length bucket in particular also collects the harmless resyncs
/// after a lost notification, which were happening before this change too. So
/// `payloadCRCOKButEnvelopeRejected` is counted separately; it is the class that used to pass, and thus
/// the cleanest regression signal.
///
/// Counted per reason only — NOT additionally per device family. A connection talks to exactly one
/// strap, so a family dimension would be constant.
///
/// A tally asserts only what it observed: an unverifiable payload CRC32 is counted as
/// `payloadCRCUnverifiable`, never folded into `payloadCRCMismatch`. "Could not be checked" is not
/// "was wrong".
public struct FrameRejectTally: Equatable, Sendable {
    /// How often each reason was the FIRST rule a frame failed. `.none` is never counted.
    public private(set) var counts: [FrameRejectReason: Int] = [:]

    /// The named class from D3: envelope rejected while the payload CRC32 verified.
    public private(set) var payloadCRCOKButEnvelopeRejected = 0

    /// The reassembler's monotonic drop count already folded into `.belowMinimumLength`, so repeated
    /// folds of the same counter cannot double-count.
    private var absorbedReassemblerDrops = 0

    public init() {}

    /// Count one parse result. Intact frames are ignored, so this can sit on the frame path unguarded.
    /// Returns the reason recorded, or `.none` when the frame was intact and nothing was counted.
    @discardableResult
    public mutating func note(_ parsed: ParsedFrame) -> FrameRejectReason {
        guard !parsed.ok else { return .none }
        let reason = parsed.rejectReason
        counts[reason, default: 0] += 1
        if parsed.payloadCRCOKButEnvelopeRejected { payloadCRCOKButEnvelopeRejected += 1 }
        return reason
    }

    /// Count one frame from the VERIFIER's result rather than from a parse result.
    ///
    /// The offload path does not parse its frames at the BLE seam — it hands them straight to the
    /// Backfiller — so the parse-result overload above never sees them, and the named counter the
    /// hardware run's abort criterion is read from would stay at zero for exactly the traffic in which
    /// the permanent loss occurs. `FrameCheck` already carries the verdict, the reason and the payload
    /// CRC32 outcome, so this counts what was observed and costs no second parse.
    ///
    /// It asserts no more than the parse-result overload: `payloadCRCOKButEnvelopeRejected` is raised
    /// only when the CRC32 was actually computed and verified, never when it could not be checked.
    @discardableResult
    public mutating func note(_ check: FrameCheck) -> FrameRejectReason {
        guard !check.ok else { return .none }
        counts[check.reason, default: 0] += 1
        if check.crc32OK == true { payloadCRCOKButEnvelopeRejected += 1 }
        return check.reason
    }

    /// Fold a reassembler's `belowMinimumLengthDrops` into the `.belowMinimumLength` bucket.
    ///
    /// A byte run the reassembler drops never reaches a parser — and never reaches the evidence-
    /// preserving reader either — so without this it would vanish with no trace at all. The argument is
    /// the reassembler's MONOTONIC total; only the growth since the last fold is added, so calling this
    /// once per notification is correct and idempotent.
    public mutating func absorbReassemblerDrops(_ monotonicTotal: Int) {
        guard monotonicTotal > absorbedReassemblerDrops else { return }
        counts[.belowMinimumLength, default: 0] += monotonicTotal - absorbedReassemblerDrops
        absorbedReassemblerDrops = monotonicTotal
    }

    /// How often `reason` was recorded.
    public func count(_ reason: FrameRejectReason) -> Int { counts[reason] ?? 0 }

    /// Every rejection counted, across all reasons.
    public var totalRejected: Int { counts.values.reduce(0, +) }

    /// One line naming every reason that actually occurred, in a stable order, or nil when nothing was
    /// rejected — a per-connection readout, so its caller gates it behind the Test Centre domain.
    /// Silence when there is nothing to report; no "0 rejections" line to read past.
    public func summaryLine() -> String? {
        guard totalRejected > 0 else { return nil }
        let parts = FrameRejectReason.allCases
            .filter { $0 != .none && count($0) > 0 }
            .map { "\($0.rawValue)=\(count($0))" }
        return "frameReject total=\(totalRejected) " + parts.joined(separator: " ")
            + " payloadCRCOKButEnvelopeRejected=\(payloadCRCOKButEnvelopeRejected)"
    }
}

/// The inspector's one-line rendering of a parsed frame.
///
/// It lives in the library rather than in the command-line tool so a test can pin it: the tool is an
/// executable target with no test target of its own, and the property that matters — a REJECTED frame
/// still shows its packet type, and shows why it was rejected — is exactly the kind that goes quiet
/// unnoticed.
///
/// `index` and `family` are provenance the caller holds; everything else comes off the parse result.
public func frameInspectionLine(index: Int, family: DeviceFamily, parsed: ParsedFrame) -> String {
    let crc = parsed.crcOK.map { $0 ? "ok" : "BAD" } ?? "—"
    var line = "[\(index)] \(family.rawValue) ok=\(parsed.ok) type=\(parsed.typeName)"
    line += " seq=\(parsed.seq.map(String.init) ?? "—") crc=\(crc)"
    // Only on a rejection, and only the reason the verifier actually reported: an intact frame carries
    // no reason, and printing `reason=none` on every line would train the eye to skip the field.
    if !parsed.ok { line += " reason=\(parsed.rejectReason.rawValue)" }
    return line
}
