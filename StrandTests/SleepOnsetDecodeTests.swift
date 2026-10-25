import XCTest
import WhoopStore
@testable import Strand

/// The 2026-07-14 "shown bedtime 1:29 instead of 12:16" regression, pinned at the DECODE PATH.
///
/// TWO stagesJSON formats exist in the sleepSession table: imported nights store a dict of MINUTES
/// `{"light","deep","rem","awake"}`; on-device COMPUTED nights store a SEGMENT ARRAY
/// `[{"start":epoch,"end":epoch,"stage":…}]` (`AnalyticsEngine.encodeStages`). The displayed-onset
/// stub test (`nightOnsetTs` / `isPreOnsetAwakeStub`) read asleep minutes via the dict-only
/// `decodeStages`, which returns nil for the array format — so every fragment of an on-device night
/// counted as 0 asleep minutes, the real ~54-min first sleep (12:16 → 1:22) tripped the "essentially
/// sleepless stub" branch (0 <= 3), and the shown bedtime jumped to the 1:29 main block. The #259
/// real-sleep-episode floor (`preOnsetStubMinorAsleepFloorMin`) — added for this exact night — never
/// engaged because its input was zeroed before the comparison. `SleepOnsetStubTests` pins the rule on
/// PRE-COMPUTED minutes; these tests pin `SleepView.decodedAsleepMinutes`, the format-agnostic seam
/// the onset walk now reads, using the night's REAL stored JSON.
///
/// Android twin: SleepScreen's onset stub-test caller needs the same both-format decode.
final class SleepOnsetDecodeTests: XCTestCase {

    /// The REAL 12:16 → 1:22 first-sleep fragment (deviceId my-whoop-noop, startTs 1784013364),
    /// byte-for-byte as stored on the device: an on-device computed night's SEGMENT ARRAY.
    /// Non-wake sum: light 926 s + deep 1320 s + rem 990 s = 3236 s ≈ 53.9 asleep minutes.
    private static let fragmentStagesJSON = """
        [{"end":1784013450,"stage":"light","start":1784013364},{"end":1784013540,"stage":"wake","start":1784013450},{"end":1784013600,"stage":"light","start":1784013540},{"end":1784013720,"stage":"wake","start":1784013600},{"end":1784013930,"stage":"light","start":1784013720},{"end":1784015250,"stage":"deep","start":1784013930},{"end":1784015580,"stage":"light","start":1784015250},{"end":1784015640,"stage":"wake","start":1784015580},{"end":1784015880,"stage":"light","start":1784015640},{"end":1784016180,"stage":"wake","start":1784015880},{"end":1784017170,"stage":"rem","start":1784016180},{"end":1784017375,"stage":"wake","start":1784017170}]
        """
    private static let fragmentEffectiveStartTs = 1_784_013_364
    private static let fragmentEndTs = 1_784_017_375

    /// The REAL 1:29 → 7:32 main block (startTs 1784018465, hand-edited onset startTsAdjusted
    /// 1784017740), same night, same stored format. Non-wake sum ≈ 277.6 asleep minutes.
    private static let mainStagesJSON = """
        [{"end":1784018820,"start":1784017740,"stage":"light"},{"end":1784018940,"start":1784018820,"stage":"wake"},{"start":1784018940,"end":1784020140,"stage":"light"},{"end":1784021220,"start":1784020140,"stage":"wake"},{"stage":"light","start":1784021220,"end":1784021670},{"end":1784021910,"start":1784021670,"stage":"wake"},{"stage":"light","end":1784022150,"start":1784021910},{"start":1784022150,"stage":"deep","end":1784023260},{"start":1784023260,"end":1784023380,"stage":"light"},{"start":1784023380,"stage":"wake","end":1784023890},{"stage":"light","start":1784023890,"end":1784024250},{"stage":"wake","end":1784024520,"start":1784024250},{"end":1784024910,"stage":"light","start":1784024520},{"start":1784024910,"end":1784025120,"stage":"deep"},{"end":1784025330,"start":1784025120,"stage":"light"},{"start":1784025330,"end":1784025450,"stage":"rem"},{"start":1784025450,"end":1784025780,"stage":"wake"},{"stage":"light","start":1784025780,"end":1784026050},{"start":1784026050,"end":1784026710,"stage":"deep"},{"stage":"light","start":1784026710,"end":1784027040},{"end":1784027220,"stage":"wake","start":1784027040},{"stage":"light","start":1784027220,"end":1784027670},{"end":1784028510,"stage":"rem","start":1784027670},{"start":1784028510,"stage":"light","end":1784029080},{"stage":"wake","start":1784029080,"end":1784029620},{"end":1784029980,"stage":"light","start":1784029620},{"start":1784029980,"stage":"wake","end":1784030070},{"stage":"light","end":1784031600,"start":1784030070},{"end":1784031690,"stage":"wake","start":1784031600},{"start":1784031690,"stage":"light","end":1784032530},{"end":1784033400,"stage":"rem","start":1784032530},{"start":1784033400,"end":1784033940,"stage":"wake"},{"start":1784033940,"end":1784034300,"stage":"light"},{"stage":"wake","start":1784034300,"end":1784034330},{"end":1784035680,"stage":"light","start":1784034330},{"start":1784035680,"end":1784036100,"stage":"wake"},{"end":1784036160,"stage":"light","start":1784036100},{"start":1784036160,"end":1784037900,"stage":"rem"},{"end":1784038620,"stage":"wake","start":1784037900},{"start":1784038620,"end":1784038650,"stage":"light"},{"start":1784038650,"stage":"rem","end":1784039558}]
        """
    private static let mainEffectiveStartTs = 1_784_017_740
    private static let mainEndTs = 1_784_039_558

    // MARK: - decodedAsleepMinutes (the format-agnostic seam)

    /// THE BUG: the segment-array format (an on-device computed night) must decode to its real asleep
    /// minutes. Before the fix the dict-only decode returned nil here and the caller substituted 0 —
    /// the zero that made a real 54-min first sleep read as a "sleepless" stub.
    func testSegmentArrayFormatDecodesRealAsleepMinutes() {
        let asleep = SleepView.decodedAsleepMinutes(Self.fragmentStagesJSON,
                                                    effectiveStartTs: Self.fragmentEffectiveStartTs)
        XCTAssertEqual(asleep, 3236.0 / 60.0, accuracy: 0.01)
        // Above the #259 floor — the whole point: a real sleep episode must clear it.
        XCTAssertGreaterThanOrEqual(asleep, SleepView.preOnsetStubMinorAsleepFloorMin)
    }

    /// The imported dict-of-minutes format still decodes (asleep = light + deep + rem, awake excluded).
    func testDictFormatStillDecodes() {
        let asleep = SleepView.decodedAsleepMinutes(#"{"light":200,"deep":80,"rem":60,"awake":30}"#,
                                                    effectiveStartTs: 0)
        XCTAssertEqual(asleep, 340, accuracy: 0.001)
    }

    /// nil / empty / garbage stay 0 — the degenerate inputs keep the old behaviour.
    func testDegenerateInputsAreZero() {
        XCTAssertEqual(SleepView.decodedAsleepMinutes(nil, effectiveStartTs: 0), 0)
        XCTAssertEqual(SleepView.decodedAsleepMinutes("", effectiveStartTs: 0), 0)
        XCTAssertEqual(SleepView.decodedAsleepMinutes("not json", effectiveStartTs: 0), 0)
        XCTAssertEqual(SleepView.decodedAsleepMinutes("[]", effectiveStartTs: 0), 0)
    }

    /// The segment decode threads the #259 pre-onset trim: segments before `effectiveStartTs` don't
    /// count, exactly as the hero's stage totals trim them.
    func testSegmentDecodeTrimsPreOnset() {
        // One 10-min light segment, but the effective onset sits 5 min into it.
        let json = #"[{"start":1000,"end":1600,"stage":"light"}]"#
        XCTAssertEqual(SleepView.decodedAsleepMinutes(json, effectiveStartTs: 1300), 5, accuracy: 0.001)
    }

    // MARK: - The golden: the real night's onset comes from the 12:16 fragment

    /// END-TO-END through the decode path: both REAL blocks of the 2026-07-14 night, decoded from their
    /// stored segment-array JSON (NOT pre-computed minutes), resolve the first fragment's timestamp.
    /// Before the fix both decoded to 0 asleep, the fragment classified as a sleepless stub, and the
    /// index was 1 (the 1:29 main block) — the "last night's sleep 1:29" VK saw on the Sleep tab hero.
    func testRealNightOnsetIsTheFirstSleepFragment() {
        let frags: [(json: String, effStart: Int, end: Int)] = [
            (Self.fragmentStagesJSON, Self.fragmentEffectiveStartTs, Self.fragmentEndTs),
            (Self.mainStagesJSON, Self.mainEffectiveStartTs, Self.mainEndTs),
        ]
        let sessions = frags.map {
            CachedSleepSession(startTs: $0.effStart, endTs: $0.end,
                               efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: $0.json)
        }
        XCTAssertEqual(SleepModel.nightOnsetTs(sessions), Self.fragmentEffectiveStartTs)
    }
}
