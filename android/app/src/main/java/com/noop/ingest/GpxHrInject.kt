package com.noop.ingest

/**
 * GPX heart-rate injector — the byte-for-byte twin of the Swift `GpxHrInjector` in
 * `Packages/StrandImport` (verified by oracle in [GpxHrInjectTest]: the Swift implementation's stdout
 * over shared fixtures is pasted there as the expected literals; change both together).
 *
 * Takes a GPX file exported from another service (Strava, Garmin Connect, …) that carries a GPS
 * track but NO heart rate, and returns the SAME document with the strap's stored per-second HR
 * injected into each timed trackpoint as the Garmin TrackPointExtension (`gpxtpx:hr`) — the form
 * every major service reads back, Strava included. Deliberate TEXT SURGERY on the original document,
 * not a parse-and-reserialize: position, elevation, times and everything else survive byte-for-byte;
 * the only changes are the inserted extension blocks and, when the root `<gpx>` tag lacks it, the
 * `xmlns:gpxtpx` namespace declaration.
 *
 * Direction of use (issue #2679, option-1 family): the wearer records a run in another app, NOOP has
 * the measured HR for that window in its own store, and the merged file is handed back through the
 * share intent. Fully offline, file-in/file-out, nothing persisted. Pure JVM — no Android types.
 */
object GpxHrInject {

    /** The namespace the inserted elements live in — what Strava itself writes when a run HAS HR. */
    const val GPXTPX_NAMESPACE = "http://www.garmin.com/xmlschemas/TrackPointExtension/v1"

    /**
     * Widest plausible gap between a trackpoint's time and the nearest stored HR sample. The strap
     * stores per-second HR and GPX trackpoints are at most a few seconds apart, so 5 s matches
     * everything real while refusing to smear HR across a recording gap.
     */
    const val DEFAULT_TOLERANCE_SEC = 5

    /** A successful merge: the rewritten document plus honest coverage counts for the UI line. */
    data class Injected(
        val gpx: String,
        /** Timed trackpoints that received an HR value. */
        val matched: Int,
        /** Trackpoints that carried a parseable `<time>` (the denominator for [matched]). */
        val total: Int,
        /** The track's time window (unix seconds) — first to last timed trackpoint. */
        val startTs: Long,
        val endTs: Long,
    )

    /**
     * Every way the merge can refuse, each carrying the numbers that explain it — a failed merge
     * must say exactly why (never a silent pass-through that re-exports the file unchanged).
     */
    sealed class Failure(message: String) : Exception(message) {
        /** The data is not a GPX document (no `<gpx` root). */
        object NotGpx : Failure("not a GPX document") { private fun readResolve(): Any = NotGpx }

        /** No trackpoint carried a parseable `<time>` — nothing to match HR against. */
        object NoTimedTrackpoints : Failure("no timed trackpoints") { private fun readResolve(): Any = NoTimedTrackpoints }

        /** [points] trackpoints already carry HR — overwriting measured values would be destructive. */
        data class AlreadyHasHeartRate(val points: Int) : Failure("file already carries heart rate on $points points")

        /** [samples] stored samples were offered but none fell within tolerance of the [points] timed trackpoints. */
        data class NoHeartRateMatched(val startTs: Long, val endTs: Long, val points: Int, val samples: Int) :
            Failure("no stored heart rate matched the track window")

        /** The file blew the same point cap as the importer ([ActivityFileImporter.MAX_POINTS]). */
        object TooManyTrackpoints : Failure("too many trackpoints") { private fun readResolve(): Any = TooManyTrackpoints }
    }

    // ── Public API ──────────────────────────────────────────────────────────────────────────────

    /**
     * The track's time window (unix seconds) read without injecting — the app layer calls this
     * first, fetches the store's HR samples for the window, then calls [inject].
     */
    fun timeWindow(gpx: String): LongRange {
        val doc = document(gpx)
        val scan = scanTrackpoints(doc)
        val lo = scan.points.minOfOrNull { it.ts } ?: throw Failure.NoTimedTrackpoints
        val hi = scan.points.maxOf { it.ts }
        return lo..hi
    }

    /** Merge `hr` (the store's measured samples for the window) into `gpx`. */
    fun inject(
        gpx: String,
        hr: List<ActivityFileImporter.HrPoint>,
        toleranceSec: Int = DEFAULT_TOLERANCE_SEC,
    ): Injected {
        val doc = document(gpx)
        val scan = scanTrackpoints(doc)
        if (scan.hrPoints > 0) throw Failure.AlreadyHasHeartRate(scan.hrPoints)
        val points = scan.points
        if (points.isEmpty()) throw Failure.NoTimedTrackpoints
        val startTs = points.minOf { it.ts }
        val endTs = points.maxOf { it.ts }

        val samples = hr.sortedBy { it.ts }

        val out = StringBuilder(doc.length + points.size * 96)
        var cursor = 0
        var matched = 0
        for (p in points) {
            val bpm = nearestBpm(p.ts, samples, toleranceSec) ?: continue
            matched += 1
            val insertion = "<gpxtpx:TrackPointExtension><gpxtpx:hr>$bpm</gpxtpx:hr></gpxtpx:TrackPointExtension>"
            out.append(doc, cursor, p.insertAt)
            // Inside an existing <extensions> block the TrackPointExtension goes in bare; a point
            // with none gets the full wrapper.
            out.append(if (p.insideExtensions) insertion else "<extensions>$insertion</extensions>")
            cursor = p.insertAt
        }
        out.append(doc, cursor, doc.length)

        if (matched == 0) throw Failure.NoHeartRateMatched(startTs, endTs, points.size, samples.size)
        return Injected(ensureNamespace(out.toString()), matched, points.size, startTs, endTs)
    }

    // ── Document scanning ───────────────────────────────────────────────────────────────────────

    /**
     * One timed trackpoint: its unix-second time and where the injected block goes (before
     * `</extensions>` when the point has one — schema order keeps `extensions` last in `trkpt` —
     * else before `</trkpt>`).
     */
    internal data class TimedPoint(val ts: Long, val insertAt: Int, val insideExtensions: Boolean)

    /**
     * Everything one pass yields: the timed, HR-less trackpoints in document order, plus the count
     * of trackpoints that ALREADY carry an HR element (local name `hr`/`heartrate`, timed or not).
     */
    internal data class Scan(val points: List<TimedPoint>, val hrPoints: Int)

    internal fun document(gpx: String): String {
        val doc = if (gpx.startsWith("﻿")) gpx.substring(1) else gpx
        if (rangeOfOpenTag("gpx", doc, 0) == null) throw Failure.NotGpx
        return doc
    }

    /**
     * Scan every `<trkpt>…</trkpt>`: collect the timed, HR-less points in document order and count
     * the points that already carry HR. Throws only on the importer's point cap; emptiness is the
     * caller's judgement ([timeWindow] and [inject] both refuse an empty result loudly).
     */
    internal fun scanTrackpoints(doc: String): Scan {
        val points = mutableListOf<TimedPoint>()
        var hrPoints = 0
        var seen = 0
        var search = 0
        while (true) {
            val open = rangeOfOpenTag("trkpt", doc, search) ?: break
            seen += 1
            if (seen > ActivityFileImporter.MAX_POINTS) throw Failure.TooManyTrackpoints
            // Self-closing <trkpt …/> has no children, so no time — skip past it.
            if (isSelfClosing(doc, open)) {
                search = open.last + 1
                continue
            }
            val close = rangeOfCloseTag("trkpt", doc, open.last + 1) ?: break
            val body = doc.substring(open.last + 1, close.first)
            search = close.last + 1

            if (bodyCarriesHr(body)) {
                hrPoints += 1
                continue
            }
            // Same shared ISO parser the GPX importer uses, so merge and import agree on time handling.
            val timeText = elementText("time", body)
            val ts = if (timeText.isNullOrEmpty()) null else ActivityFileImporter.parseTimeS(timeText)
            if (ts == null) continue
            // Prefer an existing </extensions> inside the body (last one, to stay schema-ordered).
            var insertAt = close.first
            var inside = false
            val ext = lastRangeOfCloseTag("extensions", doc, open.last + 1, close.first)
            if (ext != null) {
                insertAt = ext.first
                inside = true
            }
            points.add(TimedPoint(ts, insertAt, inside))
        }
        return Scan(points, hrPoints)
    }

    /**
     * True when the trackpoint body already carries a heart-rate element in any of the forms the
     * parser accepts: `gpxtpx:hr` / `ns3:hr` / bare `hr` / Cluetrust `gpxdata:hr` / `heartrate` —
     * matched on the LOCAL element name, mirroring the GPX importer.
     */
    internal fun bodyCarriesHr(body: String): Boolean {
        var search = 0
        while (true) {
            val lt = body.indexOf('<', search)
            if (lt < 0) return false
            var i = lt + 1
            // Skip end tags / comments / PIs — we only test element open tags.
            if (i < body.length && (body[i] == '/' || body[i] == '!' || body[i] == '?')) {
                search = lt + 1
                continue
            }
            val name = StringBuilder()
            while (i < body.length && !body[i].isWhitespace() && body[i] != '>' && body[i] != '/') {
                name.append(body[i]); i += 1
            }
            val local = name.toString().lowercase().substringAfterLast(':')
            if (local == "hr" || local == "heartrate") return true
            search = lt + 1
        }
    }

    /**
     * Nearest sample to `ts` within `toleranceSec`, by binary search over `samples` (sorted by ts).
     * Ties (equidistant neighbours) take the EARLIER sample, matching the Swift twin exactly.
     */
    internal fun nearestBpm(ts: Long, samples: List<ActivityFileImporter.HrPoint>, toleranceSec: Int): Int? {
        if (samples.isEmpty()) return null
        var lo = 0
        var hi = samples.size - 1
        while (lo < hi) {
            val mid = (lo + hi) / 2
            if (samples[mid].ts < ts) lo = mid + 1 else hi = mid
        }
        // `lo` is the first sample ≥ ts; its left neighbour is the other candidate.
        val right = samples[lo]
        val best = if (lo > 0) {
            val left = samples[lo - 1]
            if (Math.abs(left.ts - ts) <= Math.abs(right.ts - ts)) left else right
        } else {
            right
        }
        return if (Math.abs(best.ts - ts) <= toleranceSec) best.bpm else null
    }

    /**
     * Add `xmlns:gpxtpx` to the root `<gpx …>` tag when absent, so the inserted prefix is bound.
     * An existing declaration (any value) is left alone — redeclaring a prefix is an XML error.
     */
    internal fun ensureNamespace(doc: String): String {
        val open = rangeOfOpenTag("gpx", doc, 0) ?: return doc
        val tag = doc.substring(open.first, open.last + 1)
        if (tag.contains("xmlns:gpxtpx")) return doc
        // Insert before the closing ">" (or "/>" — impossible for a root with content, handled anyway).
        var insert = open.last
        if (doc[insert - 1] == '/') insert -= 1
        return doc.substring(0, insert) + " xmlns:gpxtpx=\"$GPXTPX_NAMESPACE\"" + doc.substring(insert)
    }

    // ── Tag scanning primitives (local-name matched, prefix-blind, case-insensitive) ────────────

    /**
     * Range (inclusive first..last char index) of the next `<name …>` open tag whose LOCAL name is
     * `name`, at or after `from`. Prefixed forms (`<ns:trkpt`) match too.
     */
    internal fun rangeOfOpenTag(name: String, doc: String, from: Int): IntRange? {
        var search = from
        while (true) {
            val lt = doc.indexOf('<', search)
            if (lt < 0) return null
            val afterLt = lt + 1
            if (afterLt >= doc.length) return null
            if (doc[afterLt] == '/' || doc[afterLt] == '!' || doc[afterLt] == '?') {
                search = afterLt
                continue
            }
            var i = afterLt
            val tagName = StringBuilder()
            while (i < doc.length && !doc[i].isWhitespace() && doc[i] != '>' && doc[i] != '/') {
                tagName.append(doc[i]); i += 1
            }
            val local = tagName.toString().lowercase().substringAfterLast(':')
            val gt = doc.indexOf('>', i)
            if (gt < 0) return null
            if (local == name) return lt..gt
            search = lt + 1
        }
    }

    /** Range of the next `</name>` close tag at or after `from` (whitespace before `>` tolerated). */
    internal fun rangeOfCloseTag(name: String, doc: String, from: Int): IntRange? {
        var search = from
        while (true) {
            val lt = doc.indexOf('<', search)
            if (lt < 0) return null
            val afterLt = lt + 1
            if (afterLt >= doc.length) return null
            if (doc[afterLt] != '/') {
                search = afterLt
                continue
            }
            var i = afterLt + 1
            val tagName = StringBuilder()
            while (i < doc.length && !doc[i].isWhitespace() && doc[i] != '>') {
                tagName.append(doc[i]); i += 1
            }
            val local = tagName.toString().lowercase().substringAfterLast(':')
            val gt = doc.indexOf('>', i)
            if (gt < 0) return null
            if (local == name) return lt..gt
            search = lt + 1
        }
    }

    /** The LAST `</extensions>` close tag fully inside `bodyStart until bodyEnd`, or null. */
    internal fun lastRangeOfCloseTag(name: String, doc: String, bodyStart: Int, bodyEnd: Int): IntRange? {
        var found: IntRange? = null
        var search = bodyStart
        while (true) {
            val r = rangeOfCloseTag(name, doc, search) ?: break
            if (r.last + 1 > bodyEnd) break
            found = r
            search = r.last + 1
        }
        return found
    }

    /** Whether the open tag at `open` is self-closing (`…/>`). */
    internal fun isSelfClosing(doc: String, open: IntRange): Boolean {
        val beforeGt = open.last - 1
        return beforeGt >= open.first && doc[beforeGt] == '/'
    }

    /** Text content of the FIRST `<name>…</name>` element in `body` (local-name matched), trimmed. */
    internal fun elementText(name: String, body: String): String? {
        val open = rangeOfOpenTag(name, body, 0) ?: return null
        val close = rangeOfCloseTag(name, body, open.last + 1) ?: return null
        return body.substring(open.last + 1, close.first).trim()
    }
}
