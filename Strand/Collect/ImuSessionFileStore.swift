import Compression
import Foundation
import WhoopProtocol

/// Canonical decoded 100 Hz IMU storage: UTC half-hour files with appendable 30-second zlib blocks.
@MainActor
final class ImuSessionFileStore {
    struct Stats { let bytes: Int64; let coveredSeconds: Int; let firstTs: Int64? }
    struct ExportSegment { let name: String; let data: Data; let startTs, endTs: Int; let sampleCount: Int }
    private struct Window: Codable { let id, deviceId: String; let from: Int64; var to: Int64? }
    private struct Record { let ts, receivedAtMs: Int64; let columns: [Int16] }
    static let shared = ImuSessionFileStore()
    static let sampleRate = 100, axes = 6, blockSeconds = 30
    static let segmentSeconds: Int64 = 30 * 60
    private static let payloadBytes = sampleRate * axes * 2
    private static let magic = Data("NOOPIMU2".utf8)
    private let defaults = UserDefaults.standard
    private let key = "imu-session-windows-v1"
    private let directory: URL
    private var seen: [String: Set<Int64>] = [:]
    private var pending: [String: [Record]] = [:]

    private init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        directory = base.appendingPathComponent("OpenWhoop/RawImuSessions", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func start(id: String, deviceId: String, fromMs: Int64) {
        var value = windows().filter { $0.id != id }
        value.append(Window(id: id, deviceId: deviceId, from: fromMs / 1_000, to: nil)); save(value)
        try? FileManager.default.createDirectory(at: sessionDirectory(id), withIntermediateDirectories: true)
    }
    func complete(id: String, toMs: Int64) {
        flushSession(id); var value = windows()
        if let index = value.firstIndex(where: { $0.id == id }) { value[index].to = toMs / 1_000; save(value) }
    }
    func register(id: String, deviceId: String, fromMs: Int64, toMs: Int64) {
        var value = windows().filter { $0.id != id }
        value.append(Window(id: id, deviceId: deviceId, from: fromMs / 1_000, to: toMs / 1_000)); save(value)
        try? FileManager.default.createDirectory(at: sessionDirectory(id), withIntermediateDirectories: true)
    }
    func remove(id: String) {
        pending.keys.filter { $0.hasPrefix("\(id)/") }.forEach { pending[$0] = nil }
        seen.keys.filter { $0.hasPrefix(sessionDirectory(id).path) }.forEach { seen[$0] = nil }
        save(windows().filter { $0.id != id })
    }

    func deleteFiles(_ id: String, removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) -> Bool {
        flushSession(id); let dir = sessionDirectory(id)
        guard FileManager.default.fileExists(atPath: dir.path) else { return true }
        do { try removeItem(dir); return true } catch { return false }
    }

    func deleteDevice(_ deviceId: String) -> Bool {
        let owned = windows().filter { $0.deviceId == deviceId }.map(\.id)
        guard owned.allSatisfy({ deleteFiles($0) }) else { return false }
        owned.forEach { remove(id: $0) }; return true
    }

    @discardableResult
    func append(deviceId: String, frame: [UInt8], receivedAtMs: Int64) -> Int {
        guard let ts = Whoop5RawImu.baseTs(frame), let columns = Whoop5RawImu.rawColumns(frame) else { return 0 }
        var count = 0
        for window in windows() where window.deviceId == deviceId && Int64(ts) >= window.from
            && (window.to == nil || Int64(ts) <= window.to!) {
            let bucket = Self.bucketStart(Int64(ts)), url = segmentFile(window.id, bucket)
            var timestamps = seen[url.path] ?? scan(url)
            guard timestamps.insert(Int64(ts)).inserted else { continue }
            seen[url.path] = timestamps
            let pendingKey = "\(window.id)/\(bucket)"
            pending[pendingKey, default: []].append(Record(ts: Int64(ts), receivedAtMs: receivedAtMs, columns: columns))
            if pending[pendingKey]!.count >= Self.blockSeconds { flushKey(pendingKey) }
            count += 1
        }
        return count
    }

    func stats(_ id: String, from: Int, to: Int) -> Stats {
        let records = readRecords(id, from: from, to: to, includePending: true)
        let disk = segmentFiles(id).reduce(Int64(0)) { value, url in
            value + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let queued = pending.filter { $0.key.hasPrefix("\(id)/") }.values.flatMap { $0 }
            .reduce(Int64(0)) { $0 + Int64($1.columns.count * 2 + 20) }
        return Stats(bytes: disk + queued, coveredSeconds: Set(records.map(\.ts)).count,
                     firstTs: records.map(\.ts).min())
    }

    func exportSegments(_ id: String, from: Int, to: Int) -> [ExportSegment] {
        flushSession(id)
        let records = Dictionary(grouping: readRecords(id, from: from, to: to, includePending: false), by: \.ts)
            .compactMap { $0.value.first }.sorted { $0.ts < $1.ts }
        return Dictionary(grouping: records) { Self.bucketStart($0.ts) }.sorted { $0.key < $1.key }.compactMap { element in
            let (bucket, rows) = element
            guard let first = rows.first, let last = rows.last else { return nil }
            return ExportSegment(name: "imu-\(Self.utcName(bucket)).imus", data: encode(bucket: bucket, records: rows),
                startTs: Int(first.ts), endTs: Int(last.ts), sampleCount: rows.count * Self.sampleRate)
        }
    }

    private func readRecords(_ id: String, from: Int, to: Int, includePending: Bool) -> [Record] {
        var rows = segmentFiles(id).flatMap { decode((try? Data(contentsOf: $0)) ?? Data()) }
            .filter { $0.ts >= from && $0.ts <= to }
        if includePending { rows += pending.filter { $0.key.hasPrefix("\(id)/") }.values.flatMap { $0 }
            .filter { $0.ts >= from && $0.ts <= to } }
        return rows
    }

    private func encode(bucket: Int64, records: [Record]) -> Data {
        var result = header(bucket)
        for start in stride(from: 0, to: records.count, by: Self.blockSeconds) {
            result.append(block(Array(records[start..<min(start + Self.blockSeconds, records.count)])))
        }
        return result
    }
    private func decode(_ data: Data) -> [Record] {
        guard data.count >= 24, data.prefix(8) == Self.magic else { return [] }
        let bytes = [UInt8](data); var offset = 8
        _ = Int64(bigEndianBytes: bytes, at: offset); offset += 8
        guard int32(bytes, offset) == Self.sampleRate, int32(bytes, offset + 4) == Self.axes else { return [] }
        offset += 8; var result: [Record] = []
        while offset + 12 <= bytes.count {
            let count = int32(bytes, offset), rawSize = int32(bytes, offset + 4), compressedSize = int32(bytes, offset + 8)
            offset += 12
            guard count > 0, count <= Self.blockSeconds, rawSize > 0, compressedSize > 0,
                  offset + compressedSize <= bytes.count,
                  let raw = inflate(Data(bytes[offset..<offset + compressedSize]), size: rawSize) else { break }
            offset += compressedSize; let rawBytes = [UInt8](raw); var rawOffset = 0
            for _ in 0..<count {
                guard rawOffset + 20 + Self.payloadBytes <= rawBytes.count else { break }
                let ts = Int64(bigEndianBytes: rawBytes, at: rawOffset)
                let received = Int64(bigEndianBytes: rawBytes, at: rawOffset + 8)
                let length = int32(rawBytes, rawOffset + 16); rawOffset += 20
                guard length == Self.payloadBytes, rawOffset + length <= rawBytes.count else { break }
                var columns: [Int16] = []; columns.reserveCapacity(Self.sampleRate * Self.axes)
                for index in stride(from: rawOffset, to: rawOffset + length, by: 2) {
                    columns.append(Int16(bitPattern: UInt16(rawBytes[index]) | UInt16(rawBytes[index + 1]) << 8))
                }
                rawOffset += length; result.append(Record(ts: ts, receivedAtMs: received, columns: columns))
            }
        }
        return result
    }

    private func flushSession(_ id: String) { pending.keys.filter { $0.hasPrefix("\(id)/") }.forEach(flushKey) }
    private func flushKey(_ key: String) {
        guard let records = pending.removeValue(forKey: key), !records.isEmpty,
              let tail = key.split(separator: "/").last,
              let bucket = Int64(String(tail)) else { return }
        let id = String(key.split(separator: "/")[0]), url = segmentFile(id, bucket)
        try? FileManager.default.createDirectory(at: sessionDirectory(id), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: header(bucket)) }
        guard let handle = try? FileHandle(forWritingTo: url) else { pending[key] = records; return }
        do { try handle.seekToEnd(); try handle.write(contentsOf: block(records)); try handle.close() }
        catch { try? handle.close(); pending[key] = records }
    }
    private func header(_ bucket: Int64) -> Data {
        var data = Self.magic; data.appendBigEndian(bucket); data.appendBigEndian(Int32(Self.sampleRate)); data.appendBigEndian(Int32(Self.axes)); return data
    }
    private func block(_ records: [Record]) -> Data {
        var raw = Data()
        for record in records {
            raw.appendBigEndian(record.ts); raw.appendBigEndian(record.receivedAtMs); raw.appendBigEndian(Int32(Self.payloadBytes))
            for value in record.columns { raw.append(UInt8(truncatingIfNeeded: value)); raw.append(UInt8(truncatingIfNeeded: value >> 8)) }
        }
        guard let compressed = deflate(raw) else { return Data() }
        var data = Data(); data.appendBigEndian(Int32(records.count)); data.appendBigEndian(Int32(raw.count))
        data.appendBigEndian(Int32(compressed.count)); data.append(compressed); return data
    }

    private func windows() -> [Window] { defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Window].self, from: $0) } ?? [] }
    private func save(_ value: [Window]) { defaults.set(try? JSONEncoder().encode(value), forKey: key) }
    private func sessionDirectory(_ id: String) -> URL { directory.appendingPathComponent(id, isDirectory: true) }
    private func segmentFile(_ id: String, _ bucket: Int64) -> URL { sessionDirectory(id).appendingPathComponent("imu-\(Self.utcName(bucket)).imus") }
    private func segmentFiles(_ id: String) -> [URL] { ((try? FileManager.default.contentsOfDirectory(at: sessionDirectory(id), includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "imus" }.sorted { $0.lastPathComponent < $1.lastPathComponent } }
    private func scan(_ url: URL) -> Set<Int64> { Set(decode((try? Data(contentsOf: url)) ?? Data()).map(\.ts)) }
    private static func bucketStart(_ ts: Int64) -> Int64 { ts >= 0 ? ts / segmentSeconds * segmentSeconds : ((ts - segmentSeconds + 1) / segmentSeconds) * segmentSeconds }
    private static func utcName(_ ts: Int64) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts))) }
    private func int32(_ bytes: [UInt8], _ offset: Int) -> Int { Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3]) }
    private func deflate(_ input: Data) -> Data? { let capacity = input.count + 128; var output = Data(count: capacity); let written = output.withUnsafeMutableBytes { dst in input.withUnsafeBytes { src in compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity, src.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB) } }; guard written > 0 else { return nil }; output.count = written; return output }
    private func inflate(_ input: Data, size: Int) -> Data? { var output = Data(count: size); let written = output.withUnsafeMutableBytes { dst in input.withUnsafeBytes { src in compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size, src.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB) } }; return written == size ? output : nil }
}

private extension Int64 { init(bigEndianBytes bytes: [UInt8], at offset: Int) { self = bytes[offset..<(offset + 8)].reduce(0) { ($0 << 8) | Int64($1) } } }
private extension Data { mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) { var value = value.bigEndian; Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) } } }
