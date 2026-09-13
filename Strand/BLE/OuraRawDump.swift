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
/// LIFETIME: the live file holds exactly ONE capture session. At the START of a session — the first time
/// this object resolves its file — the previous session is rolled into a numbered generation ring
/// (`.1` … `.N`, newest first) and never touched again while the session runs. One `OuraRawDump` is built
/// per `OuraLiveSource`, and a source survives BLE reconnects (`SourceCoordinator` returns early when the
/// active strap is unchanged), so a drain that disconnects and re-engages several times still lands whole
/// in one file.
///
/// WHY NOT a size threshold, which is what this used to do: a threshold can fire MID-DRAIN, and on
/// 2026-08-09 it did — 25 MB rolled at 07:06:58 during the morning offload, carrying 32,005 records of
/// that drain and 71 of the night's 75 `0x5D` records into the `.1`. Lowering the threshold makes that
/// MORE frequent, not less; only rolling on a session boundary removes it. The corpus stays bounded
/// because a session is bounded: an overnight drain is ~32,000 records ≈ 4 MB.
///
/// WHY A RING AND NOT ONE `.1`, which is what the first version of this did: **retaining a single
/// generation is not enough to survive an ordinary morning.** Measured 2026-08-10 — the app relaunched
/// twice after wake (07:45 and 08:17 local), so by the time the capture was pulled off the phone BOTH
/// retained slots held post-wake sessions of 87 KB and 44 KB, and the night's 4 MB was gone. Session
/// scoping fixed the mid-drain roll and then lost the night a different way: rotation ate a night every
/// ~5–6 days at random; one-deep session scoping ate it every morning the app restarted twice, which is
/// the normal morning. An iOS app is relaunched whenever the user opens it, so the number of session
/// boundaries between a night and its export is not something this class can predict — it can only keep
/// enough of them.
///
/// Two rules keep the ring honest, and both exist because of that measurement:
///   * a session under `minRolledBytes` is DISCARDED rather than rolled, so a connect that captured
///     essentially nothing (the 44 KB one above) cannot evict a real overnight capture;
///   * the retained generations are pruned oldest-first to `maxRetainedBytes`, so the ring is bounded in
///     BYTES and not merely in file count (each generation may be up to `maxSessionBytes`).
///
/// `TestBundleAssembler` ships the LARGEST generation for this kind, so the export carries the night even
/// when the live file is a fresh 30-second session — which is exactly the state a morning export is taken
/// in. Keeping generations on disk without that change would only help someone with a USB cable.
///
/// Location: `<Application Support>/OpenWhoop/Diagnostics/oura-raw-<deviceId>.jsonl` — beside the SQLite.
final class OuraRawDump {
    private let deviceId: String
    private let log: (String) -> Void
    private let directory: URL?
    private var fileURL: URL?
    private var resolveFailed = false
    private var announced = false
    private var sessionBytes = 0
    private var ceilingHit = false

    /// Hard ceiling on ONE session's file. Never a rotation — a session that somehow reaches this stops
    /// appending and says so once, because rolling mid-session is the exact failure this class was changed
    /// to remove. Far above a real overnight drain (~4 MB), so in practice it never fires; it exists so a
    /// pathological backlog cannot fill the disk.
    static let maxSessionBytes = 25 * 1024 * 1024

    /// How many completed sessions are kept beside the live file, as `.1` (newest) … `.N` (oldest). Eight
    /// covers a morning of app relaunches with room to spare, and at a typical ~4 MB overnight session the
    /// whole ring is ~32 MB — well inside `maxRetainedBytes`, which is what actually bounds it.
    static let retainedGenerations = 8

    /// A finished session smaller than this is deleted instead of rolled. It is not a judgement about which
    /// captures matter — it is the one rule that stops a burst of trivial reconnect sessions from flushing
    /// the ring. 16 KB is ~100 records: a connect that drained nothing. Deliberately far below the 44 KB
    /// session that destroyed the 2026-08-10 capture, so the rule is a backstop and the ring does the work.
    static let minRolledBytes = 16 * 1024

    /// Byte budget for the retained generations (the live file is excluded — it has its own ceiling).
    /// Pruned oldest-first, so a pathological run of large sessions cannot fill the disk.
    static let maxRetainedBytes = 64 * 1024 * 1024

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// `directory` is injectable so the session-roll behaviour is testable against a temp dir; production
    /// passes nil and gets `<Application Support>/OpenWhoop/Diagnostics`.
    init(deviceId: String, log: @escaping (String) -> Void, directory: URL? = nil) {
        self.deviceId = deviceId
        self.log = log
        self.directory = directory
    }

    /// Append one raw notification's bytes verbatim (hex-encoded), stamped with wall-clock arrival time.
    /// No-op on empty input. Best-effort: any file error is logged once and never disrupts the BLE path.
    func record(bytes: [UInt8]) {
        guard !bytes.isEmpty, let url = resolveURL() else { return }

        let now = Date()
        let line = OuraRawDumpLine.encode(
            deviceId: deviceId, utc: Int(now.timeIntervalSince1970),
            iso: Self.iso.string(from: now), bytes: bytes)

        guard let data = (line + "\n").data(using: .utf8) else { return }

        // Ceiling check against a running counter, not a stat per record: the file starts EMPTY each
        // session (resolveURL rolls it), so the counter is authoritative and costs no filesystem call.
        guard sessionBytes + data.count <= Self.maxSessionBytes else {
            if !ceilingHit {
                ceilingHit = true
                log("Oura: raw capture reached its \(Self.maxSessionBytes / (1024 * 1024)) MB session "
                    + "ceiling - no longer appending (the file is NOT rolled mid-session)")
            }
            return
        }

        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            handle.write(data)
            sessionBytes += data.count
        } catch {
            log("Oura: raw dump write failed - \(error.localizedDescription)")
            return
        }

        if !announced {
            announced = true
            log("Oura: raw notification capture → \(url.path) [undecoded TLV bytes, JSONL; reframe offline]")
        }
    }

    /// Resolve the sidecar file + its parent directory, ROLLING the previous session's file aside on the
    /// first call so this session starts from empty. Cached, so the roll happens exactly once per object —
    /// which is what makes it a session boundary rather than a size threshold. A failure is logged once and
    /// latched so we never spam the strap log on a read-only volume.
    private func resolveURL() -> URL? {
        if let fileURL { return fileURL }
        if resolveFailed { return nil }
        do {
            let dir: URL
            if let directory {
                dir = directory
            } else {
                let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
                dir = base.appendingPathComponent("OpenWhoop/Diagnostics", isDirectory: true)
            }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safeId = deviceId.replacingOccurrences(of: "/", with: "_")
            let url = dir.appendingPathComponent("oura-raw-\(safeId).jsonl")

            // Session roll: shift the previous session into the generation ring and begin fresh, so the live
            // file is always exactly this capture. A leftover that captured essentially nothing (including an
            // empty one) is dropped rather than rolled — spending a generation on it is how the 2026-08-10
            // capture was lost.
            let existing = Self.byteSize(url)
            if existing >= Self.minRolledBytes {
                rollGenerations(in: dir, base: url)
                pruneRetained(in: dir, base: url)
            } else if existing > 0 {
                try? FileManager.default.removeItem(at: url)
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            sessionBytes = 0
            fileURL = url
            return url
        } catch {
            resolveFailed = true
            log("Oura: raw dump unavailable - \(error.localizedDescription)")
            return nil
        }
    }

    /// The generation file for `index` (1 = newest retained session).
    static func generationURL(base: URL, index: Int) -> URL {
        base.deletingLastPathComponent()
            .appendingPathComponent(base.lastPathComponent + ".\(index)")
    }

    private static func byteSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    }

    /// Shift the ring up by one: the oldest generation is dropped, every other moves down a slot, and the
    /// finished live file becomes `.1`. Best-effort throughout — a failed move must never break the BLE
    /// path, and the worst outcome is one lost generation rather than a lost session.
    private func rollGenerations(in dir: URL, base url: URL) {
        let oldest = Self.generationURL(base: url, index: Self.retainedGenerations)
        try? FileManager.default.removeItem(at: oldest)
        var index = Self.retainedGenerations - 1
        while index >= 1 {
            let from = Self.generationURL(base: url, index: index)
            let to = Self.generationURL(base: url, index: index + 1)
            if FileManager.default.fileExists(atPath: from.path) {
                try? FileManager.default.removeItem(at: to)
                try? FileManager.default.moveItem(at: from, to: to)
            }
            index -= 1
        }
        try? FileManager.default.moveItem(at: url, to: Self.generationURL(base: url, index: 1))
    }

    /// Drop retained generations oldest-first until they fit `maxRetainedBytes`. Counts only the ring: the
    /// live file has its own per-session ceiling and is not part of this budget.
    private func pruneRetained(in dir: URL, base url: URL) {
        var total = 0
        var kept: [URL] = []
        for index in 1...Self.retainedGenerations {
            let gen = Self.generationURL(base: url, index: index)
            let size = Self.byteSize(gen)
            guard size > 0 else { continue }
            total += size
            kept.append(gen)
        }
        guard total > Self.maxRetainedBytes else { return }
        for gen in kept.reversed() {           // oldest slot first
            guard total > Self.maxRetainedBytes else { break }
            total -= Self.byteSize(gen)
            try? FileManager.default.removeItem(at: gen)
        }
        log("Oura: raw capture ring pruned to its \(Self.maxRetainedBytes / (1024 * 1024)) MB budget")
    }
}
