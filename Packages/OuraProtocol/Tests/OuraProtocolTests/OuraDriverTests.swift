import XCTest
@testable import OuraProtocol

/// OuraDriver flow tests: the transport-agnostic state machine drives scan -> auth -> enable -> stream
/// purely from transitions (no BLE), and ingest(record:) decodes records (with Tier-B gating).
final class OuraDriverTests: XCTestCase {
    private let key: [UInt8] = Array(0..<16)   // deterministic 16-byte app key
    private let rt: UInt32 = 0x0001_0002

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    // MARK: - Full happy-path step sequence (auth -> enable triplet -> streaming)

    func testFullEnableSequence() throws {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        XCTAssertEqual(d.phase, .idle)

        // ready -> enable notifications + request nonce.
        let onReady = d.nextStep(after: .ready)
        XCTAssertEqual(d.phase, .authenticating)
        XCTAssertEqual(onReady.map { $0.label }, ["notify_all", "get_nonce"])
        XCTAssertEqual(onReady[1].bytes, [0x2F, 0x01, 0x2B])

        // nonce -> submit proof.
        let nonce = bytes("0102030405060708090a0b0c0d0e0f")
        let onNonce = d.nextStep(after: .nonceReceived(nonce))
        XCTAssertEqual(onNonce.count, 1)
        XCTAssertEqual(Array(onNonce[0].bytes[0..<3]), [0x2F, 0x11, 0x2D])
        // The proof body matches the known vector.
        XCTAssertEqual(Array(onNonce[0].bytes[3...]), bytes("c49fb9e83c46087a555183a9dc511ee9"))

        // auth success -> first live-HR enable step (read DHR status).
        let onAuth = d.nextStep(after: .authCompleted(.success))
        XCTAssertEqual(d.phase, .enablingLiveHR)
        XCTAssertEqual(onAuth.map { $0.label }, ["dhr_read"])
        XCTAssertEqual(onAuth[0].bytes, [0x2F, 0x02, 0x20, 0x02])

        // ack 1 -> enable ; ack 2 -> subscribe ; ack 3 -> streaming (no more commands).
        let step2 = d.nextStep(after: .enableAckReceived)
        XCTAssertEqual(step2.map { $0.label }, ["dhr_enable"])
        XCTAssertEqual(step2[0].bytes, [0x2F, 0x03, 0x22, 0x02, 0x03])

        let step3 = d.nextStep(after: .enableAckReceived)
        XCTAssertEqual(step3.map { $0.label }, ["dhr_subscribe"])
        XCTAssertEqual(step3[0].bytes, [0x2F, 0x03, 0x26, 0x02, 0x02])

        let done = d.nextStep(after: .enableAckReceived)
        XCTAssertTrue(done.isEmpty)
        XCTAssertEqual(d.phase, .streaming)
    }

    // MARK: - Honest pairing path when no key

    func testNoKeyDrivesNeedsKeyInstall() {
        let d = OuraDriver(ringGen: .gen3, authKey: nil)
        let cmds = d.nextStep(after: .ready)
        XCTAssertTrue(cmds.isEmpty, "without an app key we cannot authenticate; emit no commands")
        XCTAssertEqual(d.phase, .needsKeyInstall)
    }

    func testIsPlausibleAnchorEpochBounds() {
        // The anchor plausibility window is [2020-01-01, 2035-01-01] UTC. OuraLiveSource reads this same
        // predicate to log WHY an anchor was rejected (#91), so the boundaries are pinned here.
        XCTAssertTrue(OuraDriver.isPlausibleAnchorEpoch(1_577_836_800))   // 2020-01-01, inclusive min
        XCTAssertTrue(OuraDriver.isPlausibleAnchorEpoch(2_051_222_400))   // 2035-01-01, inclusive max
        XCTAssertTrue(OuraDriver.isPlausibleAnchorEpoch(1_700_000_000))   // ~2023, mid-window
        XCTAssertFalse(OuraDriver.isPlausibleAnchorEpoch(1_577_836_799))  // one second before min
        XCTAssertFalse(OuraDriver.isPlausibleAnchorEpoch(2_051_222_401))  // one second past max
        XCTAssertFalse(OuraDriver.isPlausibleAnchorEpoch(0))              // epoch 0 — the ~1970 anchor #91 must avoid
    }

    func testFactoryResetStatusDrivesNeedsKeyInstall() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        _ = d.nextStep(after: .ready)
        let cmds = d.nextStep(after: .authCompleted(.inFactoryReset))
        XCTAssertTrue(cmds.isEmpty)
        XCTAssertEqual(d.phase, .needsKeyInstall)
    }

    func testAuthErrorIsSurfacedNotRetriedBlindly() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        _ = d.nextStep(after: .ready)
        _ = d.nextStep(after: .authCompleted(.authError))
        XCTAssertEqual(d.phase, .authFailed(.authError))
    }

    // MARK: - Post-factory-reset key install sequencing (s3.2), gated on allowKeyInstall

    /// With allowKeyInstall == true the adopt flow sequences needsKeyInstall -> installingKey ->
    /// (on the 0x25 ack) re-auth, and the post-install re-auth uses the freshly-provisioned key.
    func testKeyInstallSequencesReauthWhenAllowed() throws {
        // No injected key -> the honest needs-pairing path; the transport will provision one.
        let d = OuraDriver(ringGen: .gen3, authKey: nil, allowKeyInstall: true)
        let onReady = d.nextStep(after: .ready)
        XCTAssertTrue(onReady.isEmpty)
        XCTAssertEqual(d.phase, .needsKeyInstall)

        // The transport generates + persists a fresh 16-byte key and asks the driver for the install
        // command. It must be the DANGEROUS `24 10 <key>` write (s3.2) and advance to installingKey.
        let install = d.beginKeyInstall(key: key)
        XCTAssertNotNil(install)
        XCTAssertEqual(install?.label, "DANGEROUS_install_key")
        XCTAssertEqual(install?.bytes, [0x24, 0x10] + key)
        XCTAssertEqual(d.phase, .installingKey)

        // The ring acks with `25 01 00`; the transport calls back and the driver drives re-auth.
        let onAck = d.keyInstallAcknowledged()
        XCTAssertEqual(onAck.map { $0.label }, ["notify_all", "get_nonce"])
        XCTAssertEqual(onAck[1].bytes, [0x2F, 0x01, 0x2B])
        XCTAssertEqual(d.phase, .authenticating)

        // Re-auth uses the freshly-installed key: the proof matches the known vector for that key.
        let nonce = bytes("0102030405060708090a0b0c0d0e0f")
        let onNonce = d.nextStep(after: .nonceReceived(nonce))
        XCTAssertEqual(onNonce.count, 1)
        XCTAssertEqual(Array(onNonce[0].bytes[0..<3]), [0x2F, 0x11, 0x2D])
        XCTAssertEqual(Array(onNonce[0].bytes[3...]), bytes("c49fb9e83c46087a555183a9dc511ee9"))
    }

    /// With allowKeyInstall == false (the default) the driver MUST NOT sequence an install: it stays at
    /// needsKeyInstall, emits no command, and a stray 0x25 ack cannot advance the flow.
    func testNoKeyInstallSequencedWhenNotAllowed() {
        let d = OuraDriver(ringGen: .gen3, authKey: nil)   // allowKeyInstall defaults to false
        _ = d.nextStep(after: .ready)
        XCTAssertEqual(d.phase, .needsKeyInstall)

        let install = d.beginKeyInstall(key: key)
        XCTAssertNil(install, "no dangerous 0x24 write may be produced without an opt-in adopt flow")
        XCTAssertEqual(d.phase, .needsKeyInstall, "phase must stay needsKeyInstall")

        // A stray ack must be ignored too (no install was sequenced, so there is nothing to acknowledge).
        let onAck = d.keyInstallAcknowledged()
        XCTAssertTrue(onAck.isEmpty)
        XCTAssertEqual(d.phase, .needsKeyInstall)
    }

    /// Even with allowKeyInstall == true, beginKeyInstall only fires from needsKeyInstall; a call from
    /// another phase is a no-op (the gate is BOTH the flag and the phase).
    func testKeyInstallIgnoredOutsideNeedsKeyInstallPhase() {
        let d = OuraDriver(ringGen: .gen3, authKey: key, allowKeyInstall: true)
        _ = d.nextStep(after: .ready)        // -> authenticating (a real key is present)
        XCTAssertEqual(d.phase, .authenticating)
        XCTAssertNil(d.beginKeyInstall(key: key), "install must not fire outside needsKeyInstall")
        XCTAssertEqual(d.phase, .authenticating)
    }

    // MARK: - History fetch loop

    func testHistoryFetchFlushesThenFetchesThenContinues() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        let start = d.nextStep(after: .startHistoryFetch(cursor: 0))
        XCTAssertEqual(d.phase, .fetchingHistory)
        XCTAssertEqual(start.map { $0.label }, ["flush_buffer", "get_events"])
        // get_events cursor 0, max 255, flags FFFFFFFF.
        XCTAssertEqual(start[1].bytes, [0x10, 0x09, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])

        // More data -> continuation fetch at the ADVANCED cursor, SAME shape as the initial request
        // (max 255, open_oura drain_events). The old max=0 "ack" made the ring restart its serve.
        let cont = d.nextStep(after: .historyCursorAdvanced(cursor: 0x12345678, moreData: true))
        XCTAssertEqual(cont.count, 1)
        XCTAssertEqual(cont[0].bytes, [0x10, 0x09, 0x78, 0x56, 0x34, 0x12, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])

        // No more -> back to streaming.
        let stop = d.nextStep(after: .historyCursorAdvanced(cursor: 0x12345678, moreData: false))
        XCTAssertTrue(stop.isEmpty)
        XCTAssertEqual(d.phase, .streaming)
    }

    // MARK: - Ring-time -> UTC anchor (s5.5)

    /// Little-endian bytes of the RAW 0x42 wire value the decoder reads into `OuraTimeSync.epochMs`. The
    /// wire value is unix SECONDS (s6.11), despite the field's "epochMs" name (which reflects what
    /// OURA_PROTOCOL.md s6.11 claims, not what the driver now does with it), so tests build this from a
    /// seconds value.
    private func le8(_ v: Int64) -> [UInt8] {
        (0..<8).map { UInt8((UInt64(bitPattern: v) >> (8 * $0)) & 0xFF) }
    }

    func testNoAnchorBeforeAnyTimeSyncOrBeacon() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        XCTAssertNil(d.unixSeconds(forRingTimestamp: rt))
    }

    func testTimeSyncSetsAnchorAndConvertsPastAndFutureRingTimes() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        let anchorEpochSeconds: Int64 = 1_700_000_000   // the wire's raw value (seconds, not ms)
        let anchorRt: UInt32 = 10_000
        let payload = le8(anchorEpochSeconds) + [0x00]   // raw wire epoch (8B) + tz offset (0 half-hours)
        let rec = OuraRecord(type: OuraEventTag.timeSync.rawValue, ringTimestamp: anchorRt, payload: payload)
        let events = d.ingest(record: rec)
        XCTAssertEqual(events, [.timeSync(OuraTimeSync(ringTimestamp: anchorRt, epochMs: anchorEpochSeconds, tzOffsetSeconds: 0))])

        // Exactly at the anchor: the driver applies the x1000 seconds->ms correction internally, so
        // unixSeconds recovers the ORIGINAL seconds value.
        XCTAssertEqual(d.unixSeconds(forRingTimestamp: anchorRt), Int(anchorEpochSeconds))
        // 100 ticks (10s at the default 100ms/tick) BEFORE the anchor -> 10s earlier (a past/historical
        // record, e.g. from a GetEvents history fetch).
        XCTAssertEqual(d.unixSeconds(forRingTimestamp: anchorRt - 100), Int(anchorEpochSeconds) - 10)
        // 100 ticks AFTER the anchor -> 10s later.
        XCTAssertEqual(d.unixSeconds(forRingTimestamp: anchorRt + 100), Int(anchorEpochSeconds) + 10)
    }

    /// #1073: a banked sample that converts to the future is rejected (the caller falls back to arrival
    /// time), while a historical sample still converts. "now" is injected so the test does not depend on
    /// the wall clock. The anchor is set to `now`, so a ring time far enough after it converts past now.
    func testSampleConvertingToFutureIsRejected() {
        let anchorEpochSeconds: Int64 = 1_700_000_000     // 2023-11-14, mid anchor window
        let anchorRt: UInt32 = 1_000_000
        // Freeze "now" AT the anchor instant, so any sample after the anchor is "in the future".
        let d = OuraDriver(ringGen: .gen3, authKey: key,
                           nowMsProvider: { anchorEpochSeconds * 1000 })
        let payload = le8(anchorEpochSeconds) + [0x00]
        _ = d.ingest(record: OuraRecord(type: OuraEventTag.timeSync.rawValue, ringTimestamp: anchorRt, payload: payload))

        // Historical (10s before now) and exactly-now still convert.
        XCTAssertEqual(d.unixSeconds(forRingTimestamp: anchorRt - 100), Int(anchorEpochSeconds) - 10)
        XCTAssertEqual(d.unixSeconds(forRingTimestamp: anchorRt), Int(anchorEpochSeconds))
        // Inside the 300s skew tolerance (+200s) still converts.
        XCTAssertEqual(d.unixSeconds(forRingTimestamp: anchorRt + 2_000), Int(anchorEpochSeconds) + 200)
        // Just past the tolerance (+301s) is rejected as future/corrupt.
        XCTAssertNil(d.unixSeconds(forRingTimestamp: anchorRt + 3_010))
        // The regression that #1073 is about: a sample ~1 year ahead (still inside the OLD 2020-2035
        // anchor window, so the old gate banked it) is now rejected because it is after `now`.
        XCTAssertNil(d.unixSeconds(forRingTimestamp: anchorRt + 315_360_000),
                     "a sample a year in the future passed the old 2035 gate; the now-gate must reject it")
    }

    /// The two gates are decoupled (#1073): anchor ADOPTION still uses the full 2020-2035 window even when
    /// "now" is frozen years earlier — only the per-sample conversion is bounded by now. A 2034 anchor is
    /// adopted (event emitted), yet converting its own ring time returns nil because 2034 is after now.
    func testAnchorAdoptionStillUsesFullWindowIndependentOfNow() {
        let futureAnchorSeconds: Int64 = 2_020_000_000    // 2034, inside the 2020-2035 anchor window
        let anchorRt: UInt32 = 500
        let d = OuraDriver(ringGen: .gen3, authKey: key,
                           nowMsProvider: { 1_700_000_000 * 1000 })   // now frozen at 2023
        let payload = le8(futureAnchorSeconds) + [0x00]
        let events = d.ingest(record: OuraRecord(type: OuraEventTag.timeSync.rawValue, ringTimestamp: anchorRt, payload: payload))
        XCTAssertEqual(events, [.timeSync(OuraTimeSync(ringTimestamp: anchorRt, epochMs: futureAnchorSeconds, tzOffsetSeconds: 0))],
                       "a 2034 anchor is still adopted — adoption uses the 2020-2035 window, not now")
        XCTAssertNil(d.unixSeconds(forRingTimestamp: anchorRt),
                     "but converting a sample stamped in 2034 is rejected because it is after now (2023)")
    }

    func testRtcBeaconOnlyAnchorsWhenNoTimeSyncSeenYet() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        let beaconRt: UInt32 = 5_000
        let beaconUnixSeconds = 1_700_000_500
        // 0x85 rtc_beacon_ind: unix_s u32 LE + 4 reserved + trailer (payload just needs >= 4 bytes).
        let beaconPayload: [UInt8] = [
            UInt8(beaconUnixSeconds & 0xFF), UInt8((beaconUnixSeconds >> 8) & 0xFF),
            UInt8((beaconUnixSeconds >> 16) & 0xFF), UInt8((beaconUnixSeconds >> 24) & 0xFF),
        ]
        let beaconRec = OuraRecord(type: OuraEventTag.rtcBeacon.rawValue, ringTimestamp: beaconRt, payload: beaconPayload)
        _ = d.ingest(record: beaconRec)
        XCTAssertEqual(d.unixSeconds(forRingTimestamp: beaconRt), beaconUnixSeconds)

        // A later, more precise 0x42 time-sync must override the coarser beacon anchor.
        let syncEpochSeconds: Int64 = 1_700_001_000
        let syncRt: UInt32 = 6_000
        let syncPayload = le8(syncEpochSeconds) + [0x00]
        let syncRec = OuraRecord(type: OuraEventTag.timeSync.rawValue, ringTimestamp: syncRt, payload: syncPayload)
        _ = d.ingest(record: syncRec)
        XCTAssertEqual(d.unixSeconds(forRingTimestamp: syncRt), Int(syncEpochSeconds))

        // A SECOND beacon after a time-sync anchor is already set must NOT override it (secondary only
        // fills a gap, never displaces the primary source).
        let laterBeaconRec = OuraRecord(type: OuraEventTag.rtcBeacon.rawValue, ringTimestamp: syncRt + 100,
                                        payload: beaconPayload)
        _ = d.ingest(record: laterBeaconRec)
        XCTAssertEqual(d.unixSeconds(forRingTimestamp: syncRt), Int(syncEpochSeconds),
                       "a later RTC beacon must not displace an already-set time-sync anchor")
    }

    func testStopClearsTheAnchor() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        let payload = le8(1_700_000_000) + [0x00]
        let rec = OuraRecord(type: OuraEventTag.timeSync.rawValue, ringTimestamp: 1_000, payload: payload)
        _ = d.ingest(record: rec)
        XCTAssertNotNil(d.unixSeconds(forRingTimestamp: 1_000))
        d.stop()
        XCTAssertNil(d.unixSeconds(forRingTimestamp: 1_000), "a stale anchor must not survive stop()/a new session")
    }

    /// Regression test for the crash-safety rule (s6.11): a full cursor=0 history dump can hit a 0x42
    /// record deep in the backlog with an implausible raw value that would overflow Int64 on the naive
    /// seconds->ms `* 1000` conversion (Swift traps on overflow). The plausibility gate must reject it
    /// WITHOUT crashing and WITHOUT setting a garbage anchor.
    func testImplausibleTimeSyncNeverCrashesOrAnchors() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        let hugePayload = le8(Int64.max) + [0x00]   // the exact class of value that overflows the multiply
        let hugeRec = OuraRecord(type: OuraEventTag.timeSync.rawValue, ringTimestamp: 1_000, payload: hugePayload)
        XCTAssertNoThrow(_ = d.ingest(record: hugeRec))
        XCTAssertNil(d.unixSeconds(forRingTimestamp: 1_000), "an implausible epoch must never become the anchor")

        // A negative epoch (int64 sign bit set on a misaligned record) must be equally rejected.
        let negativePayload = le8(-1) + [0x00]
        let negativeRec = OuraRecord(type: OuraEventTag.timeSync.rawValue, ringTimestamp: 2_000, payload: negativePayload)
        XCTAssertNoThrow(_ = d.ingest(record: negativeRec))
        XCTAssertNil(d.unixSeconds(forRingTimestamp: 2_000))

        // A GOOD time-sync arriving afterward must still anchor normally (the gate doesn't wedge the driver).
        let goodPayload = le8(1_700_000_000) + [0x00]
        let goodRec = OuraRecord(type: OuraEventTag.timeSync.rawValue, ringTimestamp: 3_000, payload: goodPayload)
        _ = d.ingest(record: goodRec)
        XCTAssertEqual(d.unixSeconds(forRingTimestamp: 3_000), 1_700_000_000)
    }

    // MARK: - ingest(record:) decoding

    func testIngestDecodesTierARecord() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        // 0x7B SpO2 stable record -> one spo2 event (970, BE).
        let rec = OuraFraming.parseRecord(bytes("7b060200010003ca"))!
        let events = d.ingest(record: rec)
        XCTAssertEqual(events, [.spo2(OuraSpO2(ringTimestamp: rt, value: 970))])
    }

    func testIngestUnknownTagYieldsNothing() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        // 0x99 is not in the dictionary -> [] (never a guessed value).
        let rec = OuraRecord(type: 0x99, ringTimestamp: rt, payload: [0x01, 0x02])
        XCTAssertEqual(d.ingest(record: rec), [])
    }

    // MARK: - Tier-B gating

    func testTierBDroppedByDefault() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)   // allowTierB defaults to false
        // 0x49 sleep_summary_1 is Tier B (UNVERIFIED).
        let rec = OuraFraming.parseRecord(bytes("49080200010001020304"))!
        XCTAssertEqual(d.ingest(record: rec), [], "Tier-B must not feed values when not explicitly allowed")
    }

    func testTierBEmittedOnlyWhenAllowed() {
        let d = OuraDriver(ringGen: .gen3, authKey: key, allowTierB: true)
        let rec = OuraFraming.parseRecord(bytes("49080200010001020304"))!
        let events = d.ingest(record: rec)
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].isTierB)
        if case .tierB(let summary) = events[0] {
            XCTAssertEqual(summary.tag, 0x49)
            XCTAssertEqual(summary.kind, "sleep_summary")
            XCTAssertEqual(summary.rawPayload, bytes("01020304"))
        } else {
            XCTFail("expected a tierB event")
        }
    }

    // MARK: - #287: 0x71 green_ibi_and_amp demoted to Tier B (was corrupting HRV via the 0x60 decoder)

    func testGreenIBIAmp0x71TierIsB() {
        // tierA == corpus-verified; there is no captured 0x71 fixture, and §6.2 documents a different
        // layout than the 0x60 decoder it was wired to — so it must NOT be Tier A.
        XCTAssertEqual(OuraEventTag.greenIbiAmp.tier, .tierB)
    }

    func testGreenIBIAmp0x71GatedOutOfLiveEmission() {
        // The SAME body the 0x60 decoder turns into IBIs, but tagged 0x71. Under the old Tier-A routing a
        // 0x71 record fed fabricated R-R into HRV; now it is Tier B, so by default it yields NOTHING.
        let d = OuraDriver(ringGen: .gen3, authKey: key)   // allowTierB defaults to false
        let rec = OuraFraming.parseRecord(bytes("7112020001007d10000000000000000000000007"))!
        XCTAssertEqual(d.ingest(record: rec), [], "0x71 must not emit IBIs — it is not corpus-verified (#287)")
        // Control: the same bytes ARE otherwise decodable by the 0x60 decoder, so the [] above is the tier
        // gate, not a short/garbage body that would have dropped anyway.
        XCTAssertNotNil(OuraDecoders.decodeIBIAmplitude(rec), "0x60 decoder still yields IBIs for these bytes")
    }

    func testGreenIBIAmp0x71EmitsRawSummaryNotIBIUnderAllowTierB() {
        // With Tier B explicitly allowed it surfaces as RAW BYTES for inspection — never a guessed IBI, and
        // OuraStreamMapping never folds a .tierB into scoring.
        let d = OuraDriver(ringGen: .gen3, authKey: key, allowTierB: true)
        let rec = OuraFraming.parseRecord(bytes("7112020001007d10000000000000000000000007"))!
        let events = d.ingest(record: rec)
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].isTierB)
        if case .tierB(let summary) = events[0] {
            XCTAssertEqual(summary.tag, 0x71)
            XCTAssertEqual(summary.kind, "green_ibi_amp")
        } else {
            XCTFail("expected a tierB raw-bytes summary, not a fabricated IBI")
        }
        for e in events { if case .ibi = e { XCTFail("0x71 must never emit .ibi (#287)") } }
    }

    func testSleepPhase0x4BReclassifiedAsTierAHypnogram() {
        // 0x4B was previously a Tier-B "sleep summary" (dropped by default). It is actually a hypnogram
        // alias (open_oura `0x4b | 0x4e | 0x5a => decode_sleep_phases`), so it now decodes with the SAME
        // validated 2-bit phase decoder as 0x4E/0x5A and emits Tier-A sleep-phase events even when
        // allowTierB == false. Same payload as the 0x4E golden; open_oura's validated stage mapping
        // (0=deep, 1=light, 2=rem, 3=awake) -> codes 1,2,3,0 = light, rem, awake, deep.
        XCTAssertEqual(OuraEventTag(rawValue: 0x4B), .sleepPhaseB)
        XCTAssertEqual(OuraEventTag.sleepPhaseB.tier, .tierA)
        let d = OuraDriver(ringGen: .gen3, authKey: key)   // allowTierB defaults to false
        let rec = OuraFraming.parseRecord(bytes("4b0602000100006c"))!
        XCTAssertEqual(d.ingest(record: rec), [
            .sleepPhase(OuraSleepPhase(ringTimestamp: rt, index: 0, stage: .light)),
            .sleepPhase(OuraSleepPhase(ringTimestamp: rt, index: 1, stage: .rem)),
            .sleepPhase(OuraSleepPhase(ringTimestamp: rt, index: 2, stage: .awake)),
            .sleepPhase(OuraSleepPhase(ringTimestamp: rt, index: 3, stage: .deep)),
        ])
    }

    // MARK: - Activity info (0x50, Tier B, third-party formula) - real Gen 3 captures (PR #960)
    //
    // The six payloads below are byte-for-byte what a real Gen 3 ring sent across the PR #960
    // investigation sessions (2026-07-02): three short static captures, then a full day from steady
    // resting (~0.9 MET) through a vigorous-activity burst (7.4 MET). The ringTimestamp was not part of
    // the captures, so the fixture `rt` stamps them - the pinned evidence is the decoded state/MET
    // values, each RECOMPUTED from the s6.13 formula (met = byte*0.1 below 0x80), not copied blind
    // (the v8.0.1 Oura SpO2 bug was a wrong-decode that asserted constants would have hidden).

    func testActivityInfoDecodesRealCapture1() {
        let d = OuraDriver(ringGen: .gen3, authKey: key, allowTierB: true)
        // Raw payload 41 12 13 13 20: state 0x41=65; MET 18*0.1, 19*0.1, 19*0.1, 32*0.1.
        let rec = OuraRecord(type: OuraEventTag.activityInfo.rawValue, ringTimestamp: rt,
                             payload: bytes("4112131320"))
        let events = d.ingest(record: rec)
        XCTAssertEqual(events, [.activityInfo(OuraActivityInfo(ringTimestamp: rt, state: 0x41,
                                                               met: [1.8, 1.9, 1.9, 3.2]))])
        XCTAssertTrue(events[0].isTierB, "activityInfo must still report isTierB - the formula is UNVERIFIED")
    }

    func testActivityInfoDecodesRealCapture2() {
        let d = OuraDriver(ringGen: .gen3, authKey: key, allowTierB: true)
        // Raw payload 37 21 17 0e 0e 0d 0f 11: state 0x37=55; MET 3.3, 2.3, 1.4, 1.4, 1.3, 1.5, 1.7.
        let rec = OuraRecord(type: OuraEventTag.activityInfo.rawValue, ringTimestamp: rt,
                             payload: bytes("3721170e0e0d0f11"))
        XCTAssertEqual(d.ingest(record: rec),
                       [.activityInfo(OuraActivityInfo(ringTimestamp: rt, state: 0x37,
                                                       met: [3.3, 2.3, 1.4, 1.4, 1.3, 1.5, 1.7]))])
    }

    func testActivityInfoDecodesRealCapture3() {
        let d = OuraDriver(ringGen: .gen3, authKey: key, allowTierB: true)
        // Raw payload 4a 19 20 0e 18: state 0x4a=74; MET 2.5, 3.2, 1.4, 2.4.
        let rec = OuraRecord(type: OuraEventTag.activityInfo.rawValue, ringTimestamp: rt,
                             payload: bytes("4a19200e18"))
        XCTAssertEqual(d.ingest(record: rec),
                       [.activityInfo(OuraActivityInfo(ringTimestamp: rt, state: 0x4a,
                                                       met: [2.5, 3.2, 1.4, 2.4]))])
    }

    func testActivityInfoDecodesRealCapture4Resting() {
        let d = OuraDriver(ringGen: .gen3, authKey: key, allowTierB: true)
        // Full-day session, steady resting: state 0, MET 1.1 then 12 x 0.9 (bytes 0x0B, 0x09 x 12).
        let rec = OuraRecord(type: OuraEventTag.activityInfo.rawValue, ringTimestamp: rt, payload: [
            0x00, 0x0B, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09,
        ])
        XCTAssertEqual(d.ingest(record: rec),
                       [.activityInfo(OuraActivityInfo(ringTimestamp: rt, state: 0,
                           met: [1.1, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9]))])
    }

    func testActivityInfoDecodesRealCapture5ModerateActivity() {
        let d = OuraDriver(ringGen: .gen3, authKey: key, allowTierB: true)
        // Light/moderate period: state 0x2E=46, 13 MET samples 1.2-2.3.
        let rec = OuraRecord(type: OuraEventTag.activityInfo.rawValue, ringTimestamp: rt, payload: [
            0x2E, 0x17, 0x11, 0x11, 0x0E, 0x0D, 0x11, 0x0D, 0x0D, 0x0D, 0x0E, 0x0E, 0x0C, 0x13,
        ])
        XCTAssertEqual(d.ingest(record: rec),
                       [.activityInfo(OuraActivityInfo(ringTimestamp: rt, state: 46,
                           met: [2.3, 1.7, 1.7, 1.4, 1.3, 1.7, 1.3, 1.3, 1.3, 1.4, 1.4, 1.2, 1.9]))])
    }

    func testActivityInfoDecodesRealCapture6ExerciseBurst() {
        let d = OuraDriver(ringGen: .gen3, authKey: key, allowTierB: true)
        // Vigorous burst: state 0x8B=139 (high bit set on the STATE byte, which is NOT MET-encoded),
        // MET 1.8 and 7.4 (0x4A=74 -> 7.4, the highest real value seen). Also the shortest real payload
        // (2 samples), consistent with more frequent flushes during a high-variability period.
        let rec = OuraRecord(type: OuraEventTag.activityInfo.rawValue, ringTimestamp: rt,
                             payload: [0x8B, 0x12, 0x4A])
        XCTAssertEqual(d.ingest(record: rec),
                       [.activityInfo(OuraActivityInfo(ringTimestamp: rt, state: 139, met: [1.8, 7.4]))])
    }

    func testActivityInfoHighByteBranchUsesCoarseSlope() {
        // No real capture has hit the >= 0x80 MET branch yet (nothing above 7.4 MET seen), so pin it
        // with SYNTHETIC vectors recomputed from the s6.13 formula: met = 12.8 + (byte - 128) * 0.2.
        //   0x80 = 128 -> 12.8   |   0x90 = 144 -> 12.8 + 16*0.2 = 16.0   |   0xFF = 255 -> 12.8 + 127*0.2 = 38.2
        let rec = OuraRecord(type: OuraEventTag.activityInfo.rawValue, ringTimestamp: rt,
                             payload: [0x01, 0x80, 0x90, 0xFF])
        XCTAssertEqual(OuraDecoders.decodeActivityInfo(rec),
                       OuraActivityInfo(ringTimestamp: rt, state: 1, met: [12.8, 16.0, 38.2]))
    }

    func testActivityInfoDroppedByDefaultLikeOtherTierB() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)   // allowTierB defaults to false
        let rec = OuraRecord(type: OuraEventTag.activityInfo.rawValue, ringTimestamp: rt,
                             payload: bytes("4112131320"))
        XCTAssertEqual(d.ingest(record: rec), [], "the Tier-B gate must cover .activityInfo too")
    }

    func testActivityInfoEmptyPayloadDecodesToNil() {
        // No state byte at all -> honest nil, never a guessed state.
        XCTAssertNil(OuraDecoders.decodeActivityInfo(
            OuraRecord(type: OuraEventTag.activityInfo.rawValue, ringTimestamp: rt, payload: [])))
    }

    // MARK: - Real steps features (0x7E/0x7F, Tier B, third-party formula) - real Gen 3 capture
    //
    // PARITY/PROVENANCE: the two pairs below are byte-for-byte two CONSECUTIVE real_steps pairs from a
    // real Gen 3 capture (2026-07-30, ring times 3499176-3499474 and their +1 0x7F partners). Expected
    // fields are RECOMPUTED from the [oura-rs] unpack formula, not copied blind.

    func testRealStepsFieldsDecodesRealCapture0x7E() {
        let d = OuraDriver(ringGen: .gen3, authKey: key, allowTierB: true)
        let rec = OuraRecord(type: OuraEventTag.realSteps1.rawValue, ringTimestamp: 3_499_176,
                             payload: bytes("6feb5e0a633e106865da4c136571"))
        let events = d.ingest(record: rec)
        XCTAssertEqual(events, [.realStepsFields(OuraRealStepsFields(tag: OuraEventTag.realSteps1.rawValue, ringTimestamp: 3_499_176,
            fields: [222, 470, 188, 10, 99, 62, 16, 104, 202, 436, 152, 19, 101, 113]))])
        XCTAssertTrue(events[0].isTierB, "realStepsFields must still report isTierB - the formula is UNVERIFIED")
    }

    func testRealStepsFieldsDecodesRealCapture0x7F() {
        let d = OuraDriver(ringGen: .gen3, authKey: key, allowTierB: true)
        // The 0x7F partner of the same pair (ring time = the 0x7E record's rt + 1). Its packed block
        // starts at byte 2, NOT byte 0 (see OuraDecoders.realStepsFieldOffset), so it yields 12 fields:
        // 12/13 would need record bytes 14/15, which do not exist in a 14-byte body.
        let rec = OuraRecord(type: OuraEventTag.realSteps2.rawValue, ringTimestamp: 3_499_177,
                             payload: bytes("24d467b25c127e3721a0a34dbde3"))
        XCTAssertEqual(d.ingest(record: rec), [.realStepsFields(OuraRealStepsFields(tag: OuraEventTag.realSteps2.rawValue, ringTimestamp: 3_499_177,
            fields: [206, 356, 184, 18, 126, 55, 33, 160, 327, 154, 378, 99]))])
    }

    func testRealStepsFieldsDecodesSecondRealPair() {
        let d = OuraDriver(ringGen: .gen3, authKey: key, allowTierB: true)
        let recE = OuraRecord(type: OuraEventTag.realSteps1.rawValue, ringTimestamp: 3_499_474,
                              payload: bytes("6b556d05356b1d6faa2c85aa2368"))
        XCTAssertEqual(d.ingest(record: recE), [.realStepsFields(OuraRealStepsFields(tag: OuraEventTag.realSteps1.rawValue, ringTimestamp: 3_499_474,
            fields: [214, 170, 218, 5, 53, 107, 29, 111, 341, 88, 266, 42, 35, 104]))])

        let recF = OuraRecord(type: OuraEventTag.realSteps2.rawValue, ringTimestamp: 3_499_475,
                              payload: bytes("213590eb62a4515c22b4c381512c"))
        XCTAssertEqual(d.ingest(record: recF), [.realStepsFields(OuraRealStepsFields(tag: OuraEventTag.realSteps2.rawValue, ringTimestamp: 3_499_475,
            fields: [289, 470, 196, 36, 81, 92, 34, 180, 390, 258, 162, 44]))])
    }

    // MARK: - 0x7F's +2 block offset (NOOP finding, 2026-08-01)

    func testRealStepsBlockOffsetIsTagDependent() {
        XCTAssertEqual(OuraDecoders.realStepsFieldOffset(forTag: OuraEventTag.realSteps1.rawValue), 0)
        XCTAssertEqual(OuraDecoders.realStepsFieldOffset(forTag: OuraEventTag.realSteps2.rawValue), 2,
                       "0x7F's packed block starts 2 bytes later than 0x7E's - see OURA_PROTOCOL.md s6.13")
    }

    func testRealStepsFields0x7FYields12Fields0x7EYields14() {
        // 0x7F drops fields 12/13 rather than zero-filling them: they would read past the 14-byte body,
        // and a fabricated zero is indistinguishable from a real one (honest-data invariant).
        let e = OuraRecord(type: OuraEventTag.realSteps1.rawValue, ringTimestamp: 3_499_176,
                           payload: bytes("6feb5e0a633e106865da4c136571"))
        let f = OuraRecord(type: OuraEventTag.realSteps2.rawValue, ringTimestamp: 3_499_177,
                           payload: bytes("24d467b25c127e3721a0a34dbde3"))
        XCTAssertEqual(OuraDecoders.decodeRealStepsFields(e)?.fields.count, 14)
        XCTAssertEqual(OuraDecoders.decodeRealStepsFields(f)?.fields.count, 12)
    }

    func testRealSteps0x7FOffsetReadsTheCarryBitFromTheRightByte() {
        // The regression this offset fixes: fields 0/8 take their 9th bit from the block's byte 3 / byte 11
        // MSB. For 0x7F those are RECORD bytes 5 and 13. Craft a body where the OLD (unshifted) read would
        // see a clear carry and the CORRECT (shifted) read sees a set one - the two decodes cannot agree.
        var payload = [UInt8](repeating: 0, count: 14)
        payload[2] = 0xFF     // block byte 0 for 0x7F -> field0's high bits
        payload[5] = 0x80     // block byte 3 for 0x7F -> field0's carry bit SET; old read would use byte 3 (=0)
        let rec = OuraRecord(type: OuraEventTag.realSteps2.rawValue, ringTimestamp: rt, payload: payload)
        let fields = OuraDecoders.decodeRealStepsFields(rec)?.fields
        XCTAssertEqual(fields?[0], 511, "0xFF<<1 | carry(1) - the carry must come from record byte 5, not byte 3")
        XCTAssertEqual(fields?[3], 0, "block byte 3 (record byte 5) = 0x80, & 0x7f = 0")
    }

    func testRealStepsFieldsCarryBitCombinesWithNeighborByte() {
        // Synthetic, isolating the carry-bit mechanic the [oura-rs] source documents: byte0=0xFF (all
        // ones) with byte3's MSB SET must read field0 = 0xFF*2 + 1 = 511 (the 9-bit max), and byte3's
        // own value (field3) must read only its low 7 bits (the MSB was consumed by field0's carry).
        let rec = OuraRecord(type: OuraEventTag.realSteps1.rawValue, ringTimestamp: rt, payload: [
            0xFF, 0x00, 0x00, 0x80, 0, 0, 0, 0, 0x00, 0x00, 0x00, 0x00, 0, 0,
        ])
        let fields = OuraDecoders.decodeRealStepsFields(rec)?.fields
        XCTAssertEqual(fields?[0], 511)   // 0xFF<<1 | 1
        XCTAssertEqual(fields?[3], 0)     // byte3 = 0x80, & 0x7f = 0
        XCTAssertEqual(fields?[8], 0)     // byte11's MSB is clear -> no carry
    }

    func testRealStepsFieldsDroppedByDefaultLikeOtherTierB() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)   // allowTierB defaults to false
        let rec = OuraRecord(type: OuraEventTag.realSteps1.rawValue, ringTimestamp: rt,
                             payload: bytes("6feb5e0a633e106865da4c136571"))
        XCTAssertEqual(d.ingest(record: rec), [], "the Tier-B gate must cover .realStepsFields too")
    }

    func testRealStepsFieldsWrongLengthDecodesToNil() {
        // The source's own length gate: anything other than exactly 14 bytes -> honest nil, never a guess.
        XCTAssertNil(OuraDecoders.decodeRealStepsFields(
            OuraRecord(type: OuraEventTag.realSteps1.rawValue, ringTimestamp: rt, payload: bytes("00"))))
        XCTAssertNil(OuraDecoders.decodeRealStepsFields(
            OuraRecord(type: OuraEventTag.realSteps1.rawValue, ringTimestamp: rt, payload: [])))
    }

    // MARK: - Live-HR push routing + decode

    func testHandleSecureFrameRoutesNonceStatusAndPush() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        let nonceFrame = OuraSecureFrame(subop: 0x2C, subBody: bytes("0102030405060708090a0b0c0d0e0f"))
        XCTAssertEqual(d.handleSecureFrame(nonceFrame), .nonce(bytes("0102030405060708090a0b0c0d0e0f")))

        let statusFrame = OuraSecureFrame(subop: 0x2E, subBody: [0x00])
        XCTAssertEqual(d.handleSecureFrame(statusFrame), .authStatus(.success))

        let ackFrame = OuraSecureFrame(subop: 0x23, subBody: [0x02, 0x00])
        XCTAssertEqual(d.handleSecureFrame(ackFrame), .enableAck)

        // s5.6 step 1: the dhr_read feature-read ACK (`2f 06 21 02 01 11 02 00`) is subop 0x21 with body
        // `02 01 11 02 00`. It must route to .enableAck or the enable triplet stalls at step 0 (#900).
        let dhrReadAck = OuraSecureFrame(subop: 0x21, subBody: bytes("0201110200"))
        XCTAssertEqual(d.handleSecureFrame(dhrReadAck), .enableAck)

        // The push subBody is the 14 bytes AFTER `2f 0f 28` from the s5.6 wire frame (IBI at [5..6]).
        let pushBody = bytes("020002000001040000000000007f")
        XCTAssertEqual(pushBody.count, 14)
        XCTAssertEqual(d.handleSecureFrame(OuraSecureFrame(subop: 0x28, subBody: pushBody)), .liveHRPush(pushBody))
    }

    func testLiveHRPushIngestStampsLastRingTime() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        // Ingest a TLV record first so the driver learns a ring time to stamp the push with.
        let rec = OuraFraming.parseRecord(bytes("420d0200010000d2dd639001000002"))!
        _ = d.ingest(record: rec)
        // The push body is the 14-byte s5.6 subBody (after `2f 0f 28`); IBI at [5..6] = 01 04 -> 1025 ms.
        let push = bytes("020002000001040000000000007f")
        let events = d.ingestLiveHRPush(body: push)
        XCTAssertEqual(events, [
            .hr(OuraHR(ringTimestamp: rt, bpm: 59, ibiMs: 1025)),
            .ibi(OuraIBI(ringTimestamp: rt, ibiMs: 1025)),
        ])
    }

    // MARK: - Notification-level ingest (open_oura: one record per notification)

    func testIngestDecodesOneRecordPerNotification() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        let reassembler = OuraReassembler()
        // The ring streams one event per notification; feed them separately, not packed. A 0x7B SpO2
        // notification, then a 0x46 temp notification (whose payload holds two int16 samples).
        let spo2 = d.ingest(notification: bytes("7b060200010003ca"), reassembler: reassembler)
        XCTAssertEqual(spo2, [.spo2(OuraSpO2(ringTimestamp: rt, value: 970))])
        let temp = d.ingest(notification: bytes("460802000100420e470e"), reassembler: reassembler)
        XCTAssertEqual(temp, [
            .temp(OuraTemp(ringTimestamp: rt, celsius: 36.50)),
            .temp(OuraTemp(ringTimestamp: rt, celsius: 36.55)),
        ])
    }

    func testIngestNotificationDecodesOnlyFirstPacketWhenBytesLookPacked() {
        // Defensive: if a notification ever carries bytes that LOOK like two packed records, only the
        // first is decoded (one lenient packet per notification) — the trailing bytes are ignored, never
        // walked into phantom records. Documents the open_oura contract.
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        let reassembler = OuraReassembler()
        let value = bytes("7b060200010003ca" + "460802000100420e470e")
        let events = d.ingest(notification: value, reassembler: reassembler)
        XCTAssertEqual(events, [.spo2(OuraSpO2(ringTimestamp: rt, value: 970))])
    }

    // MARK: - Generation-driven command set / MTU

    func testRingGenMtuAndCaps() {
        XCTAssertEqual(OuraRingGen.gen3.mtu, 203)
        XCTAssertEqual(OuraRingGen.gen5.mtu, 247)
        XCTAssertTrue(OuraRingGen.gen5.hasExtraNotifyChars)
        XCTAssertFalse(OuraRingGen.gen3.hasExtraNotifyChars)
        XCTAssertEqual(OuraRingGen.from(model: "Oura Ring 5"), .gen5)
        XCTAssertEqual(OuraRingGen.from(model: "Oura Ring 3"), .gen3)
        XCTAssertTrue(OuraRingGen.gen3.capabilities.contains(.hrv))
    }

    func testSyncTimeCommandIsU64SecondsLEPlusTz() {
        // Authoritative layout: 12 09 <unix_secs u64 LE> <tz i8>. 1_700_000_000 = 0x6553F100
        // -> LE 00 F1 53 65 00 00 00 00, tz 0. (Supersedes the old unix/256 + 0xF6-trailer guess.)
        let cmd = OuraCommands.syncTime(unixSeconds: 1_700_000_000)
        XCTAssertEqual(cmd.bytes,
                       [0x12, 0x09, 0x00, 0xF1, 0x53, 0x65, 0x00, 0x00, 0x00, 0x00, 0x00])
    }

    func testSyncTimeCommandTimezoneByte() {
        // tz is a signed half-hour offset in the trailing byte: +4 (=UTC+2) -> 0x04; -4 -> 0xFC.
        XCTAssertEqual(OuraCommands.syncTime(unixSeconds: 0, tzHalfHours: 4).bytes.last, 0x04)
        XCTAssertEqual(OuraCommands.syncTime(unixSeconds: 0, tzHalfHours: -4).bytes.last, 0xFC)
    }

    // MARK: - Dangerous commands are isolated and labelled

    func testDangerousCommandsAreClearlyNamed() {
        XCTAssertEqual(OuraDangerousCommands.softReset().bytes, [0x0E, 0x01, 0xFF])
        XCTAssertTrue(OuraDangerousCommands.softReset().label.hasPrefix("DANGEROUS_"))
        XCTAssertTrue(OuraDangerousCommands.factoryReset().label.hasPrefix("DANGEROUS_"))
        // The normal command builders never produce a reboot/reset opcode.
        XCTAssertNotEqual(OuraCommands.getBattery().bytes.first, 0x0E)
        XCTAssertNotEqual(OuraCommands.getBattery().bytes.first, 0x1A)
    }
}
