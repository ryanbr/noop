import Foundation

/// Per-day reuse identity for the steps-calibration motion fold in `IntelligenceEngine.analyzeRecent`.
///
/// The drain this closes: the calibration fits one coefficient from sixty days of strap motion, and it
/// re-folded all sixty on EVERY pass. Each day meant a `gravitySamples` read capped at 200,000 rows, so a
/// worn library paid millions of materialised rows per pass to re-derive numbers that had not moved. The
/// phase does not scale with the days being re-scored — it always reads the same sixty — so a two-day pass
/// could cost more than a twenty-one-day one, which is what made it hard to see in a cost line keyed on the
/// day loop.
///
/// `StepsEstimateEngine.dayMotionIntensity` is a pure fold over one day's gravity stream. Nothing else
/// reaches it: no profile field, no baseline, no toggle, no other stream. So unlike `AnalyzeRecentDayCache`
/// there is no pass-config signature to invalidate against — the value changes exactly when that one day's
/// gravity changes, and the key below is the whole story.
///
/// Unlike the day-scan cache this one PERSISTS across launches, and the paragraph above is why it can. A
/// persisted day scan would have to carry `dayCacheConfigSig`, which folds in baselines1 and the habitual
/// sleep terms — and `sleepConsistency` (1-CV over 28 nights) and `habitualMidsleepSec` (a circular mean)
/// shift with ANY night moving, so it would invalidate wholesale on exactly the passes it would need to
/// survive. Nothing pass-global reaches this fold, so the payload stays valid while gravity stands still and
/// the sixty-day fold is paid once per install instead of once per launch: measured 32.9 s -> 3.3 s on a
/// worn 60-day library, which the cold pass otherwise repaid after every relaunch.
///
/// It stays a DERIVED cache and nothing else reads it, so the whole failure surface is one re-fold: a
/// payload that is missing, unreadable, or written by an older fold is discarded rather than repaired.
///
/// It still does NOT cross the `.noopbak` boundary, and must not start: the key is deliberately absent from
/// both `BackupSettings` whitelists. A restore carries the settings and the record store, and this describes
/// neither — it describes gravity rows AS THEY WERE ON ONE DEVICE. Shipping it to another device would be
/// the one way to serve a fold whose key no longer witnesses anything, which is the failure every other
/// guard here exists to prevent. A restored device simply re-folds once.
public enum StepsMotionCache {
    /// The per-day reuse key. Reuse a cached motion volume iff this string is unchanged.
    ///
    /// - `owner`: the resolved owning device the fold was measured against. A day whose owner flips between
    ///   straps must re-fold, and the fingerprint below is device-scoped, so this makes that explicit rather
    ///   than relying on two devices never producing an identical count and newest timestamp for one window.
    /// - `gravityCount` / `gravityMaxTs`: the day window's gravity witness. Any gravity row added or removed
    ///   moves one of the two. Deliberately NOT the wider `dayStreamFingerprint`: that also counts HR, R-R,
    ///   respiration, SpO2, steps, skin temp and sleep state, so an ordinary HR offload would invalidate a
    ///   motion volume that cannot have changed by it.
    public static func cacheKey(owner: String, gravityCount: Int, gravityMaxTs: Int) -> String {
        "\(owner)|\(gravityCount)|\(gravityMaxTs)"
    }

    /// The pass's one-line reuse readout, beside the phase cost line.
    ///
    /// `reused` and `folded` sum to the days scanned, so the ratio is readable without a second line. A pass
    /// reporting `folded=60` every time means the key is moving when it should not, which is the failure
    /// this cache can have and the reason the number is reported at all rather than assumed.
    public static func logLine(reused: Int, folded: Int, size: Int) -> String {
        "analyzeRecent stepsMotion reused=\(reused)/\(reused + folded) size=\(size)"
    }

    /// The version of the FOLD the persisted values were produced by. Bump on any change to
    /// `StepsEstimateEngine.dayMotionIntensity` that moves what it returns for the same samples.
    ///
    /// In memory this could not exist: a process cannot outlive the binary that filled it, so the fold that
    /// produced a cached value is always the fold that would reproduce it. A persisted entry outlives its
    /// build, and `cacheKey` witnesses the INPUTS only — a day whose gravity has not moved keys identically
    /// across an app update, so without this the old volume would be served until that day's stream happened
    /// to change. A bump discards every entry and costs one full re-fold, once, which is the cheap side.
    public static let foldVersion = 1

    /// Render the cache for storage. Days are emitted in sorted order so an unchanged cache renders to an
    /// identical payload and the write is a no-op rather than churn.
    ///
    /// One line per day, `day\tkey\tmotion`, under a header naming `foldVersion`. Tab-separated because the
    /// key itself contains `|`; the motion is written by raw bit pattern so it round-trips exactly and
    /// locale-free, the same reason `cacheKey` encodes the skin anchor that way.
    public static func serialize(_ entries: [String: (key: String, motion: Double)]) -> String {
        var out = header
        for day in entries.keys.sorted() {
            guard let e = entries[day] else { continue }
            out += "\n\(day)\t\(e.key)\t\(e.motion.bitPattern)"
        }
        return out
    }

    /// Parse a stored payload. Returns empty on anything it cannot vouch for — a wrong/absent header (an
    /// older `foldVersion` included), a malformed line, or an implausible entry count. Every rejection costs
    /// one re-fold, so this discards rather than salvages: a half-trusted cache is the one failure mode that
    /// could feed a stale volume into the calibration fit.
    public static func deserialize(_ raw: String) -> [String: (key: String, motion: Double)] {
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == Substring(header) else { return [:] }
        lines.removeFirst()
        guard lines.count <= maxEntries else { return [:] }
        var out: [String: (key: String, motion: Double)] = [:]
        for line in lines {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == 3, !f[0].isEmpty, !f[1].isEmpty, let bits = UInt64(f[2]) else { continue }
            out[String(f[0])] = (key: String(f[1]), motion: Double(bitPattern: bits))
        }
        return out
    }

    /// Payload header. Carries `foldVersion` so a fold change invalidates by failing the equality check.
    private static var header: String { "stepsMotion v\(foldVersion)" }

    /// Upper bound on entries a payload may declare. The writer prunes to the calibration window every pass,
    /// so a payload far above it did not come from this cache and is not worth parsing.
    private static let maxEntries = 512
}
