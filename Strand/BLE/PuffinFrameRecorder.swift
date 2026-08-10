import Foundation
import CoreBluetooth
import WhoopProtocol

/// App-side glue around the pure `PuffinCapture`: gates on a user toggle, stamps each frame with a
/// wall-clock time and the live (standard-profile) heart rate, and persists the growing capture to a
/// JSON file under Application Support. Read-only with respect to the strap — it only records frames
/// that already arrived, it never writes to the device — so it is always safe to leave on.
///
/// `@MainActor` because it reads `LiveState.heartRate` and updates published capture status; the
/// BLEManager delegate callbacks that feed it are already on the main queue. The actual JSON encode +
/// atomic file write + old-capture eviction — the part whose cost grows with the capture size — does
/// NOT run on the main actor: it is handed off to the `fileWriter` background actor (#652) so a flush
/// never blocks the main thread / SwiftUI, no matter how large the in-memory buffer has grown this
/// session. Only the cheap bookkeeping (appending to `buffer`, bumping counters, snapshotting the
/// buffer for a flush) stays on the main actor, since that is what other code reads synchronously for
/// live-state display (`LiveState.puffinCaptureCount`/`puffinCaptureURL`, read by SettingsView et al).
@MainActor
final class PuffinFrameRecorder {
    /// UserDefaults flag, mirrored by the Settings toggle (`@AppStorage`). Separate from the puffin
    /// *probe* switch (`PuffinExperiment`): capturing is passive/safe, probing actively guesses.
    static let enabledKey = "noopPuffinCapture"

    /// Flush to disk every this-many frames so a crash/yank loses at most a handful of frames.
    private static let flushEvery = 25

    /// Soft cap on the total size of the puffin-captures directory (#27). One file is written per app
    /// launch and never trimmed, so without a cap the directory grows without bound — an experimental
    /// capture toggle a 5/MG user left on reached 19 GB. After each flush, oldest files are evicted
    /// (by filename, which is timestamp-sorted) until the total is back under the cap. Never deletes
    /// the file the current session is still writing.
    private nonisolated static let directorySoftCapBytes = 50 * 1024 * 1024

    private weak var state: LiveState?
    private let buffer = PuffinCapture()
    private var sinceFlush = 0
    private var fileURL: URL?

    /// Performs the encode + write + eviction off the main actor. An `actor`, so overlapping flushes
    /// serialize on it rather than racing two writes at the same file.
    private let fileWriter = PuffinFileWriter()

    /// Non-nil while a flush's background write is in-flight. Lets `capture()` skip redundant
    /// auto-flush triggers while one is already running, and lets a concurrent explicit `flush()` call
    /// (export/reveal/disconnect) await the SAME write instead of racing a second one for the same
    /// file — which could otherwise let an older, smaller snapshot's write land after a newer one's
    /// and regress the on-disk capture.
    private var flushTask: Task<Void, Never>?

    init(state: LiveState) {
        self.state = state
    }

    private var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// `<AppSupport>/OpenWhoop/puffin-captures/`, created on demand. `nonisolated` so the background
    /// `fileWriter` actor can call it (via `evictOldCaptures`) without hopping back to the main actor.
    private nonisolated static func captureDirectory() throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                             appropriateFor: nil, create: true)
            .appendingPathComponent("OpenWhoop", isDirectory: true)
            .appendingPathComponent("puffin-captures", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Record one puffin frame (off `fd4b0003/0004/0005/0007`). No-op unless capture is enabled.
    /// Synchronous — this is called directly from a CoreBluetooth delegate callback on the main queue
    /// and must never block on file I/O, so a due auto-flush is only ever *triggered* here, never
    /// awaited (see `flush()`).
    func capture(frame: [UInt8], char: CBUUID) {
        guard isEnabled else { return }
        let tsMs = Int(Date().timeIntervalSince1970 * 1000)
        buffer.record(frame: frame, char: char.uuidString.lowercased(),
                      tsMs: tsMs, hr: state?.heartRate)
        sinceFlush += 1
        state?.puffinCaptureCount = buffer.count
        if sinceFlush >= Self.flushEvery && flushTask == nil {
            flushTask = Task { [weak self] in
                guard let self else { return }
                await self.runFlush()
            }
        }
    }

    /// Flush the buffered frames to disk (best-effort, atomic). Awaited by explicit callers (export,
    /// reveal, disconnect-before-reconnect) so the on-disk file is guaranteed current by the time this
    /// returns — joins an in-flight auto-flush instead of starting a second, racing write when one is
    /// already running.
    func flush() async {
        // Let any in-flight auto-flush finish first (don't race a second write for the same generation),
        // THEN do one FRESH write of the current buffer — so the file includes every frame captured up to
        // this call, which export / reveal / disconnect rely on. (Coalescing straight onto the in-flight
        // flush would return that flush's OLDER snapshot and silently drop frames captured since.) This
        // fresh write goes directly through the serializing `fileWriter` actor and deliberately does NOT
        // touch `flushTask`, so it can't disturb the auto-flush guard; if capture() starts a new auto-flush
        // while this write is in flight, the actor serializes the two (this one submitted first, so an
        // even-newer auto-flush lands last) and neither corrupts nor regresses the file.
        if let inFlight = flushTask { await inFlight.value }
        guard buffer.count > 0, let url = try? sessionFileURL() else { return }
        if await fileWriter.write(records: buffer.records, to: url) {
            sinceFlush = 0
            state?.puffinCaptureURL = url
        }
    }

    /// The actual flush body: snapshot the buffer on the main actor (an O(1) copy-on-write of a
    /// value-type array, not a re-encode), then hand the JSON encode + atomic write + eviction to the
    /// `fileWriter` background actor. Only the state hand-off crosses the actor boundary.
    private func runFlush() async {
        defer { flushTask = nil }
        guard buffer.count > 0, let url = try? sessionFileURL() else { return }
        let snapshot = buffer.records
        let ok = await fileWriter.write(records: snapshot, to: url)
        if ok {
            sinceFlush = 0
            state?.puffinCaptureURL = url
        }
        // A failed write is best-effort, exactly as before: `sinceFlush` and `puffinCaptureURL` are
        // left alone, so the next flush just rewrites the whole file again.
    }

    /// Enforce the directory soft cap by deleting the oldest capture files (best-effort). Filenames are
    /// `puffin-yyyyMMdd-HHmmss.json`, so lexicographic order is chronological — delete from the front
    /// until the total is back under the cap. `keep` (the active session file) is never deleted.
    /// `fileprivate nonisolated` so the background `fileWriter` actor can call it directly after a
    /// write, without hopping back to the main actor.
    fileprivate nonisolated static func evictOldCaptures(keeping keep: URL) {
        let fm = FileManager.default
        guard let dir = try? captureDirectory() else { return }
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]) else { return }
        // Sort oldest-first by name (timestamped). Pair each with its size up front.
        let files = entries
            .filter { $0.pathExtension == "json" }
            .map { (url: $0, size: (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files {
            guard total > directorySoftCapBytes else { break }
            if file.url == keep { continue }   // never delete the active session file
            do {
                try fm.removeItem(at: file.url)
                total -= file.size
            } catch {
                // Best-effort: skip a file we couldn't remove; the next flush retries.
            }
        }
    }

    /// One file per recorder lifetime (i.e. per app launch), named on first use. Re-flushing rewrites
    /// the same file, so the capture file always holds the complete session.
    private func sessionFileURL() throws -> URL {
        if let url = fileURL { return url }
        let stamp = Self.fileStampFormatter.string(from: Date())
        let url = try Self.captureDirectory().appendingPathComponent("puffin-\(stamp).json")
        fileURL = url
        return url
    }

    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}

/// Off-main-actor home for the expensive part of a puffin flush: encoding the (growing) in-memory
/// capture to JSON and atomically rewriting the session file, then evicting old captures. `actor`
/// isolation means two overlapping calls (an auto-flush racing an explicit flush) are serialized
/// rather than both touching the same file at once — `PuffinFrameRecorder.flush()` additionally
/// coalesces callers onto a single in-flight `Task` so a second write for the same generation of data
/// is never even started, but the actor boundary is kept as a second, independent safety net.
///
/// This still re-encodes+rewrites the WHOLE capture on every flush (the JSON-array-of-objects format
/// that downstream tooling — the export/share/bundle paths and the protocol-mapping fixture format —
/// already expects is kept as-is here; switching to an append-only JSONL format was judged a bigger
/// format-migration risk than the win of avoiding the O(n) re-encode, see #652). What moved is WHERE
/// that encode+write runs, not how much work it does per flush.
private actor PuffinFileWriter {
    /// Encode `records` and atomically write them to `url`, then run the directory eviction. Returns
    /// whether the write succeeded; best-effort exactly like the flush this replaces.
    func write(records: [PuffinCaptureRecord], to url: URL) -> Bool {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try enc.encode(records)
            try data.write(to: url, options: .atomic)
            // Bound on-disk growth (#27): evict oldest captures beyond the soft cap, never the file
            // this session is still writing. Runs off the main actor too, alongside the write.
            PuffinFrameRecorder.evictOldCaptures(keeping: url)
            return true
        } catch {
            return false
        }
    }
}
