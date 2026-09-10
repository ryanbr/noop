import Foundation

// RecoveryScorer+Trace.swift - the Charge TERM-BREAKDOWN diagnostic (Recovery test mode).
//
// Recomputes the four-plus-one weighted Charge terms from the SAME inputs RecoveryScorer.recovery
// reads, then reuses recovery(...) verbatim for the final score so the trace can never disagree with
// the number the dashboard shows. Pure and side-effect-free: no clock, no I/O, so a fixture night
// pins the exact lines. The Recovery test mode gates this behind TestCentre.active(.recovery) at the
// call site (IntelligenceEngine recomputeRecovery); when the mode is off it is never called, so there
// is zero cost. No em-dashes. Counts, z-scores and weights only, no PII.

extension RecoveryScorer {

    /// The trace's two-decimal rounding contract, shared by both platforms: round `x * 100` to the
    /// nearest integer with half-ties AWAY FROM ZERO, divide by 100, and keep the IEEE sign bit — so a
    /// driver term that rounds to zero from below still renders `-0.0`, as it does on Android (#1437).
    ///
    /// The rounding stays in the DOUBLE domain on purpose. Kotlin's `Math.round` returns a `Long`, which
    /// saturates at 2^63-1, so `1e20` came back as `9.223372036854776e16` there while this side kept
    /// `1e20` (#47). Nothing here is clamped: any finite input round-trips, and a non-finite one (or a
    /// finite one whose `x * 100` overflows) passes through as the matching infinity or NaN. The Kotlin
    /// twin is `RecoveryScorerTrace.r2`.
    static func traceRound2(_ x: Double) -> Double {
        (x * 100.0).rounded(.toNearestOrAwayFromZero) / 100.0
    }

    /// Side-effect-free diagnostic twin of `recovery(...)`: returns the SAME score recovery(...) would,
    /// plus the per-term Charge breakdown trace. The four inputs (hrv / rhr / resp / sleepPerf) plus the
    /// skin-temp deviation each get a baseline line (mean / spread / nValid / status), a term line
    /// (z * weight), the renormalization (total weight, composite z), and the final logistic score + band.
    /// Crucially the trace names WHICH TERM WAS NIL and forced the renorm (or the nil score), so a
    /// "Charge looks wrong" report shows exactly which driver moved or was missing.
    ///
    /// Every number is computed with the EXACT same expressions as `recovery(...)` (the same zScore call,
    /// the same skin-temp penalty, the same weights), and the returned score IS `recovery(...)` verbatim,
    /// so the trace and the headline can never diverge. The Kotlin twin is
    /// RecoveryScorerTrace.recoveryTrace.
    ///
    /// - Parameters mirror `recovery(...)` exactly, taking BaselineState so the trace can read each
    ///   driver's nValid / status; the `usable` cold-start gate is enforced through `recovery(...)`.
    public static func recoveryTrace(hrv: Double,
                                     rhr: Double,
                                     resp: Double?,
                                     hrvBaseline: BaselineState,
                                     rhrBaseline: BaselineState?,
                                     respBaseline: BaselineState?,
                                     sleepPerf: Double?,
                                     skinTempDev: Double? = nil)
        -> (score: Double?, trace: [String]) {

        // Trace numbers use nearest rounding with half-ties away from zero on both platforms.
        func r2(_ x: Double) -> Double { traceRound2(x) }

        var lines: [String] = []
        var nilTerms: [String] = []

        // #1988: the trace reads this baseline DIRECTLY for its own `charge baseline rhr` line, its
        // rhrZ and the saturation guard, not only through recovery(). recovery() now drops an
        // unusable one, so without the same gate here the trace would list an rhr term the score
        // did not use, which is precisely the divergence the line below promises cannot happen.
        let rhrB = rhrBaseline.flatMap { $0.usable ? $0 : nil }

        // The score the dashboard reads, verbatim, so the trace cannot diverge from it.
        let score = recovery(hrv: hrv, rhr: rhr, resp: resp,
                             hrvBaseline: hrvBaseline, rhrBaseline: rhrB,
                             respBaseline: respBaseline, sleepPerf: sleepPerf,
                             skinTempDev: skinTempDev)

        // Cold-start gate: HRV baseline not usable -> recovery() returns nil before any term is built.
        // Report the gate so a nil Charge is explainable, then stop (no terms were scored).
        guard hrvBaseline.usable else {
            lines.append("charge nilScore reason=hrvBaselineNotUsable "
                + "hrvStatus=\(hrvBaseline.status.rawValue) hrvNValid=\(hrvBaseline.nValid) "
                + "(need nValid>=\(Baselines.minNightsSeed))")
            return (score, lines)
        }

        // Per-driver baseline state lines (mean / spread / nValid / status). The skin-temp term carries no
        // baseline arg here (skinTempDev is already a deviation), so it has no baseline line.
        lines.append("charge baseline hrv mean=\(r2(hrvBaseline.baseline)) spread=\(r2(hrvBaseline.spread)) "
            + "nValid=\(hrvBaseline.nValid) status=\(hrvBaseline.status.rawValue)")
        if let b = rhrB {
            lines.append("charge baseline rhr mean=\(r2(b.baseline)) spread=\(r2(b.spread)) "
                + "nValid=\(b.nValid) status=\(b.status.rawValue)")
        }
        if let b = respBaseline {
            lines.append("charge baseline resp mean=\(r2(b.baseline)) spread=\(r2(b.spread)) "
                + "nValid=\(b.nValid) status=\(b.status.rawValue)")
        }

        // Per-term z * weight, built with the EXACT expressions recovery(...) uses. Collect the (z, w)
        // pairs in the SAME order recovery(...) appends them so the renormalization below matches.
        var terms: [(name: String, z: Double, w: Double)] = []

        // Resting-HR z, computed up front so the saturation guard can read the HRV<->RHR coupling
        // before the HRV term is built. nil when there is no RHR baseline. Numerically identical to
        // the z recovery() builds for the RHR term (same expression, same inputs).
        let rhrZForGuard: Double? = rhrB.map { zScore($0.baseline, mean: rhr, spread: $0.spread) }

        // HRV term: higher is better. (Always present once usable; the cold-start guard above returned.)
        // This is the RAW z, exactly as recovery() scores it: the parasympathetic-saturation easing is
        // detected and reported below but NOT applied, so the trace's HRV term matches the scored one.
        // L9: every WEIGHT / SCALE / centre constant goes through r2() too (not just the z-scores), so a
        // future non-round weight (e.g. 0.333) renders identically on Swift and Kotlin and the parity
        // fixture cannot silently desync. The values render the same as before today.
        let hrvZRaw = zScore(hrv, mean: hrvBaseline.baseline, spread: hrvBaseline.spread)
        let sat = parasympatheticSaturation(hrvZ: hrvZRaw, rhrZ: rhrZForGuard)
        terms.append(("hrv", hrvZRaw, wHRV))
        lines.append("charge term hrv z=\(r2(hrvZRaw)) w=\(r2(wHRV)) (higher HRV is better)")

        // RHR term: lower is better -> (mu - x) / sigma. (Reuses the z computed for the guard.)
        if let z = rhrZForGuard {
            terms.append(("rhr", z, wRHR))
            lines.append("charge term rhr z=\(r2(z)) w=\(r2(wRHR)) (lower RHR is better)")
        } else {
            nilTerms.append("rhr")
        }

        // Resp term: lower is better, optional (needs BOTH the value and a baseline).
        if let r = resp, let b = respBaseline {
            let z = zScore(b.baseline, mean: r, spread: b.spread)
            terms.append(("resp", z, wResp))
            lines.append("charge term resp z=\(r2(z)) w=\(r2(wResp)) (lower resp is better)")
        } else {
            nilTerms.append("resp")
        }

        // Sleep-performance / Rest-quality term: no baseline needed, centered at sleepPerfCenter.
        if let sp = sleepPerf {
            let z = (sp - sleepPerfCenter) / sleepPerfScale
            terms.append(("sleepPerf", z, wSleep))
            lines.append("charge term sleepPerf z=\(r2(z)) w=\(r2(wSleep)) "
                + "(rest=\(r2(sp)) center=\(r2(sleepPerfCenter)))")
        } else {
            nilTerms.append("sleepPerf")
        }

        // Skin-temp term: SYMMETRIC penalty on |deviation|, added only when supplied.
        if let dev = skinTempDev {
            let z = -abs(dev) / skinTempScaleC
            terms.append(("skinTempDev", z, wSkinTemp))
            lines.append("charge term skinTempDev z=\(r2(z)) w=\(r2(wSkinTemp)) "
                + "(dev=\(r2(dev))C penalty=-|dev|/\(r2(skinTempScaleC)))")
        } else {
            nilTerms.append("skinTempDev")
        }

        // The nil terms that dropped out and forced the weight renormalization (the killer line).
        lines.append("charge nilTerm dropped=[\(nilTerms.joined(separator: ","))] "
            + "(each dropped term renormalizes the remaining weights)")

        // Renormalization: total surviving weight and the weighted composite z, the SAME math
        // recovery(...) runs to produce the logistic input.
        let totalWeight = terms.reduce(0) { $0 + $1.w }
        let compositeZ = totalWeight > 0
            ? terms.reduce(0) { $0 + $1.z * $1.w } / totalWeight
            : 0.0
        lines.append("charge renorm totalWeight=\(r2(totalWeight)) compositeZ=\(r2(compositeZ)) "
            + "(z = sum(z*w)/sum(w))")

        // Final logistic score + band, read from recovery(...) verbatim.
        if let s = score {
            lines.append("charge score=\(r2(s)) band=\(band(s)) "
                + "(logistic k=\(r2(logisticK)) z0=\(r2(logisticZ0)))")
        } else {
            lines.append("charge nilScore reason=noValidTerms (no driver produced a usable term)")
        }

        // ── Parasympathetic-saturation guard: DETECTED, NOT APPLIED ──────────────────────────────
        //
        // Emitted ONLY when the signature fires. The score above is the UNGUARDED number; this line
        // reports the counterfactual the guard WOULD have produced, so real low-HRV + low-RHR nights
        // can be counted and checked against ground truth before the easing is ever allowed to move
        // Charge. See the MARK header in RecoveryScorer.swift for the validation gap and the contested
        // benign-saturation / non-functional-overreaching ambiguity that keep it switched off.
        //
        // wouldRaiseCharge recomputes the composite with the eased HRV z swapped in and runs it through
        // logisticScore(...) -- the SAME curve recovery() uses -- so the delta is exact, not estimated.
        if sat.active, let s = score, totalWeight > 0 {
            let easedZ = terms.reduce(0) { $0 + ($1.name == "hrv" ? sat.easedHrvZ : $1.z) * $1.w } / totalWeight
            let wouldBe = logisticScore(compositeZ: easedZ)
            lines.append("charge saturation active hrvZraw=\(r2(hrvZRaw)) rhrZ=\(r2(rhrZForGuard ?? 0)) "
                + "damp=\(r2(sat.dampFraction)) wouldEaseHrvZTo=\(r2(sat.easedHrvZ)) "
                + "wouldRaiseCharge=\(r2(wouldBe - s)) wouldBand=\(band(wouldBe)) "
                + "(low HRV + low resting HR: candidate parasympathetic saturation. "
                + "Easing DETECTED ONLY, not applied: the score above is unchanged)")
        }

        return (score, lines)
    }
}
