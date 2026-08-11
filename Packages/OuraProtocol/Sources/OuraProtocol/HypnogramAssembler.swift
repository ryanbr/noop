import Foundation

// HypnogramAssembler: reconstruct the TIME AXIS of the ring's sleep-phase hypnogram.
//
// THE PROBLEM (observed on-device 2026-07-12, Gen3): the ring's SleepNet finalizes a night's staging
// AFTER wake and writes the whole hypnogram to its event log in ONE BURST — e.g. 23 records x 52 codes,
// all sharing essentially the same envelope ring-time (~09:30, the WRITE moment). The envelope
// timestamp therefore marks WHEN THE ANALYSIS WAS SAVED, not when the sleep happened; anchoring each
// record at its envelope collapses an entire night onto a few seconds.
//
// THE RECONSTRUCTION: the burst's codes are one contiguous sequence at 30 s/code, ENDING at the burst's
// envelope time. Laying N codes backward from the anchored burst end recovers the real window. The
// 30 s epoch is triple-confirmed: open_oura's sleepnet.md ("DEEP/LIGHT/REM/WAKE classification at
// 30-second intervals"), the observed window math (1,196 codes over a ~23:35-09:00 night), and the
// 0x49 summary's 600-minute window over those same 1,196 codes (~30.1 s/code).
//
// Platform-pure, value types + one small accumulator class; no CoreBluetooth, no clock (the caller
// resolves the anchored end time). Builds and tests on Linux.

/// One completed burst of consecutive sleep-phase records (usually a whole night's hypnogram).
public struct OuraHypnogramBurst: Equatable, Sendable {
    /// The records in arrival (= log) order, each with its envelope ring-time and decoded codes.
    public let records: [OuraHypnogramRecord]

    public init(records: [OuraHypnogramRecord]) {
        self.records = records
    }

    /// Total 2-bit codes across the burst.
    public var totalCodes: Int { records.reduce(0) { $0 + $1.phases.count } }

    /// The burst's LAST envelope ring-time — the write/finalization moment the reconstruction anchors
    /// its END to, and the resume-cursor note for the whole burst.
    public var lastRingTimestamp: UInt32 { records.last?.ringTimestamp ?? 0 }

    /// True when any record's envelope ring-time is LOWER than its predecessor's within this burst —
    /// the one signal that the arrival order (which the layout trusts as the sequence ground truth)
    /// might not be chronological. Surfaced so the caller can LOG it rather than fail silently;
    /// re-sorting is deliberately not done (envelope ring-times of a burst are near-identical write
    /// moments, so a sort on them could scramble the true code sequence).
    public var hasNonMonotonicRingTimes: Bool {
        zip(records, records.dropFirst()).contains { $1.ringTimestamp < $0.ringTimestamp }
    }

    /// Lay the burst's codes out backward from `endUnixSeconds` at `secondsPerCode`. Code j of N gets
    /// `ts = end - (N - j) * secondsPerCode` — i.e. each ts marks the START of that code's interval and
    /// the final code's interval ends exactly at the burst end. Order: records in arrival order, codes
    /// by their in-record index (the sequence is the ground truth; the spacing is the documented 30 s
    /// SleepNet epoch). Arrival order is deliberately NOT re-sorted by envelope ring-time: the envelopes
    /// mark the near-identical WRITE moments of a finalization burst, so they are useless as a sort key
    /// (an unstable sort on near-equal keys could scramble the true sequence) — see
    /// `hasNonMonotonicRingTimes` for the surfaced escape hatch.
    /// When `sleepStartUnixSeconds` is given (the ring's 0x49 window ONSET), codes that fall BEFORE it are
    /// dropped — clipping the SleepNet burst's pre-window epochs to the ring's own sleep window, symmetric
    /// with anchoring the end to the 0x49 sleep-end. A clamp that would drop EVERY code is IGNORED (the
    /// full unclamped lay is returned) so a mis-paired window can never empty the night. `nil` = no clip.
    public func codesWithTimes(endUnixSeconds: Int, sleepStartUnixSeconds: Int? = nil, secondsPerCode: Int = 30)
        -> [(phase: OuraSleepPhase, ts: Int)] {
        let n = totalCodes
        var out: [(phase: OuraSleepPhase, ts: Int)] = []
        out.reserveCapacity(n)
        var j = 0
        for record in records {
            for phase in record.phases {
                out.append((phase, endUnixSeconds - (n - j) * secondsPerCode))
                j += 1
            }
        }
        // #1246: drop UNWRITTEN epochs (whole-record `0xFF` erased pages) from the reconstructed hypnogram
        // — they are a GAP, not `awake`. Done AFTER the lay so `n`/`j` (and thus every WRITTEN code's ts)
        // are computed over the full sequence: an unwritten run anywhere — head, middle, or tail — leaves
        // the real codes around it correctly timed. An all-unwritten burst yields [] (an honest no-stage
        // night), which the caller drops rather than persisting a blank session.
        let written = out.filter { !$0.phase.unwritten }
        guard let start = sleepStartUnixSeconds else { return written }
        let clipped = written.filter { $0.ts >= start }
        return clipped.isEmpty ? written : clipped
    }
}

/// One sleep-phase record as fed to the assembler: its envelope ring-time + decoded codes in order.
public struct OuraHypnogramRecord: Equatable, Sendable {
    public let ringTimestamp: UInt32
    public let phases: [OuraSleepPhase]
    public init(ringTimestamp: UInt32, phases: [OuraSleepPhase]) {
        self.ringTimestamp = ringTimestamp
        self.phases = phases
    }
}

/// Accumulate consecutive sleep-phase records into bursts. Records whose envelope ring-times sit
/// within `burstGapTicks` of the previous record belong to the same burst (a finalization write-out);
/// a larger gap (a different night / a separate analysis pass) closes the burst and starts a new one.
public final class OuraHypnogramAssembler {
    /// Max envelope ring-time gap (ticks, 100 ms each) between records of ONE burst. Observed bursts
    /// share rts within a few seconds; 600 ticks = 60 s is generous while still splitting nights
    /// (separate finalizations are hours apart).
    public let burstGapTicks: UInt32
    private var current: [OuraHypnogramRecord] = []

    public init(burstGapTicks: UInt32 = 600) {
        self.burstGapTicks = burstGapTicks
    }

    /// Feed one record. Returns the PREVIOUS burst when this record's ring-time gap closes it (the fed
    /// record then starts the next burst); nil while the current burst is still growing. Records with
    /// no codes are ignored (nothing to place).
    public func feed(ringTimestamp: UInt32, phases: [OuraSleepPhase]) -> OuraHypnogramBurst? {
        guard !phases.isEmpty else { return nil }
        let record = OuraHypnogramRecord(ringTimestamp: ringTimestamp, phases: phases)
        if let last = current.last {
            let gap = ringTimestamp >= last.ringTimestamp
                ? ringTimestamp - last.ringTimestamp
                : last.ringTimestamp - ringTimestamp
            if gap > burstGapTicks {
                let done = OuraHypnogramBurst(records: current)
                current = [record]
                return done
            }
        }
        current.append(record)
        return nil
    }

    /// Close and return the in-progress burst (call at drain end / teardown), or nil if none.
    public func flush() -> OuraHypnogramBurst? {
        guard !current.isEmpty else { return nil }
        let done = OuraHypnogramBurst(records: current)
        current = []
        return done
    }

    /// Discard any partial state (fresh session).
    public func reset() {
        current = []
    }

    /// Number of records currently accumulating (observability only).
    public var pendingRecordCount: Int { current.count }
}
