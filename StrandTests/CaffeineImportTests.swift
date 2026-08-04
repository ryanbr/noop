import XCTest
@testable import Strand

/// #949 — caffeine imported from Apple Health sits in the same log as hand-entered intakes, and these
/// pin the rules that keep the two from corrupting each other.
///
/// The shape of the problem is the same one the imported hydration row solves, but harder: hydration is
/// a single day total that can simply be replaced, whereas caffeine is a LIST of individual events. So
/// imported intakes carry the HealthKit sample UUID in `externalId`, and a sync replaces the imported
/// subset wholesale — that is what makes a re-import idempotent instead of logging a second copy of
/// every coffee, and what lets a drink deleted in the source app disappear here too.
///
/// Headless: a private UserDefaults suite per test, no HealthKit, no UI.
final class CaffeineImportTests: XCTestCase {

    @MainActor
    private func store(_ now: Date = Date()) -> CaffeineLogStore {
        let suite = UserDefaults(suiteName: "caffeine.import.test.\(UUID().uuidString)")!
        suite.removePersistentDomain(forName: suite.description)
        return CaffeineLogStore(defaults: suite, now: { now })
    }

    private func imported(_ at: Date, mg: Double, id: String) -> CaffeineIntake {
        CaffeineIntake(at: at, mg: mg, externalId: id)
    }

    /// A fixed stand-in for a HealthKit sample uuid.
    private let sampleUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    /// Builds an intake exactly the way `HealthKitBridge.collectCaffeine` does — the sample's own uuid
    /// as BOTH the identity and the external marker. Kept in one place so a drift between this and the
    /// bridge is a one-line fix rather than a silently passing test.
    private func fromSample(uuid: UUID, at: Date, mg: Double) -> CaffeineIntake {
        CaffeineIntake(id: uuid, at: at, mg: mg, externalId: uuid.uuidString)
    }

    // MARK: - the model

    @MainActor
    func testAHandLoggedIntakeIsNotImported() {
        XCTAssertFalse(CaffeineIntake(at: Date(), mg: 80).isImported)
    }

    @MainActor
    func testAnIntakeWithAnExternalIdIsImported() {
        XCTAssertTrue(imported(Date(), mg: 80, id: "abc").isImported)
    }

    /// Stored JSON written before this change has no `externalId` field at all. It must still decode, and
    /// every existing intake must read back as HAND-LOGGED — not as an import that the next sync would
    /// then feel free to delete.
    @MainActor
    func testOldJsonWithoutExternalIdDecodesAsHandLogged() throws {
        let json = #"[{"id":"\#(UUID().uuidString)","at":760000000,"mg":95}]"#
        let decoded = try JSONDecoder().decode([CaffeineIntake].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].externalId)
        XCTAssertFalse(decoded[0].isImported)
    }

    // MARK: - replaceImported

    @MainActor
    func testImportedIntakesAreAdded() {
        let now = Date()
        let s = store(now)
        s.replaceImported([imported(now.addingTimeInterval(-3600), mg: 95, id: "a")])
        XCTAssertEqual(s.intakes.count, 1)
        XCTAssertEqual(s.intakes[0].mg, 95)
    }

    /// The core idempotency claim: syncing the same Health window twice leaves ONE intake, not two.
    ///
    /// Built from a fresh `CaffeineIntake` each time rather than reusing one value, because that is what
    /// the bridge actually does — it rebuilds every intake from the HealthKit samples on each sync. An
    /// earlier version of this test reused a single value and would have passed while the real path was
    /// broken.
    @MainActor
    func testReimportingTheSameSampleDoesNotDuplicateIt() {
        let now = Date()
        let s = store(now)
        let at = now.addingTimeInterval(-3600)
        s.replaceImported([fromSample(uuid: sampleUUID, at: at, mg: 95)])
        s.replaceImported([fromSample(uuid: sampleUUID, at: at, mg: 95)])
        XCTAssertEqual(s.intakes.count, 1)
    }

    /// The identity of an imported intake must come from the SAMPLE, not be freshly minted per sync.
    ///
    /// This is the bug the test above could not see: `CaffeineIntake.id` defaults to `UUID()`, so
    /// building one per sync gave the same coffee a new identity every time — `replaceImported`'s
    /// "nothing changed" guard never matched (a pointless rewrite and republish on every sync) and
    /// `ForEach` rebuilt the whole logged list. Two intakes built from one sample must be EQUAL.
    @MainActor
    func testTwoIntakesBuiltFromTheSameSampleAreEqual() {
        let at = Date().addingTimeInterval(-3600)
        XCTAssertEqual(fromSample(uuid: sampleUUID, at: at, mg: 95),
                       fromSample(uuid: sampleUUID, at: at, mg: 95))
    }

    /// ...and the id is the sample's, so SwiftUI sees a stable row across syncs.
    @MainActor
    func testImportedIntakeIdIsTheSampleId() {
        let intake = fromSample(uuid: sampleUUID, at: Date(), mg: 95)
        XCTAssertEqual(intake.id, sampleUUID)
        XCTAssertEqual(intake.externalId, sampleUUID.uuidString)
    }

    /// Re-importing an unchanged window must leave the stored array untouched, identities included.
    @MainActor
    func testReimportingAnUnchangedWindowKeepsTheSameIds() {
        let now = Date()
        let s = store(now)
        let at = now.addingTimeInterval(-3600)
        s.replaceImported([fromSample(uuid: sampleUUID, at: at, mg: 95)])
        let before = s.intakes.map(\.id)
        s.replaceImported([fromSample(uuid: sampleUUID, at: at, mg: 95)])
        XCTAssertEqual(before, s.intakes.map(\.id))
    }

    /// Hand-logged intakes are never touched by a sync.
    @MainActor
    func testImportingLeavesHandLoggedIntakesAlone() {
        let now = Date()
        let s = store(now)
        s.log(at: now.addingTimeInterval(-1800), mg: 60)
        s.replaceImported([imported(now.addingTimeInterval(-3600), mg: 95, id: "a")])
        XCTAssertEqual(s.intakes.count, 2)
        XCTAssertEqual(s.intakes.filter { !$0.isImported }.count, 1)
        XCTAssertEqual(s.intakes.filter { $0.isImported }.count, 1)
    }

    /// Deleting the coffee in the app that logged it removes it here on the next sync, rather than
    /// leaving it stranded in NOOP forever.
    @MainActor
    func testAnIntakeThatVanishesFromHealthIsDropped() {
        let now = Date()
        let s = store(now)
        s.replaceImported([imported(now.addingTimeInterval(-3600), mg: 95, id: "a"),
                           imported(now.addingTimeInterval(-7200), mg: 80, id: "b")])
        XCTAssertEqual(s.intakes.count, 2)
        s.replaceImported([imported(now.addingTimeInterval(-3600), mg: 95, id: "a")])
        XCTAssertEqual(s.intakes.count, 1)
        XCTAssertEqual(s.intakes[0].externalId, "a")
    }

    /// An empty Health window clears the imported set but must not touch what the user typed in.
    @MainActor
    func testAnEmptyImportClearsOnlyTheImportedOnes() {
        let now = Date()
        let s = store(now)
        s.log(at: now.addingTimeInterval(-1800), mg: 60)
        s.replaceImported([imported(now.addingTimeInterval(-3600), mg: 95, id: "a")])
        s.replaceImported([])
        XCTAssertEqual(s.intakes.count, 1)
        XCTAssertFalse(s.intakes[0].isImported)
    }

    @MainActor
    func testIntakesStayNewestFirstAfterAnImport() {
        let now = Date()
        let s = store(now)
        s.log(at: now.addingTimeInterval(-7200), mg: 60)
        s.replaceImported([imported(now.addingTimeInterval(-1800), mg: 95, id: "a")])
        XCTAssertEqual(s.intakes.map(\.at), s.intakes.map(\.at).sorted(by: >))
    }

    // MARK: - imported intakes are not the user's to edit

    /// Honouring this would be a lie: the next sync re-reads the same window and brings it back.
    @MainActor
    func testRemoveRefusesAnImportedIntake() {
        let now = Date()
        let s = store(now)
        s.replaceImported([imported(now.addingTimeInterval(-3600), mg: 95, id: "a")])
        let id = s.intakes[0].id
        s.remove(id)
        XCTAssertEqual(s.intakes.count, 1, "an imported intake must survive a remove")
    }

    @MainActor
    func testRemoveStillWorksOnAHandLoggedIntake() {
        let now = Date()
        let s = store(now)
        s.log(at: now.addingTimeInterval(-1800), mg: 60)
        s.remove(s.intakes[0].id)
        XCTAssertTrue(s.intakes.isEmpty)
    }

    /// "Clear" clears what the user owns. Wiping the imported ones would only last until the next sync.
    @MainActor
    func testClearAllKeepsImportedAndClearsHandLogged() {
        let now = Date()
        let s = store(now)
        s.log(at: now.addingTimeInterval(-1800), mg: 60)
        s.replaceImported([imported(now.addingTimeInterval(-3600), mg: 95, id: "a")])
        s.clearAll()
        XCTAssertEqual(s.intakes.count, 1)
        XCTAssertTrue(s.intakes[0].isImported)
    }

    // MARK: - the estimate consumes imported intakes like any other

    @MainActor
    func testImportedIntakesFeedTheActiveEstimate() {
        let now = Date()
        let s = store(now)
        s.replaceImported([imported(now.addingTimeInterval(-3600), mg: 100, id: "a")])
        let est = s.estimate()
        XCTAssertTrue(est.hasActive)
        XCTAssertNotNil(est.totalRemainingMg, "an imported sample always carries a dose")
    }

    /// Persistence round-trip: a fresh store over the same defaults sees the imported intake, and still
    /// knows it was imported.
    @MainActor
    func testImportedIntakesSurviveAReload() throws {
        let now = Date()
        let suite = UserDefaults(suiteName: "caffeine.import.test.\(UUID().uuidString)")!
        let a = CaffeineLogStore(defaults: suite, now: { now })
        a.replaceImported([imported(now.addingTimeInterval(-3600), mg: 95, id: "sample-1")])
        let b = CaffeineLogStore(defaults: suite, now: { now })
        XCTAssertEqual(b.intakes.count, 1)
        XCTAssertEqual(b.intakes[0].externalId, "sample-1")
        XCTAssertTrue(b.intakes[0].isImported)
    }
}
