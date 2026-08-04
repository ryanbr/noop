import Foundation

/// A phase marker written by NOOP while a controlled WHOOP 5/MG optical experiment is running.
/// `unixTs` deliberately shares a clock domain with each v20 frame's `baseTs`; log-arrival time does
/// not, because the strap may deliver a buffer minutes or hours later during history offload.
public struct OpticalExperimentMarker: Codable, Equatable, Sendable {
    public let label: String
    public let unixTs: Int
    public let loggedAtMs: Int?

    public init(label: String, unixTs: Int, loggedAtMs: Int? = nil) {
        self.label = label
        self.unixTs = unixTs
        self.loggedAtMs = loggedAtMs
    }
}

public struct OpticalExperimentChannelSummary: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let mean: Double?
    public let rms: Double?
    public let standardDeviation: Double?
    public let minimum: Int32?
    public let maximum: Int32?
}

public struct OpticalExperimentBlockSummary: Codable, Equatable, Sendable {
    public let blockIndex: Int
    public let frameCount: Int
    public let sampleCountHistogram: [String: Int]
    public let uniqueHeaderCount: Int
    /// A 21-byte header assembled from the independently modal value at each byte offset. This stays
    /// stable when AGC makes whole-header combinations unique.
    public let modalHeaderHex: String?
    public let channels: [OpticalExperimentChannelSummary]
}

public struct OpticalExperimentPhaseSummary: Codable, Equatable, Sendable {
    public let label: String
    public let startUnixTs: Int
    public let endUnixTs: Int?
    public let frameCount: Int
    public let firstFrameUnixTs: Int?
    public let lastFrameUnixTs: Int?
    public let blocks: [OpticalExperimentBlockSummary]
}

public struct OpticalExperimentBlockComparison: Codable, Equatable, Sendable {
    public let blockIndex: Int
    public let frameCountDelta: Int
    public let activationChanged: Bool
    public let sampleCountHistogramChanged: Bool
    /// Offsets in the 21-byte block header whose modal values differ between the two phases.
    public let headerByteOffsetsChanged: [Int]
    /// `to.mean - from.mean` for the two physical channel slots; nil if either phase has no samples.
    public let channelMeanDeltas: [Double?]
}

public struct OpticalExperimentPhaseComparison: Codable, Equatable, Sendable {
    public let fromLabel: String
    public let fromStartUnixTs: Int
    public let toLabel: String
    public let toStartUnixTs: Int
    public let blocks: [OpticalExperimentBlockComparison]
}

public struct OpticalExperimentReport: Codable, Equatable, Sendable {
    public let markers: [OpticalExperimentMarker]
    public let phases: [OpticalExperimentPhaseSummary]
    public let comparisons: [OpticalExperimentPhaseComparison]
    public let sourceLineCount: Int
    public let decodedBufferCount: Int
    public let assignedBufferCount: Int
    public let ignoredLineCount: Int
    public let invalidLineCount: Int
    /// Frames this many seconds after every marker were treated as transition data and not assigned.
    public let settlingSeconds: Int
}

/// Compares v20 optical blocks between user-labelled physical phases without assigning wavelengths or
/// physiological meaning. It reports only directly observed activation, headers, and ADC statistics.
public enum Whoop5OpticalExperimentAnalyzer {
    private struct LogLine: Decodable {
        let kind: String?
        let label: String?
        let unixTs: Int?
        let loggedAtMs: Int?
        let strapTs: Int?
        let size: Int?
        let hex: String?

        enum CodingKeys: String, CodingKey {
            case kind, label, size, hex
            case unixTs = "unix_ts"
            case loggedAtMs = "ts_ms"
            case strapTs = "strap_ts"
        }
    }

    private struct ChannelAccumulator {
        var count = 0
        var sum = 0.0
        var sumSquares = 0.0
        var minimum: Int32?
        var maximum: Int32?

        mutating func add(_ values: [Int32]) {
            for value in values {
                let d = Double(value)
                count += 1
                sum += d
                sumSquares += d * d
                minimum = minimum.map { Swift.min($0, value) } ?? value
                maximum = maximum.map { Swift.max($0, value) } ?? value
            }
        }

        func summary() -> OpticalExperimentChannelSummary {
            OpticalExperimentChannelSummary(
                sampleCount: count,
                mean: count == 0 ? nil : sum / Double(count),
                rms: count == 0 ? nil : sqrt(sumSquares / Double(count)),
                standardDeviation: count == 0 ? nil : sqrt(max(
                    0, sumSquares / Double(count) - pow(sum / Double(count), 2))),
                minimum: minimum,
                maximum: maximum)
        }
    }

    private struct BlockAccumulator {
        let index: Int
        var frameCount = 0
        var sampleCountHistogram: [Int: Int] = [:]
        var headerCounts: [String: Int] = [:]
        var headerByteCounts = Array(
            repeating: [UInt8: Int](), count: Whoop5RawOptical.headerLength)
        var channels = [ChannelAccumulator(), ChannelAccumulator()]

        mutating func add(_ block: Whoop5OpticalBlock) {
            frameCount += 1
            sampleCountHistogram[block.sampleCount, default: 0] += 1
            let header = block.rawHeader
            headerCounts[hex(header), default: 0] += 1
            for (offset, byte) in header.enumerated() where offset < headerByteCounts.count {
                headerByteCounts[offset][byte, default: 0] += 1
            }
            for channelIndex in block.channels.indices where channelIndex < channels.count {
                channels[channelIndex].add(block.channels[channelIndex].samples)
            }
        }

        func summary() -> OpticalExperimentBlockSummary {
            let modalHeader: String? = frameCount == 0 ? nil : hex(headerByteCounts.compactMap { counts in
                counts.max {
                    $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value
                }?.key
            })
            return OpticalExperimentBlockSummary(
                blockIndex: index,
                frameCount: frameCount,
                sampleCountHistogram: Dictionary(uniqueKeysWithValues:
                    sampleCountHistogram.map { (String($0.key), $0.value) }),
                uniqueHeaderCount: headerCounts.count,
                modalHeaderHex: modalHeader,
                channels: channels.map { $0.summary() })
        }
    }

    private struct PhaseAccumulator {
        let marker: OpticalExperimentMarker
        let endUnixTs: Int?
        var frameCount = 0
        var firstFrameUnixTs: Int?
        var lastFrameUnixTs: Int?
        var blocks = (0..<Whoop5RawOptical.blockCount).map { BlockAccumulator(index: $0) }

        mutating func add(_ frame: Whoop5OpticalFrame) {
            frameCount += 1
            firstFrameUnixTs = firstFrameUnixTs.map { min($0, frame.baseTs) } ?? frame.baseTs
            lastFrameUnixTs = lastFrameUnixTs.map { max($0, frame.baseTs) } ?? frame.baseTs
            for block in frame.blocks where block.index < blocks.count {
                blocks[block.index].add(block)
            }
        }

        func summary() -> OpticalExperimentPhaseSummary {
            OpticalExperimentPhaseSummary(
                label: marker.label,
                startUnixTs: marker.unixTs,
                endUnixTs: endUnixTs,
                frameCount: frameCount,
                firstFrameUnixTs: firstFrameUnixTs,
                lastFrameUnixTs: lastFrameUnixTs,
                blocks: blocks.map { $0.summary() })
        }
    }

    /// Analyze the append-only `puffin-deepbuffers.jsonl` format. Marker lines may appear after the
    /// corresponding buffers; attribution uses `unix_ts` versus decoded frame `baseTs`, never line order.
    public static func analyze(jsonl: String, settlingSeconds: Int = 0) -> OpticalExperimentReport {
        let settlingSeconds = max(0, settlingSeconds)
        var markers: [OpticalExperimentMarker] = []
        jsonl.enumerateLines { line, _ in
            guard let decoded = decodeLine(line),
                  decoded.kind == "optical_phase",
                  let label = decoded.label,
                  let unixTs = decoded.unixTs else { return }
            markers.append(OpticalExperimentMarker(
                label: label, unixTs: unixTs, loggedAtMs: decoded.loggedAtMs))
        }
        markers.sort {
            if $0.unixTs != $1.unixTs { return $0.unixTs < $1.unixTs }
            return ($0.loggedAtMs ?? 0) < ($1.loggedAtMs ?? 0)
        }

        // `experiment_end` is a boundary, not a phase. Keep it in `markers` for provenance, but use it
        // only as the preceding phase's end so later offload records are not attributed past the run.
        var phases = markers.enumerated().compactMap { index, marker -> PhaseAccumulator? in
            guard marker.label != "experiment_end" else { return nil }
            return PhaseAccumulator(
                marker: marker,
                endUnixTs: index + 1 < markers.count ? markers[index + 1].unixTs : nil)
        }
        let phaseMarkers = phases.map(\.marker)
        var sourceLineCount = 0
        var decodedBufferCount = 0
        var assignedBufferCount = 0
        var ignoredLineCount = 0
        var invalidLineCount = 0

        jsonl.enumerateLines { line, _ in
            sourceLineCount += 1
            guard let decoded = decodeLine(line) else {
                invalidLineCount += 1
                return
            }
            if decoded.kind == "optical_phase" { return }
            guard decoded.size == Whoop5RawOptical.bufferLength,
                  let strapTs = decoded.strapTs,
                  let encoded = decoded.hex else {
                ignoredLineCount += 1
                return
            }
            guard let bytes = bytes(fromHex: encoded),
                  let frame = Whoop5RawOptical.decode(bytes) else {
                invalidLineCount += 1
                return
            }
            decodedBufferCount += 1
            // Trust the decoded timestamp. `strap_ts` is retained as a consistency gate against a
            // malformed/misassociated JSON envelope rather than as a substitute for frame content.
            guard frame.baseTs == strapTs else {
                invalidLineCount += 1
                return
            }
            guard let phaseIndex = phaseIndex(for: frame.baseTs, markers: phaseMarkers),
                  phases[phaseIndex].endUnixTs.map({ frame.baseTs < $0 }) ?? true else {
                ignoredLineCount += 1
                return
            }
            guard frame.baseTs >= phaseMarkers[phaseIndex].unixTs + settlingSeconds else {
                ignoredLineCount += 1
                return
            }
            phases[phaseIndex].add(frame)
            assignedBufferCount += 1
        }

        let summaries = phases.map { $0.summary() }
        return OpticalExperimentReport(
            markers: markers,
            phases: summaries,
            comparisons: adjacentComparisons(summaries),
            sourceLineCount: sourceLineCount,
            decodedBufferCount: decodedBufferCount,
            assignedBufferCount: assignedBufferCount,
            ignoredLineCount: ignoredLineCount,
            invalidLineCount: invalidLineCount,
            settlingSeconds: settlingSeconds)
    }

    private static func adjacentComparisons(
        _ phases: [OpticalExperimentPhaseSummary]
    ) -> [OpticalExperimentPhaseComparison] {
        guard phases.count > 1 else { return [] }
        return (1..<phases.count).compactMap { index in
            let from = phases[index - 1]
            let to = phases[index]
            // An explicit `experiment_end` creates a gap: don't present phases from separate runs as
            // an adjacent controlled comparison merely because they share one file.
            guard from.endUnixTs == to.startUnixTs else { return nil }
            let blockCount = min(from.blocks.count, to.blocks.count)
            let blocks = (0..<blockCount).map { blockIndex in
                compare(from.blocks[blockIndex], to.blocks[blockIndex])
            }
            return OpticalExperimentPhaseComparison(
                fromLabel: from.label,
                fromStartUnixTs: from.startUnixTs,
                toLabel: to.label,
                toStartUnixTs: to.startUnixTs,
                blocks: blocks)
        }
    }

    private static func compare(
        _ from: OpticalExperimentBlockSummary,
        _ to: OpticalExperimentBlockSummary
    ) -> OpticalExperimentBlockComparison {
        let fromActive = from.channels.contains { $0.sampleCount > 0 }
        let toActive = to.channels.contains { $0.sampleCount > 0 }
        let fromHeader = from.modalHeaderHex.flatMap(bytes(fromHex:)) ?? []
        let toHeader = to.modalHeaderHex.flatMap(bytes(fromHex:)) ?? []
        let headerCount = min(fromHeader.count, toHeader.count)
        var changed = (0..<headerCount).filter { fromHeader[$0] != toHeader[$0] }
        if fromHeader.count != toHeader.count {
            changed.append(contentsOf: headerCount..<max(fromHeader.count, toHeader.count))
        }
        let channelCount = min(from.channels.count, to.channels.count)
        let deltas: [Double?] = (0..<channelCount).map { index in
            guard let a = from.channels[index].mean, let b = to.channels[index].mean else { return nil }
            return b - a
        }
        return OpticalExperimentBlockComparison(
            blockIndex: from.blockIndex,
            frameCountDelta: to.frameCount - from.frameCount,
            activationChanged: fromActive != toActive,
            sampleCountHistogramChanged: !sameHistogramDistribution(
                from.sampleCountHistogram, to.sampleCountHistogram),
            headerByteOffsetsChanged: changed,
            channelMeanDeltas: deltas)
    }

    private static func sameHistogramDistribution(
        _ lhs: [String: Int], _ rhs: [String: Int]
    ) -> Bool {
        let lhsTotal = lhs.values.reduce(0, +)
        let rhsTotal = rhs.values.reduce(0, +)
        if lhsTotal == 0 || rhsTotal == 0 { return lhsTotal == rhsTotal }
        let keys = Set(lhs.keys).union(rhs.keys)
        return keys.allSatisfy { key in
            lhs[key, default: 0] * rhsTotal == rhs[key, default: 0] * lhsTotal
        }
    }

    private static func phaseIndex(for timestamp: Int, markers: [OpticalExperimentMarker]) -> Int? {
        guard !markers.isEmpty, timestamp >= markers[0].unixTs else { return nil }
        var low = 0
        var high = markers.count
        while low < high {
            let mid = (low + high) / 2
            if markers[mid].unixTs <= timestamp { low = mid + 1 } else { high = mid }
        }
        return low - 1
    }

    private static func decodeLine(_ line: String) -> LogLine? {
        try? JSONDecoder().decode(LogLine.self, from: Data(line.utf8))
    }

    private static func bytes(fromHex hexString: String) -> [UInt8]? {
        let value = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count.isMultiple(of: 2) else { return nil }
        var output: [UInt8] = []
        output.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            output.append(byte)
            index = next
        }
        return output
    }
}

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}
