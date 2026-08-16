import XCTest
@testable import StrandAnalytics

/// Golden vectors for content-driven breath protocols (holds + Presence tempos).
final class BreathProtocolPlayerTests: XCTestCase {

    func test_box_one_cycle_cues() {
        let proto = BreathProtocolCatalog.protocolById("box_4_4_4_4")!
        let cues = BreathProtocolPlayer.schedule(proto, sessionMs: 16_000)
        XCTAssertEqual(cues, [
            BreathCue(offsetMs: 0, phase: .inhale, loops: 1),
            BreathCue(offsetMs: 4_000, phase: .hold, loops: 0),
            BreathCue(offsetMs: 8_000, phase: .exhale, loops: 2),
            BreathCue(offsetMs: 12_000, phase: .hold, loops: 0),
        ])
    }

    func test_deep_and_478() {
        let deep = BreathProtocolCatalog.protocolById("deep_4_2_6")!
        XCTAssertEqual(
            BreathProtocolPlayer.schedule(deep, sessionMs: 12_000),
            [
                BreathCue(offsetMs: 0, phase: .inhale, loops: 1),
                BreathCue(offsetMs: 4_000, phase: .hold, loops: 0),
                BreathCue(offsetMs: 6_000, phase: .exhale, loops: 2),
            ]
        )
        let fse = BreathProtocolCatalog.protocolById("four_seven_eight")!
        let cues = BreathProtocolPlayer.schedule(fse, sessionMs: 19_000)
        XCTAssertEqual(cues.map(\.offsetMs), [0, 4_000, 11_000])
        XCTAssertEqual(cues.map(\.phase), [.inhale, .hold, .exhale])
    }

    func test_nadi_labels_and_cycle() {
        let proto = BreathProtocolCatalog.protocolById("nadi_shodhana")!
        XCTAssertEqual(proto.cycleDurationMs, 24_000)
        let cues = BreathProtocolPlayer.schedule(proto, sessionMs: 24_000)
        XCTAssertEqual(cues.count, 6)
        XCTAssertEqual(cues[0].label, "Inhale left")
        XCTAssertEqual(cues[2].label, "Exhale right")
        XCTAssertEqual(cues[5].label, "Exhale left")
    }

    func test_presence_regular_and_punching() {
        let reg = BreathProtocolCatalog.protocolById("presence_regular")!
        let cues = BreathProtocolPlayer.schedule(reg, sessionMs: 7_600)
        XCTAssertEqual(cues, [
            BreathCue(offsetMs: 0, phase: .inhale, loops: 1),
            BreathCue(offsetMs: 3_800, phase: .exhale, loops: 2),
        ])
        let punch = BreathProtocolCatalog.protocolById("presence_punching")!
        XCTAssertEqual(punch.cycleDurationMs, 3_800)
        let pc = BreathProtocolPlayer.schedule(punch, sessionMs: 3_800)
        XCTAssertEqual(pc.first?.phase, .inhale)
        XCTAssertEqual(pc[1].offsetMs, 1_900)
    }

    func test_guided_schedules_empty() {
        for id in ["kapalabhati", "holotropic", "wim_hof", "shamanic"] {
            let proto = BreathProtocolCatalog.protocolById(id)!
            XCTAssertEqual(proto.mode, .guided)
            XCTAssertTrue(BreathProtocolPlayer.schedule(proto, sessionMs: 60_000).isEmpty)
        }
    }

    func test_catalog_contains_expected_ids() {
        let ids = Set(BreathProtocolCatalog.all.map(\.id))
        for need in ["relax_4_6", "coherence_5_5", "box_4_4_4_4", "presence_regular",
                     "presence_mid", "presence_punching", "coherent_6_6", "wim_hof"] {
            XCTAssertTrue(ids.contains(need), "missing \(need)")
        }
    }
}
