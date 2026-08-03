import Foundation
import Compression
import GRDB
import WhoopProtocol

public struct ClockRef: Equatable, Codable {
    public let device: Int
    public let wall: Int
    public init(device: Int, wall: Int) { self.device = device; self.wall = wall }
}

public struct RawBatchMeta: Equatable {
    public let batchId: String
    public let deviceId: String
    public let clockRef: ClockRef
    public let capturedAt: Int
    public let startTs: Int
    public let endTs: Int
    public let frameCount: Int
    public let byteSize: Int
    public init(batchId: String, deviceId: String, clockRef: ClockRef, capturedAt: Int,
                startTs: Int, endTs: Int, frameCount: Int, byteSize: Int) {
        self.batchId = batchId; self.deviceId = deviceId; self.clockRef = clockRef
        self.capturedAt = capturedAt; self.startTs = startTs; self.endTs = endTs
        self.frameCount = frameCount; self.byteSize = byteSize
    }
}

extension WhoopStore {
    // MARK: - frame (de)serialization
    // Layout: [count u32 LE]{ [len u32 LE][bytes] } x count. zlib-compressed as a whole.

    static func packFrames(_ frames: [[UInt8]]) -> Data {
        var buf = Data()
        func appendU32(_ v: Int) {
            let u = UInt32(v)
            buf.append(UInt8(u & 0xFF)); buf.append(UInt8((u >> 8) & 0xFF))
            buf.append(UInt8((u >> 16) & 0xFF)); buf.append(UInt8((u >> 24) & 0xFF))
        }
        appendU32(frames.count)
        for f in frames {
            appendU32(f.count)
            buf.append(contentsOf: f)
        }
        return buf
    }

    static func unpackFrames(_ data: Data) -> [[UInt8]] {
        let bytes = [UInt8](data)
        var off = 0
        func readU32() -> Int? {
            guard off + 4 <= bytes.count else { return nil }
            let v = Int(bytes[off]) | (Int(bytes[off + 1]) << 8)
                | (Int(bytes[off + 2]) << 16) | (Int(bytes[off + 3]) << 24)
            off += 4
            return v
        }
        guard let count = readU32() else { return [] }
        var out: [[UInt8]] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard let len = readU32(), off + len <= bytes.count else { break }
            out.append(Array(bytes[off..<off + len]))
            off += len
        }
        return out
    }

    // MARK: - zlib helpers using Apple Compression framework

    /// Decompress a blob that was produced by `zlibCompressWithLength`.
    /// The first 4 bytes are the uncompressed length (UInt32 LE); the rest is the zlib payload.
    static func zlibDecompressWithLength(_ input: Data) throws -> Data {
        // Read the 4-byte uncompressed-length prefix (UInt32 LE).
        guard input.count >= 4 else { throw CocoaError(.fileReadUnknown) }
        let n = Int(input[input.startIndex])
            | (Int(input[input.startIndex + 1]) << 8)
            | (Int(input[input.startIndex + 2]) << 16)
            | (Int(input[input.startIndex + 3]) << 24)
        let compressed = input.dropFirst(4)
        // n == 0 means packFrames returned empty data; return empty.
        guard n > 0 else { return Data() }
        var dst = [UInt8](repeating: 0, count: n)
        let written: Int = compressed.withUnsafeBytes { src in
            guard let srcPtr = src.baseAddress else { return 0 }
            return compression_decode_buffer(&dst, n, srcPtr, compressed.count, nil, COMPRESSION_ZLIB)
        }
        // If written != n the blob is genuinely corrupt (not a sizing issue).
        guard written == n else { throw CocoaError(.fileReadCorruptFile) }
        return Data(dst)
    }

    /// Compress `input` and prepend its uncompressed length as a UInt32 LE prefix.
    static func zlibCompressWithLength(_ input: Data) throws -> Data {
        let sourceSize = input.count
        let dstCapacity = max(64, sourceSize * 2 + 64)
        var dst = [UInt8](repeating: 0, count: dstCapacity)
        let written: Int = input.withUnsafeBytes { src in
            guard let srcPtr = src.baseAddress else { return 0 }
            return compression_encode_buffer(&dst, dstCapacity, srcPtr, sourceSize, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { throw CocoaError(.fileWriteUnknown) }
        // Prepend uncompressed length as UInt32 LE.
        let u = UInt32(sourceSize)
        var blob = Data(capacity: 4 + written)
        blob.append(UInt8(u & 0xFF)); blob.append(UInt8((u >> 8) & 0xFF))
        blob.append(UInt8((u >> 16) & 0xFF)); blob.append(UInt8((u >> 24) & 0xFF))
        blob.append(contentsOf: dst[0..<written])
        return blob
    }

    // MARK: - Public API

    /// Compress raw frames into the outbox and store batch meta.
    public func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {
        let packed = WhoopStore.packFrames(frames)
        let blob = try WhoopStore.zlibCompressWithLength(packed)
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO rawBatch
                    (batchId, deviceId, capturedAt, deviceClockRef, wallClockRef,
                     startTs, endTs, frameCount, byteSize, framesBlob, syncedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                ON CONFLICT(batchId) DO NOTHING
                """, arguments: [
                    meta.batchId, meta.deviceId, meta.capturedAt,
                    meta.clockRef.device, meta.clockRef.wall,
                    meta.startTs, meta.endTs, meta.frameCount, meta.byteSize, blob])
        }
    }

    /// Decompress and return the exact frame bytes for a batch (empty if unknown).
    public func rawFrames(batchId: String) async throws -> [[UInt8]] {
        let row: Row? = try syncRead { db in
            try Row.fetchOne(db,
                sql: "SELECT framesBlob FROM rawBatch WHERE batchId = ?",
                arguments: [batchId])
        }
        guard let row = row else { return [] }
        let blob: Data = row["framesBlob"]
        let raw = try WhoopStore.zlibDecompressWithLength(blob)
        return WhoopStore.unpackFrames(raw)
    }

    private static func metaFromRow(_ row: Row) -> RawBatchMeta {
        RawBatchMeta(
            batchId: row["batchId"], deviceId: row["deviceId"],
            clockRef: ClockRef(device: row["deviceClockRef"], wall: row["wallClockRef"]),
            capturedAt: row["capturedAt"], startTs: row["startTs"], endTs: row["endTs"],
            frameCount: row["frameCount"], byteSize: row["byteSize"])
    }

    /// Un-synced batches (syncedAt IS NULL), oldest first, capped at `limit`.
    public func pendingRawBatches(limit: Int) async throws -> [RawBatchMeta] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT batchId, deviceId, capturedAt, deviceClockRef, wallClockRef,
                       startTs, endTs, frameCount, byteSize
                FROM rawBatch
                WHERE syncedAt IS NULL
                ORDER BY capturedAt ASC
                LIMIT ?
                """, arguments: [limit]).map(WhoopStore.metaFromRow)
        }
    }

    /// Mark a batch synced (timestamp in unix seconds).
    ///
    /// #981 — NO production caller, and by design: see the dormancy note on `pruneRaw`'s Policy 1. Kept
    /// because it is the natural hook for a future on-device export lane, not because anything calls it.
    public func markRawBatchSynced(batchId: String, at: Int) async throws {
        try syncWrite { db in
            try db.execute(sql: "UPDATE rawBatch SET syncedAt = ? WHERE batchId = ?",
                           arguments: [at, batchId])
        }
    }
}

extension WhoopStore {
    /// Prune raw outbox rows. Returns the number of rawBatch rows deleted.
    ///
    /// **Policy 1 — DORMANT in a shipping build (#981):** Delete SYNCED batches whose `syncedAt`
    /// timestamp is older than `now - keepWindowSeconds`. Synced raw is safe to drop because the decoded
    /// streams are persisted separately.
    ///
    /// It cannot fire today. `syncedAt` is only ever set by `markRawBatchSynced`, which has no production
    /// caller — and cannot get one, because marking a batch "synced" needs somewhere to sync it to and
    /// NOOP has no server, no account and no cloud sync by design (`CLAUDE.md`). The API and this policy
    /// are inherited from the upstream `my-whoop` store (see `ATTRIBUTION.md`), which did have a sync
    /// lane. Kept rather than deleted: both halves are correct and tested, and an on-device EXPORT lane
    /// would be a legitimate server-free way to drain the outbox — at which point marking exported
    /// batches synced and letting this reap them is exactly the right shape.
    ///
    /// Nothing is unbounded in the meantime: **Policy 2 is the real growth bound**, and is what the 19 GB
    /// note below refers to.
    ///
    /// **Policy 2 (size eviction, #27):** Cap the total on-disk raw footprint at
    /// `maxUnsyncedBytes`. Walk the surviving batches newest-first (`capturedAt DESC`),
    /// summing `byteSize`, and DELETE every row once the running total exceeds the cap —
    /// i.e. drop the OLDEST raw. Raw is transient working data, not an archive: the decoded
    /// streams are persisted BEFORE the raw batch is enqueued (Collector E2 invariant), so
    /// dropping the oldest raw never loses a decoded metric. Without this an experimental
    /// capture toggle could grow local storage without bound (a 5/MG user saw 19 GB).
    ///
    /// - Parameters:
    ///   - now: Current unix-second timestamp used to compute the synced-aging cutoff.
    ///   - keepWindowSeconds: Synced batches older than `now - keepWindowSeconds` are removed.
    ///   - maxUnsyncedBytes: Total raw-footprint cap; oldest batches beyond it are evicted.
    @discardableResult
    public func pruneRaw(now: Int, keepWindowSeconds: Int, maxUnsyncedBytes: Int) async throws -> Int {
        try syncWrite { db in
            var pruned = 0
            // Policy 1: aged synced batches.
            let cutoff = now - keepWindowSeconds
            try db.execute(sql: """
                DELETE FROM rawBatch WHERE syncedAt IS NOT NULL AND syncedAt < ?
                """, arguments: [cutoff])
            pruned += db.changesCount

            // Policy 2 (#27): size-based eviction of the OLDEST raw beyond the cap. Sum byteSize
            // newest-first; once the cumulative total exceeds maxUnsyncedBytes, the remaining (older)
            // rows are over budget and get dropped. rowid keeps the cutoff stable regardless of ties
            // on capturedAt. Decoded streams persist before raw (E2), so this loses no metric.
            let rows = try Row.fetchAll(db, sql: """
                SELECT rowid, byteSize FROM rawBatch ORDER BY capturedAt DESC, rowid DESC
                """)
            var cumulative = 0
            var evict: [Int64] = []
            for row in rows {
                let size: Int = row["byteSize"]
                let rowid: Int64 = row["rowid"]
                cumulative += size
                if cumulative > maxUnsyncedBytes {
                    evict.append(rowid)
                }
            }
            if !evict.isEmpty {
                let placeholders = evict.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM rawBatch WHERE rowid IN (\(placeholders))",
                    arguments: StatementArguments(evict))
                pruned += db.changesCount
            }
            return pruned
        }
    }

    // MARK: - Test helper
    public func allBatchIdsForTest() async throws -> [String] {
        try syncRead { db in
            try String.fetchAll(db, sql: "SELECT batchId FROM rawBatch ORDER BY capturedAt ASC")
        }
    }
}
