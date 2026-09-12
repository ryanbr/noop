import Foundation
import WhoopProtocol
import WhoopStore

/// Pure helper: correlate the strap's monotonic device clock to wall time.
/// REALTIME_DATA timestamps are a device monotonic epoch; the server/app maps them to
/// unix time using the (device, wall) pair captured at connect via GET_CLOCK + now.
/// No CoreBluetooth, no I/O — fully unit-testable.
enum ClockCorrelation {
    /// Build a `ClockRef` from a decoded GET_CLOCK COMMAND_RESPONSE frame and the wall
    /// time observed when the response arrived. Returns nil unless the frame is INTACT and carries a
    /// `clock` value.
    ///
    /// `ok` is the verifier's full verdict — header checksum, payload CRC32 and structural length
    /// together — so one condition now covers what the two-part check used to. The stake is why this
    /// gate is worth stating plainly: the anchor set here converts every live device timestamp into wall
    /// time, and until it is set the Collector and the Backfiller both hold their rows. An anchor taken
    /// from a damaged frame does not block persistence, it timestamps everything wrongly, which is worse
    /// — so an unverifiable frame leaves the anchor unset and the downstream storage blocked.
    ///
    /// The `crcOK` condition is kept for parse results that did not come from a fresh parse: a
    /// `ParsedFrame` decoded from a capture written before the verdict widened carries the old constant
    /// `ok: true` beside a false `crcOK`.
    static func clockRef(from parsed: ParsedFrame, wall: Int) -> ClockRef? {
        guard parsed.ok, parsed.crcOK != false,
              let device = parsed.parsed["clock"]?.intValue else { return nil }
        return ClockRef(device: device, wall: wall)
    }
}
