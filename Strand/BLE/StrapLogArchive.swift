import Foundation

/// The strap log on disk: every line of every app run, kept across restarts within a fixed size.
///
/// WHY THIS EXISTS. `LiveState.log` lives in memory and dies with the process. It used to be mirrored to
/// UserDefaults — the newest 2,000 lines, re-serialised every 32 lines (#510) — and each launch rolled that
/// mirror into a ring of the last three runs, 1,000 lines each (#1263). A restart's cause survived only when
/// restarts were rare and the cause was recent. Three things were lost every time: the lines logged since the
/// last mirror (up to 31 — the seconds before iOS kills a process, the ones that explain the kill); everything
/// but a run's last 1,000 lines; and every run before the last three. On 21 Sep 2026 iOS killed NOOP for
/// background CPU four times in 28 minutes of one session, and the log saved afterwards began half an hour
/// after the moment it was saved for.
///
/// Now each line is appended to its run's file as it is logged — one small write, which the kernel keeps even
/// when the process is killed a moment later. A run is split into segments of `segmentBytes`; once all the
/// segments pass `budgetBytes`, the oldest are deleted. So the log holds the newest ~2 MB — about 20,000 lines,
/// some three hours with a strap streaming heart rate — however often NOOP restarts, and a whole run rather
/// than its last 5,000 lines. Exports render it exactly as the ring did: earlier runs oldest first, each under
/// its "previous app session" header, then the current run after its marker, so every tool that reads a strap
/// log reads it unchanged.
///
/// Before the first unlock after a boot iOS refuses the files — just when a restart after a reboot is logged — so
/// lines that cannot be written wait in memory, the newest within the budget, and go to disk the moment a file
/// opens.
///
/// An export reads no file while a run is written: the open segment's lines are kept in memory and everything
/// before them is rendered once, again only when a segment closes — the Test Centre asks for an export on
/// every new line while a guided mode is on.
///
/// Twin of Android's `com.noop.ui.StrapLogArchive`: same file names, sizes and rendering.
final class StrapLogArchive: @unchecked Sendable {

    /// How much of the log is kept, all runs together.
    static let budgetBytes = 2 * 1024 * 1024
    /// The size at which a run's file is closed and the next one begun — what the oldest runs are deleted by.
    static let segmentBytes = 256 * 1024
    /// Separates the earlier runs from the current one in an export, as the ring's exports did.
    static let currentRunMarker = "===== current app session ====="
    /// Lines carried over from the UserDefaults ring the first time this runs: rendered first, as they were.
    static let legacyFileName = "legacy.log"

    let directory: URL
    /// When this run began, in unix milliseconds: the name its files sort by, and when the run before it
    /// ended ("rolled at" in that run's header).
    let runStart: Int64
    private let budget: Int
    private let segmentLimit: Int

    private let lock = NSLock()
    private var handle: FileHandle?
    private var segment = 0
    /// Bytes written to the open segment.
    private var segmentSize = 0
    /// The open segment's lines, all on disk, so an export reads nothing that is being written.
    private var openLines: [String] = []
    /// Lines not on disk yet, all newer than `openLines`: storage refused them (iOS, before the first unlock after
    /// a boot — when a restart after a reboot is logged) or no file would open. Written the moment one opens;
    /// meanwhile in this run's export, the newest within the budget.
    private var unwritten: [String] = []
    private var unwrittenBytes = 0
    /// Lines until the next attempt to open a file while none is open: every 64 lines, not on every line.
    private var openAttemptIn = 0
    /// Everything before the open segment, rendered: the earlier runs under their headers, and this run's
    /// closed segments. Nil until an export needs it, and again when pruning deletes a file.
    private var rendered: (previous: String, closed: String)?

    init(directory: URL, budgetBytes: Int = StrapLogArchive.budgetBytes,
         segmentBytes: Int = StrapLogArchive.segmentBytes, now: Date = Date()) {
        self.directory = directory
        self.budget = budgetBytes
        self.segmentLimit = segmentBytes
        self.runStart = Int64((now.timeIntervalSince1970 * 1000).rounded())
    }

    /// Log one line: onto disk now, or — if storage cannot be written — into memory until it can, the newest lines
    /// within the budget. Either way it is in this run's export.
    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        unwritten.append(line)
        unwrittenBytes += line.utf8.count + 1
        writeUnwritten()
        guard unwrittenBytes > budget else { return }
        var dropped = 0
        while unwrittenBytes > budget {
            unwrittenBytes -= unwritten[dropped].utf8.count + 1
            dropped += 1
        }
        unwritten.removeFirst(dropped)
        // Nothing of this run on disk yet: its first file then starts at segment 1, which reads as a clipped head.
        if segment == 0, openLines.isEmpty { segment = 1 }
    }

    /// Write what waits, oldest first; a refusal leaves the rest waiting and the next attempt 64 lines away.
    private func writeUnwritten() {
        if handle == nil {
            guard openAttemptIn == 0 else { openAttemptIn -= 1; return }
            openSegment()
            guard handle != nil else { openAttemptIn = 63; return }
        }
        var written = 0
        defer { unwritten.removeFirst(written) }
        for line in unwritten {
            let data = Data((line + "\n").utf8)
            if !openLines.isEmpty, segmentSize + data.count > segmentLimit {
                closeSegment()
                openSegment()
                guard handle != nil else { openAttemptIn = 63; return }
            }
            guard (try? handle?.write(contentsOf: data)) != nil else {
                try? handle?.close()
                handle = nil
                openAttemptIn = 63
                return
            }
            segmentSize += data.count
            unwrittenBytes -= data.count
            openLines.append(line)
            written += 1
        }
    }

    /// The whole log as an export shows it: earlier runs, the marker, then this run.
    func exportText() -> String {
        lock.lock(); defer { lock.unlock() }
        let earlier = renderedEarlier()
        let open = (openLines + unwritten).joined(separator: "\n")
        let current = earlier.closed.isEmpty ? open : open.isEmpty ? earlier.closed : earlier.closed + "\n" + open
        return earlier.previous + current
    }

    /// Keep the ring's lines when the log first moves to disk: written once, before every run, as they were.
    func importLegacy(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let url = directory.appendingPathComponent(Self.legacyFileName)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
        rendered = nil
    }

    // MARK: - Files

    /// One file: a segment of a run, or the carried-over ring (`run` nil).
    private struct File {
        var url: URL
        var run: Int64?
        var index: Int
        var bytes: Int
    }

    static func fileName(run: Int64, segment: Int) -> String {
        String(format: "%013lld-%04ld.log", run, segment)
    }

    /// Every file, oldest first: the carried-over ring, then each run's segments in order.
    private func files() -> [File] {
        let keys: [URLResourceKey] = [.fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys))
            ?? []
        return urls.compactMap { url -> File? in
            let name = url.lastPathComponent
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if name == Self.legacyFileName { return File(url: url, run: nil, index: 0, bytes: bytes) }
            let parts = name.dropLast(4).split(separator: "-")
            guard name.hasSuffix(".log"), parts.count == 2,
                  let run = Int64(parts[0]), let index = Int(parts[1]) else { return nil }
            return File(url: url, run: run, index: index, bytes: bytes)
        }
        .sorted { ($0.run ?? -1, $0.index) < ($1.run ?? -1, $1.index) }
    }

    private func openSegment() {
        let url = directory.appendingPathComponent(Self.fileName(run: runStart, segment: segment))
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        prune()
    }

    private func closeSegment() {
        try? handle?.close()
        handle = nil
        if let earlier = rendered {
            let closing = openLines.joined(separator: "\n")
            rendered = (earlier.previous, earlier.closed.isEmpty ? closing : earlier.closed + "\n" + closing)
        }
        segment += 1
        segmentSize = 0
        openLines = []
    }

    /// Delete the oldest files until everything fits the budget — never the segment being written.
    private func prune() {
        let open = Self.fileName(run: runStart, segment: segment)
        var all = files()
        var total = all.reduce(0) { $0 + $1.bytes }
        while total > budget, let oldest = all.first(where: { $0.url.lastPathComponent != open }) {
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.bytes
            all.removeAll { $0.url == oldest.url }
            rendered = nil
        }
    }

    // MARK: - Rendering

    private func renderedEarlier() -> (previous: String, closed: String) {
        if let rendered { return rendered }
        let open = Self.fileName(run: runStart, segment: segment)
        var legacy: [String] = []
        var runs: [(start: Int64, lines: [String], clipped: Bool)] = []
        var closed: [String] = []
        for file in files() where file.url.lastPathComponent != open {
            let lines = Self.lines(of: file.url)
            guard let run = file.run else { legacy += lines; continue }
            if run == runStart { closed += lines; continue }
            if let last = runs.last, last.start == run {
                runs[runs.count - 1].lines += lines
            } else {
                runs.append((run, lines, file.index > 0))
            }
        }
        let result = (previous: Self.render(legacy: legacy, runs: runs, currentStart: runStart),
                      closed: closed.joined(separator: "\n"))
        rendered = result
        return result
    }

    /// The ring's lines as its export printed them: each stored run already carries its own header; a tail the
    /// ring had not rolled yet gets the header its roll would have written, now.
    static func legacyRingLines(generations: [[String]], tail: [String], now: Date) -> [String] {
        var lines = generations.flatMap { $0 }
        if !tail.isEmpty {
            lines.append(header(lines: tail.count, clipped: false,
                                rolledAt: Int64((now.timeIntervalSince1970 * 1000).rounded())))
            lines += tail
        }
        return lines
    }

    /// One earlier run's header. Byte-identical to the ring's, which the log tools parse; the time is UTC,
    /// to the second.
    static func header(lines: Int, clipped: Bool, rolledAt: Int64) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "UTC")
        let rolled = iso.string(from: Date(timeIntervalSince1970: TimeInterval(rolledAt / 1000)))
        let count = "\(lines) line(s)" + (clipped ? ", head clipped" : "")
        return "===== previous app session, \(count), rolled at \(rolled) (this launch) ====="
    }

    /// The earlier runs as an export prints them, ending in the current-run marker; "" when there are none.
    /// A run's "rolled at" is when the run after it began — the moment the ring used to roll it.
    static func render(legacy: [String], runs: [(start: Int64, lines: [String], clipped: Bool)],
                       currentStart: Int64) -> String {
        guard !legacy.isEmpty || !runs.isEmpty else { return "" }
        var out = legacy
        for (i, run) in runs.enumerated() {
            let next = i + 1 < runs.count ? runs[i + 1].start : currentStart
            out.append(header(lines: run.lines.count, clipped: run.clipped, rolledAt: next))
            out += run.lines
        }
        return out.joined(separator: "\n") + "\n" + currentRunMarker + "\n"
    }

    private static func lines(of url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
