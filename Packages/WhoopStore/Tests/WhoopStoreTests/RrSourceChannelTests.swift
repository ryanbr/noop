import XCTest
import WhoopProtocol
import OuraProtocol
@testable import WhoopStore

/// #1071 — `rrInterval` mixed two optical channels, so every Oura beat was stored twice.
///
/// The ring measures the SAME heartbeats on more than one tag (0x80 green all night, 0x6E only while
/// SpO2 is running) and both decoded to `OuraEvent.ibi`, so the table held roughly two complete copies
/// of a night: 2.06x the beats the measured HR curve allows over one 488-min window. That leaves the
/// MEAN correct (resting HR was never wrong) and destroys everything built on successive differences —
/// a ~200 ms nocturnal SDNN where a healthy adult asleep is 40-100 ms.
///
/// The fix is deliberately NOT a de-duplication: both rows are real measurements, so the channel is
/// LABELLED at decode, both rows are STORED, and the scoring read takes one. These tests pin all three
/// halves of that sentence, plus the two things a channel filter can most easily break — a WHOOP row
/// (NULL forever, one beat source) and a pre-v32 row (NULL, never labelled).
final class RrSourceChannelTests: XCTestCase {
    private let ts = 1_750_000_000

    func testWhoop4HistoricalSourceWinsAndPromotesLegacyLiveRows() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "strap", mac: nil, name: nil)
        try DeviceRegistryStore(dbQueue: store.registryWriter).add(PairedDevice(
            id: "strap", brand: "WHOOP", model: "4.0", sourceKind: .liveBLE,
            capabilities: [.hr, .hrv], status: .active, addedAt: ts, lastSeenAt: ts))

        _ = try await store.insert(Streams(rr: [RRInterval(ts: ts, rrMs: 800),
                                                  RRInterval(ts: ts + 1, rrMs: 810)]), deviceId: "strap")
        _ = try await store.insert(Streams(rr: [RRInterval(ts: ts, rrMs: 800, srcChannel: .whoop4Historical),
                                                  RRInterval(ts: ts + 1, rrMs: 820, srcChannel: .whoop4Historical)]),
                                   deviceId: "strap")

        let selected = try await store.rrIntervals(deviceId: "strap", from: ts, to: ts + 1, limit: 100)
        XCTAssertEqual(selected.map(\.rrMs), [800, 820])
        XCTAssertEqual(selected.map(\.srcChannel), [.whoop4Historical, .whoop4Historical])
    }

    func testWhoop4FallsBackToUnlabelledRowsWhenNoHistoricalDataExists() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "strap", mac: nil, name: nil)
        try DeviceRegistryStore(dbQueue: store.registryWriter).add(PairedDevice(
            id: "strap", brand: "WHOOP", model: "4.0", sourceKind: .liveBLE,
            capabilities: [.hr, .hrv], status: .active, addedAt: ts, lastSeenAt: ts))
        _ = try await store.insert(Streams(rr: [RRInterval(ts: ts, rrMs: 800)]), deviceId: "strap")

        let selected = try await store.rrIntervals(deviceId: "strap", from: ts, to: ts, limit: 100)
        XCTAssertEqual(selected.map(\.rrMs), [800])
        XCTAssertNil(selected.first?.srcChannel)
    }

    func testWhoop4UsesOneHistoricalTransportForTheWholeWindow() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "strap", mac: nil, name: nil)
        try DeviceRegistryStore(dbQueue: store.registryWriter).add(PairedDevice(
            id: "strap", brand: "WHOOP", model: "4.0", sourceKind: .liveBLE,
            capabilities: [.hr, .hrv], status: .active, addedAt: ts, lastSeenAt: ts))
        _ = try await store.insert(Streams(rr: [RRInterval(ts: ts, rrMs: 800),
                                                  RRInterval(ts: ts + 1, rrMs: 810)]), deviceId: "strap")
        _ = try await store.insert(Streams(rr: [RRInterval(ts: ts, rrMs: 805, srcChannel: .whoop4Historical)]),
                                   deviceId: "strap")

        let selected = try await store.rrIntervals(deviceId: "strap", from: ts, to: ts + 1, limit: 100)
        XCTAssertEqual(selected.map(\.rrMs), [805])
        XCTAssertEqual(selected.map(\.srcChannel), [.whoop4Historical])
    }

    // MARK: - The label survives the mapping

    /// A 0x6E record and a 0x80 record covering the same interval must produce rows with DISTINCT
    /// `srcChannel` values — the requirement that makes everything downstream possible.
    func testTwoChannelsOverTheSameIntervalMapToDistinctSrcChannels() {
        let s = OuraStreamMapping.streams(from: [
            .ibi(OuraIBI(ringTimestamp: 100, ibiMs: 848, channel: .greenQuality)),
            .ibi(OuraIBI(ringTimestamp: 100, ibiMs: 848, channel: .spo2Ibi)),
        ], at: ts)
        XCTAssertEqual(s.rr.map(\.srcChannel), [.greenQuality, .spo2Ibi])
        // Same beat, same second, same value — nothing but the channel tells them apart.
        XCTAssertEqual(s.rr.map(\.rrMs), [848, 848])
        XCTAssertEqual(s.rr.map(\.ts), [ts, ts])
    }

    func testMappingCarriesEachDecodersOwnChannel() {
        let s = OuraStreamMapping.streams(from: [
            .ibi(OuraIBI(ringTimestamp: 100, ibiMs: 820, amplitude: 42, channel: .ibiAmplitude)),
            .ibi(OuraIBI(ringTimestamp: 101, ibiMs: 815, channel: .greenQuality)),
            .ibi(OuraIBI(ringTimestamp: 102, ibiMs: 808, channel: .spo2Ibi)),
        ], at: ts)
        XCTAssertEqual(s.rr.map(\.srcChannel), [.ibiAmplitude, .greenQuality, .spo2Ibi])
    }

    /// A channel is never invented. An `OuraIBI` from a source that does not report one stays nil all
    /// the way to the row, where it reads as an unlabelled beat rather than a guessed channel.
    func testAnUnlabelledIbiStaysNilRatherThanBeingGuessed() {
        let s = OuraStreamMapping.streams(from: [
            .ibi(OuraIBI(ringTimestamp: 100, ibiMs: 820)),
        ], at: ts)
        XCTAssertEqual(s.rr.map(\.srcChannel), [nil])
    }

    /// The two enums are pinned to the same raw values on purpose: they are one durable storage code
    /// split across two packages only because `OuraProtocol` does not depend on `WhoopProtocol`.
    func testTheTwoChannelEnumsAgreeCaseForCaseAndCodeForCode() {
        XCTAssertEqual(OuraIBIChannel.allCases.count,
                       RRSourceChannel.allCases.filter { !$0.isWhoop5Transport && $0.rawValue <= 4 }.count)
        for c in OuraIBIChannel.allCases {
            let mapped = OuraStreamMapping.rrChannel(c)
            XCTAssertEqual(mapped?.rawValue, c.rawValue,
                           "\(c) must map to the SAME durable storage code on both sides")
        }
        XCTAssertNil(OuraStreamMapping.rrChannel(nil))
    }

    // MARK: - The migration

    func testV32AddsSrcChannelAndKeepsItOutOfThePrimaryKey() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "rrInterval")
        XCTAssertTrue(cols.contains("srcChannel"), "rrInterval missing v32 srcChannel column")
        let pk = try await store.primaryKeyColumns("rrInterval")
        XCTAssertEqual(pk, ["deviceId", "ts", "rrMs", "seq"],
                       "srcChannel must not enter the key — keying on the label would store the SAME " +
                       "beat twice under two labels, which is the double-count this fixes")
    }

    // MARK: - Store, then filter at read

    /// The whole shape of the fix in one test: both channels are WRITTEN, and only one is READ.
    func testBothChannelsAreStoredButOnlyOneIsScored() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "ring", mac: nil, name: nil)

        // One night's worth in miniature: green runs throughout, 0x6E only over the middle stretch —
        // the SpO2 duty cycle that makes the whole-night inflation ratio vary from 1.09x to 4.11x.
        var rows: [RRInterval] = []
        for i in 0..<10 {
            rows.append(RRInterval(ts: ts + i, rrMs: 800 + i, srcChannel: .greenQuality))
            if (3...6).contains(i) {
                rows.append(RRInterval(ts: ts + i, rrMs: 900 + i, srcChannel: .spo2Ibi))
            }
        }
        let n = try await store.insert(Streams(rr: rows), deviceId: "ring")
        XCTAssertEqual(n.rr, 14, "every measurement is stored; nothing is de-duplicated at insert")

        let stored = try await store.rrRowsWithChannelForTest(deviceId: "ring")
        XCTAssertEqual(stored.count, 14)
        XCTAssertEqual(stored.filter { $0.srcChannel == RRSourceChannel.spo2Ibi.rawValue }.count, 4,
                       "the 0x6E rows must SURVIVE — they are the cross-check on green, not garbage")

        let scored = try await store.rrIntervals(deviceId: "ring", from: 0, to: ts + 1_000, limit: 1_000)
        XCTAssertEqual(scored.count, 10, "scoring reads ONE channel: the 4 SpO2 beats are filtered out")
        XCTAssertEqual(Set(scored.compactMap(\.srcChannel)), [.greenQuality])
        XCTAssertEqual(scored.map(\.rrMs), (0..<10).map { 800 + $0 })
    }

    /// The 0x44 split (#1071 follow-up) is a LABEL, not a filter: 0x60 and 0x44 share a decoder and now
    /// carry distinct codes, and BOTH are still read for scoring exactly as the merged label was. If this
    /// ever starts failing, the split has quietly become a behaviour change — which it must not be, or
    /// the capture it exists to make measurable would be measuring a different night.
    func testBare0x44RowsAreLabelledSeparatelyAndStillScored() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "ring", mac: nil, name: nil)
        var rows: [RRInterval] = []
        for i in 0..<6 {
            rows.append(RRInterval(ts: ts + i, rrMs: 800 + i,
                                   srcChannel: i % 2 == 0 ? .ibiAmplitude : .ibiBare))
        }
        _ = try await store.insert(Streams(rr: rows), deviceId: "ring")

        let stored = try await store.rrRowsWithChannelForTest(deviceId: "ring")
        XCTAssertEqual(stored.filter { $0.srcChannel == RRSourceChannel.ibiBare.rawValue }.count, 3)
        XCTAssertEqual(stored.filter { $0.srcChannel == RRSourceChannel.ibiAmplitude.rawValue }.count, 3,
                       "0x60 keeps its own code — the split must not relabel it")

        let scored = try await store.rrIntervals(deviceId: "ring", from: 0, to: ts + 1_000, limit: 1_000)
        XCTAssertEqual(scored.count, 6, "both tags are still scored; only the label changed")
        XCTAssertEqual(Set(scored.compactMap(\.srcChannel)), [.ibiAmplitude, .ibiBare])
    }

    /// The mapping carries the new code end to end, and it is the durable storage value 4.
    func testBare0x44MapsToItsOwnDurableStorageCode() {
        let s = OuraStreamMapping.streams(from: [
            .ibi(OuraIBI(ringTimestamp: 100, ibiMs: 820, amplitude: 42, channel: .ibiBare)),
        ], at: ts)
        XCTAssertEqual(s.rr.map(\.srcChannel), [.ibiBare])
        XCTAssertEqual(RRSourceChannel.ibiBare.rawValue, 4)
    }

    /// The regression the filter could most easily cause. A WHOOP strap has ONE beat source, so its
    /// rows carry no channel — a whitelist filter would have deleted every WHOOP night from scoring.
    func testWhoopRowsCarryNoChannelAndAreNeverFiltered() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "strap", mac: nil, name: nil)
        let beats = [812, 795, 840, 801, 833]
        _ = try await store.insert(
            Streams(rr: beats.map { RRInterval(ts: ts, rrMs: $0) }), deviceId: "strap")

        let stored = try await store.rrRowsWithChannelForTest(deviceId: "strap")
        XCTAssertEqual(stored.map(\.srcChannel), Array(repeating: nil, count: 5),
                       "NULL is the honest value for a single-source strap, not a placeholder")
        let read = try await store.rrIntervals(deviceId: "strap", from: 0, to: ts + 10, limit: 100)
        XCTAssertEqual(read.map(\.rrMs), beats, "emission order (#823) is unchanged by the filter")
        XCTAssertEqual(read.map(\.srcChannel), Array(repeating: nil, count: 5))
    }

    /// Rows written before v32 are NULL and still read. They were never labelled, so their old inflated
    /// coverage stands — a backfill would be a guess, and dropping them would delete real history.
    func testPreV32RowsAreUnlabelledAndStillRead() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "ring", mac: nil, name: nil)
        for v in [812, 795, 840] {
            try await store.insertLegacyRrWithoutOrdForTest(deviceId: "ring", ts: ts, rrMs: v)
        }
        let read = try await store.rrIntervals(deviceId: "ring", from: 0, to: ts + 10, limit: 100)
        XCTAssertEqual(read.map(\.rrMs), [795, 812, 840],
                       "pre-v32 rows keep the pre-v30 (rrMs, seq) fallback order, unchanged")
        XCTAssertEqual(read.map(\.srcChannel), [nil, nil, nil])
    }

    /// `ibiAmplitude` (0x60/0x44) is deliberately NOT excluded: it does not fire on the hardware where
    /// the duplication was measured, and on a ring where it is the only beat source, excluding it would
    /// leave nothing to score. The filter drops the one channel proven redundant, not every non-green.
    func testTheAmplitudeChannelIsKeptBecauseItMayBeARingsOnlyBeatSource() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "ring", mac: nil, name: nil)
        _ = try await store.insert(Streams(rr: [
            RRInterval(ts: ts, rrMs: 1028, srcChannel: .ibiAmplitude),
            RRInterval(ts: ts + 1, rrMs: 987, srcChannel: .ibiAmplitude),
        ]), deviceId: "ring")

        let read = try await store.rrIntervals(deviceId: "ring", from: 0, to: ts + 10, limit: 100)
        XCTAssertEqual(read.map(\.rrMs), [1028, 987])
        XCTAssertEqual(read.map(\.srcChannel), [.ibiAmplitude, .ibiAmplitude])
    }

    /// The measurable claim behind the issue: an unfiltered night reads ~2x the beats the HR curve
    /// allows, and the filtered read is back on ~1x. This is the `coverage 2.21 -> ~1.0` regression
    /// check in miniature, on data whose true beat count is known by construction.
    func testFilteredReadRestoresOneBeatPerHeartbeat() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "ring", mac: nil, name: nil)

        let trueBeats = 600                              // 10 minutes at 1 Hz
        var rows: [RRInterval] = []
        for i in 0..<trueBeats {
            // The SAME beat seen twice: green on the 1 ms grid, 0x6E rounded onto its 8 ms grid.
            let rr = 1000 + (i % 7) * 3
            rows.append(RRInterval(ts: ts + i, rrMs: rr, srcChannel: .greenQuality))
            rows.append(RRInterval(ts: ts + i, rrMs: (rr / 8) * 8, srcChannel: .spo2Ibi))
        }
        _ = try await store.insert(Streams(rr: rows), deviceId: "ring")

        let allStored = try await store.rrRowsWithChannelForTest(deviceId: "ring")
        let scored = try await store.rrIntervals(deviceId: "ring", from: 0, to: ts + 10_000, limit: 10_000)

        // Stored: ~2 rows per heartbeat (a shade under, where the 8 ms round lands on the green value
        // and the two collide on the (ts, rrMs, seq) key — exactly the 1-in-8 chance the issue notes).
        XCTAssertGreaterThan(Double(allStored.count) / Double(trueBeats), 1.8)
        // Read: exactly one.
        XCTAssertEqual(scored.count, trueBeats)
        XCTAssertEqual(Set(scored.compactMap(\.srcChannel)), [.greenQuality])
    }

    // MARK: - One Oura beat channel per window

    /// 0x60 and 0x80 over the SAME night: 0x60 is the complete train, 0x80 a partial second copy of the
    /// same beats. Read together they over-cover the wall clock and the #1118 gate refuses the night, so
    /// the read keeps the fuller channel alone. NULL rows pass untouched; 0x6E stays excluded.
    /// Fixture shared byte-for-byte with Kotlin `OuraOneChannelReadSqliteTest`.
    func testTwoOuraBeatChannelsOverOneNightScoreOnlyTheFullerOne() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "ring", mac: nil, name: nil)
        _ = try await store.insert(Streams(rr: Self.oneChannelFixture(ts: ts)), deviceId: "ring")

        let read = try await store.rrIntervals(deviceId: "ring", from: ts, to: ts + 200, limit: 1000)
        XCTAssertEqual(read.map(\.rrMs), [1000, 1001, 1002, 1003, 1004, 1005, 1006, 1007, 1008, 1009,
                                          1010, 1011, 777])
        XCTAssertEqual(Set(read.compactMap(\.srcChannel)), [.ibiAmplitude])
        XCTAssertEqual(read.filter { $0.srcChannel == nil }.count, 1)
    }

    /// Which channel is complete is a property of the capture, not the tag. Where 0x80 is the fuller
    /// stream it is the one scored — the #1071 guarantee that a ring's only full source is never dropped.
    func testWhenGreenIsTheFullerChannelItIsTheOneScored() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "ring", mac: nil, name: nil)
        var rows: [RRInterval] = []
        for i in 0..<10 { rows.append(RRInterval(ts: ts + i, rrMs: 950 + i, srcChannel: .greenQuality)) }
        for i in 0..<3 { rows.append(RRInterval(ts: ts + 3 * i, rrMs: 1100 + i, srcChannel: .ibiAmplitude)) }
        _ = try await store.insert(Streams(rr: rows), deviceId: "ring")

        let read = try await store.rrIntervals(deviceId: "ring", from: ts, to: ts + 100, limit: 1000)
        XCTAssertEqual(read.map(\.rrMs), Array(950...959))
        XCTAssertEqual(Set(read.compactMap(\.srcChannel)), [.greenQuality])
    }

    /// The choice is made over the REQUESTED window, not the device's whole history: a window where 0x80
    /// is the only channel present still reads it, even though 0x60 dominates the night around it.
    func testTheChannelIsChosenWithinTheRequestedWindow() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "ring", mac: nil, name: nil)
        _ = try await store.insert(Streams(rr: Self.oneChannelFixture(ts: ts)), deviceId: "ring")
        // A window after the 0x60 train ends, holding only the late 0x80 tail.
        _ = try await store.insert(Streams(rr: [
            RRInterval(ts: ts + 300, rrMs: 880, srcChannel: .greenQuality),
            RRInterval(ts: ts + 301, rrMs: 881, srcChannel: .greenQuality),
        ]), deviceId: "ring")

        let read = try await store.rrIntervals(deviceId: "ring", from: ts + 250, to: ts + 350, limit: 1000)
        XCTAssertEqual(read.map(\.rrMs), [880, 881])
    }

    /// Equal counts keep the amplitude family, so a tie has one defined answer on both platforms.
    func testAChannelTieResolvesToTheAmplitudeFamily() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "ring", mac: nil, name: nil)
        var rows: [RRInterval] = []
        for i in 0..<3 {
            rows.append(RRInterval(ts: ts + i, rrMs: 900 + i, srcChannel: .greenQuality))
            rows.append(RRInterval(ts: ts + i, rrMs: 1200 + i, srcChannel: .ibiAmplitude))
        }
        _ = try await store.insert(Streams(rr: rows), deviceId: "ring")

        let read = try await store.rrIntervals(deviceId: "ring", from: ts, to: ts + 100, limit: 1000)
        XCTAssertEqual(read.map(\.rrMs), [1200, 1201, 1202])
    }

    /// 0x60 and 0x44 are ONE family (one decoder, split for labelling only), so they are counted together
    /// against green and kept together: 4 + 4 amplitude beats outweigh 6 green, though neither tag would
    /// alone.
    func testTheAmplitudeFamilyIsCountedAndKeptAsOne() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "ring", mac: nil, name: nil)
        var rows: [RRInterval] = []
        for i in 0..<6 { rows.append(RRInterval(ts: ts + i, rrMs: 900 + i, srcChannel: .greenQuality)) }
        for i in 0..<8 {
            rows.append(RRInterval(ts: ts + i, rrMs: 1000 + i, srcChannel: i % 2 == 0 ? .ibiAmplitude : .ibiBare))
        }
        _ = try await store.insert(Streams(rr: rows), deviceId: "ring")

        let read = try await store.rrIntervals(deviceId: "ring", from: ts, to: ts + 100, limit: 1000)
        XCTAssertEqual(read.map(\.rrMs), Array(1000...1007))
        XCTAssertEqual(Set(read.compactMap(\.srcChannel)), [.ibiAmplitude, .ibiBare])
    }

    /// 12 s of 0x60 (the full train), 4 overlapping 0x80 beats (the partial copy), 0x6E over the same
    /// seconds (excluded by name), and one unlabelled row. Mirrored exactly in the Kotlin test.
    /// The diagnostic read makes no selection: both Oura beat channels come back, 0x6E still excluded.
    /// Same fixture and expected values as Kotlin `OuraOneChannelReadSqliteTest.theRawExportReadKeepsBothBeatChannels`.
    func testTheRawDiagnosticReadKeepsBothBeatChannels() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "ring", mac: nil, name: nil)
        _ = try await store.insert(Streams(rr: Self.oneChannelFixture(ts: ts)), deviceId: "ring")
        let read = try await store.rawRrIntervals(deviceId: "ring", from: ts, to: ts + 200, limit: 1_000)
        XCTAssertEqual(Set(read.compactMap { $0.srcChannel?.rawValue }), [1, 3])
        XCTAssertEqual(read.count, 12 + 4 + 1)
    }

    static func oneChannelFixture(ts: Int) -> [RRInterval] {
        var rows: [RRInterval] = []
        for i in 0..<12 { rows.append(RRInterval(ts: ts + i, rrMs: 1000 + i, srcChannel: .ibiAmplitude)) }
        for i in 0..<4 { rows.append(RRInterval(ts: ts + 2 * i, rrMs: 900 + i, srcChannel: .greenQuality)) }
        for i in 0..<12 { rows.append(RRInterval(ts: ts + i, rrMs: 1000 + 8 * i, srcChannel: .spo2Ibi)) }
        rows.append(RRInterval(ts: ts + 100, rrMs: 777))
        return rows
    }
}
