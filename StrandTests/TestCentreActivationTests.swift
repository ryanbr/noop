import XCTest
import StrandAnalytics
@testable import Strand

@MainActor
final class TestCentreActivationTests: XCTestCase {

    private var savedDefaults: [String: Any] = [:]
    private var touchedKeys: [String] {
        TestDomain.allCases.flatMap { domain in
            ["testcentre.active.\(domain.id)", "testcentre.startedAt.\(domain.id)",
             "testcentre.answers.\(domain.id)"]
        } + [PuffinExperiment.deepDataKey]
    }

    override func setUp() async throws {
        try await super.setUp()
        savedDefaults = [:]
        for key in touchedKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() async throws {
        for key in touchedKeys {
            if let value = savedDefaults[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        savedDefaults = [:]
        try await super.tearDown()
    }

    func testActivateThenActiveThenDeactivate() {
        XCTAssertFalse(TestCentre.active(.sleep))
        TestCentre.activate(.sleep)
        XCTAssertTrue(TestCentre.active(.sleep))
        XCTAssertFalse(TestCentre.active(.battery))
        TestCentre.deactivate(.sleep)
        XCTAssertFalse(TestCentre.active(.sleep))
    }

    func testMasterImpliesAll() {
        TestCentre.activate(.master)
        XCTAssertTrue(TestCentre.active(.sleep))
        XCTAssertTrue(TestCentre.active(.battery))
        XCTAssertTrue(TestCentre.active(.hrv))
    }

    func testUniversalRidesAnyActiveMode() {
        XCTAssertFalse(TestCentre.active(.universal))   // nothing on
        TestCentre.activate(.battery)
        XCTAssertTrue(TestCentre.active(.universal))    // universal rides whatever is on
    }

    func testStartedAtStampedOnActivate() {
        XCTAssertNil(TestCentre.startedAt(.sleep))
        let before = Date()
        TestCentre.activate(.sleep)
        let s = TestCentre.startedAt(.sleep)
        XCTAssertNotNil(s)
        XCTAssertGreaterThanOrEqual(s!.timeIntervalSince1970, before.timeIntervalSince1970 - 1)
    }

    func testAnswersReadsPersistedQuestionnaire() throws {
        let key = "testcentre.answers.battery"
        XCTAssertEqual(TestCentre.answers(.battery), [:])
        let answers = ["whoopAppInstalled": "yes", "batterySaverApps": "none"]
        UserDefaults.standard.set(try JSONEncoder().encode(answers), forKey: key)
        XCTAssertEqual(TestCentre.answers(.battery), answers)
        XCTAssertEqual(TestCentre.answers(.sleep), [:])
    }

    func testAnswersRejectsMalformedPersistedQuestionnaire() {
        let key = "testcentre.answers.battery"
        for raw in ["not JSON", "[]", "{\"answer\":null}"] {
            UserDefaults.standard.set(Data(raw.utf8), forKey: key)
            XCTAssertEqual(TestCentre.answers(.battery), [:], raw)
        }
    }

    func testActivationPreservesLegacyKeys() {
        UserDefaults.standard.set(true, forKey: PuffinExperiment.deepDataKey)
        TestCentre.activate(.battery)
        TestCentre.deactivate(.battery)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: PuffinExperiment.deepDataKey))
    }
}
