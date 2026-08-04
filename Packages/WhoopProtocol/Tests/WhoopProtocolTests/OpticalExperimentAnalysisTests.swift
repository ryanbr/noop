import XCTest
@testable import WhoopProtocol

final class OpticalExperimentAnalysisTests: XCTestCase {
    func testAssignsDelayedOffloadByStrapTimestampAndComparesBlocks() throws {
        let baseline = frame(baseTs: 150, block0Value: 10, block0HeaderByte1: 1,
                             block1SampleCount: 0)
        let covered = frame(baseTs: 250, block0Value: 30, block0HeaderByte1: 9,
                            block1SampleCount: 1)

        // Buffers deliberately precede markers in file order. Arrival order must not control phases.
        let jsonl = [
            bufferLine(baseline, strapTs: 150),
            bufferLine(covered, strapTs: 250),
            markerLine("baseline", unixTs: 100, loggedAtMs: 100_100),
            markerLine("covered", unixTs: 200, loggedAtMs: 200_100),
            markerLine("experiment_end", unixTs: 300, loggedAtMs: 300_100),
        ].joined(separator: "\n")

        let report = Whoop5OpticalExperimentAnalyzer.analyze(jsonl: jsonl)

        XCTAssertEqual(report.decodedBufferCount, 2)
        XCTAssertEqual(report.assignedBufferCount, 2)
        XCTAssertEqual(report.phases.map(\.label), ["baseline", "covered"])
        XCTAssertEqual(report.phases.map(\.frameCount), [1, 1])
        XCTAssertEqual(report.phases[0].blocks[0].sampleCountHistogram, ["2": 1])
        XCTAssertEqual(report.phases[0].blocks[0].channels[0].mean, 10)
        XCTAssertEqual(report.phases[1].blocks[0].channels[0].mean, 30)

        let baselineToCovered = report.comparisons[0]
        XCTAssertEqual(baselineToCovered.blocks[0].headerByteOffsetsChanged, [1])
        XCTAssertEqual(baselineToCovered.blocks[0].channelMeanDeltas[0], 20)
        XCTAssertTrue(baselineToCovered.blocks[1].activationChanged)
        XCTAssertEqual(baselineToCovered.blocks[1].sampleCountHistogramChanged, true)
    }

    func testRejectsEnvelopeTimestampMismatchAndCountsNoiseSeparately() {
        let validFrame = frame(baseTs: 150, block0Value: 10, block0HeaderByte1: 1,
                               block1SampleCount: 0)
        let jsonl = [
            markerLine("baseline", unixTs: 100, loggedAtMs: 100_100),
            bufferLine(validFrame, strapTs: 151),
            "{not-json}",
            "{\"kind\":\"something_else\"}",
        ].joined(separator: "\n")

        let report = Whoop5OpticalExperimentAnalyzer.analyze(jsonl: jsonl)

        XCTAssertEqual(report.decodedBufferCount, 1)
        XCTAssertEqual(report.assignedBufferCount, 0)
        XCTAssertEqual(report.invalidLineCount, 2) // malformed JSON + timestamp mismatch
        XCTAssertEqual(report.ignoredLineCount, 1)
    }

    func testSettlingWindowDropsTransitionFrames() {
        let early = frame(baseTs: 105, block0Value: 10, block0HeaderByte1: 1,
                          block1SampleCount: 0)
        let settled = frame(baseTs: 115, block0Value: 20, block0HeaderByte1: 1,
                            block1SampleCount: 0)
        let jsonl = [
            markerLine("baseline", unixTs: 100, loggedAtMs: 100_100),
            bufferLine(early, strapTs: 105),
            bufferLine(settled, strapTs: 115),
        ].joined(separator: "\n")

        let report = Whoop5OpticalExperimentAnalyzer.analyze(jsonl: jsonl, settlingSeconds: 10)

        XCTAssertEqual(report.settlingSeconds, 10)
        XCTAssertEqual(report.decodedBufferCount, 2)
        XCTAssertEqual(report.assignedBufferCount, 1)
        XCTAssertEqual(report.ignoredLineCount, 1)
        XCTAssertEqual(report.phases[0].blocks[0].channels[0].mean, 20)
    }

    func testComparisonIgnoresDifferentPhaseDurationsWithSameSampleCount() {
        let lines = [
            markerLine("first", unixTs: 100, loggedAtMs: 100_100),
            bufferLine(frame(baseTs: 110, block0Value: 10, block0HeaderByte1: 1,
                             block1SampleCount: 0), strapTs: 110),
            markerLine("second", unixTs: 200, loggedAtMs: 200_100),
            bufferLine(frame(baseTs: 210, block0Value: 10, block0HeaderByte1: 1,
                             block1SampleCount: 0), strapTs: 210),
            bufferLine(frame(baseTs: 211, block0Value: 10, block0HeaderByte1: 1,
                             block1SampleCount: 0), strapTs: 211),
        ]
        let report = Whoop5OpticalExperimentAnalyzer.analyze(jsonl: lines.joined(separator: "\n"))

        XCTAssertFalse(report.comparisons[0].blocks[0].sampleCountHistogramChanged)
        XCTAssertEqual(report.comparisons[0].blocks[0].frameCountDelta, 1)
    }

    func testModalHeaderIsComputedPerByteWhenEveryWholeHeaderIsUnique() {
        var a = frame(baseTs: 110, block0Value: 10, block0HeaderByte1: 1,
                      block1SampleCount: 0)
        var b = frame(baseTs: 111, block0Value: 10, block0HeaderByte1: 1,
                      block1SampleCount: 0)
        var c = frame(baseTs: 112, block0Value: 10, block0HeaderByte1: 2,
                      block1SampleCount: 0)
        let header = Whoop5RawOptical.blockStart
        a[header + 2] = 3
        b[header + 2] = 4
        c[header + 2] = 3
        let jsonl = [
            markerLine("baseline", unixTs: 100, loggedAtMs: 100_100),
            bufferLine(a, strapTs: 110),
            bufferLine(b, strapTs: 111),
            bufferLine(c, strapTs: 112),
        ].joined(separator: "\n")

        let report = Whoop5OpticalExperimentAnalyzer.analyze(jsonl: jsonl)

        XCTAssertEqual(report.phases[0].blocks[0].uniqueHeaderCount, 3)
        XCTAssertTrue(report.phases[0].blocks[0].modalHeaderHex?.hasPrefix("020103") == true)
    }

    func testEndMarkerSeparatesRunsAndSettlingUsesTheLaterRunStart() {
        let earlySecondRun = frame(baseTs: 305, block0Value: 10, block0HeaderByte1: 1,
                                   block1SampleCount: 0)
        let settledSecondRun = frame(baseTs: 315, block0Value: 20, block0HeaderByte1: 1,
                                     block1SampleCount: 0)
        let jsonl = [
            markerLine("first_run", unixTs: 100, loggedAtMs: 100_100),
            markerLine("experiment_end", unixTs: 200, loggedAtMs: 200_100),
            markerLine("second_run", unixTs: 300, loggedAtMs: 300_100),
            bufferLine(earlySecondRun, strapTs: 305),
            bufferLine(settledSecondRun, strapTs: 315),
        ].joined(separator: "\n")

        let report = Whoop5OpticalExperimentAnalyzer.analyze(jsonl: jsonl, settlingSeconds: 10)

        XCTAssertEqual(report.phases.map(\.label), ["first_run", "second_run"])
        XCTAssertEqual(report.phases.map(\.frameCount), [0, 1])
        XCTAssertTrue(report.comparisons.isEmpty)
    }

    private func markerLine(_ label: String, unixTs: Int, loggedAtMs: Int) -> String {
        "{\"kind\":\"optical_phase\",\"label\":\"\(label)\",\"unix_ts\":\(unixTs),\"ts_ms\":\(loggedAtMs)}"
    }

    private func bufferLine(_ frame: [UInt8], strapTs: Int) -> String {
        "{\"ts_ms\":999999,\"strap_ts\":\(strapTs),\"size\":\(frame.count),\"offload\":true,\"char\":\"fd4b\",\"hex\":\"\(hex(frame))\"}"
    }

    private func frame(baseTs: Int, block0Value: Int32, block0HeaderByte1: UInt8,
                       block1SampleCount: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Whoop5RawOptical.bufferLength)
        bytes[0] = 0xAA
        bytes[8] = 0x2F
        bytes[9] = 20
        write(UInt32(7), to: &bytes, at: 11)
        write(UInt32(baseTs), to: &bytes, at: 15)

        let block0 = Whoop5RawOptical.blockStart
        bytes[block0] = 2
        bytes[block0 + 1] = block0HeaderByte1
        for channel in 0..<2 {
            let samples = block0 + Whoop5RawOptical.headerLength
                + channel * Whoop5RawOptical.channelSlotLength
            write(UInt32(bitPattern: block0Value), to: &bytes, at: samples)
            write(UInt32(bitPattern: block0Value), to: &bytes, at: samples + 4)
        }

        let block1 = block0 + Whoop5RawOptical.blockLength
        bytes[block1] = UInt8(block1SampleCount)
        if block1SampleCount > 0 {
            let samples = block1 + Whoop5RawOptical.headerLength
            write(UInt32(bitPattern: 44), to: &bytes, at: samples)
            write(UInt32(bitPattern: 55), to: &bytes,
                  at: samples + Whoop5RawOptical.channelSlotLength)
        }
        return bytes
    }

    private func write(_ value: UInt32, to bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
