import Foundation

/// Group Oura sidecar rows by the ring epoch each one implies, so a session filed under the wrong
/// anchor is visible without needing a trusted anchor to compare against.
///
/// #2252: the ticks×10 defect (#2239) filed whole sessions in the past, and the rows it wrote carry no
/// ring-time in the store, so nothing there can say which they were. The decoded sidecars do carry both
/// axes, and they are written on every live-feeding connection rather than behind a Test Centre toggle,
/// so the evidence is already on the affected devices.
///
/// Every row implies `epoch = utc - ringTs / 10`: the UTC at which the ring's tick counter read zero.
/// Rows anchored correctly against one ring boot all imply the SAME epoch. A session whose anchor was
/// adopted as seconds×10 implies one `0.9 × anchorTicks` seconds earlier, which for the Ring 5 in #2239
/// was 41.7 days. The shift is CONSTANT across that session, because it comes from the anchor rather
/// than from each record:
///
///     stored = T + (rt - 10R)/10,  true = T + (rt - R)/10,  true - stored = 0.9R
///
/// This DESCRIBES, it does not classify. A ring that genuinely restarted also starts a new epoch, and
/// telling a restart from a mis-anchored session is a judgement the caller makes with the registration
/// date and the ring's own history in hand. Reporting the clusters is what makes that judgement
/// possible; guessing it here would be the same confident wrongness the defect itself was.
public enum OuraRingEpochScan {

    /// One run of rows agreeing on where the ring's clock started.
    public struct Cluster: Equatable, Sendable {
        /// Implied UTC of ring tick 0, taken as the median of the run so one outlying row cannot move it.
        public let epochUnix: Int
        public let rows: Int
        /// The stored-UTC span of this run, which is what a reader sees on a calendar.
        public let firstStoredUtc: Int
        public let lastStoredUtc: Int

        public init(epochUnix: Int, rows: Int, firstStoredUtc: Int, lastStoredUtc: Int) {
            self.epochUnix = epochUnix
            self.rows = rows
            self.firstStoredUtc = firstStoredUtc
            self.lastStoredUtc = lastStoredUtc
        }
    }

    /// Six hours, the default gap that separates one epoch from the next.
    ///
    /// Not tight, deliberately. The ring's clock runs at 9.94 to 10.25 ticks per second rather than
    /// exactly 10 (#2239 measured 58 pairs), so dividing by 10 accumulates error WITHIN a correctly
    /// anchored session: across a fortnight of banked history a 2.5% rate error is about eight hours of
    /// implied-epoch drift. A tolerance under that would split one honest boot into several clusters and
    /// report drift as corruption. The defect this exists to surface moves the epoch by DAYS, so six
    /// hours separates the two cases without inventing a precision the tick rate does not support.
    public static let defaultToleranceSeconds = 21_600

    /// One report line when the rows disagree about where the ring's clock started, or nil when they do
    /// not. Nil is the healthy answer and the common one: a ring that has never restarted implies a
    /// single epoch, and an absent line keeps a healthy report byte-unchanged by this existing.
    ///
    /// Deliberately states the gap in days rather than naming a cause. `0.9 x anchorTicks` for the #2239
    /// ring was 41.7 days, so a gap near that is the ticks×10 signature; a gap of a few days is more
    /// likely a genuine restart. Both look identical from here, and the reader has the registration date.
    ///
    /// The Kotlin twin is `OuraRingEpochScan.summaryLine`.
    public static func summaryLine(_ clusters: [Cluster]) -> String? {
        guard clusters.count > 1, let newest = clusters.first else { return nil }
        var line = "ouraRingEpoch clusters=\(clusters.count) newest=\(isoDay(newest.epochUnix)) rows=\(newest.rows)"
        for older in clusters.dropFirst() {
            let gapDays = Double(newest.epochUnix - older.epochUnix) / 86_400
            line += " | epoch=\(isoDay(older.epochUnix)) rows=\(older.rows)"
                + " gapDays=\(String(format: "%.1f", gapDays))"
                + " stored=\(isoDay(older.firstStoredUtc))..\(isoDay(older.lastStoredUtc))"
        }
        return line
    }

    /// UTC calendar day for a unix second, as the report prints dates elsewhere.
    ///
    /// The Kotlin twin is `OuraRingEpochScan.isoDay`.
    static func isoDay(_ unix: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    /// Cluster `rows` by implied ring epoch, newest epoch first.
    ///
    /// The Kotlin twin is `OuraRingEpochScan.cluster`.
    ///
    /// `rows` may arrive in any order and may mix sidecars; only `ringTs` and the stored `utc` matter.
    /// A row whose `ringTs` is 0 is dropped: an unanchored record has no time axis to imply an epoch
    /// from, and including it would invent one at `utc`.
    public static func cluster(_ rows: [(ringTs: UInt32, utc: Int)],
                               toleranceSeconds: Int = defaultToleranceSeconds) -> [Cluster] {
        let points = rows
            .filter { $0.ringTs > 0 }
            .map { (epoch: $0.utc - Int($0.ringTs) / 10, utc: $0.utc) }
            .sorted { $0.epoch < $1.epoch }
        guard !points.isEmpty else { return [] }

        // Runs are collected first and turned into clusters after, rather than closed by a local helper:
        // a nested function is a DECLARATION the parity ledger sees on each side and cannot pair, so the
        // twin would owe two one-sided entries for a private detail neither platform exposes.
        var runs: [[(epoch: Int, utc: Int)]] = []
        var run: [(epoch: Int, utc: Int)] = [points[0]]

        for point in points.dropFirst() {
            // Against the PREVIOUS row, not the run's first: a long session drifts steadily, and measuring
            // from the start would eventually exceed any tolerance and split one boot in two.
            if point.epoch - run[run.count - 1].epoch <= toleranceSeconds {
                run.append(point)
            } else {
                runs.append(run)
                run = [point]
            }
        }
        runs.append(run)

        let clusters = runs.map { r -> Cluster in
            let epochs = r.map(\.epoch).sorted()
            let utcs = r.map(\.utc)
            return Cluster(epochUnix: epochs[epochs.count / 2],
                           rows: r.count,
                           firstStoredUtc: utcs.min() ?? 0,
                           lastStoredUtc: utcs.max() ?? 0)
        }
        // Tie-broken, not just ordered by epoch: Swift's `sorted(by:)` is NOT stable while Kotlin's
        // `sortedByDescending` is, so two clusters sharing a median epoch could come back in a different
        // order on each platform and `summaryLine` would name a different one "newest". Ordering by row
        // count and then by stored span makes the result a function of the values on both.
        return clusters.sorted {
            if $0.epochUnix != $1.epochUnix { return $0.epochUnix > $1.epochUnix }
            if $0.rows != $1.rows { return $0.rows > $1.rows }
            return $0.firstStoredUtc > $1.firstStoredUtc
        }
    }
}
