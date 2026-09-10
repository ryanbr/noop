import Foundation
import StrandAnalytics

/// Scores today's stress for the surfaces that draw it, and does it as rarely as it can get away with.
///
/// Swift twin of the Kotlin `StressWidgetProducer`, and the same reasoning governs both.
///
/// THE GATE IS THE POINT. Scoring a day means reading today's heart rate, R-R and gravity, three reads
/// bounded at 200 000 rows each, which is the work the Stress screen does when you open it. The screen
/// does that once, on a deliberate act. A widget producer runs on the publish path, which fires when
/// the app becomes active and after every Health sync, so nothing is read until `Repository`'s cheap
/// heart-rate fingerprint — a COUNT and a MAX over an indexed column — says today's heart rate actually
/// moved. A publish that changed nothing costs that one query and reuses the previous curve.
///
/// SCORING MODE. Always the `.dayRelative` default, never the opt-in personal-baseline lens. Resolving
/// that mode reads fourteen trailing days of heart rate to decide whether enough worn history exists,
/// which the screen can afford on demand and a publish path cannot. Stated plainly because it is
/// user-visible: with the personal-baseline toggle on, the widget shows the default lens while the
/// screen shows the refined one, so the two can differ.
enum StressDayCurve {

    /// What the last scoring saw and produced, swapped in as ONE value.
    ///
    /// Separate fields could tear: a second call arriving between two assignments would read one
    /// call's fingerprint beside another's result and serve a curve for a day it was not scored
    /// against. Both callers are `@MainActor` today, so the window is narrow, but an immutable holder
    /// closes it for free.
    private struct Memo {
        let count: Int
        let maxTs: Int
        let day: Int
        let result: DaytimeStress.Result
    }

    @MainActor private static var memo: Memo?

    /// Today's curve and the local day number it belongs to, or nil when it could not be scored.
    ///
    /// Nil is not "today scored nothing": it means "say nothing about stress right now", so a caller
    /// that persists this must carry forward what it already had rather than blanking. An EMPTY result
    /// with a day is the real "nothing scored today" answer.
    ///
    /// Returns the analytics `Result` rather than any one drawing's point type, because two surfaces
    /// read it: the iOS widget, which maps it into its own `StressPoint`, and the Today host card,
    /// which hands `timeline` straight to `DaytimeLoadLine`. Keeping the widget's type here would have
    /// kept this file iOS-only, and the Today card is shared with macOS.
    @MainActor
    static func today(repo: Repository, now: Date = Date(),
                      calendar: Calendar = .current) async -> (result: DaytimeStress.Result, day: Int)? {
        let startOfDay = calendar.startOfDay(for: now)
        let from = Int(startOfDay.timeIntervalSince1970)
        let to = Int(now.timeIntervalSince1970)
        let day = localDayNumber(now, calendar: calendar)

        guard let fingerprint = await repo.hrFingerprint(from: from, to: to) else { return nil }
        // Same day, same heart rate: nothing can have changed the score, so nothing is read. The day is
        // part of the check because a fingerprint that happened to match across midnight would otherwise
        // serve yesterday's curve as today's.
        if let memo, memo.day == day, memo.count == fingerprint.count, memo.maxTs == fingerprint.maxTs {
            return (memo.result, day)
        }

        let hr = await repo.hrSamples(from: from, to: to, limit: 200_000)
        var scored: DaytimeStress.Result = .empty
        if hr.count >= DaytimeStress.minHourHRSamples {
            let rr = await repo.rrIntervals(from: from, to: to, limit: 200_000)
            // Wrist accelerometer for the motion gate, so an ambulatory hour reads as exertion rather
            // than as stress. Empty on hardware or imports without gravity, which degrades to no masking
            // exactly as the screen does.
            let gravity = await repo.gravitySamplesUnion(from: from, to: to, limit: 200_000)
            let tz = TimeZone.current.secondsFromGMT(for: now)
            // Scored OFF the main actor. `Repository` is `@MainActor`, so without this hop a day's worth
            // of hours would be bucketed and averaged on the main thread — and unlike the Stress screen,
            // which does this because the user asked for it and is waiting, this runs unprompted when
            // the app becomes active and after every Health sync, which is exactly when the UI is busy.
            // The Kotlin twin gets this for free by living in a coroutine; here it has to be asked for.
            // The samples are plain value structs, so the hop retains rather than copies them.
            // The half-step display series is asked for here (`includeTimeline`), because both readers
            // draw a curve. Nothing downstream of this counts hours, so the overlap is free.
            scored = await Task.detached(priority: .utility) {
                DaytimeStress.analyze(hr: hr, rr: rr, gravity: gravity,
                                      tzOffsetSeconds: tz, mode: .dayRelative,
                                      includeTimeline: true)
            }.value
        }
        // Too little signal leaves an EMPTY result, which is a real answer about today rather than a
        // refusal: a reader should drop yesterday's line rather than keep drawing it.
        memo = Memo(count: fingerprint.count, maxTs: fingerprint.maxTs, day: day, result: scored)
        return (scored, day)
    }

    /// Days since the epoch on the LOCAL calendar.
    ///
    /// RESTATED from `WidgetSnapshot.localDayNumber` rather than shared, because there is no module
    /// both readers can see: `WidgetSnapshot` lives in the iOS/widget sources, which the macOS app does
    /// not compile, and the widget extension links no packages, so it cannot reach this file either.
    ///
    /// The two MUST agree. The widget stores the day this returns and later compares it against
    /// `WidgetSnapshot.localDayNumber` to decide whether the stored curve is still today's, so a
    /// divergence would silently drop a valid curve. `HostedCardPrefsTests` pins them equal from the
    /// app target, which can see both.
    ///
    /// Counted by the calendar rather than by dividing by 86 400, because that arithmetic is wrong on a
    /// DST day: `Europe/London` produces one day a year whose number would equal the previous day's.
    static func localDayNumber(_ date: Date, calendar: Calendar = .current) -> Int {
        let epoch = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        return calendar.dateComponents([.day], from: epoch,
                                       to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// Drops the memo so a test starts from a known state.
    @MainActor
    static func resetForTest() { memo = nil }
}
