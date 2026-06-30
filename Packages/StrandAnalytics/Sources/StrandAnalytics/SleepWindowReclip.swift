import Foundation

/// Reshape a sleep session's stored stage breakdown to a hand-corrected `[newStart, newEnd]` window, so a
/// bed-time (onset) and/or wake-time edit updates the hypnogram and the total-asleep / stage footer, not
/// just the displayed "Woke" / "Bed" label. Pure + deterministic (no store, no raw signals, no I/O), so
/// it's unit-tested directly and works for a Bluetooth-only night, an imported night, online or off: it
/// reclips whatever `stagesJSON` the session already carries.
///
/// START-AWARE on BOTH ends (#0): a pure onset edit (newStart moves, newEnd unchanged) must drop the
/// stages BEFORE the corrected bed time, not leave them in place. Otherwise an imported / pre-sync night
/// keeps sleep that happened before the user got into bed while the displayed window shrank.
///
/// Two formats, mirroring the app's two writers (see SleepView.decodeSegments / decodeStages):
///   • segment array `[{"start":epoch,"end":epoch,"stage":"wake"|"light"|"deep"|"rem"}]` — computed
///     nights. Clip to `[newStart, newEnd]`: drop segments wholly outside it, clip a straddling
///     segment's start up to `newStart` and end down to `newEnd`, and if the window grew at the tail
///     append a trailing `wake` segment (extra time in bed reads as awake).
///   • minute dict `{"awake","light","deep","rem"}` — imported nights. No timeline, so shift by the
///     duration delta `(newEnd - newStart) - (oldEnd - sessionStart)`: trim from the tail-most stages
///     (awake → light → rem → deep) when shortened, add to awake when lengthened.
///
/// Returns the re-encoded JSON in the SAME shape it received, or nil when there's nothing usable to
/// reclip (the caller then keeps the existing JSON).
public enum SleepWindowReclip {

    public static func reclip(stagesJSON: String?, sessionStart: Int, oldEnd: Int,
                              newStart: Int, newEnd: Int) -> String? {
        guard let stagesJSON, let data = stagesJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let arr = obj as? [[String: Any]] {
            return reclipSegments(arr, newStart: newStart, newEnd: newEnd)
        }
        if let dict = obj as? [String: Any] {
            return reclipMinutes(dict, deltaSeconds: (newEnd - newStart) - (oldEnd - sessionStart))
        }
        return nil
    }

    private static func reclipSegments(_ arr: [[String: Any]], newStart: Int, newEnd: Int) -> String? {
        var out: [[String: Any]] = []
        var maxEnd = newStart
        for seg in arr {
            guard let start = (seg["start"] as? NSNumber)?.intValue,
                  let end = (seg["end"] as? NSNumber)?.intValue,
                  let stage = seg["stage"] as? String, end > start else { continue }
            if start >= newEnd { continue }                 // wholly after the new wake → drop
            if end <= newStart { continue }                 // wholly before the new bed time → drop
            let clippedStart = max(start, newStart)         // clip the segment spanning the new bed time
            let clippedEnd = min(end, newEnd)               // clip the segment spanning the new wake
            out.append(["start": clippedStart, "end": clippedEnd, "stage": stage])
            maxEnd = max(maxEnd, clippedEnd)
        }
        if newEnd > maxEnd, maxEnd >= newStart {            // window grew → trailing time in bed = awake
            out.append(["start": maxEnd, "end": newEnd, "stage": "wake"])
        }
        // If every segment was trimmed away (the corrected window lands outside every stage), don't
        // return nil — that would let the store's COALESCE keep the OLD stages, which then extend PAST
        // the new wake. Emit a single wake segment covering the (valid, ≥60s) corrected window instead.
        if out.isEmpty, newEnd > newStart {
            out.append(["start": newStart, "end": newEnd, "stage": "wake"])
        }
        guard !out.isEmpty, let d = try? JSONSerialization.data(withJSONObject: out) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static func reclipMinutes(_ dict: [String: Any], deltaSeconds: Int) -> String? {
        func val(_ k: String) -> Double { (dict[k] as? NSNumber)?.doubleValue ?? 0 }
        var awake = val("awake"), light = val("light"), deep = val("deep"), rem = val("rem")
        let deltaMin = Double(deltaSeconds) / 60.0
        if deltaMin >= 0 {
            awake += deltaMin                               // extra time in bed reads as awake
        } else {
            var trim = -deltaMin                            // remove from the tail-most stages first
            func cut(_ v: Double) -> Double { let c = min(v, max(trim, 0)); trim -= c; return v - c }
            awake = cut(awake); light = cut(light); rem = cut(rem); deep = cut(deep)
        }
        let out: [String: Double] = ["awake": awake, "light": light, "deep": deep, "rem": rem]
        guard out.values.reduce(0, +) > 0,
              let d = try? JSONSerialization.data(withJSONObject: out) else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
