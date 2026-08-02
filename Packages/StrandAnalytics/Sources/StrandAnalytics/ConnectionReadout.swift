import Foundation

// ConnectionReadout.swift - pure values + line formatters for the Connection & Sync test mode.
//
// ConnectionTrace builds the upfront diagnostic lines the Connection emitters write: the CLOCK-DRIFT
// summary (the strap-reported banked-record range vs wall clock, with a future-date flag, promoted from
// the buried raw GET_DATA_RANGE frames to one summary line), the firmware-layout line, and the
// no-cursor / trim sentinel line. ConnectionReadout parses the tagged log tail back into the three
// liveReadout ids the in-app panel binds (connectionUptime, reconnectCount, lastOffloadResult).
//
// Everything here is pure and side-effect-free (no clock read of its own, no I/O), so a fixture pins the
// exact lines and the BLE layer simply gates the call behind TestCentre.active(.connection). No PII -
// counts, durations and ISO dates only. No em-dashes. The Kotlin twin is ConnectionReadout.kt.

public enum ConnectionTrace {
    /// The ` after <n>s` suffix on a `connect down` trace line, or empty when the session start is
    /// unknown (#1020).
    ///
    /// A session's length separates the causes of a drop at a glance: a bond watchdog fires seconds in,
    /// a keep-alive stall bounce minutes in, a radio drop anywhere. The bare `connect down (uptime ends)`
    /// could not distinguish them, which is why a report of thousands of reconnects needed a round trip
    /// before anyone could start on it.
    ///
    /// An unknown start yields NO suffix rather than `after 0.0s` — "instant drop" and "we do not know"
    /// are different diagnoses. Locale-fixed so a decimal comma cannot follow the phone language into a
    /// log people paste into issues. Twin of the Kotlin `ConnectionTrace.sessionHeldSuffix`.
    public static func sessionHeldSuffix(millis: Int) -> String {
        guard millis >= 0 else { return "" }
        return " after " + String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"),
                                  Double(millis) / 1000.0) + "s"
    }


    /// The CLOCK-DRIFT summary line (#767 / #754 cluster): the strap-reported banked-record window
    /// [oldest, newest] against the wall clock, with a FUTURE-DATE flag when the strap's newest record is
    /// dated ahead of wall-now (the tell of a wandering / un-clocked strap). Promoted from the buried raw
    /// GET_DATA_RANGE frames to one upfront `.connection` line so a clock-broken strap is visible at a
    /// glance rather than only via the per-record drop diagnostics.
    ///
    /// All three timestamps are unix seconds in the SAME wall domain (the caller decodes oldest/newest
    /// from the strap's GET_DATA_RANGE reply and passes its own wall-now), so the future-date test is a
    /// plain comparison: `newest > wallNow + tolerance`. `oldest` is optional (a half/short range reply
    /// gives only the upper bound). The span is reported in days for the backlog-depth read.
    ///
    /// - Parameter futureToleranceSeconds: slack before flagging FUTURE (clock skew between the strap RTC
    ///   and the phone is normal up to a minute or two); the default mirrors a couple of minutes.
    /// - Parameter behindToleranceSeconds: slack before flagging a BEHIND drift (#990). A newest banked
    ///   record naturally trails wall time by hours (unworn strap, backlog), so the default is 48 h;
    ///   beyond that the old line claimed "clockOk" at -363 days, hiding the exact clock fault the
    ///   reporter needed to see.
    public static func clockDriftLine(oldestUnix: Int?,
                                      newestUnix: Int,
                                      wallNowUnix: Int,
                                      futureToleranceSeconds: Int = 120,
                                      behindToleranceSeconds: Int = behindToleranceDefault) -> String {
        let iso = isoDate(newestUnix)
        let aheadSeconds = newestUnix - wallNowUnix
        var line = "clockDrift newest=\(iso) wall=\(isoDate(wallNowUnix)) "
            + "newestVsWall=\(signed(aheadSeconds))s"
        if let oldestUnix {
            let spanDays = max(0, (newestUnix - oldestUnix)) / 86_400
            line += " oldest=\(isoDate(oldestUnix)) spanDays=\(spanDays)"
        }
        line += clockVerdict(aheadSeconds: aheadSeconds, newestUnix: newestUnix,
                             futureToleranceSeconds: futureToleranceSeconds,
                             behindToleranceSeconds: behindToleranceSeconds)
        return line
    }

    // MARK: - Strap-clock verdict (shared by clockDriftLine + UniversalTrace.clockDriftLine, #990/#987)

    /// 1972-01-01 unix. A strap RTC that was never set counts up from its 1970 epoch, so any strap-side
    /// timestamp below this ceiling means "the clock never latched" (the #77/#91/#987 cluster tell:
    /// the strap banks nothing to flash until its clock is set). Public so the readout warning (#987)
    /// and the export line share ONE definition of "epoch-era".
    public static let rtcEpochCeilingUnix = 63_072_000

    /// The default BEHIND drift tolerance (#990): ±48 h. Being a day or two behind is a strap that
    /// simply was not worn; beyond that the line must read as a clock warning, never "clockOk".
    public static let behindToleranceDefault = 48 * 3_600

    /// The strap-clock VERDICT token both clock-drift lines end with. One function so the Connection
    /// and the universal line can never disagree about what counts as a clock fault. Ordered most
    /// specific first: FUTURE (RTC ahead), RTC-EPOCH (never set, ~1970/71), CLOCK-WARNING (behind by
    /// more than the tolerance, #990: a -363 d drift used to read "clockOk"), else clockOk. Honest
    /// wording on the behind case: a reset clock and a long-unworn strap look identical from here, so
    /// the line names both instead of guessing.
    static func clockVerdict(aheadSeconds: Int, newestUnix: Int,
                             futureToleranceSeconds: Int, behindToleranceSeconds: Int) -> String {
        if aheadSeconds > futureToleranceSeconds { return " FUTURE-DATED (strap clock ahead of wall)" }
        if newestUnix < rtcEpochCeilingUnix {
            return " RTC-EPOCH (strap clock reads 1970/71, never set; charge to 100% and reconnect so it latches)"
        }
        if aheadSeconds < -behindToleranceSeconds {
            let days = -aheadSeconds / 86_400
            return " CLOCK-WARNING (newest banked record \(days)d behind wall; strap clock reset or history stale)"
        }
        return " clockOk"
    }

    /// The firmware-layout line for a HEALTHY sync: which historical record layout the strap emits
    /// (v18/v24/v25/v26). Surfaced once per distinct version so the connection report always reveals the
    /// firmware the strap hands over, not only when NOOP cannot decode it.
    public static func firmwareLine(version: Int, decodable: Bool) -> String {
        "firmware layout=v\(version) \(decodable ? "decodable" : "UNMAPPED (no motion/HR decoded)")"
    }

    /// The trim / no-cursor sentinel line: the strap reported trim=0xFFFFFFFF, its "no valid flash cursor"
    /// marker, so it has no banked history to offload (a clock/charge state, not a decode bug).
    public static func noCursorLine() -> String {
        "offload trim=0xFFFFFFFF noCursor (strap has no banked history to offload)"
    }

    /// Compact ISO-8601 date-time (no fractional seconds), UTC, for the strap-record timestamps. UTC keeps
    /// the line stable across the tester's timezone so a shared report reads identically everywhere.
    static func isoDate(_ unix: Int) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime]
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    /// Sign-prefixed integer so the newest-vs-wall delta reads as a signed offset ("+30" / "-3600").
    static func signed(_ n: Int) -> String { n >= 0 ? "+\(n)" : "\(n)" }
}

/// Pure values for the Connection & Sync live-readout panel. Each parses the `.connection`-tagged log
/// tail the Connection emitters write, so the panel reflects exactly the live link state without the
/// BLE layer having to expose new published properties. No state, no side effects, no em-dashes. The
/// Kotlin twin is the ConnectionReadout object in ConnectionReadout.kt.
public enum ConnectionReadout {

    /// Connection uptime for the readout's `connectionUptime` id. The connect emitter writes
    /// "[connection] connect ... uptimeStart=<unix>" at the instant the link comes up and clears it on
    /// disconnect, so the most recent connect-or-disconnect line tells us whether we are up and since
    /// when. `nowUnix` is injected so the readout is testable without a live clock. Returns a short
    /// human label ("3m 12s" / "not connected").
    public static func uptimeLabel(taggedTail: [String], nowUnix: Int) -> String {
        for line in taggedTail.reversed() {
            if line.contains("connect down") { return "not connected" }
            if let start = intField(line, key: "uptimeStart=") {
                let secs = max(0, nowUnix - start)
                return durationLabel(secs)
            }
        }
        return "not connected"
    }

    /// Reconnect count for the readout's `reconnectCount` id: the highest `reconnect n=<count>` seen in
    /// the tail this session (the reconnect-churn emitter increments it on each involuntary reconnect).
    /// 0 when no reconnect line is present.
    public static func reconnectCount(taggedTail: [String]) -> Int {
        var maxN = 0
        for line in taggedTail where line.contains("reconnect ") {
            if let n = intField(line, key: "n=") { maxN = max(maxN, n) }
        }
        return maxN
    }

    /// Last offload result for the readout's `lastOffloadResult` id: the most recent "offload result=<...>"
    /// fragment the offload-progress emitter writes (e.g. "complete rows=42 nights=2", "empty (console
    /// only)", "stalled (idle timeout)"). nil when no offload has finished this session.
    public static func lastOffloadResult(taggedTail: [String]) -> String? {
        for line in taggedTail.reversed() {
            if let r = line.range(of: "offload result=") {
                let frag = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !frag.isEmpty { return frag }
            }
        }
        return nil
    }

    /// Rows drained (persisted) THIS session, for the readout row beside the all-time tally (#990):
    /// the newest `sessionRows=<n>` running total the per-chunk offload-progress emitter writes, falling
    /// back to the final `offload result= ... rows=<n>` when the session already summarised. nil when no
    /// offload has drained anything this session.
    public static func sessionRows(taggedTail: [String]) -> Int? {
        for line in taggedTail.reversed() {
            // A finished session's result line wins (it is the newest line). An "empty (console only)"
            // result carries no rows= field and honestly means 0, NOT an older session's running total.
            if line.contains("offload result=") { return intField(line, key: "rows=") ?? 0 }
            if let n = intField(line, key: "sessionRows=") { return n }
        }
        return nil
    }

    /// #990: parse the Backfiller's session summary ("Backfill: session persisted N rows (...) across
    /// K night(s).") back into its row count, so the log sink can fold each session into the persisted
    /// ALL-TIME drained-rows tally. That summary is emitted UNCONDITIONALLY whenever rows landed (the
    /// #150 win-rate line), so the cumulative counter accrues on every session, not only while the
    /// Connection test mode is on. nil for any other line.
    public static func drainedRowsFromSummary(_ line: String) -> Int? {
        guard let r = line.range(of: "session persisted ") else { return nil }
        let rest = line[r.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(" rows") else { return nil }
        return Int(digits)
    }

    /// #987: the device-side clock value from the newest "Clock correlated: device=<d> wall=<w>" line
    /// the correlation path logs, or nil when no correlation happened this session. Parsed from the
    /// UNTAGGED log tail (correlation is not a test-mode emitter), so the caller passes the full log lines.
    public static func clockCorrelatedDevice(logLines: [String]) -> Int? {
        for line in logLines.reversed() where line.contains("Clock correlated:") {
            return intField(line, key: "device=")
        }
        return nil
    }

    /// #987/#261: the "clock latched" readout value. "yes" once EITHER signal lands with a plausible
    /// (post-1972) timestamp: a GET_CLOCK correlation (`deviceClockUnix`, the WHOOP4 path), or a
    /// GET_DATA_RANGE reply's newest banked record (`strapNewestUnix`, the fallback). "no (RTC reads
    /// 1970/71)" when whichever signal landed reads epoch-era; "no (waiting for the strap clock)" before
    /// either replies.
    ///
    /// A WHOOP 5/MG's GET_CLOCK reply rides the puffin notify channel and never reaches the WHOOP4-only
    /// correlation path that sets `deviceClockUnix` (see `BLEManager`'s connect-handshake comment) — its
    /// records carry absolute timestamps, so it never NEEDS that correlation to decode history. Without
    /// this fallback the row read "no (waiting for the strap clock)" forever on every 5/MG, even a fully
    /// working one, because the one signal it checked structurally never populates for that family. The
    /// data-range reply is an equal-weight proof the strap answered with a working clock, not a downgrade
    /// — `rtcWarning` below already trusts it the same way.
    public static func clockLatchedLabel(deviceClockUnix: Int?, strapNewestUnix: Int? = nil) -> String {
        if let d = deviceClockUnix {
            return d < ConnectionTrace.rtcEpochCeilingUnix ? "no (RTC reads 1970/71)" : "yes"
        }
        if let n = strapNewestUnix {
            return n < ConnectionTrace.rtcEpochCeilingUnix ? "no (RTC reads 1970/71)" : "yes"
        }
        return "no (waiting for the strap clock)"
    }

    /// #987: a plain-words warning when the strap RTC reads epoch-era (~1970/71), from EITHER signal we
    /// hold: the correlated device clock or the strap's newest banked-record timestamp. nil when both
    /// look sane (or neither was seen yet - we never fabricate a fault). One string, shown verbatim on
    /// the Devices / Test Centre connection readout, naming the consequence and the fix.
    public static func rtcWarning(deviceClockUnix: Int?, strapNewestUnix: Int?) -> String? {
        let ceiling = ConnectionTrace.rtcEpochCeilingUnix
        let clockBad = deviceClockUnix.map { $0 > 0 && $0 < ceiling } ?? false
        let newestBad = strapNewestUnix.map { $0 > 0 && $0 < ceiling } ?? false
        guard clockBad || newestBad else { return nil }
        return "Strap clock reads 1970/71 (never set since its last reset), so it is not banking history. "
            + "Charge the strap to 100% and reconnect so the clock latches."
    }

    /// #987: freshness label for the "last frame" readout row: how long ago the most recent strap frame
    /// was routed ("12s ago"), or "no frames yet" before the first one. `nowUnix` injected for testability.
    public static func lastFrameLabel(lastFrameUnix: Int?, nowUnix: Int) -> String {
        guard let t = lastFrameUnix else { return "no frames yet" }
        return durationLabel(max(0, nowUnix - t)) + " ago"
    }

    /// Parse a `key=<int>` field out of a line (the value runs up to the next space). nil when absent or
    /// non-numeric.
    static func intField(_ line: String, key: String) -> Int? {
        guard let r = line.range(of: key) else { return nil }
        let token = line[r.upperBound...].prefix { $0 != " " }
        return Int(token)
    }

    /// Short "Xm Ys" / "Xs" / "Xh Ym" duration label for the uptime readout.
    static func durationLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}
