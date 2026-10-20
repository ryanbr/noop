import Foundation

// MARK: - GPX heart-rate injector
//
// Takes a GPX file exported from another service (Strava, Garmin Connect, …) that carries a GPS
// track but NO heart rate, and returns the SAME document with the strap's stored per-second HR
// injected into each timed trackpoint as the Garmin TrackPointExtension (`gpxtpx:hr`) — the form
// every major service reads back, Strava included. The result keeps position, elevation, times and
// everything else in the source file byte-for-byte: this is deliberate TEXT SURGERY on the original
// document, not a parse-and-reserialize, so nothing the exporting service wrote is lost or
// reordered. The only changes are the inserted extension blocks and, when the root `<gpx>` tag
// lacks it, the `xmlns:gpxtpx` namespace declaration.
//
// Direction of use (issue #2679, option 1 family): the wearer records a run in another app, NOOP
// has the measured HR for that window in its own store, and the merged file is handed back to the
// wearer through the share sheet. Fully offline, file-in/file-out, nothing persisted; the local
// database stays the sole authority and nothing here touches the import or scoring paths.
//
// PARITY: `GpxHrInject.kt` (android `com.noop.ingest`) is the byte-identical Kotlin twin — same
// insertion text, same matching rule, same error cases. Verified by oracle (Swift stdout pasted as
// Kotlin expected literals), per AGENTS.md; change both together.
public enum GpxHrInjector {

    /// The namespace the inserted elements live in — Garmin's TrackPointExtension v1, which is what
    /// Strava itself writes when a run HAS heart rate, so readers treat the merged file as native.
    static let gpxtpxNamespace = "http://www.garmin.com/xmlschemas/TrackPointExtension/v1"

    /// Widest plausible gap between a trackpoint's time and the nearest stored HR sample. The strap
    /// stores per-second HR and GPX trackpoints are at most a few seconds apart, so 5 s matches
    /// everything real while refusing to smear HR across a recording gap.
    public static let defaultToleranceSec = 5

    /// A successful merge: the rewritten document plus honest coverage counts for the UI line
    /// ("Heart rate added to N of M points").
    public struct Injected: Sendable, Equatable {
        /// The merged GPX document (UTF-8).
        public let gpx: Data
        /// Timed trackpoints that received an HR value.
        public let matched: Int
        /// Trackpoints that carried a parseable `<time>` (the denominator for `matched`).
        public let total: Int
        /// The track's time window (unix seconds) — first to last timed trackpoint.
        public let startTs: Int
        public let endTs: Int
    }

    /// Every way the merge can refuse, each carrying the numbers that explain it — a failed merge
    /// must say exactly why (never a silent pass-through that re-exports the file unchanged).
    public enum Failure: Error, Equatable {
        /// The data is not a GPX document (no `<gpx` root).
        case notGpx
        /// No trackpoint carried a parseable `<time>` — with no timestamps there is nothing to
        /// match HR against.
        case noTimedTrackpoints
        /// `points` trackpoints already carry HR — the file doesn't need the merge, and silently
        /// overwriting measured values from another device would be destructive.
        case alreadyHasHeartRate(points: Int)
        /// `samples` stored HR samples were offered but none fell within tolerance of any of the
        /// file's `points` timed trackpoints over `[startTs, endTs]` — usually the strap wasn't
        /// worn (or wasn't synced) for that window.
        case noHeartRateMatched(startTs: Int, endTs: Int, points: Int, samples: Int)
        /// The file blew the same point cap as the importer (`ActivityFileImporter.maxPoints`).
        case tooManyTrackpoints
    }

    // MARK: - Public API

    /// The track's time window (unix seconds), read without injecting — the app layer calls this
    /// first, fetches the store's HR samples for the window, then calls ``inject``.
    public static func timeWindow(gpx: Data) throws -> ClosedRange<Int> {
        let doc = try document(from: gpx)
        let scan = try scanTrackpoints(in: doc)
        guard let lo = scan.points.map(\.ts).min(), let hi = scan.points.map(\.ts).max() else {
            throw Failure.noTimedTrackpoints
        }
        return lo...hi
    }

    /// Merge `hr` (unix-second, bpm — the store's measured samples for the window) into `gpx`.
    public static func inject(
        gpx: Data,
        hr: [ActivityHRSample],
        toleranceSec: Int = defaultToleranceSec
    ) throws -> Injected {
        let doc = try document(from: gpx)
        let scan = try scanTrackpoints(in: doc)
        guard scan.hrPoints == 0 else { throw Failure.alreadyHasHeartRate(points: scan.hrPoints) }
        let points = scan.points
        guard !points.isEmpty else { throw Failure.noTimedTrackpoints }
        let startTs = points.map(\.ts).min() ?? 0
        let endTs = points.map(\.ts).max() ?? 0

        // Sort once; `nearestBpm` binary-searches per point.
        let samples = hr.sorted { $0.ts < $1.ts }

        // Build the output by splicing between trackpoints, back to front would also work; forward
        // with a running cursor keeps it single-pass and readable.
        var out = ""
        out.reserveCapacity(doc.count + points.count * 96)
        var cursor = doc.startIndex
        var matched = 0
        for p in points {
            guard let bpm = nearestBpm(to: p.ts, in: samples, toleranceSec: toleranceSec) else { continue }
            matched += 1
            let insertion = "<gpxtpx:TrackPointExtension><gpxtpx:hr>\(bpm)</gpxtpx:hr></gpxtpx:TrackPointExtension>"
            out += doc[cursor..<p.insertAt]
            // Inside an existing <extensions> block the TrackPointExtension goes in bare; a point
            // with none gets the full wrapper.
            out += p.insideExtensions ? insertion : "<extensions>\(insertion)</extensions>"
            cursor = p.insertAt
        }
        out += doc[cursor...]

        guard matched > 0 else {
            throw Failure.noHeartRateMatched(startTs: startTs, endTs: endTs,
                                             points: points.count, samples: samples.count)
        }
        return Injected(gpx: Data(ensureNamespace(in: out).utf8),
                        matched: matched, total: points.count, startTs: startTs, endTs: endTs)
    }

    // MARK: - Document scanning

    /// One timed trackpoint found in the document: its unix-second time and where the injected
    /// block goes (before `</extensions>` when the point has one — schema order keeps `extensions`
    /// last in `trkpt` — else before `</trkpt>`).
    struct TimedPoint {
        let ts: Int
        let insertAt: String.Index
        let insideExtensions: Bool
    }

    /// Everything one pass over the document yields: the timed, HR-less trackpoints in document
    /// order, plus the count of trackpoints that ALREADY carry an HR element (any element whose
    /// local name is `hr`/`heartrate`, timed or not — `alreadyHasHeartRate` must see them all).
    struct Scan {
        let points: [TimedPoint]
        let hrPoints: Int
    }

    static func document(from data: Data) throws -> String {
        guard let s = String(data: BOM.stripUTF8(data), encoding: .utf8),
              rangeOfOpenTag("gpx", in: s, from: s.startIndex) != nil else {
            throw Failure.notGpx
        }
        return s
    }

    /// Scan every `<trkpt>…</trkpt>`: collect the timed, HR-less points in document order and count
    /// the points that already carry HR. Throws only on the importer's point cap; emptiness is the
    /// caller's judgement (`timeWindow` and `inject` both refuse an empty result loudly).
    static func scanTrackpoints(in doc: String) throws -> Scan {
        var points: [TimedPoint] = []
        var hrPoints = 0
        var seen = 0
        var search = doc.startIndex
        while let open = rangeOfOpenTag("trkpt", in: doc, from: search) {
            seen += 1
            guard seen <= ActivityFileImporter.maxPoints else { throw Failure.tooManyTrackpoints }
            // Self-closing <trkpt …/> has no children, so no time — skip past it.
            if isSelfClosing(doc, open) {
                search = open.upperBound
                continue
            }
            guard let close = rangeOfCloseTag("trkpt", in: doc, from: open.upperBound) else { break }
            let body = doc[open.upperBound..<close.lowerBound]
            search = close.upperBound

            if bodyCarriesHr(body) {
                hrPoints += 1
                continue
            }
            // Same shared ISO parser the GPX importer's delegate uses, so merge and import agree
            // on time handling.
            guard let timeText = elementText("time", in: body), !timeText.isEmpty,
                  let date = WhoopTime.parse(timeText, offsetMinutes: 0) else { continue }
            // Prefer an existing </extensions> inside the body (last one, to stay schema-ordered).
            var insertAt = close.lowerBound
            var inside = false
            if let ext = lastRangeOfCloseTag("extensions", in: doc, bodyRange: open.upperBound..<close.lowerBound) {
                insertAt = ext.lowerBound
                inside = true
            }
            points.append(TimedPoint(ts: Int(date.timeIntervalSince1970.rounded()),
                                     insertAt: insertAt, insideExtensions: inside))
        }
        return Scan(points: points, hrPoints: hrPoints)
    }

    /// True when the trackpoint body already carries a heart-rate element in any of the forms the
    /// parser accepts: `gpxtpx:hr` / `ns3:hr` / bare `hr` / Cluetrust `gpxdata:hr` / `heartrate` —
    /// matched on the LOCAL element name, mirroring `GpxParser`.
    static func bodyCarriesHr(_ body: Substring) -> Bool {
        var search = body.startIndex
        while let lt = body[search...].firstIndex(of: "<") {
            var i = body.index(after: lt)
            // Skip end tags / comments / PIs — we only test element open tags.
            if i < body.endIndex, body[i] == "/" || body[i] == "!" || body[i] == "?" {
                search = body.index(after: lt); continue
            }
            var name = ""
            while i < body.endIndex, !body[i].isWhitespace, body[i] != ">", body[i] != "/" {
                name.append(body[i]); i = body.index(after: i)
            }
            let local = name.lowercased().split(separator: ":").last.map(String.init) ?? name.lowercased()
            if local == "hr" || local == "heartrate" { return true }
            search = body.index(after: lt)
        }
        return false
    }

    /// Nearest sample to `ts` within `toleranceSec`, by binary search over `samples` (sorted by ts).
    /// Ties (equidistant neighbours) take the EARLIER sample, so the Kotlin twin can't drift.
    static func nearestBpm(to ts: Int, in samples: [ActivityHRSample], toleranceSec: Int) -> Int? {
        guard !samples.isEmpty else { return nil }
        var lo = 0, hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].ts < ts { lo = mid + 1 } else { hi = mid }
        }
        // `lo` is the first sample ≥ ts; its left neighbour is the other candidate.
        var best: ActivityHRSample? = nil
        let right = samples[lo]
        if lo > 0 {
            let left = samples[lo - 1]
            best = abs(left.ts - ts) <= abs(right.ts - ts) ? left : right
        } else {
            best = right
        }
        guard let b = best, abs(b.ts - ts) <= toleranceSec else { return nil }
        return b.bpm
    }

    /// Add `xmlns:gpxtpx` to the root `<gpx …>` tag when absent, so the inserted prefix is bound.
    /// An existing declaration (any value) is left alone — redeclaring a prefix is an XML error.
    static func ensureNamespace(in doc: String) -> String {
        guard let open = rangeOfOpenTag("gpx", in: doc, from: doc.startIndex) else { return doc }
        let tag = doc[open]
        guard !tag.contains("xmlns:gpxtpx") else { return doc }
        // Insert before the closing ">" (or "/>" — impossible for a root with content, handled anyway).
        var insert = doc.index(before: open.upperBound)
        if doc[insert] == "/" { insert = doc.index(before: insert) }
        var out = doc
        out.insert(contentsOf: " xmlns:gpxtpx=\"\(gpxtpxNamespace)\"", at: insert)
        return out
    }

    // MARK: - Tag scanning primitives (local-name matched, prefix-blind, case-insensitive like GpxParser)

    /// Range of the next `<name …>` open tag (full tag including both angle brackets) whose LOCAL
    /// name is `name`, at or after `from`. Prefixed forms (`<ns:trkpt`) match too.
    static func rangeOfOpenTag(_ name: String, in doc: String, from: String.Index) -> Range<String.Index>? {
        var search = from
        while let lt = doc[search...].firstIndex(of: "<") {
            let afterLt = doc.index(after: lt)
            guard afterLt < doc.endIndex else { return nil }
            if doc[afterLt] == "/" || doc[afterLt] == "!" || doc[afterLt] == "?" {
                search = afterLt; continue
            }
            var i = afterLt
            var tagName = ""
            while i < doc.endIndex, !doc[i].isWhitespace, doc[i] != ">", doc[i] != "/" {
                tagName.append(doc[i]); i = doc.index(after: i)
            }
            let local = tagName.lowercased().split(separator: ":").last.map(String.init) ?? tagName.lowercased()
            guard let gt = doc[i...].firstIndex(of: ">") else { return nil }
            if local == name {
                return lt..<doc.index(after: gt)
            }
            search = doc.index(after: lt)
        }
        return nil
    }

    /// Range of the next `</name>` close tag at or after `from` (whitespace before `>` tolerated).
    static func rangeOfCloseTag(_ name: String, in doc: String, from: String.Index) -> Range<String.Index>? {
        var search = from
        while let lt = doc[search...].firstIndex(of: "<") {
            let afterLt = doc.index(after: lt)
            guard afterLt < doc.endIndex else { return nil }
            guard doc[afterLt] == "/" else { search = afterLt; continue }
            var i = doc.index(after: afterLt)
            var tagName = ""
            while i < doc.endIndex, !doc[i].isWhitespace, doc[i] != ">" {
                tagName.append(doc[i]); i = doc.index(after: i)
            }
            let local = tagName.lowercased().split(separator: ":").last.map(String.init) ?? tagName.lowercased()
            guard let gt = doc[i...].firstIndex(of: ">") else { return nil }
            if local == name {
                return lt..<doc.index(after: gt)
            }
            search = doc.index(after: lt)
        }
        return nil
    }

    /// The LAST `</extensions>` close tag inside `bodyRange`, or nil.
    static func lastRangeOfCloseTag(_ name: String, in doc: String, bodyRange: Range<String.Index>) -> Range<String.Index>? {
        var found: Range<String.Index>? = nil
        var search = bodyRange.lowerBound
        while let r = rangeOfCloseTag(name, in: doc, from: search), r.upperBound <= bodyRange.upperBound {
            found = r
            search = r.upperBound
        }
        return found
    }

    /// Whether the open tag at `open` is self-closing (`…/>`), i.e. its char before `>` is `/`.
    static func isSelfClosing(_ doc: String, _ open: Range<String.Index>) -> Bool {
        let beforeGt = doc.index(open.upperBound, offsetBy: -2)
        return beforeGt >= open.lowerBound && doc[beforeGt] == "/"
    }

    /// Text content of the FIRST `<name>…</name>` element in `body` (local-name matched), trimmed.
    static func elementText(_ name: String, in body: Substring) -> String? {
        let doc = String(body)
        guard let open = rangeOfOpenTag(name, in: doc, from: doc.startIndex),
              let close = rangeOfCloseTag(name, in: doc, from: open.upperBound) else { return nil }
        return String(doc[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
