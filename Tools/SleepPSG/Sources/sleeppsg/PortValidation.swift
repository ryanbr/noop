import Foundation
import StrandAnalytics
import WhoopProtocol

// PortValidation — the check that entitles this harness to say its variant numbers describe NOOP's shipped
// recipe rather than a lookalike.
//
// `RecipePort.swift` re-states `SleepStagerV2` with its constants exposed. That is the only way to ask
// "what would this recipe score with one constant moved", and it is also the classic way a benchmark
// quietly starts measuring something else: someone edits the shipped file, nobody edits the port, and every
// number the tool prints afterwards is about code that never ran on anyone's wrist.
//
// So the port is not reviewed for equivalence — it is MEASURED for it, on every build. Both paths stage the
// same nights and every epoch label must agree. The nights are generated here rather than loaded, for two
// reasons: the check has to run in CI where no dataset and no health data exist, and generated nights can
// be aimed at the paths a real night rarely reaches (a stream with no heart rate at all, a night whose
// motion gate fires on every epoch, a two-epoch nap).
//
// A failure here is never "the test is flaky". It means `RecipeConfig.shipped` and
// `Packages/StrandAnalytics/Sources/StrandAnalytics/SleepStagerV2.swift` have diverged; the report names
// the night and the first epoch that differs.

/// SplitMix64 — a tiny deterministic PRNG so the generated corpus is identical on every machine and every
/// run. A benchmark whose validation set moves between runs cannot tell a real divergence from a reroll.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func double(_ lo: Double, _ hi: Double) -> Double { Double.random(in: lo..<hi, using: &self) }
    mutating func int(_ lo: Int, _ hi: Int) -> Int { Int.random(in: lo...hi, using: &self) }
    mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &self) < p }
}

/// One synthetic night: the exact arguments a `stageSession` call takes, plus a name for the report.
struct SyntheticNight {
    let name: String
    let start: Int
    let end: Int
    let grav: [GravitySample]
    let hr: [HRSample]
    let rr: [RRInterval]
    let resp: [RespSample]
}

enum PortValidation {

    /// The pinned corpus seed. Fixed rather than time- or machine-derived so that a divergence is always a
    /// code change and never a reroll — and so a failure reported by CI reproduces exactly on a laptop.
    static let defaultSeed: UInt64 = 0x5EED_5_1EE9_0001

    /// The corpus: 48 randomised nights plus the degenerate cases. Deterministic given `seed`.
    static func corpus(seed: UInt64 = PortValidation.defaultSeed, randomNights: Int = 48) -> [SyntheticNight] {
        if seed == defaultSeed && randomNights == 48 { return pinnedCorpus }
        return build(seed: seed, randomNights: randomNights)
    }

    /// The default corpus, built once. Generating it is not free — a few million RNG draws per night in a
    /// debug build — and several tests want the same nights, so building it per call would put minutes of
    /// pure setup into `swift test`. A `static let` is initialised lazily and exactly once, thread-safely.
    static let pinnedCorpus = build(seed: defaultSeed, randomNights: 48)

    private static func build(seed: UInt64, randomNights: Int) -> [SyntheticNight] {
        var g = SplitMix64(seed: seed)
        var out: [SyntheticNight] = []
        for i in 0..<randomNights { out.append(randomNight(index: i, g: &g)) }
        out.append(contentsOf: degenerateNights())
        return out
    }

    // MARK: - Randomised nights

    /// A night with plausible cardio-respiratory and motion structure, and randomised sparsity. The point is
    /// not realism — it is to reach every branch the recipe has: present/absent channels, coverage gaps,
    /// arousals, unsorted input, and a window that does not begin on a 30 s boundary.
    static func randomNight(index: Int, g: inout SplitMix64) -> SyntheticNight {
        // ~20 min to ~3.7 h. Sized so the whole corpus lands in the same order of magnitude as a night's
        // worth of epochs per subject without making `swift test` slow: the RSA term runs a band-limited
        // DFT per epoch, and this check stages every night TWICE.
        let nEpochs = g.int(40, 440)
        // Deliberately misalign some windows from the 30 s wall-clock grid: `features` starts at the first
        // multiple of 30 at or after `start`, and an off-grid start is where a tiling bug would show.
        let start = 1_700_000_000 + g.int(0, 5000) * 30 + (g.chance(0.4) ? g.int(1, 29) : 0)
        let end = start + nEpochs * 30 + (g.chance(0.5) ? g.int(0, 29) : 0)

        let haveHR = g.chance(0.9)
        let haveRR = g.chance(0.75)
        let haveGrav = g.chance(0.95)
        let hrDropout = g.double(0.0, 0.55)
        let gravDropout = g.double(0.0, 0.45)

        // A slow HR baseline with a couple of arousals, so the 5- and 11-min flatness windows see real
        // structure rather than white noise.
        let hrBase = g.double(44, 68)
        let hrDrift = g.double(-6, 6)
        let arousals = (0..<g.int(0, 5)).map { _ in g.int(0, max(1, nEpochs - 1)) }
        // Motion: a quiescent floor plus bursts, so the night-relative jerk floor is meaningful.
        let jerkFloor = g.double(1e-5, 4e-3)
        let burstEpochs = Set((0..<g.int(0, nEpochs / 6 + 1)).map { _ in g.int(0, max(0, nEpochs - 1)) })

        var hr: [HRSample] = [], grav: [GravitySample] = [], rr: [RRInterval] = []
        var gx = g.double(-0.9, 0.9), gy = g.double(-0.9, 0.9), gz = g.double(-0.9, 0.9)
        var rrCarry = 0.0
        for e in 0..<nEpochs {
            let epochStart = ((start + 29) / 30) * 30 + e * 30
            let arousal = arousals.contains(e) ? g.double(6, 22) : 0
            let burst = burstEpochs.contains(e)
            for s in 0..<30 {
                let t = epochStart + s
                let phase = Double(e) / Double(max(1, nEpochs))
                let bpm = hrBase + hrDrift * phase + arousal
                    + 3.0 * sin(Double(t) * 0.013) + g.double(-1.5, 1.5)
                if haveHR && !g.chance(hrDropout) {
                    hr.append(HRSample(ts: t, bpm: Int(bpm.rounded())))
                }
                let step = burst ? g.double(0, 0.35) : jerkFloor * g.double(0.2, 2.4)
                gx += g.double(-step, step); gy += g.double(-step, step); gz += g.double(-step, step)
                let n = max(1e-9, (gx * gx + gy * gy + gz * gz).squareRoot())
                gx /= n; gy /= n; gz /= n
                if haveGrav && !g.chance(gravDropout) {
                    grav.append(GravitySample(ts: t, x: gx, y: gy, z: gz))
                }
                // R-R beats: emit whenever the accumulated inter-beat time crosses a second, with an RSA
                // modulation so `respRegularity` sees a band-limited signal rather than noise.
                if haveRR {
                    rrCarry += 1.0
                    let ibi = 60.0 / max(25.0, bpm) * (1.0 + 0.06 * sin(Double(t) * 0.25 * 2 * .pi * 0.05))
                    while rrCarry >= ibi {
                        rrCarry -= ibi
                        rr.append(RRInterval(ts: t, rrMs: Int((ibi * 1000).rounded())))
                    }
                }
            }
        }
        // Hand some nights in unsorted: both paths sort defensively, and "defensively" is worth pinning.
        if g.chance(0.25) { hr.shuffle(using: &g) }
        if g.chance(0.25) { grav.shuffle(using: &g) }
        return SyntheticNight(name: "random-\(index)", start: start, end: end,
                              grav: grav, hr: hr, rr: rr, resp: [])
    }

    // MARK: - Degenerate nights

    /// The seven shapes a real night reaches rarely or never, each of which lands on a branch with its own
    /// early return, fallback constant, or divide-by-zero guard.
    static func degenerateNights() -> [SyntheticNight] {
        let base = 1_700_000_000
        var out: [SyntheticNight] = []

        // 1. All HR missing — every HR-derived feature is nil, the prefix grid is empty, and `stdOfSeconds`
        //    returns nil for every window. Only motion may speak.
        do {
            let n = 120
            var grav: [GravitySample] = []
            for s in 0..<(n * 30) {
                let a = Double(s) * 0.0007
                grav.append(GravitySample(ts: base + s, x: cos(a), y: sin(a), z: 0.05))
            }
            out.append(SyntheticNight(name: "degenerate-all-hr-missing", start: base, end: base + n * 30,
                                      grav: grav, hr: [], rr: [], resp: []))
        }

        // 2. Zero-variance HR — `zfun`'s std is 0, which it must treat as 1.0 rather than dividing by it,
        //    and every flatness window ties, so the percentile rank is degenerate too.
        do {
            let n = 120
            var grav: [GravitySample] = [], hr: [HRSample] = []
            for s in 0..<(n * 30) {
                hr.append(HRSample(ts: base + s, bpm: 55))
                let a = Double(s) * 0.0011
                grav.append(GravitySample(ts: base + s, x: cos(a), y: sin(a), z: 0.02))
            }
            out.append(SyntheticNight(name: "degenerate-zero-variance-hr", start: base, end: base + n * 30,
                                      grav: grav, hr: hr, rr: [], resp: []))
        }

        // 3. One epoch — the Viterbi lattice never takes a transition, and the segment tiler's first and
        //    last epoch are the same epoch.
        do { out.append(shortNight(name: "degenerate-1-epoch", base: base, epochs: 1)) }

        // 4. Two epochs — exactly one transition, the smallest lattice that uses the transition matrix.
        do { out.append(shortNight(name: "degenerate-2-epoch", base: base, epochs: 2)) }

        // 5. Saturated motion gate — every epoch's peak jerk clears the night-relative gate, so the wake
        //    boost is applied everywhere and the night-relative floor is at its most fragile.
        do {
            let n = 90
            var grav: [GravitySample] = [], hr: [HRSample] = []
            for s in 0..<(n * 30) {
                hr.append(HRSample(ts: base + s, bpm: 58 + (s % 7)))
                // Alternate poles: consecutive per-second jerks are ~2 g, orders above any median floor.
                let f = s % 2 == 0 ? 1.0 : -1.0
                grav.append(GravitySample(ts: base + s, x: f, y: 0, z: 0))
            }
            out.append(SyntheticNight(name: "degenerate-saturated-motion", start: base, end: base + n * 30,
                                      grav: grav, hr: hr, rr: [], resp: []))
        }

        // 6. No coverage at all — `features` returns empty and the recipe must fall back to a single
        //    light-labelled segment spanning the window rather than returning nothing.
        do {
            out.append(SyntheticNight(name: "degenerate-no-coverage", start: base, end: base + 3600,
                                      grav: [], hr: [], rr: [], resp: []))
        }

        // 7. Motion absent, heart rate only — no jerks anywhere, so the quiescent floor falls back to its
        //    1e-6 epsilon and `motionQuiescent` is true on every epoch.
        do {
            let n = 100
            var hr: [HRSample] = []
            for s in 0..<(n * 30) { hr.append(HRSample(ts: base + s, bpm: Int(52 + 9 * sin(Double(s) * 0.002)))) }
            out.append(SyntheticNight(name: "degenerate-no-motion", start: base, end: base + n * 30,
                                      grav: [], hr: hr, rr: [], resp: []))
        }
        return out
    }

    private static func shortNight(name: String, base: Int, epochs: Int) -> SyntheticNight {
        var grav: [GravitySample] = [], hr: [HRSample] = []
        for s in 0..<(epochs * 30) {
            hr.append(HRSample(ts: base + s, bpm: 56 + (s % 5)))
            let a = Double(s) * 0.02
            grav.append(GravitySample(ts: base + s, x: cos(a), y: sin(a), z: 0.1))
        }
        return SyntheticNight(name: name, start: base, end: base + epochs * 30,
                              grav: grav, hr: hr, rr: [], resp: [])
    }

    // MARK: - The check

    struct Divergence {
        let night: String
        let epochIndex: Int
        let shipped: String
        let port: String
    }

    struct Result {
        var nights = 0
        var randomNights = 0
        var degenerateNights = 0
        var epochs = 0
        var matchingEpochs = 0
        var divergences: [Divergence] = []
        var ok: Bool { divergences.isEmpty && epochs > 0 && matchingEpochs == epochs }
    }

    /// Stage every night through BOTH paths and compare epoch labels on the 30 s grid.
    ///
    /// Epoch labels rather than the raw `[StageSegment]` array, because that is the unit every score in this
    /// harness is computed on — an equivalence that held only after run-length collapsing would not
    /// guarantee the numbers agree. (The segment arrays do also match; comparing labels is the stricter
    /// statement for our purposes and the weaker one to state, so it is what the report claims.)
    static func run(seed: UInt64 = PortValidation.defaultSeed, randomNights: Int = 48) -> Result {
        let nights = corpus(seed: seed, randomNights: randomNights)
        // Nights are staged concurrently: staging is pure, and the shipped stager's memo cache is itself
        // lock-guarded (`AnalyticsMemoCache`), so the only shared state is safe. Serially this check runs
        // for minutes in a debug build — the recipe's RSA term is a per-epoch DFT and every night is staged
        // twice — and a validation nobody wants to wait for is a validation that gets skipped.
        var perNight = [(epochs: Int, matching: Int, divergences: [Divergence])](
            repeating: (0, 0, []), count: nights.count)
        perNight.withUnsafeMutableBufferPointer { buf in
            let out = buf
            DispatchQueue.concurrentPerform(iterations: nights.count) { idx in
                let n = nights[idx]
                let shipped = SleepStagerV2.stageSession(start: n.start, end: n.end, grav: n.grav,
                                                         hr: n.hr, rr: n.rr, resp: n.resp)
                let port = V2Recipe.stageSession(start: n.start, end: n.end, grav: n.grav,
                                                 hr: n.hr, rr: n.rr, resp: n.resp, cfg: .shipped)
                let a = epochLabels(shipped, start: n.start, end: n.end)
                let b = epochLabels(port, start: n.start, end: n.end)
                var epochs = 0, matching = 0
                var divs: [Divergence] = []
                for i in 0..<min(a.count, b.count) {
                    epochs += 1
                    if a[i] == b[i] { matching += 1 }
                    else if divs.count < 20 {
                        divs.append(Divergence(night: n.name, epochIndex: i, shipped: a[i], port: b[i]))
                    }
                }
                if a.count != b.count {
                    divs.append(Divergence(night: n.name, epochIndex: -1,
                                           shipped: "\(a.count) epochs", port: "\(b.count) epochs"))
                }
                out[idx] = (epochs, matching, divs)
            }
        }
        var r = Result()
        for (i, n) in nights.enumerated() {
            r.nights += 1
            if n.name.hasPrefix("degenerate") { r.degenerateNights += 1 } else { r.randomNights += 1 }
            r.epochs += perNight[i].epochs
            r.matchingEpochs += perNight[i].matching
            r.divergences.append(contentsOf: perNight[i].divergences.prefix(max(0, 20 - r.divergences.count)))
        }
        return r
    }
}
