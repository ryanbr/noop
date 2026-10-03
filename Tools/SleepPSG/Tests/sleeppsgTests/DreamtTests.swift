import XCTest
import WhoopProtocol
@testable import sleeppsg

/// The DREAMT reader, on synthetic files written to a temp directory. No PhysioNet download, no health
/// data, no network — these run in CI, where the dataset never exists.
final class DreamtTests: XCTestCase {

    private let header = "TIMESTAMP,BVP,ACC_X,ACC_Y,ACC_Z,TEMP,EDA,HR,IBI,Sleep_Stage,Obstructive_Apnea,Central_Apnea,Hypopnea,Multiple_Events\n"

    private func makeFixture(rows: String, info: String = "S901,40.0,F,24,1,2.5,96%,10,None,None\n") throws -> String {
        let root = NSTemporaryDirectory() + "sleeppsg-dreamt-" + UUID().uuidString
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/data_64Hz", withIntermediateDirectories: true)
        try (header + rows).write(toFile: root + "/data_64Hz/S901_whole_df.csv", atomically: true, encoding: .utf8)
        try ("SID,AGE,GENDER,BMI,OAHI,AHI,Mean_SaO2,Arousal Index,MEDICAL_HISTORY,Sleep_Disorders\n" + info)
            .write(toFile: root + "/participant_info.csv", atomically: true, encoding: .utf8)
        addTeardownBlock { try? fm.removeItem(atPath: root) }
        return root
    }

    /// One row per second from `from` to `to` (exclusive): the stage, a constant HR, no IBI.
    private func seconds(_ from: Int, _ to: Int, stage: String, hr: String = "60.0", acc: String = "0.0,0.0,64.0") -> String {
        (from..<to).map { "\($0).0,0.0,\(acc),35.0,0.1,\(hr),,\(stage),,,,\n" }.joined()
    }

    /// The forward fill hides a beat whose interval repeats the previous one; the arithmetic recovers it.
    /// Each case below is one of the four the header names.
    func testBeatsAreRecoveredFromTheForwardFill() {
        // consecutive: changes 0.8 s apart, the second interval 0.8 s.
        XCTAssertEqual(Dreamt.reconstructBeats([(10.0, 0.75), (10.8, 0.8)]).map { $0.t }, [10.0, 10.8])
        // one hidden repeat: 0.75 + 0.8 = 1.55 s apart → a beat at 10.75 carrying 0.75.
        let one = Dreamt.reconstructBeats([(10.0, 0.75), (11.55, 0.8)])
        XCTAssertEqual(one.map { $0.t }, [10.0, 10.75, 11.55])
        XCTAssertEqual(one.map { $0.v }, [0.75, 0.75, 0.8])
        // two hidden repeats: 2 × 0.75 + 0.8 = 2.3 s apart.
        XCTAssertEqual(Dreamt.reconstructBeats([(10.0, 0.75), (12.3, 0.8)]).map { $0.t }, [10.0, 10.75, 11.5, 12.3])
        // a gap: 5 s apart fits no run of repeats, so nothing is invented between them.
        XCTAssertEqual(Dreamt.reconstructBeats([(10.0, 0.75), (15.0, 0.8)]).map { $0.t }, [10.0, 15.0])
    }

    func testStageCodes() {
        XCTAssertNil(Dreamt.label(Dreamt.stageCode(Array("P".utf8))))
        XCTAssertEqual(Dreamt.label(Dreamt.stageCode(Array("W".utf8))), "wake")
        XCTAssertEqual(Dreamt.label(Dreamt.stageCode(Array("N1".utf8))), "light")
        XCTAssertEqual(Dreamt.label(Dreamt.stageCode(Array("N2".utf8))), "light")
        XCTAssertEqual(Dreamt.label(Dreamt.stageCode(Array("N3".utf8))), "deep")
        XCTAssertEqual(Dreamt.label(Dreamt.stageCode(Array("R".utf8))), "rem")
        XCTAssertNil(Dreamt.label(Dreamt.stageCode(Array("Missing".utf8))))
    }

    /// The scoring grid starts at the first scored epoch, not at t = 0: DREAMT's grid sits 24 s past a
    /// multiple of 30 on the files checked. The window runs from there to the last scored epoch, a trailing
    /// partial epoch is dropped, and a `Missing` epoch inside the night is nil, not wake.
    func testGridStartsAtTheFirstScoredEpoch() throws {
        let rows = seconds(0, 24, stage: "P")
            + seconds(24, 54, stage: "W")
            + seconds(54, 84, stage: "N3")
            + seconds(84, 114, stage: "Missing")
            + seconds(114, 144, stage: "R")
            + seconds(144, 150, stage: "R")          // 6 s of a fifth epoch: partial, dropped
        let root = try makeFixture(rows: rows)
        XCTAssertEqual(Dreamt.resolveRoot(root), root)
        XCTAssertEqual(Dreamt.subjectIDs(root: root), ["S901"])
        let info = Dreamt.participants(root: root)
        XCTAssertEqual(info["S901"]?.ahi, 2.5)

        let s = try XCTUnwrap(Dreamt.load(root: root, id: "S901", info: info["S901"]))
        XCTAssertEqual(s.truth, ["wake", "deep", nil, "rem"])
        XCTAssertEqual(s.start, Dreamt.timeBase)
        XCTAssertEqual(s.end, Dreamt.timeBase + 120)
        XCTAssertEqual(s.start % 30, 0)
        XCTAssertEqual(s.ahi, 2.5)
        // File second 24 is the first scored second: it lands on the window start.
        XCTAssertEqual(s.hr.first(where: { $0.ts == Dreamt.timeBase })?.bpm, 60)
        XCTAssertEqual(s.hr.first?.ts, Dreamt.timeBase - 24, "the P period is inside the recipe's read window")
    }

    /// Gravity is the per-second mean of the accelerometer rows in that second; HR is the value at the
    /// second; the IBI column becomes R-R rows stamped with the whole second of each beat.
    func testStreamsAreCollapsedPerSecondAndBeatsBecomeRR() throws {
        var rows = ""
        // Second 0 (scored W): two 64 Hz-style rows with different acceleration, an IBI appearing at 0.5 s.
        rows += "0.0,0.0,0.0,0.0,64.0,35.0,0.1,58.0,,W,,,,\n"
        rows += "0.5,0.0,64.0,0.0,0.0,35.0,0.1,58.0,0.75,W,,,,\n"
        // Second 1: the same IBI forward-filled, then a new one 2.05 s after the first change
        // (0.75 + 1.3): one hidden repeat of 0.75 at 1.25 s, and a 1.3 s beat at 2.55 s.
        rows += "1.0,0.0,0.0,64.0,0.0,35.0,0.1,59.0,0.75,W,,,,\n"
        rows += "2.55,0.0,0.0,64.0,0.0,35.0,0.1,59.0,1.3,W,,,,\n"
        rows += seconds(3, 30, stage: "W")
        let root = try makeFixture(rows: rows)
        let s = try XCTUnwrap(Dreamt.load(root: root, id: "S901", info: nil))

        XCTAssertEqual(s.grav.first?.ts, Dreamt.timeBase)
        XCTAssertEqual(s.grav.first?.x ?? .nan, 32.0, accuracy: 1e-12, "the mean of 0 and 64")
        XCTAssertEqual(s.grav.first?.y ?? .nan, 0.0, accuracy: 1e-12)
        XCTAssertEqual(s.grav.first?.z ?? .nan, 32.0, accuracy: 1e-12, "the mean of 64 and 0")
        XCTAssertEqual(s.hr.prefix(2).map { $0.bpm }, [58, 59])
        XCTAssertEqual(s.rr.map { $0.ts - Dreamt.timeBase }, [0, 1, 2])
        XCTAssertEqual(s.rr.map { $0.rrMs }, [750, 750, 1300])
        XCTAssertNil(s.ahi)
    }

    /// A file with no scored epoch at all has nothing to score against.
    func testAFileWithNoScoredEpochIsSkipped() throws {
        let root = try makeFixture(rows: seconds(0, 60, stage: "P"))
        XCTAssertNil(Dreamt.load(root: root, id: "S901", info: nil))
    }

    /// The participant table's medical-history column holds quoted commas.
    func testParticipantTableHonoursQuotes() throws {
        let root = try makeFixture(rows: seconds(0, 30, stage: "W"),
                                   info: "S901,65.9,M,27,19,19,91%,98,\"Asthma, GERD, Sleep Apnea\",OSA\n")
        let info = Dreamt.participants(root: root)
        XCTAssertEqual(info["S901"]?.ahi, 19)
        XCTAssertEqual(info["S901"]?.age, 65.9)
        XCTAssertEqual(info["S901"]?.sex, "M")
        let fields = Dreamt.splitCSV("S901,65.9,M,27,19,19,91%,98,\"Asthma, GERD, Sleep Apnea\",OSA")
        XCTAssertEqual(fields.count, 10, "the quoted commas do not split the field")
        XCTAssertEqual(fields[8], "Asthma, GERD, Sleep Apnea")
        XCTAssertEqual(fields[9], "OSA")
    }
}
