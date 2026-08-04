import XCTest
@testable import WhoopProtocol

/// #174: the R22 DISABLE path — the sequence bytes, the key-aware `SET_FF_VALUE(120)` allowlist, and the
/// staged write→read-back run that turns the inferred off value into a measurement.
///
/// Everything here runs with no app, no strap and no CoreBluetooth: `R22DisableReport` is pure and
/// order-dependent, so the whole verdict table — including the case where the strap refuses `'0'` — is
/// covered without hardware. That matters more than usual here, because the one thing that CANNOT be
/// tested off-strap is whether the firmware accepts the value, and the design is built so that the run
/// itself answers that on first use rather than assuming it.
final class R22DisableTests: XCTestCase {

    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

    // MARK: - The sequence

    func testDisableSequenceMirrorsEnableExactly() {
        let enable = Whoop5Config.enableR22Sequence
        let disable = Whoop5Config.disableR22Sequence
        XCTAssertEqual(disable.count, enable.count, "the undo must cover every key the enable sets")
        XCTAssertEqual(disable.map(\.name), enable.map(\.name),
                       "same keys in the same order — the master flag is cleared first")
        XCTAssertTrue(disable.allSatisfy { $0.value == Whoop5Config.featureFlagOffValue })
    }

    func testOffValueIsAsciiZero() {
        XCTAssertEqual(Whoop5Config.featureFlagOffValue, 0x30)
        XCTAssertEqual(Character(UnicodeScalar(Whoop5Config.featureFlagOffValue)), "0")
    }

    /// The disable frame differs from the enable frame in EXACTLY one byte — the value at body offset 32
    /// (frame offset 12 + 32 = 44). Anything else changing means the encoding drifted.
    func testDisableFrameDiffersFromEnableInOnlyTheValueByte() {
        let on = Whoop5Config.frame(flag: Whoop5Config.Flag("enable_r22_packets", 0x32), seq: 1)
        let off = Whoop5Config.frame(flag: Whoop5Config.Flag("enable_r22_packets", 0x30), seq: 1)
        XCTAssertEqual(on.count, off.count)
        let differing = (0..<on.count).filter { on[$0] != off[$0] }
        // The value byte, plus the 4-byte CRC32 trailer it necessarily changes.
        XCTAssertEqual(differing.first, 44, "the value byte sits at frame offset 44")
        XCTAssertEqual(differing.count, 5, "value byte + CRC32 trailer only")
        XCTAssertEqual(off[44], 0x30)
    }

    func testDisableFramesVerifyAndCarryDistinctSeqs() {
        let frames = Whoop5Config.disableSequenceFrames(firstSeq: 1)
        XCTAssertEqual(frames.count, 16)
        XCTAssertEqual(frames.map { $0[9] }, Array(1...16))
        for f in frames {
            XCTAssertTrue(verifyFrame(f, family: .whoop5).ok, "every disable frame must pass 5/MG CRCs")
        }
    }

    /// `disable_pip_r26_packets` gets the SAME off byte as the `enable_*` keys. The sequence is defined as
    /// the undo of the enable sequence, not as a per-key semantic inversion — see the doc on
    /// `disableR22Sequence`. Pinned because it is the one line a reviewer is most likely to "fix".
    func testDisablePipR26GetsTheSameOffByteAsTheEnableKeys() {
        let pip = Whoop5Config.disableR22Sequence.first { $0.name == "disable_pip_r26_packets" }
        XCTAssertEqual(pip?.value, Whoop5Config.featureFlagOffValue)
        XCTAssertEqual(Whoop5Config.enableR22Sequence.first { $0.name == "disable_pip_r26_packets" }?.value, 0x32,
                       "and the enable value stays '2' — this key is why boolean semantics are not assumed")
    }

    // MARK: - The write gate

    func testGateAdmitsOnlyOpcode120() {
        let off = [0x01] + Whoop5Config.payloadBody(name: "enable_r22_packets", value: 0x30)
        // Derived, never hardcoded: enable_r22_packets' enable value is '2', not '1' — the per-key values
        // are exactly what this gate is about, so a literal here would be testing the wrong byte.
        let onValue = FeatureFlagWriteGate.enableValue(for: "enable_r22_packets")!
        let on = [0x01] + Whoop5Config.payloadBody(name: "enable_r22_packets", value: onValue)
        for opcode in UInt8.min...UInt8.max {
            XCTAssertEqual(FeatureFlagWriteGate.admitsEnableWrite(opcode: opcode, payload: on, deepDataOptIn: true),
                           opcode == 120, "enable-direction opcode \(opcode) admission")
            XCTAssertEqual(FeatureFlagWriteGate.admitsDisableWrite(opcode: opcode, payload: off, disableRunInFlight: true),
                           opcode == 120, "disable-direction opcode \(opcode) admission")
        }
    }

    func testGateRefusesDeviceConfigWriteVerb() {
        let off = [0x01] + Whoop5Config.payloadBody(name: "enable_r22_packets", value: 0x30)
        // Derived, never hardcoded: enable_r22_packets' enable value is '2', not '1' — the per-key values
        // are exactly what this gate is about, so a literal here would be testing the wrong byte.
        let onValue = FeatureFlagWriteGate.enableValue(for: "enable_r22_packets")!
        let on = [0x01] + Whoop5Config.payloadBody(name: "enable_r22_packets", value: onValue)
        XCTAssertFalse(FeatureFlagWriteGate.admitsEnableWrite(opcode: 119, payload: on, deepDataOptIn: true),
                       "119 keeps its own Broadcast-HR clause and must never be reachable from here")
        XCTAssertFalse(FeatureFlagWriteGate.admitsDisableWrite(opcode: 119, payload: off, disableRunInFlight: true),
                       "119 must be unreachable from the disable direction too")
    }

    func testEnableDirectionRefusesEverythingWithoutTheOptIn() {
        for flag in Whoop5Config.enableR22Sequence {
            for value in [flag.value, Whoop5Config.featureFlagOffValue] {
                let payload = [0x01] + Whoop5Config.payloadBody(name: flag.name, value: value)
                XCTAssertFalse(FeatureFlagWriteGate.admitsEnableWrite(opcode: 120, payload: payload, deepDataOptIn: false),
                               "\(flag.name)=\(value) must be refused with the opt-in off")
            }
        }
    }

    func testDisableDirectionRefusesEverythingWithoutARunInFlight() {
        for flag in Whoop5Config.enableR22Sequence {
            for value in [flag.value, Whoop5Config.featureFlagOffValue] {
                let payload = [0x01] + Whoop5Config.payloadBody(name: flag.name, value: value)
                XCTAssertFalse(FeatureFlagWriteGate.admitsDisableWrite(opcode: 120, payload: payload, disableRunInFlight: false),
                               "\(flag.name)=\(value) must be refused with no disable run walking its plan")
            }
        }
    }

    func testEnableDirectionAdmitsEveryR22KeyAtItsOwnEnableValue() {
        for flag in Whoop5Config.enableR22Sequence {
            let payload = [0x01] + Whoop5Config.payloadBody(name: flag.name, value: flag.value)
            XCTAssertTrue(FeatureFlagWriteGate.admitsEnableWrite(opcode: 120, payload: payload, deepDataOptIn: true),
                          "\(flag.name)=\(flag.value) must be admitted")
        }
    }

    func testDisableDirectionAdmitsEveryR22KeyAtTheOffValue() {
        for flag in Whoop5Config.enableR22Sequence {
            let payload = [0x01] + Whoop5Config.payloadBody(name: flag.name, value: Whoop5Config.featureFlagOffValue)
            XCTAssertTrue(FeatureFlagWriteGate.admitsDisableWrite(opcode: 120, payload: payload, disableRunInFlight: true),
                          "\(flag.name)='0' must be admitted while a run is in flight")
        }
    }

    /// **The regression test for the defect this split fixes.** The Settings switch is `@AppStorage`-bound,
    /// so flipping it OFF writes the pref false BEFORE the confirmation dialog is raised. Every off-value
    /// write therefore reaches the send path with `deepDataOptIn == false`, and the single old predicate
    /// refused all sixteen — the user tapped "Clear flags on strap" and nothing left the app. The disable
    /// direction must be admitted on the run alone, with the opt-in off.
    func testOffValueWritesAreAdmittedWithTheOptInOffWhileARunIsInFlight() {
        for flag in Whoop5Config.enableR22Sequence {
            let payload = [0x01] + Whoop5Config.payloadBody(name: flag.name, value: Whoop5Config.featureFlagOffValue)
            XCTAssertTrue(FeatureFlagWriteGate.admitsDisableWrite(opcode: 120, payload: payload, disableRunInFlight: true),
                          "\(flag.name)='0' must be admitted by the run gate — the opt-in is already false here")
            XCTAssertFalse(FeatureFlagWriteGate.admitsEnableWrite(opcode: 120, payload: payload, deepDataOptIn: false),
                           "and the enable direction must not be what admits it")
        }
    }

    /// The two directions are disjoint on value, which is what makes "an off value on the wire means a
    /// disable run is in flight" an exact invariant rather than an approximate one.
    func testTheTwoDirectionsAreDisjointOnValue() {
        for flag in Whoop5Config.enableR22Sequence {
            let on = [0x01] + Whoop5Config.payloadBody(name: flag.name, value: flag.value)
            let off = [0x01] + Whoop5Config.payloadBody(name: flag.name, value: Whoop5Config.featureFlagOffValue)
            XCTAssertFalse(FeatureFlagWriteGate.admitsEnableWrite(opcode: 120, payload: off, deepDataOptIn: true),
                           "\(flag.name): the enable direction must not admit the off value")
            XCTAssertFalse(FeatureFlagWriteGate.admitsDisableWrite(opcode: 120, payload: on, disableRunInFlight: true),
                           "\(flag.name): the disable direction must not admit the enable value")
        }
    }

    /// The tightening this gate exists for: before it, opcode 120 was admitted on the opt-in alone, so ANY
    /// feature-flag key with ANY value could travel. Both halves of that are closed, in both directions.
    func testGateRefusesUnknownKeysAndUnknownValues() {
        for key in ["general_ab_test", "enable_pdaf_walk_det", "enable_maverick_model", "enable_r22_v7_packets"] {
            let off = [0x01] + Whoop5Config.payloadBody(name: key, value: 0x30)
            let on = [0x01] + Whoop5Config.payloadBody(name: key, value: 0x31)
            XCTAssertFalse(FeatureFlagWriteGate.admitsDisableWrite(opcode: 120, payload: off, disableRunInFlight: true),
                           "\(key) is not an R22 key and must be refused even at the off value")
            XCTAssertFalse(FeatureFlagWriteGate.admitsEnableWrite(opcode: 120, payload: on, deepDataOptIn: true),
                           "\(key) is not an R22 key and must be refused")
        }
        for value: UInt8 in [0x00, 0x29, 0x33, 0x39, 0x41, 0xFF] {
            let payload = [0x01] + Whoop5Config.payloadBody(name: "enable_r22_packets", value: value)
            XCTAssertFalse(FeatureFlagWriteGate.admitsEnableWrite(opcode: 120, payload: payload, deepDataOptIn: true),
                           "value 0x\(String(format: "%02x", value)) is not the enable value")
            XCTAssertFalse(FeatureFlagWriteGate.admitsDisableWrite(opcode: 120, payload: payload, disableRunInFlight: true),
                           "value 0x\(String(format: "%02x", value)) is not the off value")
        }
        // enable_r22_v4_packets' enable value is '1', so '2' must be refused for THAT key specifically.
        let wrongForV4 = [0x01] + Whoop5Config.payloadBody(name: "enable_r22_v4_packets", value: 0x32)
        XCTAssertFalse(FeatureFlagWriteGate.admitsEnableWrite(opcode: 120, payload: wrongForV4, deepDataOptIn: true),
                       "the admitted value is per-key, not a shared pair")
    }

    func testGateRefusesMalformedBodies() {
        let good = Whoop5Config.payloadBody(name: "enable_r22_packets", value: 0x30)
        func refusedBothWays(_ payload: [UInt8], _ why: String) {
            XCTAssertFalse(FeatureFlagWriteGate.admitsEnableWrite(opcode: 120, payload: payload, deepDataOptIn: true), why)
            XCTAssertFalse(FeatureFlagWriteGate.admitsDisableWrite(opcode: 120, payload: payload, disableRunInFlight: true), why)
        }
        refusedBothWays([0x02] + good, "wrong inner b3 byte")
        refusedBothWays([0x01] + good.dropLast(1), "truncated")
        refusedBothWays([], "empty")
        var dirty = good
        dirty[25] = 0x41
        refusedBothWays([0x01] + dirty, "a name field whose padding is not NUL is not a name field")
        var binary = good
        binary[3] = 0x01
        refusedBothWays([0x01] + binary, "binary in the name field")
    }

    func testKeyAndValueRoundTripsEveryR22Key() {
        for flag in Whoop5Config.enableR22Sequence {
            let payload = [0x01] + Whoop5Config.payloadBody(name: flag.name, value: Whoop5Config.featureFlagOffValue)
            let parsed = FeatureFlagWriteGate.keyAndValue(inSendPayload: payload)
            XCTAssertEqual(parsed?.key, flag.name)
            XCTAssertEqual(parsed?.value, 0x30)
        }
    }

    func testReadBackOpcodeIsOnly128() {
        for opcode in UInt8.min...UInt8.max {
            XCTAssertEqual(FeatureFlagWriteGate.isReadBackOpcode(opcode), opcode == 128)
        }
    }

    // MARK: - The staged run

    /// Build a synthetic GET_FF_VALUE reply record: the key NUL-padded to 32 bytes, then the value byte —
    /// the layout `ValueResponse.value(for:)` reads.
    private func reply(key: String, value: UInt8, resultCode: Int = 1) -> DeviceConfigReadProbe.ValueResponse {
        var record = [UInt8](repeating: 0, count: 32)
        for (i, b) in Array(key.utf8).enumerated() where i < 32 { record[i] = b }
        record.append(value)
        return DeviceConfigReadProbe.ValueResponse(resultCode: resultCode, record: record)
    }

    private func failureReply() -> DeviceConfigReadProbe.ValueResponse {
        DeviceConfigReadProbe.ValueResponse(resultCode: 0, record: [])
    }

    func testPlanStartsWithTheProbeWriteThenItsReadBack() {
        var r = R22DisableReport()
        let first = r.nextStep()
        XCTAssertEqual(first?.stage, .probeWrite)
        XCTAssertEqual(first?.key, R22DisableReport.probeKey)
        XCTAssertEqual(first?.opcode, 120)
        let second = r.nextStep()
        XCTAssertEqual(second?.stage, .probeRead)
        XCTAssertEqual(second?.key, R22DisableReport.probeKey)
        XCTAssertEqual(second?.opcode, 128)
    }

    /// The gate: a probe read-back that still shows the old value STOPS the run with fifteen keys untouched.
    /// This is the case the staging exists for.
    func testProbeRejectionStopsTheRunAndLeavesFifteenKeysUntouched() {
        var r = R22DisableReport()
        let write = r.nextStep()!
        r.noteWriteAck(resultCode: 1, for: write)          // SUCCESS ack — deliberately not believed
        let read = r.nextStep()!
        r.noteReadBack(reply(key: R22DisableReport.probeKey, value: 0x31), for: read)   // still '1'

        XCTAssertNil(r.nextStep(), "no further steps once the off value is rejected")
        XCTAssertEqual(r.verdict, .offValueRejected)
        XCTAssertEqual(r.outcomes[R22DisableReport.probeKey], .unchanged)
        let skipped = r.keys.filter { r.outcomes[$0] == .skipped }
        XCTAssertEqual(skipped.count, 15, "the other fifteen must be left alone")
        XCTAssertTrue(r.render().contains("is NOT how this firmware clears a feature flag"))
        XCTAssertEqual(r.writeAcks[R22DisableReport.probeKey], 1,
                       "the SUCCESS ack is recorded even though the verdict is a rejection")
    }

    /// A clean run: probe accepts, the other fifteen are written, all sixteen read back as '0'.
    func testFullRunClearsAllSixteen() {
        var r = R22DisableReport()
        var steps = 0
        while let step = r.nextStep() {
            steps += 1
            XCTAssertLessThan(steps, 100, "plan must terminate")
            if step.isWrite {
                XCTAssertEqual(step.opcode, 120)
                r.noteWriteAck(resultCode: 1, for: step)
            } else {
                XCTAssertEqual(step.opcode, 128)
                r.noteReadBack(reply(key: step.key, value: 0x30), for: step)
            }
        }
        XCTAssertEqual(r.verdict, .allCleared)
        XCTAssertEqual(r.keys.count, 16)
        for key in r.keys {
            XCTAssertEqual(r.outcomes[key], .cleared, "\(key) should be cleared")
        }
        // 1 probe write + 1 probe read + 15 clear writes + 16 verify reads
        XCTAssertEqual(steps, 33)
        XCTAssertTrue(r.summary.contains("All 16 R22 flags cleared"))
    }

    /// FAILURE on a read-back means the key no longer has a stored value at all. Nothing predicted this
    /// outcome, so it is reported as its own state rather than folded into "cleared".
    func testFailureReadBackIsReportedAsUnsetNotCleared() {
        var r = R22DisableReport()
        let write = r.nextStep()!
        r.noteWriteAck(resultCode: 1, for: write)
        let read = r.nextStep()!
        r.noteReadBack(failureReply(), for: read)
        XCTAssertEqual(r.outcomes[R22DisableReport.probeKey], .unset)
        XCTAssertTrue(r.probePassed, "an unset key is a success — the run should continue")
        XCTAssertNotNil(r.nextStep(), "the clear stage must follow a passing probe")
    }

    func testPartialRunIsReportedAsPartialNotSuccess() {
        var r = R22DisableReport()
        while let step = r.nextStep() {
            if step.isWrite {
                r.noteWriteAck(resultCode: 1, for: step)
            } else if step.key == "wear_detect_bias" {
                r.noteReadBack(reply(key: step.key, value: 0x32), for: step)   // refused this one
            } else {
                r.noteReadBack(reply(key: step.key, value: 0x30), for: step)
            }
        }
        XCTAssertEqual(r.verdict, .partial)
        XCTAssertEqual(r.outcomes["wear_detect_bias"], .unchanged)
        XCTAssertTrue(r.summary.contains("15 of 16"))
    }

    /// A SUCCESS ack whose read-back did not move must never render as success — the #907/#891 rule.
    func testSuccessAckWithUnmovedValueIsNeverReportedAsSuccess() {
        var r = R22DisableReport()
        let write = r.nextStep()!
        r.noteWriteAck(resultCode: 1, for: write)
        let read = r.nextStep()!
        r.noteReadBack(reply(key: R22DisableReport.probeKey, value: 0x31), for: read)
        let text = r.render()
        XCTAssertFalse(r.verdict == .allCleared)
        XCTAssertTrue(text.contains("recorded, not proof"))
        XCTAssertTrue(text.contains("NOT treated as proof"))
    }

    func testSilentProbeStopsTheRun() {
        var r = R22DisableReport()
        let write = r.nextStep()!
        r.noteTimeout(for: write, seconds: 8)
        XCTAssertNil(r.outcomes[R22DisableReport.probeKey],
                     "a silent WRITE decides nothing — only the read-back does")
        let read = r.nextStep()!
        r.noteTimeout(for: read, seconds: 8)
        XCTAssertEqual(r.verdict, .probeInconclusive)
        XCTAssertNil(r.nextStep())
    }

    func testAbandonMarksRemainingKeysSkipped() {
        var r = R22DisableReport()
        let write = r.nextStep()!
        r.noteWriteAck(resultCode: 1, for: write)
        r.noteAbandoned("link dropped")
        XCTAssertEqual(r.verdict, .abandoned)
        XCTAssertNil(r.nextStep())
        XCTAssertEqual(r.keys.filter { r.outcomes[$0] == .skipped }.count, 16)
    }

    func testUndecodableReadBackIsNotTreatedAsCleared() {
        var r = R22DisableReport()
        let write = r.nextStep()!
        r.noteWriteAck(resultCode: 1, for: write)
        let read = r.nextStep()!
        r.noteReadFailure(.crc, for: read)
        XCTAssertEqual(r.outcomes[R22DisableReport.probeKey], .undecodable)
        XCTAssertFalse(r.probePassed)
        XCTAssertEqual(r.verdict, .probeInconclusive)
    }

    /// The report must state the four standing caveats verbatim, so the log, the UI and the PR cannot drift
    /// apart on what was actually established.
    func testRenderCarriesTheCaveats() {
        var r = R22DisableReport()
        while let step = r.nextStep() {
            if step.isWrite { r.noteWriteAck(resultCode: 1, for: step) }
            else { r.noteReadBack(reply(key: step.key, value: 0x30), for: step) }
        }
        let text = r.render()
        XCTAssertTrue(text.contains("'0' as the off value is INFERRED"))
        XCTAssertTrue(text.contains("not the same as reverted BEHAVIOUR"))
        XCTAssertTrue(text.contains("does not restore a snapshot"))
        XCTAssertTrue(text.contains("disable_pip_r26_packets inverts"))
        // Every key appears in the per-key table with its before value.
        for key in r.keys { XCTAssertTrue(text.contains(key), "\(key) missing from the report") }
    }

    func testProbeKeyIsTheOneWithAHardwareWriteDemonstration() {
        XCTAssertEqual(R22DisableReport.probeKey, "enable_sig12")
        XCTAssertTrue(Whoop5Config.enableR22Sequence.contains { $0.name == R22DisableReport.probeKey })
    }

    // MARK: - Fail-closed when the probe key is absent

    /// A key list without the probe key used to plan a blanket sixteen-write and set `probePassed = true`.
    /// That is fail-open on the one write path whose entire safety argument is the probe: it would write an
    /// INFERRED value to every persistent flag without ever testing it on one, and record a passed gate for
    /// a probe that never ran. It must refuse instead.
    func testAKeyListWithoutTheProbeKeyRefusesToWriteAnything() {
        var r = R22DisableReport(keys: ["enable_r22_packets", "enable_r22_v4_packets", "enable_r22_v5_packets"])
        XCTAssertNil(r.nextStep(), "no step may be planned without the probe key")
        XCTAssertFalse(r.probePassed, "probePassed must not record a probe that never ran")
        XCTAssertEqual(r.verdict, .probeUnavailable)
        for key in r.keys {
            XCTAssertEqual(r.outcomes[key], .skipped, "\(key) must be reported as skipped, not written")
        }
        XCTAssertTrue(r.render().contains("REFUSED"), "the report must say nothing was sent")
        // And it stays refused: a second call must not fall through to a plan either.
        XCTAssertNil(r.nextStep())
    }

    /// An empty key list is the degenerate case of the same thing.
    func testAnEmptyKeyListRefusesToWriteAnything() {
        var r = R22DisableReport(keys: [])
        XCTAssertNil(r.nextStep())
        XCTAssertFalse(r.probePassed)
        XCTAssertEqual(r.verdict, .probeUnavailable)
    }

    /// The shipped call sites are unaffected: the default key list contains the probe key, so the staged
    /// run still plans its probe pair first.
    func testTheDefaultKeyListStillPlansTheProbe() {
        var r = R22DisableReport()
        XCTAssertEqual(r.nextStep()?.stage, .probeWrite)
        XCTAssertNotEqual(r.verdict, .probeUnavailable)
    }
}
