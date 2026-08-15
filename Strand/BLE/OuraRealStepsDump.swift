import Foundation
import WhoopStore

/// Append-only JSONL sidecar for the Oura 0x7E/0x7F real_steps_features stream — a Tier-B RESEARCH
/// corpus for investigation, NOT a datastore row (see `OuraRealStepsDumpLine` for the rationale). Direct
/// twin of `OuraActivityDump` / `OuraCvaPpgDump`: owns the file handle, the on-disk path, the
/// once-per-launch "here is the file" log line, and a persistent ring-time high-water so records the
/// ring re-serves across reconnects are written exactly once instead of duplicating the corpus.
///
/// Location: `<Application Support>/OpenWhoop/Diagnostics/oura-real-steps-<deviceId>.jsonl` — beside the
/// app's SQLite so the user can find it. Purely diagnostic and safe to delete; nothing reads it back.
///
/// It is NOT a step-decode corpus: ground truth closed that question (no field is a count — see
/// `OuraRealStepsFields` and OURA_PROTOCOL.md §6.13). It exists as a **movement-feature** corpus — `f0`
/// and `f8` discriminate movement strongly (Cohen's d ≈ +2.35), so the file is useful for activity work
/// and for cross-checking the `0x7F` +2-byte offset against `0x7E` on new firmware. Nothing here may be
/// turned into steps.
final class OuraRealStepsDump {
    private let deviceId: String
    private let log: (String) -> Void
    private let highWaterKey: String
    /// Only records with `ringTs` STRICTLY above this are written; re-served (older) records are dropped.
    /// Persisted in UserDefaults so the dedup survives app relaunches (a fresh drain re-emits old records).
    private var highWater: UInt32
    private var fileURL: URL?
    private var resolveFailed = false
    private var announced = false

    /// Rotate the sidecar past this size (keeping one previous ".1"), so an always-on research corpus is
    /// bounded to ~2× this on disk instead of growing forever. Matches the other Oura Tier-B dumps.
    private static let maxBytes = 25 * 1024 * 1024

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    init(deviceId: String, log: @escaping (String) -> Void) {
        self.deviceId = deviceId
        self.log = log
        self.highWaterKey = "oura.realStepsDump.highwater.\(deviceId)"
        let stored = UserDefaults.standard.integer(forKey: highWaterKey)   // 0 when unset → writes everything
        self.highWater = stored > 0 ? UInt32(truncatingIfNeeded: stored) : 0
    }

    /// Append one anchored real_steps record. No-op when `ringTs` is not above the high-water (a
    /// re-serve), so the corpus stays deduped. Best-effort: any file error is logged once and never
    /// disrupts the BLE path. Call ONLY with an anchored `utc` (an un-anchored record has no real time
    /// axis and re-arrives anchored on the next drain).
    func record(tag: UInt8, ringTs: UInt32, utc: Int, fields: [Int]) {
        guard ringTs > highWater else { return }
        guard var url = resolveURL() else { return }
        // Bound the corpus (rotate to a single ".1", dropping the prior one) so an always-on research
        // sidecar can't grow unbounded — same rotation as the other Oura Tier-B dumps. Read the size via
        // a fresh FileManager stat rather than URL.resourceValues, whose cache on the reused URL can
        // return a stale small size.
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        if size > Self.maxBytes {
            let old = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
            fileURL = nil
            guard let fresh = resolveURL() else { return }
            url = fresh
        }

        let tagStr = "0x" + String(tag, radix: 16)
        let line = OuraRealStepsDumpLine.encode(
            deviceId: deviceId, tag: tagStr, ringTs: ringTs, utc: utc,
            iso: Self.iso.string(from: Date(timeIntervalSince1970: TimeInterval(utc))), fields: fields)

        guard let data = (line + "\n").data(using: .utf8) else { return }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            handle.write(data)
        } catch {
            log("Oura: real_steps dump write failed - \(error.localizedDescription)")
            return
        }

        highWater = ringTs
        UserDefaults.standard.set(Int(ringTs), forKey: highWaterKey)
        if !announced {
            announced = true
            log("Oura: real_steps 0x7E/0x7F dump → \(url.path) [Tier-B research corpus, JSONL, deduped by ring-time]")
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
            let url = dir.appendingPathComponent("oura-real-steps-\(safeId).jsonl")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            fileURL = url
            return url
        } catch {
            resolveFailed = true
            log("Oura: real_steps dump unavailable - \(error.localizedDescription)")
            return nil
        }
    }
}
