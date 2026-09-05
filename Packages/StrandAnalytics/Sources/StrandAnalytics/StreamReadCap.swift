import Foundation

/// Per-stream read caps for the `analyzeRecent` sliding windows (#1538).
///
/// One shared cap of 200,000 covered both heavy streams, and it was sized for HR. A field capture
/// (2026-09-05, WHOOP 5/MG, 21 nights) shows what that cost:
///
///     hr[read=1723815 served=1826919 truncated=0]
///     rr[read=2563444 served=610905 truncated=10]
///
/// Ten R-R windows came back AT the cap. `SlidingStreamWindow.truncatedReads` is explicit about what
/// that means - "a non-zero count means a number may be wrong, not merely slow" - because the read is
/// `ORDER BY ts ASC LIMIT`, so what gets dropped is the NEWEST rows. Every HRV number derived from one
/// of those windows was computed on a night missing its tail, silently.
///
/// ## Why R-R and not HR
///
/// Measured, not reasoned from beat rate - the capture contradicts the obvious argument. R-R is one row
/// per BEAT, so it "should" outrun HR's 1/s, yet a stride read in that same log returned 81,009 R-R rows
/// against 107,415 HR: R-R is recorded in BURSTS, not continuously, so its average over a window sits
/// BELOW HR's while its peaks run far above. Averages are why one cap looked safe; peaks are what
/// truncated it.
///
/// What is certain is the behaviour: across 21 nights R-R came back at the 200,000 cap ten times and HR
/// never did. HR's own margin is the other half of the story - a full 54-hour window at 1/s is ~194,400
/// rows, 3% under the cap, so HR was never comfortable either, merely lucky.
///
/// The caps are therefore sized against what a window can PEAK at, not what it averages. The rate
/// constants below are deliberately generous for that reason: they are a ceiling to stay clear of, not a
/// prediction of typical density.
///
/// So the bug was not the number being too small. It was ONE number serving two streams whose peak
/// densities differ, where a value comfortable for one is a silent truncation for the other.
///
/// ## The invariant
///
/// A cap must exceed what a full window can legitimately hold, or a complete read is indistinguishable
/// from a truncated one. `capExceedsFullWindow` pins exactly that, per stream, so a future change to the
/// window span or a stream's rate fails a test rather than quietly clipping a night.
///
/// Note the cap is a ceiling, not an allocation: a read still returns only the rows that exist. Raising
/// it costs nothing on a normal night and buys correctness on a dense one.
public enum StreamReadCap {

    /// How far BEFORE the day boundary the pass reads. EVERY lookback in the engine takes this value -
    /// the per-day `from`, the window start, the skin-anchor scan - so the window and the caps derived
    /// from it cannot drift apart - widening the lookback there without
    /// resizing the caps here is precisely how a stream starts truncating again, and is the "one number
    /// in two places" shape this whole type exists because of.
    public static let lookbackSeconds = 30 * 3_600

    /// How far AFTER it, capped at `now` for a day still in progress. A whole day.
    public static let forwardSeconds = 24 * 3_600

    /// The per-day read window: `dayStart - 30h` through the night, i.e. 54 hours.
    public static let windowSeconds = lookbackSeconds + forwardSeconds

    /// HR: one sample per second.
    public static let hrRowsPerSecond = 1.0

    /// R-R at its PEAK. The measured average is below 1/s (it arrives in bursts, with gaps), but bursts
    /// are what reach a cap - and #1008's cross-second overcount can double the rows a burst produces.
    /// 2/s is a ceiling chosen to stay clear of, not a claim about typical density.
    public static let rrRowsPerSecond = 2.0

    /// Gravity: one sample per second, like HR, and read over the SAME 54-hour window - the code's claim
    /// that "the other eight streams are thousands of rows" does not hold for this one. A field capture
    /// measured 192,698 gravity rows, 96% of the old shared cap.
    ///
    /// It is the most dangerous of the three, because it is a PLAIN read rather than a
    /// `SlidingStreamWindow`: nothing counts a truncation here, so a clip would be silent even by the
    /// standard that caught R-R. Sleep STAGING is what consumes it, so the cost of a clipped read is a
    /// mis-staged night rather than a slow one.
    public static let gravityRowsPerSecond = 1.0

    /// Headroom over a full window, so a legitimate read cannot land ON the cap and be mistaken for a
    /// truncated one.
    public static let headroom = 1.5

    /// The cap for a stream producing `rowsPerSecond` at its densest.
    public static func cap(rowsPerSecond: Double) -> Int {
        Int((Double(windowSeconds) * rowsPerSecond * headroom).rounded(.up))
    }

    /// 291,600 - a full HR window plus half again.
    ///
    /// STORED, not computed. A window's read cap and its truncation threshold must be the same number,
    /// and the engine names this in both slots - a stored constant makes those two references provably
    /// one value rather than two evaluations that merely ought to agree.
    public static let hr = cap(rowsPerSecond: hrRowsPerSecond)

    /// 583,200 - a full R-R window at its densest, plus half again. Stored for the reason `hr` gives.
    public static let rr = cap(rowsPerSecond: rrRowsPerSecond)

    /// 291,600 - the same shape as `hr`, for the same 54-hour window. Only the 54-hour read needs it;
    /// the day-scoped gravity reads span 24 hours and cannot approach any of these.
    public static let gravity = cap(rowsPerSecond: gravityRowsPerSecond)
}
