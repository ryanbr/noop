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
/// SCORING MODE. Background callers keep the `.dayRelative` default: resolving the personal lens reads
/// trailing days of heart rate, which a foreground screen can afford and an unprompted publish cannot.
/// Today's hosted card passes its selected foreground lens explicitly, so it agrees with Stress detail;
/// the home-screen widget does not opt in and remains a deliberately cheaper background surface.
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
        let personalBaseline: Bool
        let result: DaytimeStress.Result
    }

    /// ONE SLOT PER LENS, not one slot carrying the lens.
    ///
    /// The lens became part of the memo's identity so an unchanged heart-rate fingerprint could not
    /// replay one surface's curve into the other. With a single slot that is correct and useless: the
    /// background publishers ask with the default lens and Today asks with the selected one, so when the
    /// toggle is on each call evicts the other's entry and every call misses whatever the fingerprint
    /// says. Today re-asks on a timer, so the trailing-history read the fingerprint gate exists to avoid
    /// was being paid on essentially every tick. Keyed by lens, each surface keeps its own gate.
    @MainActor private static var memos: [Bool: Memo] = [:]

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
                      calendar: Calendar = .current,
                      personalBaseline: Bool = false) async -> (result: DaytimeStress.Result, day: Int)? {
        let startOfDay = calendar.startOfDay(for: now)
        let from = Int(startOfDay.timeIntervalSince1970)
        let to = Int(now.timeIntervalSince1970)
        let day = localDayNumber(now, calendar: calendar)

        guard let fingerprint = await repo.hrFingerprint(from: from, to: to) else { return nil }
        // Same day, same heart rate: nothing can have changed the score, so nothing is read. The day is
        // part of the check because a fingerprint that happened to match across midnight would otherwise
        // serve yesterday's curve as today's.
        // Foreground Today and the widget publisher can call in either order. Include the requested
        // lens so an unchanged HR fingerprint can never replay one surface's result into the other.
        if let memo = memos[personalBaseline], memo.day == day,
           memo.count == fingerprint.count, memo.maxTs == fingerprint.maxTs {
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
            let mode = await DaytimeStressMode.selected(
                repo: repo,
                startOfToday: startOfDay,
                calendar: calendar,
                personalBaseline: personalBaseline
            )
            // Scored OFF the main actor. `Repository` is `@MainActor`, so without this hop a day's worth
            // of hours would be bucketed and averaged on the main thread — and unlike the Stress screen,
            // which does this because the user asked for it and is waiting, this runs unprompted when
            // the app becomes active and after every Health sync, which is exactly when the UI is busy.
            // The Kotlin twin does NOT get this for free, which this comment used to claim. A coroutine
            // runs on whatever dispatcher it inherits, and a LaunchedEffect body inherits the main one,
            // so Android was scoring a day of samples on its UI thread until the producer was given an
            // explicit Dispatchers.Default of its own. Both sides now ask for the hop; neither is
            // handed it by its concurrency model.
            // The samples are plain value structs, so the hop retains rather than copies them.
            // The half-step display series is asked for here (`includeTimeline`), because both readers
            // draw a curve. Nothing downstream of this counts hours, so the overlap is free.
            // #2181: `runUnescalated`, not an awaited detached task. This caller is @MainActor, and
            // awaiting a task hands it the caller's priority, so the `.utility` here used to be a label
            // rather than a behaviour: the hop off the main actor was real, but the scoring then raced
            // the UI for cores at the UI's own quality of service. This runs unprompted on activation
            // and after every Health sync, exactly when the UI is busy, so it must yield.
            scored = await runUnescalated {
                DaytimeStress.analyze(hr: hr, rr: rr, gravity: gravity,
                                      tzOffsetSeconds: tz, mode: mode,
                                      includeTimeline: true)
            }
        }
        // Too little signal leaves an EMPTY result, which is a real answer about today rather than a
        // refusal: a reader should drop yesterday's line rather than keep drawing it.
        memos[personalBaseline] = Memo(count: fingerprint.count, maxTs: fingerprint.maxTs, day: day,
                                       personalBaseline: personalBaseline, result: scored)
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

    /// Drops both memo slots so a test starts from a known state.
    @MainActor
    static func resetForTest() { memos.removeAll() }
}
