import Foundation

/// On-demand "take an HRV reading now" — the single-value spot RMSSD path (#537).
///
/// Swift parity twin of `android/.../analytics/SpotHrvReading.kt`. This wraps NOOP's canonical
/// `HRVAnalyzer` for the LIVE, user-triggered HRV snapshot the Live screen captures over ~60 s of
/// beat-to-beat (R-R) intervals. It exists so the spot value, its honesty gate, and its data-quality
/// caveat live in ONE tested place rather than being re-derived in the view.
///
/// Why delegate to `HRVAnalyzer` (and NOT roll our own RMSSD):
///  - RMSSD is the textbook root-mean-square of successive R-R differences:
///        RMSSD = sqrt( mean( (RR[i+1] - RR[i])^2 ) )   in ms.
///  - NOOP's nightly HRV (`avgHrv`, fed into Vitality / Fitness Age) uses `HRVAnalyzer.rmssdRaw`, which
///    takes the Task Force (1996) SAMPLE denominator (n-1) over the cleaned NN series. To keep a spot
///    reading COMPARABLE to the overnight number a user sees elsewhere, this path computes RMSSD the
///    SAME way (same cleaning pipeline, same (n-1) denominator). Using a population (n) denominator
///    would make the same beats read a few percent lower than the nightly figure, which is misleading.
///    Consistency with the existing scorer is the whole point.
///
/// Honesty is built in, not bolted on:
///  - A number is returned ONLY when enough CLEAN beats survive (`HRVAnalyzer.minBeats`); otherwise the
///    result is `.insufficient` with the surviving/needed counts so the UI can say so plainly (never a
///    fabricated value, unknown stays the "no value" glyph).
///  - The caveat (`caveatFor`) is source-aware: a 60 s spot reading is not the overnight baseline, it
///    needs enough beats, and R-R derived from a WHOOP strap's optical PPG is noisier than a chest
///    strap's electrical R-R. Pure strings, US-neutral, no em-dashes.
///
/// Pure arithmetic + small value types, no I/O — fully unit-testable against a known RR series.
public enum SpotHrvReading {

    /// Where the live R-R intervals came from — drives the honesty caveat (optical PPG is noisier).
    public enum Source: Sendable {
        /// Any WHOOP strap (4.0, 5.0, MG): R-R is derived from the optical PPG via 0x2A37 — beat-to-beat, but noisier.
        case opticalPPG
        /// An electrical chest strap (e.g. Polar H10) over the standard 0x2A37 profile.
        case chestStrap
        /// Source not known (generic / unspecified strap).
        case unknown
    }

    /// Outcome of an on-demand spot reading.
    public enum Outcome: Equatable, Sendable {
        /// A trustworthy spot value: `rmssdMs` (ms), mean `hrBpm` (or nil), and the clean-beat `beats`
        /// used. Backed by the full `HRVAnalyzer` result for callers that want SDNN / pNN50 too.
        case reading(rmssdMs: Double, hrBpm: Double?, beats: Int, full: HRVAnalyzer.HRVResult)
        /// Not enough clean beats to report honestly — carries how many survived vs how many are needed
        /// so the UI can guide the user ("sit still and try again").
        case insufficient(clean: Int, needed: Int, input: Int)
    }

    /// Compute a single spot HRV reading from the raw R-R intervals (ms) gathered during the live
    /// capture window. Runs NOOP's canonical cleaning + RMSSD (range filter -> Malik ectopic rejection
    /// -> (n-1) RMSSD), so the value matches the nightly HRV math. Returns `.insufficient` rather than a
    /// number when too few clean beats survive — never a fabricated figure.
    ///
    /// - Parameters:
    ///   - rrMs: the raw R-R intervals in milliseconds, in capture order (untrusted BLE input — the
    ///     analyzer's range filter bounds-checks each to `HRVAnalyzer.rrMinMs`...`HRVAnalyzer.rrMaxMs`).
    ///   - maxRejectedFraction: the spot honesty gate (#585) — refuse the reading when more than this
    ///     fraction of beats was dropped as noise (out-of-range / ectopic), even if `minBeats` clean
    ///     beats survive. Defaults to `HRVAnalyzer.defaultSpotMaxRejectedFraction` (0.35). The nightly
    ///     windowed path does NOT use this, so overnight HRV is unchanged.
    public static func compute(_ rrMs: [Int],
                               maxRejectedFraction: Double = HRVAnalyzer.defaultSpotMaxRejectedFraction) -> Outcome {
        let result = HRVAnalyzer.analyze(rawRR: rrMs.map(Double.init),
                                         maxRejectedFraction: maxRejectedFraction)
        guard let rmssd = result.rmssd else {
            return .insufficient(clean: result.nClean, needed: HRVAnalyzer.minBeats, input: result.nInput)
        }
        return .reading(rmssdMs: rmssd,
                        hrBpm: meanHrFromNN(result.meanNN),
                        beats: result.nClean,
                        full: result)
    }

    /// Mean heart rate (bpm) from the mean NN interval (ms): 60000 / meanNN. nil when missing or <= 0.
    public static func meanHrFromNN(_ meanNN: Double?) -> Double? {
        guard let meanNN, meanNN > 0 else { return nil }
        return 60_000.0 / meanNN
    }

    /// Honest, source-aware caveat for a spot reading. Plain text, US-neutral, no em-dashes. Always
    /// states the two universal limits (a 60 s spot is not the overnight baseline; it needs enough clean
    /// beats) and adds the source-specific noise note for an optical-PPG strap.
    public static func caveatFor(_ source: Source) -> String {
        let base =
            "This is a spot reading over a short, still capture, not your overnight HRV baseline. " +
            "Take it seated, still, and at a consistent time of day for comparable numbers, and " +
            "only a reading with enough clean beats is shown."
        switch source {
        case .opticalPPG:
            return base + " On a WHOOP strap (4.0, 5.0 or MG) the intervals come from the optical pulse signal, which is " +
                "noisier than an electrical chest strap such as a Polar H10, so treat the number as a rough estimate."
        case .chestStrap, .unknown:
            return base
        }
    }
}
