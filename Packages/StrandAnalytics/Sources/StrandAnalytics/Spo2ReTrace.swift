import Foundation

// Spo2ReTrace.swift - the Connection-mode SpO2 reverse-engineering dump (PR #945, reimplemented).
//
// WHOOP 4.0 has the Blood O2 sensor and the historical decode already maps the raw red/IR PPG channels
// (spo2_red@68 / spo2_ir@70 on the v24 layout), but NOOP nulls spo2Pct for WHOOP on purpose: computing a
// calibrated % from the raw ADC needs the dense dual-wavelength waveform plus WHOOP's proprietary
// calibration curve, and guessing it would manufacture a plausible-but-wrong health number - the exact
// trap that withdrew the #194 PPG->HR attempt. The ONLY honest path to a reliable value is to find out
// whether the strap already BANKS a computed SpO2 in a record field we have not mapped.
//
// So this dumps a handful of FULL historical records (hex) alongside their mapped SpO2 channels, log-only
// and gated behind the Test Centre Connection mode, so an offline pass can correlate a byte (or the
// red/IR pair) against the SpO2 % the WHOOP app shows for the same nights. Records dump whether or not
// they carry SpO2 channels, so "the strap banks nothing" is provable too - in which case the honest
// outcome is a capability label, never a fabricated number. NO user-facing SpO2 value comes from this.
//
// Pure formatter: no I/O, no state, no em-dashes, no PII (a record is sensor payload; the serial never
// rides in it). The Kotlin twin is Spo2ReTrace.kt; the emitted line is byte-identical on both platforms.
public enum Spo2ReTrace {

    /// Max records dumped per offload session, across all layout versions. A handful is enough for an
    /// offline correlation pass and keeps the strap log bounded; the Backfiller counter spans chunks and
    /// resets per session.
    public static let maxSamples = 12

    /// Max records dumped per DISTINCT layout version, so the budget cannot be spent entirely on the
    /// layout we already understand.
    ///
    /// The dump used to take the first `maxSamples` decodable records in arrival order. On a strap that
    /// emits a dominant layout plus a rarer one, that spends the whole budget inside the first chunk on
    /// the dominant layout — and the rare one is precisely the one still unmapped. The log would then
    /// announce "historical records use layout vN" while carrying no bytes of vN at all: proof a thing
    /// exists, with no material to work on it. Stratifying guarantees every layout the strap emits gets
    /// samples, including one at 1% of traffic, and stops re-dumping a layout already at parity.
    public static let maxPerVersion = 3

    /// Max records this dump may EXAMINE per session, separate from how many it may dump.
    ///
    /// The dump budget alone stopped bounding the work the moment `maxPerVersion` arrived: the loop's
    /// outer guard counts DUMPS, so on a strap emitting one layout the per-version cap is reached at 3,
    /// the dump count sticks below `maxSamples` forever, and every later chunk keeps re-examining every
    /// frame to rediscover a version already at cap.
    ///
    /// Costs Apple far less than Android, which re-decodes each frame here while this side reads the
    /// already-parsed record. It is applied on BOTH so the two platforms examine the same frames and so
    /// dump the same records: a budget on one side only would silently diverge the two logs on a long
    /// offload, which is the one thing this line's byte-identical promise cannot survive.
    public static let maxExamined = 512

    /// One record's RE line: the mapped SpO2 channels + timestamp + layout version, then the FULL frame
    /// hex (no prefix cap - a v24 record is ~84 B and the unmapped tail is exactly where a banked SpO2
    /// would sit). Absent channels render "null" so a channel-less record still proves what it lacks.
    /// Takes already-extracted ints (ConnectionTrace's primitive style) so this package stays free of a
    /// WhoopProtocol dependency; the caller reads them off its parsed frame.
    public static func recordLine(frame: [UInt8], version: Int?, unix: Int?,
                                  red: Int?, ir: Int?, skinRaw: Int?) -> String {
        let hex = frame.map { String(format: "%02x", $0) }.joined()
        func f(_ v: Int?) -> String { v.map(String.init) ?? "null" }
        return "spo2re v=\(f(version)) unix=\(f(unix)) red=\(f(red)) ir=\(f(ir)) "
            + "skinRaw=\(f(skinRaw)) len=\(frame.count) raw=\(hex)"
    }
}
