import XCTest
@testable import WhoopProtocol

/// #2847: the flash-banked MG ECG record decodes AND has somewhere to be stored.
///
/// `Whoop5EcgR16Tests` pins the decoder; this file pins the route from an offloaded frame to a row, which
/// is the part that was missing. Layout version 16 is now in `mappedWhoop5HistoricalVersions`, and that
/// move is only safe because `extractHistoricalStreams` banks the record first: mapping a version takes
/// its frames off `rejectedHistoricalRecords`' unconditional-archive branch, and the strap frees them on
/// the trim ack either way, so the order of the two halves is the whole argument.
///
/// Fixtures are SYNTHETIC, built from the documented layout exactly as the R16 suite's are. Nothing here
/// establishes volts per count, a sample rate, or anything clinical. Kotlin twin:
/// `Whoop5EcgHistoricalStorageTest`.
final class Whoop5EcgHistoricalStorageTests: XCTestCase {

    /// A complete, CRC-valid R16 frame with a full waveform.
    ///
    /// `strapSeconds` defaults above `MIN_PLAUSIBLE_UNIX`: the R16 suite's own 0x65430001 is 1,698,889,729,
    /// which is BELOW the #547 floor, so a fixture built on it would exercise the dropped-record path
    /// rather than the storage path.
    private func r16Frame(strapSeconds: Int = 1_760_000_000,
                          sequence: Int = 0x0001_2345,
                          declaredCount: Int = Whoop5Ecg.r16MaxSamples,
                          revision: UInt8 = Whoop5Ecg.r16Revision,
                          innerLength: Int = Whoop5Ecg.r16InnerLength) -> [UInt8] {
        var inner = [UInt8](repeating: 0, count: innerLength)
        inner[0] = Whoop5Ecg.storedRecordType
        inner[1] = revision
        inner[2] = 0x5a
        put32(&inner, 3, sequence)
        put32(&inner, 7, strapSeconds)
        put16(&inner, 11, 16_384)
        inner[13] = 3                                    // quality
        inner[14] = 0x08                                 // flags: presence
        inner[17] = 100                                  // progress: terminal
        inner[19] = 64                                   // averageHR
        put16(&inner, 24, declaredCount)
        // A ramp rather than zeros, so a route that silently substituted an empty payload is visible.
        for i in 0..<declaredCount {
            let o = Whoop5Ecg.r16SampleStart + i * Whoop5Ecg.r16SampleSlotBytes
            guard o + 2 < inner.count else { break }
            inner[o] = UInt8(0x80 | (i & 3))
            inner[o + 1] = UInt8((i >> 1) & 0xff)
            inner[o + 2] = UInt8(i & 0xff)
        }
        if innerLength == Whoop5Ecg.r16InnerLength {
            inner[Whoop5Ecg.r16LeadsOffCountOffset] = 11
            for i in 0..<Whoop5Ecg.r16LeadsOffSlots {
                put16(&inner, Whoop5Ecg.r16LeadsOffIStart + i * 2, 0x0100 + i)
                put16(&inner, Whoop5Ecg.r16LeadsOffQStart + i * 2, 0x0200 + i)
            }
        }
        return puffinCommandFrame(cmd: inner[2], seq: inner[1],
                                  payload: Array(inner.dropFirst(3)), type: inner[0])
    }

    private func put16(_ b: inout [UInt8], _ i: Int, _ v: Int) {
        b[i] = UInt8(v & 0xff); b[i + 1] = UInt8((v >> 8) & 0xff)
    }

    private func put32(_ b: inout [UInt8], _ i: Int, _ v: Int) {
        for k in 0..<4 { b[i + k] = UInt8((v >> (8 * k)) & 0xff) }
    }

    /// Identity clock refs, the archive-replay seam, so no stale-RTC correction applies and the fixture's
    /// own `strapSeconds` is the ts under test.
    private func streams(_ frames: [[UInt8]]) -> Streams {
        extractHistoricalStreams(frames.map { parseFrame($0, family: .whoop5) },
                                 deviceClockRef: 0, wallClockRef: 0, family: .whoop5)
    }

    // MARK: - the row

    func testAnOffloadedEcgRecordBanksExactlyOneRow() {
        let s = streams([r16Frame()])
        XCTAssertEqual(s.ecgWaveform.count, 1)
        XCTAssertEqual(s.ecgWaveform.first?.ts, 1_760_000_000)
        XCTAssertEqual(s.ecgWaveform.first?.sequence, 0x0001_2345)
        XCTAssertEqual(s.ecgWaveform.first?.record.count, Whoop5Ecg.r16InnerLength)
    }

    /// The stored bytes are the WIRE bytes. This is the claim the whole storage shape rests on, so it is
    /// asserted against the frame rather than against a re-encode of the decode: a codec that packed
    /// decoded samples back into slots could be byte-identical for every sample it decoded and still
    /// differ in the padding past `sampleCount`, which no decode reads and no re-encode can invent.
    func testTheStoredBytesAreTheRecordsOwnBytes() throws {
        let frame = r16Frame()
        let inner = try XCTUnwrap(Whoop5Ecg.innerPayload(frame, payloadStart: Whoop5Ecg.rawTypeOffset))
        let row = try XCTUnwrap(streams([frame]).ecgWaveform.first)
        XCTAssertEqual(row.record, inner, "the row must hold the inner record verbatim")
    }

    /// And the row is READABLE by the decoder that is already pinned, rather than by a reader of its own.
    func testTheStoredRowDecodesBackThroughParseR16() throws {
        let frame = r16Frame()
        let row = try XCTUnwrap(streams([frame]).ecgWaveform.first)
        let fromRow = try XCTUnwrap(Whoop5Ecg.parseR16(inner: row.record))
        let fromFrame = try XCTUnwrap(Whoop5Ecg.r16FromFrame(frame))
        XCTAssertEqual(fromRow, fromFrame)
        XCTAssertEqual(fromRow.samples.count, Whoop5Ecg.r16MaxSamples)
        XCTAssertEqual(fromRow.leadsOffIRaw.count, Whoop5Ecg.r16LeadsOffSlots)
    }

    /// A reading is many records, and each is its own row keyed on its own second.
    func testEachRecordOfAReadingIsItsOwnRow() {
        let frames = (0..<5).map { i in
            r16Frame(strapSeconds: 1_760_000_000 + i, sequence: 100 + i)
        }
        let s = streams(frames)
        XCTAssertEqual(s.ecgWaveform.map(\.ts), (0..<5).map { 1_760_000_000 + $0 })
        XCTAssertEqual(s.ecgWaveform.map(\.sequence), (0..<5).map { 100 + $0 })
    }

    /// An ECG record is not a scoreable record, and the funnel must not pretend otherwise. `averageHR` is
    /// the strap's own average over a reading, so routing it into `hr` would feed a recovery input from a
    /// quantity nobody has validated for it (#752 bounds what may be read off this signal at all).
    func testAnEcgRecordContributesToNoScoredStream() {
        let s = streams([r16Frame()])
        XCTAssertTrue(s.hr.isEmpty)
        XCTAssertTrue(s.rr.isEmpty)
        XCTAssertTrue(s.gravity.isEmpty)
        XCTAssertTrue(s.ppgHr.isEmpty)
        XCTAssertTrue(s.ppgWaveform.isEmpty)
        XCTAssertTrue(s.spo2.isEmpty)
    }

    /// A chunk of nothing but ECG records has NOT lost its data, so the emptiness verdict that gates the
    /// insert (and drives `Backfiller.finishChunk`'s silent-data-loss line) must read non-empty.
    func testAChunkOfOnlyEcgRecordsIsNotEmpty() {
        XCTAssertFalse(streams([r16Frame()]).isEmpty)
    }

    // MARK: - the archive hand-off

    /// Mapped and stored, so NOT also archived: the raw archive is a 5 MiB ring whose per-version floor
    /// protects 64 lines, and a reading at one 1.5 KB record per second would both evict other evidence
    /// and be evicted itself (@DX23876 measured that within a couple of hours of ordinary MG traffic).
    func testAnIntactEcgRecordIsNotArchivedBecauseItIsStored() {
        XCTAssertTrue(rejectedHistoricalRecords([r16Frame()], family: .whoop5).isEmpty)
    }

    /// The skip is bound to the INTEGRITY VERDICT, not to the version byte. A broken record banks no row,
    /// so its bytes are the only copy that can exist and the archive must keep them.
    func testACorruptEcgRecordIsStillArchived() {
        var frame = r16Frame()
        frame[frame.count - 1] ^= 0xff          // break the trailing CRC32
        XCTAssertEqual(rejectedHistoricalRecords([frame], family: .whoop5).count, 1)
        XCTAssertTrue(streams([frame]).ecgWaveform.isEmpty, "a broken record must bank no row")
    }

    /// THE HOLE v26 ALREADY HAS, pinned rather than left to be discovered: an INTACT record whose own @15
    /// fails the #547 plausibility gate banks no row (the extraction drops it) and is not archived either
    /// (the skip only asks whether the frame is intact), so it is stored nowhere.
    ///
    /// Pinned as the current behaviour because it is shared with v26's far larger population and closing
    /// it needs `rejectedHistoricalRecords` to know a wall clock it has no parameter for. If someone
    /// closes it, this test is what tells them v16 was covered by the same change.
    func testAnIntactButImplausiblyDatedRecordIsStoredNowhereForNowLikeV26() {
        let frame = r16Frame(strapSeconds: 1_000)      // below MIN_PLAUSIBLE_UNIX
        XCTAssertTrue(streams([frame]).ecgWaveform.isEmpty)
        XCTAssertTrue(rejectedHistoricalRecords([frame], family: .whoop5).isEmpty)
    }

    /// A v16 frame whose record is NOT `r16InnerLength` long stays ARCHIVED, however intact it is.
    ///
    /// Found by re-reading this change: `parseR16` accepts exactly one length, so such a frame banks no
    /// row whatever its state, while the archive skip was asking only whether the frame was intact. A
    /// 1,484-byte record with both CRCs valid was skipped here AND dropped by the extraction, which is
    /// the one outcome this whole filter exists to prevent. Before v16 was mapped the same frame was
    /// archived by the unmapped-layout rule, so the hole arrived with the mapping.
    func testAnIntactVersionSixteenFrameOfTheWrongLengthIsStillArchived() {
        let frame = r16Frame(declaredCount: 10, innerLength: Whoop5Ecg.r16InnerLength - 100)
        let parsed = parseFrame(frame, family: .whoop5)
        XCTAssertTrue(parsed.ok, "the fixture must be INTACT, or it proves nothing about the skip")
        XCTAssertNotEqual(parsed.crcOK, false)
        XCTAssertNil(Whoop5Ecg.r16FromFrame(frame), "and undecodable, which is the point")
        XCTAssertTrue(streams([frame]).ecgWaveform.isEmpty)
        XCTAssertEqual(rejectedHistoricalRecords([frame], family: .whoop5).count, 1,
                       "a record nothing can store must keep its bytes in the archive")
    }

    /// A record declaring ZERO samples is still banked, and that is a decision rather than an accident.
    ///
    /// The opening records of a real run declare 0 and then 245 before the first full 500, so a count-0
    /// record marks where a reading began. The row here is the RECORD, not a waveform-only row, so its
    /// header earns the 1,572 bytes and dropping it would leave a gap in the sequence that a later reader
    /// would have to explain. The v26 rows skip their empty equivalents because there the row IS the
    /// samples.
    func testARecordDeclaringNoSamplesIsStillBanked() throws {
        let row = try XCTUnwrap(streams([r16Frame(declaredCount: 0)]).ecgWaveform.first)
        XCTAssertEqual(row.record.count, Whoop5Ecg.r16InnerLength)
        let decoded = try XCTUnwrap(Whoop5Ecg.parseR16(inner: row.record))
        XCTAssertEqual(decoded.sampleCount, 0)
        XCTAssertTrue(decoded.samples.isEmpty)
    }

    /// Two records stamped in ONE strap-second both reach the store as separate rows. The store's key is
    /// what has to keep them apart, and `EcgWaveformSampleTests` is where that is proved; this end pins
    /// that the extraction does not merge or drop one first.
    func testTwoRecordsStampedInOneSecondBothReachTheStore() {
        let frames = [r16Frame(sequence: 10, declaredCount: 0),
                      r16Frame(sequence: 11, declaredCount: 245)]
        let rows = streams(frames).ecgWaveform
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.ts), [1_760_000_000, 1_760_000_000])
        XCTAssertEqual(rows.map(\.sequence), [10, 11])
    }

    // MARK: - the layout claim is exactly one version wide

    func testOnlyRevisionSixteenTakesTheEcgRoute() {
        // Revision 17 is the LIVE record (type 43), and a type-47 frame carrying 17 is not a layout NOOP
        // maps: it must stay unmapped, and therefore archived, rather than fall into the ECG route.
        let wrongRevision = r16Frame(revision: 17)
        XCTAssertTrue(streams([wrongRevision]).ecgWaveform.isEmpty)
        XCTAssertEqual(rejectedHistoricalRecords([wrongRevision], family: .whoop5).count, 1)
    }
}
