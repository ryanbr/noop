package com.noop.analytics

import org.json.JSONArray
import org.json.JSONObject

/**
 * Reshape a sleep session's stored stage breakdown to a hand-corrected [newStart]..[newEnd] window, so a
 * bed-time (onset) and/or wake-time edit updates the hypnogram and the stage footer, not just the
 * displayed "Woke" / "Bed" label. Pure + deterministic (no store, no raw signals, no I/O). Port of
 * SleepWindowReclip.swift.
 *
 * START-AWARE on BOTH ends (#0): a pure onset edit (newStart moves, newEnd unchanged) must drop the
 * stages BEFORE the corrected bed time, not leave them in place. Otherwise an imported / pre-sync night
 * keeps sleep that happened before the user got into bed while the displayed window shrank.
 *
 * Two stagesJSON formats (matching the two writers):
 *   • Segment array `[{"start":epoch,"end":epoch,"stage":"wake"|"light"|"deep"|"rem"}]` — computed
 *     nights. Clip to [newStart]..[newEnd]: drop segments wholly outside it, clip a straddling
 *     segment's start up to [newStart] and end down to [newEnd]; if the window grew at the tail,
 *     append a trailing "wake" segment (extra time in bed reads as awake).
 *   • Minute dict `{"awake":…,"light":…,"deep":…,"rem":…}` — imported nights. No timeline, so
 *     shift by the duration delta `(newEnd - newStart) - (oldEnd - sessionStart)`: trim from the
 *     tail-most stages (awake→light→rem→deep) when shortened, add to awake when lengthened.
 *
 * Returns re-encoded JSON in the SAME shape received, or null when there is nothing usable to
 * reclip (callers then keep the existing JSON).
 */
object SleepWindowReclip {

    fun reclip(stagesJSON: String?, sessionStart: Long, oldEnd: Long, newStart: Long, newEnd: Long): String? {
        stagesJSON ?: return null
        return try {
            when {
                stagesJSON.trimStart().startsWith("[") ->
                    reclipSegments(JSONArray(stagesJSON), newStart, newEnd)
                stagesJSON.trimStart().startsWith("{") ->
                    reclipMinutes(JSONObject(stagesJSON), (newEnd - newStart) - (oldEnd - sessionStart))
                else -> null
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun reclipSegments(arr: JSONArray, newStart: Long, newEnd: Long): String? {
        val out = JSONArray()
        var maxEnd = newStart
        for (i in 0 until arr.length()) {
            val seg = arr.optJSONObject(i) ?: continue
            val start = seg.optLong("start", -1)
            val end = seg.optLong("end", -1)
            val stage = seg.optString("stage", "")
            if (start < 0 || end <= start || stage.isEmpty()) continue
            if (start >= newEnd) continue                        // wholly after new wake → drop
            if (end <= newStart) continue                        // wholly before the new bed time → drop
            val clippedStart = maxOf(start, newStart)            // clip the segment spanning the new bed time
            val clippedEnd = minOf(end, newEnd)
            out.put(JSONObject().put("start", clippedStart).put("end", clippedEnd).put("stage", stage))
            if (clippedEnd > maxEnd) maxEnd = clippedEnd
        }
        if (newEnd > maxEnd && maxEnd >= newStart) {             // window grew → trailing awake
            out.put(JSONObject().put("start", maxEnd).put("end", newEnd).put("stage", "wake"))
        }
        // If every segment trimmed away, emit a single wake covering the corrected window so the
        // store's COALESCE doesn't keep the old segments extending past the new wake time.
        if (out.length() == 0 && newEnd > newStart) {
            out.put(JSONObject().put("start", newStart).put("end", newEnd).put("stage", "wake"))
        }
        return if (out.length() > 0) out.toString() else null
    }

    private fun reclipMinutes(dict: JSONObject, deltaSeconds: Long): String? {
        var awake = dict.optDouble("awake", 0.0)
        var light = dict.optDouble("light", 0.0)
        var deep = dict.optDouble("deep", 0.0)
        var rem = dict.optDouble("rem", 0.0)
        val deltaMin = deltaSeconds / 60.0
        if (deltaMin >= 0) {
            awake += deltaMin                                     // extra time in bed = awake
        } else {
            var trim = -deltaMin
            fun cut(v: Double): Double { val c = minOf(v, maxOf(trim, 0.0)); trim -= c; return v - c }
            awake = cut(awake); light = cut(light); rem = cut(rem); deep = cut(deep)
        }
        val total = awake + light + deep + rem
        if (total <= 0.0) return null
        return JSONObject()
            .put("awake", awake).put("light", light).put("deep", deep).put("rem", rem)
            .toString()
    }
}
