import Foundation

/// Counters for what the home-screen widgets cost, so "the widget drains my battery" is decidable
/// from an export instead of being argued from the code.
///
/// Twin of Android's `WidgetTelemetry`, and deliberately only HALF of it. The push accounting maps
/// one to one — `HRPublishThrottle` gates, `saveAndReloadIfChanged` either reloads or declines — so
/// the same four outcomes exist here and are worth the same counters. The bitmap accounting does not
/// map at all: this widget draws a SwiftUI `Path` inside the extension, with no bitmap and no Binder
/// transaction, so draws, bytes and MB/h would be measuring something that does not happen.
///
/// One cost is iOS-ONLY and is the reason this is worth having rather than merely symmetrical.
/// WidgetKit budgets timeline reloads, and spending the budget does not cost battery — it makes the
/// widget go STALE, which is a correctness failure the user sees. A reloads-per-hour figure is the
/// only way to know how close the app runs to that ceiling, and nothing has ever measured it.
///
/// Process-lifetime, reset when the process dies, reported as a rate over the steady window so a
/// short session and a long one are comparable. Not persisted: writing to disk on every publish to
/// measure the cost of publishing would be its own answer to the question.
public enum WidgetTelemetry {

    /// How long after the first publish to ignore before the rates start counting.
    ///
    /// The snapshot's fields populate one after another at launch and each is a content change that
    /// publishes immediately, so a launch produces a burst that the once-a-minute HR throttle has
    /// nothing to do with. An Android capture reported six pushes in a hundred seconds as 215/h
    /// against a steady state of about sixty; the same shape applies here.
    private static let warmup: TimeInterval = 60

    private static let lock = NSLock()
    private static var startedAt: Date?
    private static var steadyStartedAt: Date?
    private static var offered = 0
    private static var gated = 0
    private static var admitted = 0
    private static var reloaded = 0
    private static var declined = 0
    private static var steadyReloads = 0
    private static var noWidget = 0
    private static var steadyNoWidget = 0
    private static var installedKnown: Bool?

    /// A publish that `HRPublishThrottle` let through.
    public static func noteAdmitted(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        if startedAt == nil { startedAt = now }
        offered += 1
        admitted += 1
        if let started = startedAt, now.timeIntervalSince(started) >= warmup, steadyStartedAt == nil {
            steadyStartedAt = now
        }
    }

    /// A publish the throttle dropped. At live-HR cadence this should dwarf the admitted count.
    public static func noteGated(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        if startedAt == nil { startedAt = now }
        offered += 1
        gated += 1
    }

    /// A publish that actually asked WidgetKit for a new timeline. THE figure that matters here: this
    /// is what spends the reload budget.
    public static func noteReloaded(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        reloaded += 1
        if steadyStartedAt != nil { steadyReloads += 1 }
    }

    /// A publish that persisted but declined the reload, because nothing a widget renders had changed
    /// (or only the trace advanced, which the next timeline picks up anyway).
    public static func noteDeclined() {
        lock.lock(); defer { lock.unlock() }
        declined += 1
    }

    /// A reload asked for with no widget installed to receive it.
    ///
    /// Android learned this the hard way: an export taken with the widget REMOVED is half of the
    /// comparison that answers whether the widget costs anything, and counting these as reloads made
    /// both halves read alike. iOS never checks whether a widget is placed before calling
    /// `reloadAllTimelines`, so without this the same figure would be just as blind here.
    public static func noteNoWidget() {
        lock.lock(); defer { lock.unlock() }
        noWidget += 1
        if steadyStartedAt != nil { steadyNoWidget += 1 }
    }

    /// Record what WidgetKit says about installed widgets. Refreshed on the async publish paths, which
    /// is the only place an `await` is available; the synchronous live path reads the last answer.
    ///
    /// Nil means never asked, and nil counts as INSTALLED at the call site. Unknown must not be able to
    /// invent a saving that was never made — over-reporting reloads is the safe direction for a figure
    /// whose purpose is to show a cost.
    public static func noteWidgetsInstalled(_ installed: Bool) {
        lock.lock(); defer { lock.unlock() }
        installedKnown = installed
    }

    /// The last known answer, defaulting to true. See [noteWidgetsInstalled].
    public static var widgetsInstalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return installedKnown ?? true
    }

    public static func snapshot(now: Date = Date()) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(
            uptime: startedAt.map { now.timeIntervalSince($0) } ?? 0,
            steady: steadyStartedAt.map { now.timeIntervalSince($0) } ?? 0,
            offered: offered,
            gated: gated,
            admitted: admitted,
            reloaded: reloaded,
            declined: declined,
            noWidget: noWidget,
            steadyReloads: steadyReloads,
            steadyNoWidget: steadyNoWidget
        )
    }

    public static func resetForTest() {
        lock.lock(); defer { lock.unlock() }
        startedAt = nil; steadyStartedAt = nil
        offered = 0; gated = 0; admitted = 0; reloaded = 0; declined = 0; steadyReloads = 0
        noWidget = 0; steadyNoWidget = 0; installedKnown = nil
    }

    public struct Snapshot: Sendable, Equatable {
        public let uptime: TimeInterval
        public let steady: TimeInterval
        public let offered: Int
        public let gated: Int
        public let admitted: Int
        public let reloaded: Int
        public let declined: Int
        public let noWidget: Int
        public let steadyReloads: Int
        public let steadyNoWidget: Int

        /// A rate is only quoted once the steady window is long enough to mean something. Five minutes
        /// of ordinary running is a handful of one-a-minute publishes; less is arithmetic.
        private var steadyEnough: Bool { steady >= 5 * 60 }

        /// Timeline reloads per hour, over the steady window.
        ///
        /// Reloads and not publishes, because a publish that declined the reload cost nothing and
        /// spent none of the budget. Counting those would make this figure unable to fall when the
        /// dedup in `saveAndReloadIfChanged` did its job, which is the one thing it is for.
        ///
        /// A reload asked for with no widget installed is not counted here either — it is recorded as
        /// [noWidget] instead of as a reload, so this figure never claims a cost that had nowhere to
        /// land.
        ///
        /// Elapsed WALL-CLOCK time is the denominator, not time spent streaming: the ceiling this runs
        /// against is expressed per hour of real time, as is a battery question.
        public var reloadsPerHour: Double? {
            guard steadyEnough, steady > 0 else { return nil }
            return Double(steadyReloads) * 3600 / steady
        }

        /// One line for the diagnostics header, matching the Android wording so two exports from the
        /// same household read the same way.
        public func render() -> String {
            guard offered > 0 else { return "Widgets:     no publishes this app session" }
            var parts: [String] = ["\(reloaded) reloaded / \(admitted) admitted / \(offered) offered"]
            if let rate = reloadsPerHour {
                parts.append(String(format: "%.1f/h", rate))
            }
            if declined > 0 { parts.append("\(declined) unchanged") }
            if noWidget > 0 { parts.append("\(noWidget) with no widget installed") }
            let mins = Int(uptime / 60)
            let span = steadyEnough
                ? "over \(mins)m"
                : "over \(mins)m, steady \(Int(steady / 60))m of 5m"
            return "Widgets:     " + parts.joined(separator: " · ") + " (\(span))"
        }
    }
}
