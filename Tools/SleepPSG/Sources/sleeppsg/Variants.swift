import Foundation

// Variants — the recipe builds this harness compares, each one a single named edit to the shipped config.
//
// The set is not arbitrary. PR #348 changed seven things about `SleepStagerV2` at once, PR #437 reverted all
// seven 48 h later, and PR #987 re-litigated the revert component-by-component and restored exactly one of
// them. That whole argument was settled on one wearer's 36 nights, against the strap's own band state —
// an independent reference, but a proprietary black box, not truth. Each component is reproduced here as
// its own variant so PSG can be asked the same question in the same shape.
//
// Every variant differs from `RecipeConfig.shipped` in the fewest fields that express it. A variant that
// bundled two changes could not be attributed.

struct Variant {
    let name: String
    let note: String
    let config: RecipeConfig
}

enum Variants {

    /// The awake transition row before PR #987, and after it. #987 forbids wake → deep and wake → REM
    /// outright and gives the freed mass to the wake self-loop. It was landed on band-state evidence — band
    /// kappa 0.105 → 0.118, wake sensitivity 16.0 % → 17.6 %, first-REM latency MAE 53.9 → 41.6 min — and
    /// never checked against PSG, which is one of the two questions this harness exists to answer.
    static let awakeRowPre987: [String: Double] = ["deep": 0.01, "rem": 0.02, "light": 0.27, "awake": 0.70]
    static let awakeRowPR987: [String: Double] = ["deep": 0.0, "rem": 0.0, "light": 0.10, "awake": 0.90]

    /// The #987 comparison, whichever side of it this branch is on.
    ///
    /// This matters because the fork and upstream disagree about the incumbent: this repository's `main`
    /// carries #987 already, upstream's does not until the PR merges, and `RecipeConfig.shipped` must track
    /// whatever `SleepStagerV2` says on the branch it is compiled against (that is exactly what
    /// `PortValidation` enforces). Rather than hard-code one direction and be wrong half the time, the
    /// variant reads the shipped awake row and offers the OTHER one. The comparison is the same either way;
    /// only the sign of the delta and the row's name flip.
    static var pr987: Variant {
        let shippedRow = RecipeConfig.shipped.transition["awake"] ?? awakeRowPre987
        let alreadyHas987 = shippedRow == awakeRowPR987
        var c = RecipeConfig.shipped
        c.transition["awake"] = alreadyHas987 ? awakeRowPre987 : awakeRowPR987
        return Variant(
            name: alreadyHas987 ? "#987 REVERTED (pre-#987 row)" : "#987 awake-transition row",
            note: alreadyHas987
                ? "wake→deep/rem restored to 0.01/0.02; self-loop 0.90→0.70"
                : "wake→deep/rem forbidden; wake self-loop 0.70→0.90",
            config: c)
    }

    /// #348 component 1 — base priors. Measured alone on band state: healthy wake fraction 9.43 % → 17.76 %,
    /// i.e. the #437 blow-out reproduced.
    static var p348Priors: Variant {
        var c = RecipeConfig.shipped
        c.priorDeep = log(0.15); c.priorAwake = log(0.34)
        return Variant(name: "#348-A base priors",
                       note: "deep 0.18→0.15, awake 0.10→0.34", config: c)
    }

    /// #348 component 2 — motion gate. A second wake channel: alone, healthy wake 9.43 % → 15.92 %.
    static var p348Motion: Variant {
        var c = RecipeConfig.shipped
        c.jerkFloorMoveMult = 75.0; c.jerkFloorGateMult = 35.0; c.motionGateBoost = 4.0
        return Variant(name: "#348-B motion gate",
                       note: "move 38→75, gate 55→35, boost 2→4", config: c)
    }

    /// #348 component 3 — emission coefficients. Alone: band kappa 0.105 → 0.094, but the closest call of
    /// the six (it cut healthy deep 22.09 % → 15.30 % and latency MAE 53.9 → 32.1 min).
    static var p348Emissions: Variant {
        var c = RecipeConfig.shipped
        c.deepZhv = -0.8; c.deepZhr = 0.5; c.deepZmv = -0.1
        c.remZhv = 0.8; c.remZmv = -0.4; c.remZhr = 0.4
        c.awakeZmv = 1.0; c.awakeZhv = 0.5; c.awakeZhr = 0.6
        return Variant(name: "#348-C emission coefficients",
                       note: "deep/rem/awake log-emission weights", config: c)
    }

    /// #348 component 4 — deep gate. Alone: healthy deep 22.09 % → 25.47 %, worsening an over-call.
    static var p348DeepGate: Variant {
        var c = RecipeConfig.shipped
        c.deepGateThresh = 0.40
        return Variant(name: "#348-D deep gate", note: "deepGateThresh 0.25→0.40", config: c)
    }

    /// #348 component 5 — awake cardiac dead-zone. Alone: band kappa 0.105 → 0.099.
    static var p348Deadzone: Variant {
        var c = RecipeConfig.shipped
        c.awakeDeadzone = 0.30
        return Variant(name: "#348-E awake dead-zone", note: "awakeDeadzone off→0.30", config: c)
    }

    /// #348 component 6 — the other three transition rows. Alone: band kappa 0.105 → 0.101, healthy REM
    /// 29.58 % → 33.11 %.
    static var p348OtherRows: Variant {
        var c = RecipeConfig.shipped
        c.transition["deep"] = ["deep": 0.76, "rem": 0.012, "light": 0.216, "awake": 0.012]
        c.transition["rem"] = ["deep": 0.00333, "rem": 0.92, "light": 0.06667, "awake": 0.01]
        c.transition["light"] = ["deep": 0.08, "rem": 0.08, "light": 0.80, "awake": 0.04]
        return Variant(name: "#348-F deep/rem/light rows",
                       note: "self-loops retuned, off-diagonals renormalised", config: c)
    }

    /// All seven together — the build #437 reverted. Reported so the component rows can be checked for
    /// additivity rather than assumed to be.
    static var p348All: Variant {
        var c = p348Priors.config
        let m = p348Motion.config, e = p348Emissions.config, d = p348Deadzone.config
        c.jerkFloorMoveMult = m.jerkFloorMoveMult; c.jerkFloorGateMult = m.jerkFloorGateMult
        c.motionGateBoost = m.motionGateBoost
        c.deepZhv = e.deepZhv; c.deepZhr = e.deepZhr; c.deepZmv = e.deepZmv
        c.remZhv = e.remZhv; c.remZmv = e.remZmv; c.remZhr = e.remZhr
        c.awakeZmv = e.awakeZmv; c.awakeZhv = e.awakeZhv; c.awakeZhr = e.awakeZhr
        c.deepGateThresh = p348DeepGate.config.deepGateThresh
        c.awakeDeadzone = d.awakeDeadzone
        c.transition = p348OtherRows.config.transition
        // #348's own awake row IS the one #987 later restored — pinned to the literal rather than to
        // `pr987`, which flips direction depending on which side of #987 the branch is on.
        c.transition["awake"] = awakeRowPR987
        return Variant(name: "#348 entire (as reverted by #437)",
                       note: "all seven components at once", config: c)
    }

    /// NOT a candidate — a provenance check, and the reason it is here is worth stating.
    ///
    /// This harness was rebuilt to reproduce a set of numbers a previous, deleted harness measured on this
    /// same dataset: kappa 0.349, REM F1 0.515, REM 20.8 % of night, median first-REM latency 142.0 min.
    /// The rebuild reproduces every TRUTH-side figure exactly (26 773 scored epochs, deep 14.76 % of night,
    /// truth first-REM 88.5 min) but lands the prediction side elsewhere — more REM, arriving earlier.
    ///
    /// Those percentages are the MEAN OF PER-SUBJECT PERCENTAGES, which is the convention the old figures
    /// were reported in; pooled over all 26 773 epochs the same truth deep fraction is 13.76 % and the same
    /// predicted deep fraction is 18.94 %. `main.swift` prints both tables, labelled, for exactly this
    /// reason — a stage fraction quoted without its convention is a number two people will disagree about
    /// while both being right. Section 6's variant table, and every `bias pp` in it, is pooled.
    ///
    /// One mechanism explains that whole pattern, and it is dated rather than mysterious: PR #930 replaced a
    /// hard `c < 0.12 ? 3.0 : 0.0` step in the SESSION-FRACTION domain with a graded penalty measured in
    /// MINUTES from sleep onset. Averaged over the epochs it covers, the graded guard is the weaker one, so
    /// after #930 the recipe admits REM earlier and admits more of it. The old numbers were measured while
    /// #930 was the CANDIDATE — so the incumbent they describe is the recipe as it stood BEFORE it.
    ///
    /// This variant runs that pre-#930 guard so the claim is checked rather than asserted.
    static var preNine30Guard: Variant {
        var c = RecipeConfig.shipped
        c.remLatencyMode = .preNine30FractionStep
        return Variant(name: "pre-#930 REM guard (provenance)",
                       note: "c<0.12 step in the fraction domain, single Viterbi pass", config: c)
    }

    /// The shipped recipe itself, so a table row exists to difference against.
    static var incumbent: Variant {
        Variant(name: "incumbent (shipped)", note: "SleepStagerV2 as it ships today", config: .shipped)
    }

    static var all: [Variant] {
        [incumbent, pr987, p348Priors, p348Motion, p348Emissions, p348DeepGate,
         p348Deadzone, p348OtherRows, p348All, preNine30Guard]
    }
}
