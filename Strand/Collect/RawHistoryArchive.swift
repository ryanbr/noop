import Foundation
import WhoopProtocol

/// Append-only on-disk archive of HISTORICAL_DATA record frames that FAILED decode (#77 / #91).
///
/// The strap frees acked history the instant we send HISTORICAL_DATA_RESULT. On an unmapped
/// firmware layout the Backfiller decodes those records to zero rows, yet still has to ack the trim
/// (refusing would wedge the whole offload on a re-send loop). Without somewhere to put the raw
/// bytes first, every undecodable record is gone forever while the UI shows a healthy "History
/// synced". This archive is the user's only remaining copy — and the corpus a later layout mapping
/// re-ingests.
///
/// Format: newline-delimited JSON, one object per line, fsynced before returning so the bytes are
/// durable BEFORE the trim ack deletes the strap's copy (the whole point):
///   {"capturedAtMs":Double,"trim":Int,"family":"whoop4"|"whoop5","frameHex":String}
/// Frames carry sensor payloads, not identifiers — no serials/MACs land here. The companion Android
/// archive uses the same record shape so one mapping toolchain reads both.
struct RawHistoryArchive {
    /// File name under `<AppSupport>/com.noopapp.noop/`.
    static let fileName = "rejected_history.jsonl"
    /// Soft cap (~5 MB). When appending would push the file past this, the archive EVICTS oldest
    /// surplus lines to make room rather than refusing the write — but only down to a per-version
    /// retention floor (see `perVersionFloor`), so a brand-new layout version is never binned merely
    /// because common versions filled the file. Only when the incoming frames alone can't fit even an
    /// empty archive does `archive` skip them (reported as unarchived). (#344)
    static let maxBytes = 5 * 1024 * 1024

    /// Per distinct layout VERSION, keep at least this many of the newest archived lines, immune to
    /// cap eviction. A never-seen version (WHOOP 4 v19, WHOOP 5 v20/v21 — `frame[5]` / `frame[9]`,
    /// the hist_version byte) emits only a handful of frames, so this floor guarantees those rare
    /// samples survive while the most-populous versions shed their oldest surplus. Bounded: the floor
    /// can hold at most `floor × distinctVersions` lines, a tiny set. (#344)
    static let perVersionFloor = 64

    /// Outcome of an archive attempt.
    enum Result {
        /// Frames were durably written (fsynced). `count` is how many lines were appended.
        case written(count: Int)
        /// The archive is full; nothing was written but the caller may still ack. `count` frames
        /// were dropped (counted as unarchived so the sync status never claims "saved").
        case capReached(count: Int)
        /// The write genuinely failed. The caller must NOT ack — hold the cursor so the strap
        /// re-sends the chunk (no data loss either way).
        case failed
    }

    private let directory: URL
    /// Effective cap/floor; default to the static constants but overridable so tests can drive the
    /// eviction path with a small archive instead of generating 5 MB of frames. (#344)
    private let maxBytes: Int
    private let perVersionFloor: Int

    /// Default location: `<AppSupport>/com.noopapp.noop/`, created on demand. Overridable for tests.
    init(directory: URL? = nil,
         maxBytes: Int = RawHistoryArchive.maxBytes,
         perVersionFloor: Int = RawHistoryArchive.perVersionFloor) {
        if let directory {
            self.directory = directory
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil, create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appendingPathComponent("com.noopapp.noop", isDirectory: true)
        }
        self.maxBytes = maxBytes
        self.perVersionFloor = perVersionFloor
        #if os(iOS)
        // Migrate an archive created by an older build while launch is normally foreground/unlocked.
        // The write path repeats this before every append so a first background write is covered too.
        try? prepareStorageForBackgroundAccess()
        #endif
    }

    /// The archive file URL (does not create anything).
    var fileURL: URL { directory.appendingPathComponent(RawHistoryArchive.fileName) }

    /// The hist_version byte distinguishing one historical layout from another: `frame[5]` on WHOOP 4,
    /// `frame[9]` on WHOOP 5/MG (the puffin envelope is 4 bytes longer). Same indices the reject filter
    /// uses. Frames too short to carry it fall back to a sentinel so they still form their own bucket.
    static func versionByte(_ frame: [UInt8], family: DeviceFamily) -> Int {
        let idx = family == .whoop5 ? 9 : 5
        return frame.count > idx ? Int(frame[idx]) : -1
    }

    /// A per-version retention key. Family is part of the key so a WHOOP 4 v18 and a WHOOP 5 v18 are
    /// kept as distinct buckets (their layouts differ despite the shared version number).
    private struct VersionKey: Hashable { let family: String; let version: Int }

    private func versionKey(family: DeviceFamily, version: Int) -> VersionKey {
        VersionKey(family: family.rawValue, version: version)
    }

    /// Durably append `frames` as JSONL. `trim`/`family` tag each line so the corpus is replayable.
    /// Empty input is a no-op success. See `Result` for the ack contract.
    ///
    /// Cap handling (#344): if appending would exceed `maxBytes`, oldest SURPLUS lines are evicted
    /// (oldest-first, from the most-populous versions) — but never below `perVersionFloor` newest
    /// lines of any distinct version, so a rare never-seen layout is never binned just because common
    /// versions filled the archive. The file is rewritten atomically in that case. Only when the
    /// incoming frames alone can't fit even an empty archive are they skipped (`.capReached`).
    func archive(_ frames: [[UInt8]], trim: UInt32, family: DeviceFamily) -> Result {
        guard !frames.isEmpty else { return .written(count: 0) }
        let url = fileURL
        do {
            try prepareStorageForBackgroundAccess()
        } catch {
            return .failed
        }
        let capturedAtMs = Date().timeIntervalSince1970 * 1000
        // Build the new JSONL lines (each newline-terminated). The version that drives floor-aware
        // retention (#344) is re-derived per line from the stored frame inside `evictLines`.
        let newLines: [String] = frames.map { f in
            let hex = f.map { String(format: "%02x", $0) }.joined()
            // Hand-built JSON: the only dynamic field is hex (always [0-9a-f]) so no escaping is
            // needed, and this avoids a JSONEncoder allocation per frame on the offload hot path.
            return "{\"capturedAtMs\":\(capturedAtMs),\"trim\":\(Int(trim)),"
                + "\"family\":\"\(family.rawValue)\",\"frameHex\":\"\(hex)\"}\n"
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let existingSize = (attrs?[.size] as? Int) ?? 0
        let incomingBytes = newLines.reduce(0) { $0 + $1.utf8.count }

        // Fast path: it all fits — plain append (no rewrite, fsync before returning).
        if existingSize + incomingBytes <= maxBytes {
            let data = Data(newLines.joined().utf8)
            do {
                try appendDurably(data, to: url)
                return .written(count: frames.count)
            } catch {
                return .failed
            }
        }

        // The incoming batch alone can't fit even an empty archive: nothing we can evict makes room,
        // so skip it (the offload may still ack — by now there is ample sample material). Preserves
        // the prior cap contract for this degenerate case.
        if incomingBytes > maxBytes {
            return .capReached(count: frames.count)
        }

        // Over cap: rewrite with floor-aware eviction. Read existing lines (oldest first), append the
        // new lines (which sort newest), then drop oldest surplus until we fit — never dropping a line
        // within the newest `perVersionFloor` of its version. `evictLines` is the pure, unit-tested core.
        let existing = (try? String(contentsOf: url, encoding: .utf8))
            .map { $0.split(separator: "\n", omittingEmptySubsequences: true).map { String($0) + "\n" } } ?? []
        let kept = RawHistoryArchive.evictLines(existing + newLines, maxBytes: maxBytes, floor: perVersionFloor)
        let data = Data(kept.joined().utf8)
        do {
            try data.write(to: url, options: .atomic)   // atomic rewrite; durable before the ack
            applyBackgroundProtectionToArchive()
            return .written(count: frames.count)
        } catch {
            return .failed
        }
    }

    /// Append `data` to `url`, fsyncing before returning so it is durable BEFORE the trim ack.
    private func appendDurably(_ data: Data, to url: URL) throws {
        try prepareStorageForBackgroundAccess()
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()   // durable BEFORE the ack — the point of the archive
        } else {
            try data.write(to: url, options: .atomic)
            applyBackgroundProtectionToArchive()
        }
    }

    /// Make the reject archive readable after the first unlock, matching the primary SQLite store's
    /// policy in `StorePaths`. Background BLE can be woken while the phone is locked; the default iOS
    /// complete protection would otherwise make this mandatory pre-ack write fail and force the strap
    /// to resend the same history chunk. Apply the policy to both the directory (future files inherit it)
    /// and any existing archive from an older build. Other platforms only need directory creation.
    private func prepareStorageForBackgroundAccess() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        let protection: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        ]
        try? fm.setAttributes(protection, ofItemAtPath: directory.path)
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.setAttributes(protection, ofItemAtPath: fileURL.path)
        }
        #endif
    }

    /// Atomic replacement creates a new inode, so explicitly re-apply the file policy after every new
    /// file/rewrite instead of relying only on directory inheritance.
    private func applyBackgroundProtectionToArchive() {
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
        #endif
    }

    /// The `VersionKey` of one archived JSONL line, re-derived from its stored frame + family; `nil`
    /// for a malformed/unparseable line — those get NO retention floor (evict them first, never let
    /// garbage occupy a floor slot a real rare version could use), and are always evictable before any
    /// real, floor-protected line.
    private static func lineVersionKey(_ line: String) -> VersionKey? {
        guard let fr = line.range(of: "\"family\":\""),
              let hr = line.range(of: "\"frameHex\":\"") else { return nil }
        let fam = String(line[fr.upperBound...].prefix { $0 != "\"" })
        let hex = line[hr.upperBound...].prefix { $0 != "\"" }
        guard let family = DeviceFamily(rawValue: fam), hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(hex.count / 2); var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b); i = j
        }
        return VersionKey(family: fam, version: RawHistoryArchive.versionByte(bytes, family: family))
    }

    /// Floor-aware cap eviction (#344), PURE so it is unit-testable. `lines` is the full
    /// newline-terminated JSONL set, oldest-first (existing + incoming). Drops oldest SURPLUS lines
    /// until the UTF-8 byte total fits `maxBytes`, but NEVER a line within the newest `floor` lines of
    /// its version — so a rare never-seen layout (WHOOP 4 v19, WHOOP 5 v20/v21) always survives even
    /// when common versions fill the archive. Bounded: if everything left is floor-protected it stops
    /// even if still over cap (the floor wins — `floor × distinctVersions` is tiny). Mirrors the Android
    /// RawHistoryArchive.evictLines.
    static func evictLines(_ lines: [String], maxBytes: Int, floor: Int) -> [String] {
        // Mark the newest `floor` indices of each version as protected (scan newest→oldest). Malformed
        // lines (nil key) are never protected — they are evicted before any real, floor-kept line.
        let keys = lines.map { lineVersionKey($0) }
        var protectedIdx = Set<Int>()
        var seen: [VersionKey: Int] = [:]
        for idx in lines.indices.reversed() {
            guard let k = keys[idx] else { continue }
            let c = (seen[k] ?? 0)
            if c < floor { protectedIdx.insert(idx); seen[k] = c + 1 }
        }
        var total = lines.reduce(0) { $0 + $1.utf8.count }
        guard total > maxBytes else { return lines }
        // Evict oldest unprotected lines first.
        var dropped = Set<Int>()
        for idx in lines.indices where total > maxBytes {   // ascending = oldest first
            if protectedIdx.contains(idx) { continue }
            dropped.insert(idx)
            total -= lines[idx].utf8.count
        }
        return lines.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
    }

    /// Every archived frame with its strap family, oldest first — the read-back of the JSONL that
    /// `archive` writes. Malformed lines are skipped; an absent/empty file yields []. (Hand-parsed to
    /// match the hand-built writer: the only dynamic fields are `family` and the [0-9a-f] `frameHex`.)
    func readAll() -> [(frame: [UInt8], family: DeviceFamily)] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let fr = line.range(of: "\"family\":\""),
                  let hr = line.range(of: "\"frameHex\":\"") else { return nil }
            let fam = String(line[fr.upperBound...].prefix { $0 != "\"" })
            let hex = line[hr.upperBound...].prefix { $0 != "\"" }
            guard let family = DeviceFamily(rawValue: fam), hex.count % 2 == 0 else { return nil }
            var bytes = [UInt8](); bytes.reserveCapacity(hex.count / 2); var i = hex.startIndex
            while i < hex.endIndex {
                let j = hex.index(i, offsetBy: 2)
                guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
                bytes.append(b); i = j
            }
            return (bytes, family)
        }
    }

    /// Re-decode every archived frame through the CURRENT decoder and insert whatever now decodes.
    /// The strap freed these records when they were acked, so this archive is the ONLY way banked
    /// history backfills after a newly-landed layout (e.g. WHOOP 4.0 v25). Idempotent: offloaded rows
    /// dedupe by (deviceId, ts), so a re-run can't double-insert. Returns rows recovered (for logging).
    /// Throws if a store insert fails — the caller MUST NOT advance the replay gate in that case, or
    /// these records (whose only surviving copy is this archive) would never be retried. (#152)
    @discardableResult
    func replay(into store: BackfillStoreWriting, deviceId: String) async throws -> Int {
        let archived = readAll()
        var rows = 0
        for family in Set(archived.map(\.family)) {
            let parsed = archived.filter { $0.family == family }.map { parseFrame($0.frame, family: family) }
            // type-47 records carry their own real-unix ts (clock offset ignored), so an identity
            // clock ref is correct here — the same fallback the Backfiller uses when clockRef is nil. Thread
            // the opt-in HR-from-PPG sub-lag interpolation flag (Test Centre → Experimental algorithms) so the
            // archive replay re-derives v26 HR with the same variant the live offload uses. Default OFF.
            let streams = extractHistoricalStreams(parsed, deviceClockRef: 0, wallClockRef: 0,
                                                   subLagInterp: PuffinExperiment.ppgHrSubLagInterpEnabled)
            // Count rows ACTUALLY inserted, not decoded: under the per-app-version gate the archive
            // replays every release, and dedupe makes those re-runs insert 0 — counting decoded rows
            // would log a false "retro-decoded N" success on every update. (#152)
            rows += (try await store.insert(streams, deviceId: deviceId)).gravity
        }
        return rows
    }
}
