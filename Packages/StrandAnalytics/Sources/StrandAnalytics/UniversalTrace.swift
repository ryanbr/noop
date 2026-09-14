import Foundation

// UniversalTrace.swift - the lines that ride EVERY Test Centre export, not only in Connection mode.
//
// The dayOwner line (built in the app's IntelligenceEngine) already rides every export tagged `.universal`.
// This adds the strap CLOCK-DRIFT + firmware-layout picture to that universal block so the RTC cluster
// (#531 / #767 / #804 / #812) self-diagnoses on every export. Previously the clock-drift summary was only
// emitted while the Connection test mode was on (BLEManager, gated on TestCentre.active(.connection)), so a
// Sleep or Battery report from a clock-broken strap never carried the one line that explains the failure.
// Hoisting it to the universal block means ANY active mode surfaces it.
//
// Pure + side-effect-free: no clock read of its own, no I/O. The caller (the export assembler) passes the
// last strap-reported banked-record window and its own wall-now; this formats one line. No PII (ISO dates,
// counts and a firmware version int only). No em-dashes. Android's universal clock diagnostic is built by
// `ConnectionTrace.clockDriftLine` and emitted by `WhoopBleClient`; its firmware-layout line is separate,
// emitted by `Backfiller` only in Connection mode. Android has no single `UniversalTrace` declaration that
// combines them.

public enum UniversalTrace {

    /// The R-R transport line: what a device has banked versus what its unit policy can actually score.
    ///
    /// #2117: a WHOOP 5 window is pinned to one transport, and a window holding no beat on a scorable
    /// channel reads back EMPTY rather than falling back. Everything derived from beats then goes blank
    /// (HRV, respiratory rate) while heart-rate-derived values carry on, which is what a wearer reports
    /// as "HRV stopped working". The analyzer cannot explain it: handed nothing, it honestly says
    /// nInput=0 and has no way to know whether the strap banked nothing or banked beats the policy
    /// refused.
    ///
    /// These two facts separate those cases, and the store already computes both. Rides every export for
    /// the same reason the clock-drift line does: the wearer who needs it is the one who did not know to
    /// turn a mode on. Returns nil for a device the policy does not apply to, so a WHOOP 4 export is
    /// unchanged.
    ///
    /// Twin of Kotlin `ConnectionTrace.rrTransportLine`.
    public static func rrTransportLine(strictWhoop5: Bool,
                                       firstRecordedUnix: Int?,
                                       firstScorableUnix: Int?) -> String? {
        guard strictWhoop5 else { return nil }
        guard let firstRecordedUnix else { return "rrTransport recorded=none scorable=none" }
        let recorded = "recorded=\(ConnectionTrace.isoDate(firstRecordedUnix))"
        guard let firstScorableUnix else {
            // Beats on disk, none the policy will score: the whole history predates transport labelling
            // or sits on an excluded channel. This is the state that blanks every night at once.
            return "rrTransport \(recorded) scorable=none unscorableHistory=yes"
        }
        let gapDays = max(0, Int((Double(firstScorableUnix - firstRecordedUnix) / 86_400).rounded()))
        return "rrTransport \(recorded) scorable=\(ConnectionTrace.isoDate(firstScorableUnix)) "
            + "unscorableHistory=\(gapDays > 0 ? "yes" : "no") gapDays=\(gapDays)"
    }

    /// The universal strap-clock line: the strap's newest banked-record timestamp vs wall clock, with a
    /// FUTURE-DATE flag (the tell of a wandering / un-clocked RTC), the optional banked span in days, and the
    /// firmware record-layout version the strap hands over. One line, tagged `.universal` by the caller, so
    /// every export self-diagnoses the clock/firmware state behind the #531/#767/#804/#812 cluster.
    ///
    /// All timestamps are unix seconds in the same wall domain (the BLE layer decodes oldest/newest from the
    /// strap's GET_DATA_RANGE reply and the caller passes its own wall-now), so the future test is a plain
    /// comparison. `oldestUnix` is optional (a short range reply gives only the upper bound). `firmwareLayout`
    /// is the historical record-layout version (18/24/25/26) the strap emits, or nil when not yet observed
    /// this session; it is reported as "v<n>" or "unknown" so the line is always firmware-aware.
    ///
    /// - Parameter futureToleranceSeconds: slack before flagging FUTURE; a strap RTC vs phone skew of a
    ///   minute or two is normal, so the default mirrors a couple of minutes.
    /// - Parameter behindToleranceSeconds: slack before flagging a BEHIND drift (#990) - a newest banked
    ///   record naturally trails wall time by hours, so the default is 48 h; beyond that "clockOk" was a
    ///   false all-clear (a -363 d drift used to read clockOk).
    public static func clockDriftLine(newestUnix: Int,
                                      wallNowUnix: Int,
                                      oldestUnix: Int? = nil,
                                      firmwareLayout: Int? = nil,
                                      futureToleranceSeconds: Int = 120,
                                      behindToleranceSeconds: Int = ConnectionTrace.behindToleranceDefault) -> String {
        let aheadSeconds = newestUnix - wallNowUnix
        var line = "strapClock newest=\(ConnectionTrace.isoDate(newestUnix)) "
            + "wall=\(ConnectionTrace.isoDate(wallNowUnix)) "
            + "newestVsWall=\(ConnectionTrace.signed(aheadSeconds))s"
        if let oldestUnix, oldestUnix < newestUnix {
            // Round to the nearest whole day so a near-3-day window reads spanDays=3, not 2 (60s shy
            // of exactly three days should still report three days of banked history).
            let spanDays = max(0, Int((Double(newestUnix - oldestUnix) / 86_400).rounded()))
            line += " oldest=\(ConnectionTrace.isoDate(oldestUnix)) spanDays=\(spanDays)"
        }
        line += firmwareLayout.map { " firmware=v\($0)" } ?? " firmware=unknown"
        // The verdict is SHARED with ConnectionTrace.clockDriftLine (#990/#987) so the universal and
        // Connection lines can never disagree about what counts as a clock fault: FUTURE-DATED,
        // RTC-EPOCH (~1970/71 never-set clock), CLOCK-WARNING (behind beyond +-48 h), else clockOk.
        line += ConnectionTrace.clockVerdict(aheadSeconds: aheadSeconds, newestUnix: newestUnix,
                                             futureToleranceSeconds: futureToleranceSeconds,
                                             behindToleranceSeconds: behindToleranceSeconds)
        return line
    }
}
