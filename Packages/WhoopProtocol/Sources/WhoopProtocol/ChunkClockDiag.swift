import Foundation

/// #1008 diagnostic: the per-CHUNK view of the historical clock basis and how densely each decoded
/// chunk packs its R-R intervals onto wall seconds.
///
/// Why per-chunk and not per-session. The session summary already logs the ONE `(device, wall)`
/// correlation captured on the first chunk (`sessionClockDevice`/`sessionClockWall`, #67). That is
/// enough to say whether the stale-RTC correction could engage at all, but it cannot answer the two
/// questions #1008 actually turns on:
///
///  1. **Does the offset move within a single offload?** A strap RTC that drifts (measured at ~8 s/hour
///     on a 4.0) has a different `wall - device` offset at the start and the end of a long session.
///     One number per session hides the trajectory; one per chunk shows it.
///  2. **Is the R-R overcount duplication, or packing?** `extractHistoricalStreams` stamps EVERY R-R
///     interval inside one type-47 record with that record's single `unix` second, so a record carrying
///     8 intervals emits 8 rows on one timestamp (`ord` 0...7). That inflates beats-per-second without
///     any record being delivered twice. `pack` (intervals per STAMPED second) separates the two: packing
///     shows `pack` well above 1 while `dens` (intervals per SPAN second) stays near the true heart rate;
///     genuine duplication moves both together.
///
/// Log-only and allocation-light — it walks the chunk's timestamps once. Nothing here feeds a stored
/// value or a gate. Twin of the Kotlin `ChunkClockDiag`.
public enum ChunkClockDiag {

    /// Build the per-chunk line, or `nil` when the chunk decoded no R-R at all (a motion/temp-only or
    /// console-only chunk has no clock story to tell and would only add noise to a strap log).
    ///
    /// - Parameters:
    ///   - chunk: 1-based index of this chunk within the session.
    ///   - deviceClockRef: the strap-side half of the session correlation, as passed to the decoder.
    ///   - wallClockRef: the phone-side half of the same correlation.
    ///   - rrTimestamps: the resolved wall seconds of every R-R interval this chunk decoded, in
    ///     emission order. Duplicates are meaningful (they ARE the packing) and must not be pre-uniqued.
    public static func line(chunk: Int,
                            deviceClockRef: Int,
                            wallClockRef: Int,
                            rrTimestamps: [Int]) -> String? {
        guard !rrTimestamps.isEmpty else { return nil }

        let offset = wallClockRef - deviceClockRef
        // Mirrors the FIRST gate inside `extractHistoricalStreams`: below the threshold the offset is
        // DISCARDED and each record keeps its own raw unix second, so a small drift (tens of seconds) never
        // reaches the stored timestamps — the drift is baked into the strap's own stamps instead, which is
        // a different problem with a different fix.
        //
        // Named for the GATE, not the outcome, and deliberately so: an open gate does NOT prove the
        // correction was applied. Past it, the #471 overshoot guard re-checks EVERY record and keeps the
        // raw ts whenever the corrected value would post-date wall time — which is exactly the field case
        // that motivated it (a drained strap whose RTC reset to ~epoch has an offset of decades, so every
        // record overshoots and none are corrected). That decision is per-record and depends on each raw
        // stamp, so no single per-chunk flag can state it; reporting the gate is the honest half.
        let staleGateOpen = abs(offset) > histStaleClockThresholdSec

        var perSecond: [Int: Int] = [:]
        var oldest = rrTimestamps[0], newest = rrTimestamps[0]
        for ts in rrTimestamps {
            perSecond[ts, default: 0] += 1
            if ts < oldest { oldest = ts }
            if ts > newest { newest = ts }
        }
        let stampedSeconds = perSecond.count
        let maxPerSecond = perSecond.values.max() ?? 0
        let spanSeconds = newest - oldest + 1          // inclusive; a single-second chunk spans 1

        return "Backfill: hist clock chunk=\(chunk) offset=\(signed(offset))s staleGate=\(staleGateOpen ? "open" : "closed")"
            + " rr=\(rrTimestamps.count) secs=\(stampedSeconds)"
            + " pack=\(fixed2(rrTimestamps.count, stampedSeconds)) max=\(maxPerSecond)"
            + " span=\(spanSeconds)s dens=\(fixed2(rrTimestamps.count, spanSeconds))"
    }

    /// Always-signed so a drift trajectory reads at a glance across chunks (`+15s` → `+48s` → `+200s`).
    static func signed(_ v: Int) -> String { v >= 0 ? "+\(v)" : "\(v)" }

    /// `numerator/denominator` to 2dp, by INTEGER half-up rounding — deliberately NOT `String(format:)`.
    ///
    /// Two traps this sidesteps, both of which would silently desync the Swift and Kotlin logs that the
    /// tests assert are byte-identical:
    ///  - **Rounding mode.** C/Swift `printf("%.2f")` rounds half-to-EVEN; Java's `String.format` rounds
    ///    half-UP. They disagree on any exact tie, and ties are ordinary here — `pack` of 9/8 renders
    ///    `1.12` on Swift and `1.13` on Kotlin.
    ///  - **Locale.** A comma decimal separator on a German/French device would break a log parser.
    ///
    /// Integer math has neither problem: `+denominator` before the divide is the half-up bias, and the
    /// operands are small (interval counts), nowhere near overflow.
    static func fixed2(_ numerator: Int, _ denominator: Int) -> String {
        guard denominator > 0 else { return "0.00" }
        let hundredths = (numerator * 200 + denominator) / (denominator * 2)
        let frac = hundredths % 100
        return "\(hundredths / 100)." + (frac < 10 ? "0\(frac)" : "\(frac)")
    }
}
