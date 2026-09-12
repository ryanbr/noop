import Foundation

/// GET_DATA_RANGE frame parsing. Pure + byte-identical to the Kotlin twin `com.noop.protocol.DataRange`.
///
/// Extracted from `BLEManager`/`WhoopBleClient` (#286 follow-up): the newest-record read gates automatic
/// sync (`isFutureDatedNewest` → `BackfillPolicy`), so its value must stay byte-identical across platforms.
/// Living here means both a WhoopProtocol `swift test` and the Kotlin JVM test pin the parity — the app-target
/// copies were previously testable on the Kotlin side only.
public enum DataRange {
    /// The newest plausible unix time banked by the strap, from a GET_DATA_RANGE frame.
    ///
    /// Scans EVERY byte offset — the newest-record `u32` isn't on a fixed grid (it sits at byte offset 8 on
    /// WHOOP 4.0, off the old aligned-from-7 scan, which straddled it and returned nil). Keeps the newest
    /// word inside a plausible unix window (2023-11…2030-03), preferring the newest that is NOT implausibly
    /// future (> `wallNowUnix + futureSkewSeconds`) so a garbage future word can't latch and stall auto-sync
    /// (#451/#928/#1012). Falls back to the newest-any word so a genuinely future-dated RTC is still surfaced
    /// downstream and the future-date guard still fires. Returns nil only for a too-short frame or no
    /// plausible word at all.
    public static func newestUnix(from frame: [UInt8], wallNowUnix: Int, futureSkewSeconds: Int) -> Int? {
        guard frame.count >= 4 else { return nil }
        let futureCutoff = wallNowUnix + futureSkewSeconds
        var newestNotFuture: Int? = nil
        var newestAny: Int? = nil
        var i = 0
        while i + 4 <= frame.count {
            let w = Int(frame[i]) | Int(frame[i + 1]) << 8 | Int(frame[i + 2]) << 16 | Int(frame[i + 3]) << 24
            if w >= 1_700_000_000 && w <= 1_900_000_000 {
                newestAny = max(newestAny ?? 0, w)
                if w <= futureCutoff { newestNotFuture = max(newestNotFuture ?? 0, w) }
            }
            i += 1
        }
        return newestNotFuture ?? newestAny
    }

    /// The OLDEST plausible unix time banked by the strap (start of stored history), from a GET_DATA_RANGE
    /// frame — the low end of the banked span (oldest…newest = the backlog DEPTH a deep oldest-first drain
    /// must cover before recent nights land, #364).
    ///
    /// Unlike `newestUnix`, this scans ONLY the 4-byte grid aligned from offset 7, NOT every offset — and
    /// that asymmetry is DELIBERATE. The minimum is fragile in a way the maximum is not: an any-offset scan
    /// of a real WHOOP 4.0 frame surfaces a spurious straddle word (offset 6 → 1_754_857_506, ~11 months
    /// *before* the true newest at offset 8) that would hijack the min and report a bogus deep backlog. The
    /// max is immune — the real newest dominates it — which is exactly why `newestUnix` can scan every offset.
    /// The aligned grid skips that straddle, so real frames with no distinct oldest word return nil here.
    /// Do NOT "make this consistent with `newestUnix`" by scanning every offset without anchoring — see
    /// `DataRangeTests.testOldestAlignedScanSkipsTheSpuriousOffset6Straddle`.
    public static func oldestUnix(from frame: [UInt8]) -> Int? {
        guard frame.count > 7 else { return nil }
        var oldest: Int? = nil
        var i = 7
        while i + 4 <= frame.count {
            let w = Int(frame[i]) | Int(frame[i + 1]) << 8 | Int(frame[i + 2]) << 16 | Int(frame[i + 3]) << 24
            if w >= 1_700_000_000 && w <= 1_900_000_000 { oldest = min(oldest ?? .max, w) }
            i += 4
        }
        return oldest
    }

    /// #689/#815: the ring-buffer page backlog ("pages behind") the strap reports in a GET_DATA_RANGE
    /// response — DIAGNOSTIC ONLY (feeds a future sync-progress UI, never gates sync or backfill itself).
    /// Confirmed against real captures on both WHOOP 4.0 (#791) and 5.0/MG (#815): the write/read pointers
    /// and ring capacity below all landed exactly where this predicts, across four independent frames.
    ///
    /// The app reads three u32s from the command-response INNER payload (whose byte 0 is a subtype), at
    /// `V(i) = word @ (i*4 + 3)`: write pointer `W = V(2)`, read pointer `U = V(3)`, ring capacity `T = V(5)`.
    /// The inner payload starts at `cmdOff + 1`, so those words sit at frame offsets `cmdOff + 12/16/24`
    /// here. Read u32 LITTLE-endian to match the frame's other words. Backlog with wraparound (unverified —
    /// no real capture has crossed it yet, but harmless to ship since this only ever feeds a diagnostic):
    /// `W < U ? W + (T - U) : W - U`. `T` has been `131072` in every real capture so far (both families) but
    /// is still read from the frame each time rather than hardcoded, in case a firmware revision differs.
    ///
    /// Returns nil for a too-short frame or implausible values — a capacity that is 0 or above a sane
    /// ceiling (a misaligned read hitting a timestamp / `0xFFFFFFFF`), a pointer at/beyond capacity, or a
    /// backlog past capacity — so a garbage frame can never log a nonsense number.
    public static func pagesBehind(from frame: [UInt8], cmdOff: Int) -> Int? {
        guard cmdOff >= 0 else { return nil }
        let payloadOffset = cmdOff + 1
        let wOff = payloadOffset + 11, uOff = payloadOffset + 15, tOff = payloadOffset + 23
        guard tOff + 4 <= frame.count else { return nil }
        func u32(_ o: Int) -> Int {
            Int(frame[o]) | Int(frame[o + 1]) << 8 | Int(frame[o + 2]) << 16 | Int(frame[o + 3]) << 24
        }
        let w = u32(wOff), u = u32(uOff), t = u32(tOff)
        guard t > 0, t <= 0x00FF_FFFF, w < t, u < t else { return nil }
        let behind = w < u ? w + (t - u) : w - u
        guard behind >= 0, behind <= t else { return nil }
        return behind
    }

    /// The BLE seam's decision on a GET_DATA_RANGE COMMAND_RESPONSE: is this a reply to `opcode`, and
    /// may it move state? A reply is accepted only on the verifier's FULL verdict.
    ///
    /// This one reply does not merely report a timestamp: `newestUnix`/`oldestUnix` become the window
    /// every drained record of the same sync is checked against (#547). A damaged reply that narrows
    /// the window makes the real records fall through it — the section persists nothing and is acked
    /// anyway, which is the permanent loss the integrity gate exists to stop. So the gate belongs to
    /// this decision, not to the seam that happens to host it: as a predicate it is testable off the
    /// app target, where nothing compiles the seam.
    ///
    /// `verdictOK` is the FULL verdict of the single parse the caller already holds, taken lazily so a
    /// frame that is not this reply costs one byte compare and no parse. The opcode is passed in rather
    /// than restated here: the command table lives with the caller.
    public static func acceptsReply(_ frame: [UInt8], cmdOff: Int, opcode: UInt8,
                                    verdictOK: @autoclosure () -> Bool) -> Bool {
        guard cmdOff >= 0, cmdOff < frame.count, frame[cmdOff] == opcode else { return false }
        return verdictOK()
    }

    /// True when a GET_DATA_RANGE COMMAND_RESPONSE is the `PENDING(2)` acknowledgement rather than the
    /// answer. The strap replies twice: a short PENDING ack, then the payload with `SUCCESS(1)`. Framing's
    /// own result-code table already states it — "2=PENDING precedes SUCCESS on GET_DATA_RANGE
    /// (hardware-confirmed, #78 fork)" — but `pagesBehind` had no way to tell the two apart, so the ack
    /// (which carries no ring pointers by construction) decoded to nil and logged as a decode FAILURE once
    /// per sync.
    ///
    /// The result byte sits at `cmdOff + 2`, after the echoed opcode and the origin sequence. A frame too
    /// short to hold one is not a PENDING ack, so it stays false and the caller keeps its existing
    /// too-short handling.
    public static func isPendingResponse(_ frame: [UInt8], cmdOff: Int) -> Bool {
        guard cmdOff >= 0, cmdOff + 2 < frame.count else { return false }
        return frame[cmdOff + 2] == 2
    }
}
