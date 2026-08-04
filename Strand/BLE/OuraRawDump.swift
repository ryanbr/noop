import Foundation
import WhoopStore

/// Append-only JSONL sidecar for the Oura RAW capture — the UNDECODED history-drain notification bytes,
/// exactly as received. Complement to the *decoded* sidecars (`OuraActivityDump` = MET, `OuraIbiHrDump` =
/// HR from IBIs): those show what NOOP interpreted; this shows what the ring actually sent.
///
/// WHY: NOOP can drop packets, and the decoded files can only ever show what we decoded — so a hole in them
/// is ambiguous (ring never sent it, vs we dropped/failed to decode it). This raw capture removes the
/// ambiguity: after a full connect we know exactly which TLV records arrived. Reframe it OFFLINE (walk the
/// `2+len` records, read tag + ring-time) and a window empty in a decoded file but present here is a DECODE
/// drop; absent in both is RING-SIDE. It also preserves tags NOOP does not decode yet. Never scored; nothing
/// reads it back; safe to delete.
///
/// SCOPE: the HISTORY-drain record path only — the tap sits where reassembled TLV notifications are fed to
/// the driver, NOT the high-frequency live-HR push, so a night stays bounded. Auth/secure frames are
/// consumed before this tap, so only DATA records land here (no challenge/response crypto). Unlike the
/// decoded sidecars there is NO dedup high-water: a re-served record is still evidence the ring re-sent it,
/// and the offline reframer collapses duplicates by (tag, ring-time).
///
/// Location: `<Application Support>/OpenWhoop/Diagnostics/oura-raw-<deviceId>.jsonl` — beside the SQLite.
final class OuraRawDump {
    private let deviceId: String
    private let log: (String) -> Void
    private var fileURL: URL?
    private var resolveFailed = false
    private var announced = false

    /// Rotate the sidecar past this size (keeping one previous ".1"), so an always-on research corpus is
    /// bounded to ~2× this on disk instead of growing forever. Matches `OuraMotionDump`/`OuraActivityDump` —
    /// this file needs it MORE than either: full hex of every notification, and no dedup high-water.
    private static let maxBytes = 25 * 1024 * 1024

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    init(deviceId: String, log: @escaping (String) -> Void) {
        self.deviceId = deviceId
        self.log = log
    }

    /// Append one raw notification's bytes verbatim (hex-encoded), stamped with wall-clock arrival time.
    /// No-op on empty input. Best-effort: any file error is logged once and never disrupts the BLE path.
    func record(bytes: [UInt8]) {
        guard !bytes.isEmpty, var url = resolveURL() else { return }

        // Bound the corpus (rotate to a single ".1", dropping the prior one) so an always-on research sidecar
        // can't grow unbounded — same rotation as OuraMotionDump. Read the size via a fresh FileManager stat
        // rather than URL.resourceValues, whose cache on the reused URL can return a stale small size.
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        if size > Self.maxBytes {
            let old = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
            fileURL = nil
            guard let fresh = resolveURL() else { return }
            url = fresh
        }

        let now = Date()
        let line = OuraRawDumpLine.encode(
            deviceId: deviceId, utc: Int(now.timeIntervalSince1970),
            iso: Self.iso.string(from: now), bytes: bytes)

        guard let data = (line + "\n").data(using: .utf8) else { return }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            handle.write(data)
        } catch {
            log("Oura: raw dump write failed - \(error.localizedDescription)")
            return
        }

        if !announced {
            announced = true
            log("Oura: raw notification capture → \(url.path) [undecoded TLV bytes, JSONL; reframe offline]")
        }
    }

    /// Resolve (and create on first use) the sidecar file + its parent directory. Cached; a failure is
    /// logged once and latched so we never spam the strap log on a read-only volume.
    private func resolveURL() -> URL? {
        if let fileURL { return fileURL }
        if resolveFailed { return nil }
        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
            let dir = base.appendingPathComponent("OpenWhoop/Diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safeId = deviceId.replacingOccurrences(of: "/", with: "_")
            let url = dir.appendingPathComponent("oura-raw-\(safeId).jsonl")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            fileURL = url
            return url
        } catch {
            resolveFailed = true
            log("Oura: raw dump unavailable - \(error.localizedDescription)")
            return nil
        }
    }
}
