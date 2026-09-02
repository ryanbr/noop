import Foundation

// SleepStager+Trace.swift - the per-candidate-run GATE TRACE formatter (Sleep & Rest test mode).
//
// Pure, side-effect-free string builders. They never touch detection state, so a caller can
// assert the exact line a fixture night produces. Every emitter that USES these is gated by
// TestCentre.active(.sleep) at the detectSleep call site, and the lines exit through the
// redacting sink, so this file holds only formatting. Counts and seconds only, no wall-clock.

extension SleepStager {

    /// Whether a candidate in-bed run survived a gate or was dropped by it.
    public enum GateVerdict: String, Sendable { case kept = "KEPT", dropped = "DROPPED" }

    /// The gate-trace line formatters. Compact, parseable, no em-dashes.
    public enum GateTrace {

        /// Why the HR-only spine did or did not run (#1801). Twin of the Kotlin `hrOnlyGateLine`.
        ///
        /// The funnel line below only exists when the spine is CALLED, so its absence was ambiguous in
        /// exactly the way that made the first field report unreadable: it could mean the gate never
        /// opened, or that the sink was never wired. This says which, on any day with no motion — the
        /// only days where the question arises.
        public static func hrOnlyGateLine(attempted: Bool, reason: String,
                                          gravRows: Int, storedNights: Int) -> String {
            "[sleep] hr-only gate attempted=\(attempted) reason=\(reason) "
                + "grav=\(gravRows) stored=\(storedNights)"
        }

        /// The HR-only spine's own funnel line (#1801). Byte-identical twin of the Kotlin
        /// `SleepStagerTrace.hrOnlyLine`, so an Android and an Apple log of the same night compare
        /// directly — which is the entire reason these formatters are twinned at all.
        ///
        /// The path shipped SILENT on both platforms, and a field log then showed `reason=no-motion`
        /// with no way to tell whether the spine had run and found nothing or never ran. Every number
        /// separates the two failures that actually happen: a band too tight (`sleepRuns` near zero)
        /// from a duration gate eating real runs (`sleepRuns` high, `longestMin` under `minSleepMin`).
        ///
        /// `anchorBpm` and `bandBpm` are printed because they are DERIVED, not configured: the anchor is
        /// a percentile of THIS window, so the same code gives every wearer a different threshold.
        public static func hrOnlyLine(anchorBpm: Double?, bandBpm: Double?,
                                      hrP50: Double?, hrP90: Double?, epochs: Int,
                                      runs: Int, mergedRuns: Int, sleepRuns: Int,
                                      longestSleepMin: Int, staged: Int, kept: Int,
                                      minSleepMin: Int) -> String {
            "[sleep] hr-only spine anchorBpm=\(round1(anchorBpm)) bandBpm=\(round1(bandBpm)) "
                + "hrP50=\(round1(hrP50)) hrP90=\(round1(hrP90)) "
                + "epochs=\(epochs) runs=\(runs) merged=\(mergedRuns) sleepRuns=\(sleepRuns) "
                + "longestMin=\(longestSleepMin) staged=\(staged) kept=\(kept) minSleepMin=\(minSleepMin)"
        }

        /// One decimal, by ARITHMETIC rather than `String(format:)`. Twin of the Kotlin `round1`, and
        /// see its note: `printf` rounds half-to-even on the binary value while Java's `String.format`
        /// rounds HALF_UP on the decimal expansion, so the two disagreed on 64.05. This does the same
        /// IEEE arithmetic on both platforms and cannot.
        ///
        /// NON-NEGATIVE ONLY, same as the Kotlin twin: `-0.5` would print "0.5", because the integer
        /// division truncates toward zero and the sign is then lost to `abs`. Every current caller is a
        /// bpm, which cannot be negative.
        private static func round1(_ v: Double?) -> String {
            guard let v else { return "nil" }
            let tenths = Int((v * 10.0).rounded())
            return "\(tenths / 10).\(abs(tenths % 10))"
        }

        /// One verdict line for a candidate run. `gate` names the constant that decided it
        /// (minSleepMin, maxMainSleepSpanS, offWrist, daytimeGuard, morningStillness, hrConfirm,
        /// sparseBridge, accepted); `detail` carries that gate's numbers. `startTs`/`endTs` give the
        /// span in seconds only (the sink scrubs identifiers; we never print a formatted clock here).
        public static func runLine(index: Int, startTs: Int, endTs: Int,
                                   verdict: GateVerdict, gate: String, detail: String) -> String {
            let spanS = max(0, endTs - startTs)
            return "gate run=\(index) spanS=\(spanS) \(verdict.rawValue) gate=\(gate) \(detail)"
        }

        /// One per-epoch wake<->sleep flip and the threshold it crossed.
        public static func flipLine(epoch: Int, from: String, to: String, threshold: String) -> String {
            "epoch=\(epoch) flip \(from)->\(to) threshold=\(threshold)"
        }
    }

    /// Round to 2 decimal places for the trace detail fields. Local to the trace so the inline
    /// emitters in `detectSleepUncached` can call it unqualified (AnalyticsEngine.round2 is a
    /// separate type's helper). Formatting only, never a scoring path.
    static func round2(_ v: Double) -> Double { (v * 100.0).rounded() / 100.0 }
}
