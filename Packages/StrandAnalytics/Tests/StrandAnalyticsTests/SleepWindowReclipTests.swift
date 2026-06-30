import XCTest
import Foundation
@testable import StrandAnalytics

final class SleepWindowReclipTests: XCTestCase {

    private func segments(_ json: String) -> [(start: Int, end: Int, stage: String)] {
        let arr = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] ?? []
        return arr.compactMap {
            guard let s = ($0["start"] as? NSNumber)?.intValue,
                  let e = ($0["end"] as? NSNumber)?.intValue,
                  let st = $0["stage"] as? String else { return nil }
            return (s, e, st)
        }
    }

    private func minutes(_ json: String) -> [String: Double] {
        let dict = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        return dict.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    // MARK: - segment array (computed nights)

    func testSegmentTrimDropsAndClips() throws {
        let json = """
        [{"start":1000,"end":2000,"stage":"light"},
         {"start":2000,"end":3000,"stage":"deep"},
         {"start":3000,"end":4000,"stage":"wake"}]
        """
        let out = try XCTUnwrap(SleepWindowReclip.reclip(
            stagesJSON: json, sessionStart: 1000, oldEnd: 4000, newStart: 1000, newEnd: 2500))
        let segs = segments(out)
        XCTAssertEqual(segs.count, 2, "the wholly-after segment is dropped")
        XCTAssertEqual(segs[0].stage, "light")
        XCTAssertEqual(segs[1].stage, "deep")
        XCTAssertEqual(segs[1].end, 2500, "the segment spanning the new wake is clipped to it")
    }

    func testSegmentExtendAppendsTrailingWake() throws {
        let json = """
        [{"start":1000,"end":2000,"stage":"light"},
         {"start":2000,"end":3000,"stage":"deep"}]
        """
        let out = try XCTUnwrap(SleepWindowReclip.reclip(
            stagesJSON: json, sessionStart: 1000, oldEnd: 3000, newStart: 1000, newEnd: 3600))
        let segs = segments(out)
        XCTAssertEqual(segs.count, 3)
        XCTAssertEqual(segs.last?.stage, "wake")
        XCTAssertEqual(segs.last?.start, 3000)
        XCTAssertEqual(segs.last?.end, 3600)
    }

    // MARK: - minute dict (imported nights)

    func testMinutesTrimCascadesFromAwakeThenLight() throws {
        // Shorten by 40 min: awake (30) → 0 and the remaining 10 comes off light.
        let json = #"{"awake":30,"light":200,"deep":80,"rem":90}"#
        let out = try XCTUnwrap(SleepWindowReclip.reclip(
            stagesJSON: json, sessionStart: 0, oldEnd: 8 * 3600, newStart: 0, newEnd: 8 * 3600 - 40 * 60))
        let m = minutes(out)
        XCTAssertEqual(try XCTUnwrap(m["awake"]), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(m["light"]), 190, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(m["deep"]), 80, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(m["rem"]), 90, accuracy: 0.001)
    }

    func testMinutesExtendAddsToAwake() throws {
        let json = #"{"awake":30,"light":200,"deep":80,"rem":90}"#
        let out = try XCTUnwrap(SleepWindowReclip.reclip(
            stagesJSON: json, sessionStart: 0, oldEnd: 8 * 3600, newStart: 0, newEnd: 8 * 3600 + 20 * 60))
        let m = minutes(out)
        XCTAssertEqual(try XCTUnwrap(m["awake"]), 50, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(m["light"]), 200, accuracy: 0.001)
    }

    func testSegmentTrimBeforeAllSegmentsReturnsWakeFillNotNil() throws {
        // Corrected wake lands before every stage → instead of returning nil (which would let the store's
        // COALESCE keep the OLD stages extending PAST the new wake), emit a single wake segment that
        // covers exactly the corrected window. (#318 review #8)
        let json = """
        [{"start":2000,"end":3000,"stage":"light"},{"start":3000,"end":4000,"stage":"deep"}]
        """
        let out = try XCTUnwrap(SleepWindowReclip.reclip(
            stagesJSON: json, sessionStart: 1000, oldEnd: 4000, newStart: 1000, newEnd: 1500))
        let segs = segments(out)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].stage, "wake")
        XCTAssertEqual(segs.map { $0.end }.max(), 1500, "no stage extends past the corrected wake")
    }

    // MARK: - degenerate input

    func testNilAndGarbageReturnNil() {
        XCTAssertNil(SleepWindowReclip.reclip(stagesJSON: nil, sessionStart: 0, oldEnd: 1, newStart: 0, newEnd: 1))
        XCTAssertNil(SleepWindowReclip.reclip(stagesJSON: "not json", sessionStart: 0, oldEnd: 1, newStart: 0, newEnd: 1))
    }

    // MARK: - bed (onset) edits: START-AWARE reclip (#0)

    func testBedOnlyEditSegmentsDropsStagesBeforeNewBed() throws {
        // A pure onset edit: the user moves bed time FORWARD from 1000 to 2000, wake unchanged at 4000.
        // The "light" segment wholly before the new bed (1000..2000) must drop; the straddling "deep"
        // (1800..3000) clips its start UP to 2000; no segment starts before the corrected bed time, and
        // total stage seconds == the corrected window (4000-2000).
        let json = """
        [{"start":1000,"end":2000,"stage":"light"},
         {"start":1800,"end":3000,"stage":"deep"},
         {"start":3000,"end":4000,"stage":"rem"}]
        """
        let out = try XCTUnwrap(SleepWindowReclip.reclip(
            stagesJSON: json, sessionStart: 1000, oldEnd: 4000, newStart: 2000, newEnd: 4000))
        let segs = segments(out)
        XCTAssertEqual(segs.count, 2, "the segment wholly before the new bed time is dropped")
        XCTAssertEqual(segs.map { $0.start }.min(), 2000, "no segment starts before the new bed time")
        XCTAssertEqual(segs[0].stage, "deep")
        XCTAssertEqual(segs[0].start, 2000, "the straddling segment's start clips up to the new bed time")
        let total = segs.reduce(0) { $0 + ($1.end - $1.start) }
        XCTAssertEqual(total, 4000 - 2000, "stage total equals the corrected [newStart, newEnd] window")
    }

    func testBedOnlyEditMinutesImportedNightShrinksByOnsetDelta() throws {
        // An imported (minute-dict) night, pure onset edit: session 0..8h, bed moved forward 40 min so the
        // window shrinks 40 min even though newEnd == oldEnd. The duration delta drives the trim
        // (awake 30 to 0, then 10 off light); the total trims by the 40 min onset delta to 360, not the
        // window (an imported minute-dict need not fill its whole window, so total != window here).
        let json = #"{"awake":30,"light":200,"deep":80,"rem":90}"#
        let oldEnd = 8 * 3600
        let newStart = 40 * 60
        let out = try XCTUnwrap(SleepWindowReclip.reclip(
            stagesJSON: json, sessionStart: 0, oldEnd: oldEnd, newStart: newStart, newEnd: oldEnd))
        let m = minutes(out)
        XCTAssertEqual(try XCTUnwrap(m["awake"]), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(m["light"]), 190, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(m["deep"]), 80, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(m["rem"]), 90, accuracy: 0.001)
        let total = m.values.reduce(0, +)
        XCTAssertEqual(total, 360, accuracy: 0.001,
                       "imported-night total trims by the onset delta (400 to 360), not the window")
    }
}
