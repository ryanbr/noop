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
/// The pass reads a 54-hour window per day. HR is one sample per second, so a full window is ~194,400
/// rows - under 200,000 by 3%, which is why HR never truncated and why the shared cap looked fine. R-R
/// is one row per BEAT, so it exceeds 1/s at any real heart rate, and a 4.0's cross-second overcount
/// roughly doubles it (#1008). A full R-R window is therefore 233,000-389,000 rows and runs straight
/// through a cap HR merely brushes.
///
/// So the bug was not the number being too small. It was ONE number serving two streams with different
/// row rates, where the safe value for the sparser one is a silent truncation for the denser one.
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

    /// The per-day read window: `dayStart - 30h` running through the night, i.e. 54 hours.
    public static let windowSeconds = 54 * 3_600

    /// HR: one sample per second.
    public static let hrRowsPerSecond = 1.0

    /// R-R: one row per beat. 1.2-1.5/s is ordinary; #1008's cross-second overcount can reach ~2/s, and
    /// the cap must hold the worst case a real strap can produce, not the average one.
    public static let rrRowsPerSecond = 2.0

    /// Headroom over a full window, so a legitimate read cannot land ON the cap and be mistaken for a
    /// truncated one.
    public static let headroom = 1.5

    /// The cap for a stream producing `rowsPerSecond` at its densest.
    public static func cap(rowsPerSecond: Double) -> Int {
        Int((Double(windowSeconds) * rowsPerSecond * headroom).rounded(.up))
    }

    /// 291,600 - a full HR window plus half again.
    public static var hr: Int { cap(rowsPerSecond: hrRowsPerSecond) }

    /// 583,200 - a full R-R window at its densest, plus half again.
    public static var rr: Int { cap(rowsPerSecond: rrRowsPerSecond) }
}
