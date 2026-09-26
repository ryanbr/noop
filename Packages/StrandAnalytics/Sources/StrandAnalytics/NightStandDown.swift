import Foundation

/// The hours of the local day in which a wearable's daytime-HR mode should stand down so the device can
/// run its own night suite — derived from the sleep schedule NOOP already learns, never from a fixed clock.
///
/// WHY THIS EXISTS. An Oura ring produces daytime heart rate ONLY while a client holds it in daytime-HR
/// mode (`DHR_mode:3`); there is no banked daytime HR family it emits on its own. NOOP's screen-off suspend
/// (#1526) stops holding the ring so its sleep suite can run — the right call at night, r = −0.93 between
/// the overnight hold and the ring producing SpO2 / a hypnogram / `0x6A` — but a screen-off gate is also
/// true for most of a working day, so from the night that build shipped the daytime 5-min HR bins went from
/// 123–144/144 to a median of ~16, and windowed rMSSD by day emptied with them (the daytime beats are the
/// same `0x80` records). This band is what lets the stand-down key on the NIGHT instead of on the screen.
///
/// Bedtime is `habitualMidsleepSec − typicalSleepHours / 2`, wake is `+ typicalSleepHours / 2`, exactly the
/// derivation `BatteryEstimator.bedtimeAlert` uses, so the two policies can never disagree about when the
/// user's night is; the band then opens `leadSeconds` before that bedtime (an early night must still stand
/// down) and closes `tailSeconds` after that wake (a lie-in must not re-arm the hold). Cold start — fewer
/// nights than the learner needs — yields nil, and the caller falls back to the screen rule: inventing a
/// 23:00 band would hold or release the ring at the wrong hour for exactly the shift/late sleepers the
/// learner exists for. A nap outside the band is not stood down for; that is a known limit of this first cut.
///
/// Pure and clock-free so it is `swift test`-able like `BatteryEstimator.bedtimeAlert`.
public enum NightStandDown {

    /// A circular local-time band `[startSec, endSec)` in seconds-of-day; `endSec` may be numerically
    /// smaller than `startSec` when the band crosses midnight, which the usual night does.
    public struct Band: Equatable, Sendable {
        public let startSec: Int
        public let endSec: Int
        public init(startSec: Int, endSec: Int) { self.startSec = startSec; self.endSec = endSec }
    }

    /// How long before the learned bedtime the stand-down opens. One hour covers an early night without
    /// giving the evening away: the screen-off grace still applies inside the band, so an evening spent on
    /// the phone keeps live HR until it is pocketed.
    public static let leadSeconds = 3_600
    /// How long after the learned wake the stand-down stays closed. One hour covers a lie-in; after it the
    /// ring is held again even with the screen still dark, which is what puts the morning back on the chart.
    public static let tailSeconds = 3_600

    static let secondsPerDay = 86_400

    /// The night band for a learned schedule, or nil at cold start (no learned midsleep / no typical night).
    public static func band(habitualMidsleepSec: Int?, typicalSleepHours: Double?,
                            leadSeconds: Int = leadSeconds, tailSeconds: Int = tailSeconds) -> Band? {
        guard let midsleep = habitualMidsleepSec, let hours = typicalSleepHours, hours > 0,
              (0..<secondsPerDay).contains(midsleep) else { return nil }
        let half = Int((hours * 1_800).rounded())
        // A schedule whose padded night would cover the whole day has nothing left to call "day"; treat
        // it as unlearned rather than hold the ring never.
        guard 2 * half + leadSeconds + tailSeconds < secondsPerDay else { return nil }
        return Band(startSec: floorMod(midsleep - half - leadSeconds, secondsPerDay),
                    endSec: floorMod(midsleep + half + tailSeconds, secondsPerDay))
    }

    /// Whether a local second-of-day falls inside the band, circularly.
    public static func contains(_ band: Band, secOfDay: Int) -> Bool {
        let s = floorMod(secOfDay, secondsPerDay)
        if band.startSec <= band.endSec {
            return s >= band.startSec && s < band.endSec
        }
        return s >= band.startSec || s < band.endSec
    }

    /// `HH:MM–HH:MM` for a log line.
    public static func describe(_ band: Band) -> String {
        "\(describeSecOfDay(band.startSec))–\(describeSecOfDay(band.endSec))"
    }

    /// `HH:MM` for a local second-of-day (wrapped into the day first), for a log line.
    public static func describeSecOfDay(_ secOfDay: Int) -> String {
        let s = floorMod(secOfDay, secondsPerDay)
        return String(format: "%02d:%02d", s / 3_600, (s % 3_600) / 60)
    }

    static func floorMod(_ a: Int, _ n: Int) -> Int {
        let r = a % n
        return r < 0 ? r + n : r
    }
}
