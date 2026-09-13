import XCTest
import GRDB
@testable import WhoopStore

final class LiftLogStoreTests: XCTestCase {

    // MARK: - v46 migration (additive: five new tables + indexes, nothing dropped)

    func testV46CreatesLiftLogTables() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["liftExercise", "liftProgram", "liftProgramItem", "liftSession", "liftSet"] {
            XCTAssertTrue(tables.contains(t), "missing table \(t)")
            let pk = try await store.primaryKeyColumns(t)
            XCTAssertEqual(pk, ["id"], "\(t) primary key should be id")
        }
    }

    func testV46ColumnsArePresent() async throws {
        let store = try await WhoopStore.inMemory()

        let exercise = try await store.columnNamesForTest(table: "liftExercise")
        for c in ["id", "deviceId", "name", "primaryMuscle", "secondaryMuscles",
                  "createdAt", "lastUsedTs"] {
            XCTAssertTrue(exercise.contains(c), "liftExercise missing column \(c)")
        }

        let program = try await store.columnNamesForTest(table: "liftProgram")
        for c in ["id", "deviceId", "name", "note", "createdAt", "updatedAt", "archived"] {
            XCTAssertTrue(program.contains(c), "liftProgram missing column \(c)")
        }

        let item = try await store.columnNamesForTest(table: "liftProgramItem")
        for c in ["id", "deviceId", "programId", "ord", "exercise", "targetSets",
                  "targetRepsLow", "targetRepsHigh", "targetRpe", "targetWeightKg",
                  "restSec", "note"] {
            XCTAssertTrue(item.contains(c), "liftProgramItem missing column \(c)")
        }

        let session = try await store.columnNamesForTest(table: "liftSession")
        for c in ["id", "deviceId", "startTs", "endTs", "sport", "programId", "programName",
                  "sessionRpe", "note"] {
            XCTAssertTrue(session.contains(c), "liftSession missing column \(c)")
        }

        let set = try await store.columnNamesForTest(table: "liftSet")
        for c in ["id", "deviceId", "sessionId", "ord", "exercise", "primaryMuscle",
                  "secondaryMuscles", "setIndex", "weightKg", "reps", "rpe", "isWarmup",
                  "startTs", "endTs", "restSec", "note"] {
            XCTAssertTrue(set.contains(c), "liftSet missing column \(c)")
        }
    }

    func testV46CreatesIndexes() async throws {
        let store = try await WhoopStore.inMemory()
        let exercise = try await store.indexNamesForTest(table: "liftExercise")
        XCTAssertTrue(exercise.contains("idx_liftExercise_natural"))

        let program = try await store.indexNamesForTest(table: "liftProgram")
        XCTAssertTrue(program.contains("idx_liftProgram_device_updatedAt"))

        let item = try await store.indexNamesForTest(table: "liftProgramItem")
        XCTAssertTrue(item.contains("idx_liftProgramItem_device"))
        XCTAssertTrue(item.contains("idx_liftProgramItem_program_ord"))

        let session = try await store.indexNamesForTest(table: "liftSession")
        XCTAssertTrue(session.contains("idx_liftSession_natural"))

        let set = try await store.indexNamesForTest(table: "liftSet")
        XCTAssertTrue(set.contains("idx_liftSet_device_exercise"))
        XCTAssertTrue(set.contains("idx_liftSet_session_ord"))
    }

    /// Additive: v46 must not drop any table that existed before it.
    func testV46IsAdditive() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["device", "hrSample", "rrInterval", "event", "battery", "rawBatch",
                  "sleepSession", "dailyMetric", "journal", "workout", "appleDaily",
                  "metricSeries", "pairedDevice", "dayOwnership", "labMarker", "appleStepHour"] {
            XCTAssertTrue(tables.contains(t), "v46 must not drop \(t)")
        }
    }

    // MARK: - Targets and the session rating, stored as numbers

    func testTargetWeightRoundTripsOnAProgramLine() async throws {
        let store = try await WhoopStore.inMemory()
        let programId = UUID().uuidString
        let item = LiftProgramItemRow(
            id: UUID().uuidString, deviceId: "dev", programId: programId, ord: 0,
            exercise: "Back squat", targetSets: 5, targetRepsLow: 5, targetRepsHigh: nil,
            targetRpe: nil, targetWeightKg: 102.5, restSec: 180, note: nil)
        _ = try await store.replaceLiftProgramItems(programId: programId, items: [item])

        let back = try await store.liftProgramItems(programId: programId)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].targetWeightKg, 102.5)
        XCTAssertEqual(back[0].targetRepsLow, 5)
    }

    func testSessionRpeRoundTripsAsANumber() async throws {
        let store = try await WhoopStore.inMemory()
        let row = LiftSessionRow(
            id: UUID().uuidString, deviceId: "dev", startTs: 1_700_000_000, endTs: 1_700_003_600,
            sport: "Strength Training", programId: nil, programName: "Upper A",
            sessionRpe: 7.5, note: nil)
        _ = try await store.upsertLiftSessions([row])

        let back = try await store.liftSessions(deviceId: "dev", fromTs: 1_700_000_000,
                                                toTs: 1_700_000_000).first
        XCTAssertEqual(back?.sessionRpe, 7.5)
    }

    func testSessionRpeIsOptionalSoASkippedRatingIsNotAZero() async throws {
        let store = try await WhoopStore.inMemory()
        let row = LiftSessionRow(
            id: UUID().uuidString, deviceId: "dev", startTs: 1_700_000_500, endTs: nil,
            sport: "Strength Training", programId: nil, programName: nil,
            sessionRpe: nil, note: nil)
        _ = try await store.upsertLiftSessions([row])

        let back = try await store.liftSessions(deviceId: "dev", fromTs: 1_700_000_500,
                                                toTs: 1_700_000_500).first
        XCTAssertNil(back?.sessionRpe,
                     "a skipped rating must stay nil — a 0 would read as 'effortless' and corrupt the load")
    }

    // MARK: - The vocabulary cap

    func testAnExistingExerciseAlwaysUpdatesEvenAtTheCap() async throws {
        let store = try await WhoopStore.inMemory()
        let row = LiftExerciseRow(id: UUID().uuidString, deviceId: "dev", name: "Bench press",
                                  primaryMuscle: .chest, secondaryMuscles: [],
                                  createdAt: 1_700_000_000, lastUsedTs: nil)
        _ = try await store.upsertLiftExercises([row])
        // Re-saving a KNOWN name is an update, not a new entry — it must never be refused, or a user
        // at the cap could no longer fix the classification of something they train weekly.
        var reclassified = row
        reclassified.primaryMuscle = .triceps
        _ = try await store.upsertLiftExercises([reclassified])

        let back = try await store.liftExercises(deviceId: "dev")
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].primaryMuscle, .triceps)
    }

    func testANewExerciseIsRefusedOnceTheVocabularyIsFull() async throws {
        let store = try await WhoopStore.inMemory()
        let limit = WhoopStore.maxRememberedExercises
        let rows = (0..<limit).map {
            LiftExerciseRow(id: UUID().uuidString, deviceId: "dev", name: "Exercise \($0)",
                            primaryMuscle: nil, secondaryMuscles: [],
                            createdAt: 1_700_000_000, lastUsedTs: nil)
        }
        _ = try await store.upsertLiftExercises(rows)

        let overflow = LiftExerciseRow(id: UUID().uuidString, deviceId: "dev", name: "One too many",
                                       primaryMuscle: nil, secondaryMuscles: [],
                                       createdAt: 1_700_000_000, lastUsedTs: nil)
        do {
            _ = try await store.upsertLiftExercises([overflow])
            XCTFail("a new name past the cap should be refused, not silently dropped")
        } catch let error as WhoopStore.LiftExerciseVocabularyFull {
            XCTAssertEqual(error.limit, limit, "the message must be able to name the limit")
        }
        // And nothing already remembered was evicted to make room.
        let back = try await store.liftExercises(deviceId: "dev")
        XCTAssertEqual(back.count, limit)
    }

    func testTheCapIsPerDeviceNotGlobal() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiftExercises([
            LiftExerciseRow(id: UUID().uuidString, deviceId: "dev-a", name: "Row",
                            primaryMuscle: nil, secondaryMuscles: [],
                            createdAt: 1, lastUsedTs: nil)])
        _ = try await store.upsertLiftExercises([
            LiftExerciseRow(id: UUID().uuidString, deviceId: "dev-b", name: "Row",
                            primaryMuscle: nil, secondaryMuscles: [],
                            createdAt: 1, lastUsedTs: nil)])
        let a = try await store.liftExercises(deviceId: "dev-a")
        let b = try await store.liftExercises(deviceId: "dev-b")
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(b.count, 1)
    }

    // MARK: - The user's own exercise vocabulary

    /// Anything the user types becomes an exercise they can reuse, with the muscle group they gave
    /// it. NOOP ships no catalogue, so this table IS the catalogue.
    func testCustomExerciseIsRememberedForReuse() async throws {
        let store = try await WhoopStore.inMemory()
        let invented = LiftExerciseRow(id: "e1", deviceId: dev, name: "Sissy Squat on the Smith",
                                       primaryMuscle: .quads, secondaryMuscles: [.glutes],
                                       createdAt: 100, lastUsedTs: 100)
        let written = try await store.upsertLiftExercises([invented])
        XCTAssertEqual(written, 1)

        let vocabulary = try await store.liftExercises(deviceId: dev)
        XCTAssertEqual(vocabulary.map(\.name), ["Sissy Squat on the Smith"],
                       "the name is kept exactly as typed, not normalised")
        XCTAssertEqual(vocabulary.first?.primaryMuscle, .quads)
        XCTAssertEqual(vocabulary.first?.secondaryMuscles, [.glutes])
    }

    /// Using an exercise again must update its recency, never duplicate it — and must never wipe the
    /// muscle group just because the caller did not resupply one.
    func testReusingAnExerciseUpdatesRecencyAndKeepsItsMuscleGroup() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiftExercises([
            LiftExerciseRow(id: "e1", deviceId: dev, name: "Leg Press",
                            primaryMuscle: .quads, secondaryMuscles: [.glutes],
                            createdAt: 100, lastUsedTs: 100),
        ])
        // Used again later, by a caller that only knows the name.
        _ = try await store.upsertLiftExercises([
            LiftExerciseRow(id: "fresh-id", deviceId: dev, name: "Leg Press",
                            primaryMuscle: nil, createdAt: 900, lastUsedTs: 900),
        ])

        let vocabulary = try await store.liftExercises(deviceId: dev)
        XCTAssertEqual(vocabulary.count, 1, "same (deviceId, name) must not duplicate")
        XCTAssertEqual(vocabulary.first?.primaryMuscle, .quads, "an absent group must not erase the set one")
        XCTAssertEqual(vocabulary.first?.lastUsedTs, 900)
        XCTAssertEqual(vocabulary.first?.id, "e1", "the original id survives")
    }

    /// Recently used first, then never-used, alphabetical within each — the picker's order.
    func testExercisePickerOrdersByRecencyThenName() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiftExercises([
            LiftExerciseRow(id: "e1", deviceId: dev, name: "Zercher Squat",
                            primaryMuscle: nil, createdAt: 1, lastUsedTs: 500),
            LiftExerciseRow(id: "e2", deviceId: dev, name: "Pec Deck",
                            primaryMuscle: nil, createdAt: 1, lastUsedTs: nil),
            LiftExerciseRow(id: "e3", deviceId: dev, name: "Dead Bug",
                            primaryMuscle: nil, createdAt: 1, lastUsedTs: nil),
        ])
        let vocabulary = try await store.liftExercises(deviceId: dev)
        XCTAssertEqual(vocabulary.map(\.name), ["Zercher Squat", "Dead Bug", "Pec Deck"])
    }

    /// Forgetting an exercise from the vocabulary must not rewrite the sets already logged under it.
    func testForgettingAnExerciseKeepsLoggedSets() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiftExercises([
            LiftExerciseRow(id: "e1", deviceId: dev, name: "Leg Press",
                            primaryMuscle: .quads, secondaryMuscles: [.glutes],
                            createdAt: 100, lastUsedTs: 100),
        ])
        _ = try await store.upsertLiftSessions([mkSession(id: "s1", startTs: 1_000)])
        _ = try await store.upsertLiftSets([mkSet(id: "x1", sessionId: "s1", ord: 0, setIndex: 1)])

        let forgotten = try await store.deleteLiftExercise(id: "e1")
        XCTAssertTrue(forgotten)
        let stillThere = try await store.liftSets(sessionId: "s1")
        XCTAssertEqual(stillThere.map(\.exercise), ["Leg Press"])
        XCTAssertEqual(stillThere.first?.primaryMuscle, .quads,
                       "the set carries its own copy, so history keeps its meaning")
    }

    // MARK: - Programs

    func testProgramRoundTripAndArchiveFilter() async throws {
        let store = try await WhoopStore.inMemory()
        let live = mkProgram(id: "p1", name: "Upper A", updatedAt: 200)
        let old = mkProgram(id: "p2", name: "Old split", updatedAt: 100, archived: true)
        let written = try await store.upsertLiftPrograms([live, old])
        XCTAssertEqual(written, 2)

        let visible = try await store.liftPrograms(deviceId: dev)
        XCTAssertEqual(visible.map(\.id), ["p1"], "archived programs stay out of the picker")

        let all = try await store.liftPrograms(deviceId: dev, includeArchived: true)
        XCTAssertEqual(all.map(\.id), ["p1", "p2"], "most recently touched first")
        XCTAssertEqual(all.first, live)
    }

    func testProgramUpsertIsIdempotentById() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiftPrograms([mkProgram(id: "p1", name: "Upper A", updatedAt: 100)])
        _ = try await store.upsertLiftPrograms([mkProgram(id: "p1", name: "Upper A2", updatedAt: 300)])

        let all = try await store.liftPrograms(deviceId: dev)
        XCTAssertEqual(all.count, 1, "same id updates in place")
        XCTAssertEqual(all.first?.name, "Upper A2")
        XCTAssertEqual(all.first?.updatedAt, 300)
    }

    func testReplaceProgramItemsSwapsTheWholeList() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiftPrograms([mkProgram(id: "p1", name: "Upper A", updatedAt: 100)])
        _ = try await store.replaceLiftProgramItems(programId: "p1", items: [
            mkItem(id: "i1", ord: 0, exercise: "Incline Machine Press"),
            mkItem(id: "i2", ord: 1, exercise: "Chest-Supported Row"),
        ])
        let firstPass = try await store.liftProgramItems(programId: "p1")
        XCTAssertEqual(firstPass.map(\.exercise), ["Incline Machine Press", "Chest-Supported Row"])

        // A reorder that also drops a line: replace wholesale, no stale rows left behind.
        _ = try await store.replaceLiftProgramItems(programId: "p1", items: [
            mkItem(id: "i2", ord: 0, exercise: "Chest-Supported Row"),
        ])
        let secondPass = try await store.liftProgramItems(programId: "p1")
        XCTAssertEqual(secondPass.map(\.id), ["i2"])
    }

    func testDeletingAProgramKeepsItsSessions() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiftPrograms([mkProgram(id: "p1", name: "Upper A", updatedAt: 100)])
        _ = try await store.replaceLiftProgramItems(programId: "p1", items: [mkItem(id: "i1", ord: 0)])
        _ = try await store.upsertLiftSessions([mkSession(id: "s1", startTs: 1_000, programId: "p1")])

        let deleted = try await store.deleteLiftProgram(id: "p1")
        XCTAssertTrue(deleted)
        let orphanedItems = try await store.liftProgramItems(programId: "p1")
        XCTAssertTrue(orphanedItems.isEmpty)

        // History survives: the session kept its own snapshot of the name it ran under.
        let sessions = try await store.liftSessions(deviceId: dev, fromTs: 0, toTs: 9_999)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.programName, "Upper A")
    }

    // MARK: - Sessions

    /// The session is keyed to its workout row by (deviceId, startTs, sport), so re-saving the same
    /// session updates it in place even when the caller mints a fresh id.
    func testSessionUpsertIsIdempotentByNaturalKey() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiftSessions([mkSession(id: "s1", startTs: 1_000, endTs: nil)])
        _ = try await store.upsertLiftSessions([mkSession(id: "different-id", startTs: 1_000, endTs: 4_600)])

        let sessions = try await store.liftSessions(deviceId: dev, fromTs: 0, toTs: 9_999)
        XCTAssertEqual(sessions.count, 1, "same (deviceId, startTs, sport) must not duplicate")
        XCTAssertEqual(sessions.first?.endTs, 4_600, "the finish time landed on the existing row")
        XCTAssertEqual(sessions.first?.id, "s1", "the original id is kept")
    }

    func testDeletingASessionDeletesItsSets() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiftSessions([mkSession(id: "s1", startTs: 1_000)])
        _ = try await store.upsertLiftSets([
            mkSet(id: "x1", sessionId: "s1", ord: 0, setIndex: 1),
            mkSet(id: "x2", sessionId: "s1", ord: 1, setIndex: 2),
        ])
        let removed = try await store.deleteLiftSession(id: "s1")
        XCTAssertTrue(removed)
        let orphanedSets = try await store.liftSets(sessionId: "s1")
        XCTAssertTrue(orphanedSets.isEmpty)
    }

    // MARK: - Sets

    func testSetsReadBackInPerformedOrder() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiftSessions([mkSession(id: "s1", startTs: 1_000)])
        // Inserted out of order on purpose: the read must sort by ord, not by insertion.
        _ = try await store.upsertLiftSets([
            mkSet(id: "x2", sessionId: "s1", ord: 1, setIndex: 2, weightKg: 62.5, reps: 9),
            mkSet(id: "x1", sessionId: "s1", ord: 0, setIndex: 1, weightKg: 60, reps: 10),
        ])
        let sets = try await store.liftSets(sessionId: "s1")
        XCTAssertEqual(sets.map(\.id), ["x1", "x2"])
        XCTAssertEqual(sets.map(\.setIndex), [1, 2])
    }

    func testVolumeIsWeightTimesRepsAndExcludesWarmups() {
        let working = mkSet(id: "w", sessionId: "s1", ord: 0, setIndex: 1, weightKg: 60, reps: 10)
        XCTAssertEqual(working.volumeKg, 600)

        var warmup = working
        warmup.isWarmup = true
        XCTAssertNil(warmup.volumeKg, "warmup sets are recorded but never counted as volume")

        var bodyweight = working
        bodyweight.weightKg = nil
        XCTAssertNil(bodyweight.volumeKg, "no weight means no volume figure, not a zero")
    }

    // MARK: - The read the feature exists for

    func testLastLiftSetsReturnsTheMostRecentSessionForThatExercise() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiftSessions([
            mkSession(id: "old", startTs: 1_000),
            mkSession(id: "recent", startTs: 5_000),
            mkSession(id: "newest", startTs: 9_000),
        ])
        _ = try await store.upsertLiftSets([
            mkSet(id: "a", sessionId: "old", ord: 0, setIndex: 1, exercise: "Leg Press", weightKg: 100, reps: 10),
            mkSet(id: "b", sessionId: "recent", ord: 0, setIndex: 1, exercise: "Leg Press", weightKg: 110, reps: 10),
            mkSet(id: "c", sessionId: "recent", ord: 1, setIndex: 2, exercise: "Leg Press", weightKg: 110, reps: 9),
            // A different exercise in a later session must not shadow the Leg Press history.
            mkSet(id: "d", sessionId: "newest", ord: 0, setIndex: 1, exercise: "Lat Pulldown", weightKg: 55, reps: 10),
        ])

        let last = try await store.lastLiftSets(deviceId: dev, exercise: "Leg Press")
        XCTAssertEqual(last.map(\.id), ["b", "c"], "the latest session that actually contained it")
        XCTAssertEqual(last.first?.weightKg, 110)

        // `before` excludes the session in progress, so a running session never pre-fills from itself.
        let previous = try await store.lastLiftSets(deviceId: dev, exercise: "Leg Press", before: 5_000)
        XCTAssertEqual(previous.map(\.id), ["a"])

        let never = try await store.lastLiftSets(deviceId: dev, exercise: "Nordic Curl")
        XCTAssertTrue(never.isEmpty, "an exercise never logged has no history, and that is not an error")
    }

    // MARK: - Muscle classification

    /// The token set is a stored-data contract: renaming a case would orphan every row written
    /// under the old spelling. This test is the tripwire — if it fails, someone renamed a case and
    /// needs a migration, not a fix to the test.
    func testMuscleTokensAreStable() {
        XCTAssertEqual(LiftMuscle.chest.rawValue, "chest")
        XCTAssertEqual(LiftMuscle.frontDelts.rawValue, "frontDelts")
        XCTAssertEqual(LiftMuscle.upperBack.rawValue, "upperBack")
        XCTAssertEqual(LiftMuscle.lowerBack.rawValue, "lowerBack")
        XCTAssertEqual(LiftMuscle.allCases.count, 20)
        XCTAssertEqual(Set(LiftMuscle.allCases.map(\.rawValue)).count, LiftMuscle.allCases.count,
                       "tokens must be unique")
    }

    func testEveryMuscleHasARegionAndEveryRegionHasMuscles() {
        for region in LiftMuscle.Region.allCases {
            XCTAssertFalse(LiftMuscle.inRegion(region).isEmpty, "\(region) has no muscles")
        }
        let regioned = LiftMuscle.Region.allCases.flatMap(LiftMuscle.inRegion)
        XCTAssertEqual(Set(regioned), Set(LiftMuscle.allCases),
                       "every muscle must appear in exactly one region")
        XCTAssertEqual(regioned.count, LiftMuscle.allCases.count)
    }

    /// A set must never be counted twice for one muscle, so the primary is stripped out of the
    /// secondary list, as are duplicates. Order the user chose is otherwise preserved.
    func testSecondaryListDropsThePrimaryAndDuplicates() {
        let encoded = LiftMuscle.encodeList([.glutes, .quads, .glutes, .hamstrings], excluding: .quads)
        XCTAssertEqual(encoded, "glutes,hamstrings")
        XCTAssertNil(LiftMuscle.encodeList([], excluding: nil), "empty stores as NULL, not \"\"")
        XCTAssertNil(LiftMuscle.encodeList([.quads], excluding: .quads))
    }

    /// A database written by a newer build must stay readable by an older one, so an unrecognised
    /// token is skipped rather than failing the whole read.
    func testUnknownMuscleTokensAreSkippedNotFatal() {
        XCTAssertEqual(LiftMuscle.decodeList("glutes,serratusMagnificus,calves"), [.glutes, .calves])
        XCTAssertEqual(LiftMuscle.decodeList(nil), [])
        XCTAssertEqual(LiftMuscle.decodeList(""), [])
    }

    func testSetClassificationRoundTrips() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiftSessions([mkSession(id: "s1", startTs: 1_000)])
        _ = try await store.upsertLiftSets([
            mkSet(id: "x1", sessionId: "s1", ord: 0, setIndex: 1,
                  primary: .chest, secondary: [.frontDelts, .triceps]),
        ])
        let read = try await store.liftSets(sessionId: "s1")
        XCTAssertEqual(read.first?.primaryMuscle, .chest)
        XCTAssertEqual(read.first?.secondaryMuscles, [.frontDelts, .triceps])
    }

    // MARK: - Per-muscle set counts (the fractional method)

    /// Direct sets count 1, indirect count 0.5 — the operationalisation the 2025 dose-response
    /// meta-regression found best supported, and the one its reference doses were derived under.
    /// The components are returned too, so the arithmetic can be checked rather than trusted.
    func testSetCountsUseTheFractionalMethod() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiftSessions([mkSession(id: "s1", startTs: 1_000)])
        _ = try await store.upsertLiftSets([
            mkSet(id: "a", sessionId: "s1", ord: 0, setIndex: 1, primary: .quads, secondary: [.glutes]),
            mkSet(id: "b", sessionId: "s1", ord: 1, setIndex: 2, primary: .quads, secondary: [.glutes]),
            mkSet(id: "c", sessionId: "s1", ord: 2, setIndex: 1, primary: .glutes, secondary: []),
        ])
        let counts = try await store.liftSetCounts(deviceId: dev, fromTs: 0, toTs: 9_999)

        XCTAssertEqual(counts.direct[.quads], 2)
        XCTAssertEqual(counts.fractional[.quads] ?? 0, 2.0, accuracy: 0.0001)

        // Glutes: one direct set (1.0) plus two indirect (0.5 each) = 2.0
        XCTAssertEqual(counts.direct[.glutes], 1)
        XCTAssertEqual(counts.indirect[.glutes], 2)
        XCTAssertEqual(counts.fractional[.glutes] ?? 0, 2.0, accuracy: 0.0001)
    }

    func testTheFractionalCreditsMatchThePublishedMethod() {
        XCTAssertEqual(LiftMuscle.directSetCredit, 1.0)
        XCTAssertEqual(LiftMuscle.indirectSetCredit, 0.5,
                       "0.5 is the meta-regression's method, not a house convention — changing it "
                       + "invalidates the reference doses shown beside it")
    }

    /// Warm-ups are excluded. RPE is NOT filtered here: the reference doses were derived from
    /// unfiltered working-set counts, so filtering would compare a smaller number against a scale
    /// built from a larger one.
    func testSetCountsExcludeWarmupsAndDoNotFilterByRpe() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiftSessions([mkSession(id: "s1", startTs: 1_000)])
        _ = try await store.upsertLiftSets([
            mkSet(id: "warm", sessionId: "s1", ord: 0, setIndex: 1, primary: .chest,
                  secondary: [], rpe: 9, isWarmup: true),
            mkSet(id: "easy", sessionId: "s1", ord: 1, setIndex: 2, primary: .chest,
                  secondary: [], rpe: 4),
            mkSet(id: "hard", sessionId: "s1", ord: 2, setIndex: 3, primary: .chest,
                  secondary: [], rpe: 9),
            mkSet(id: "unrated", sessionId: "s1", ord: 3, setIndex: 4, primary: .chest,
                  secondary: [], rpe: nil),
        ])
        let counts = try await store.liftSetCounts(deviceId: dev, fromTs: 0, toTs: 9_999)
        XCTAssertEqual(counts.direct[.chest], 3, "warm-up excluded; easy and unrated still count")
    }

    func testSetCountsRespectTheWindow() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertLiftSessions([
            mkSession(id: "inside", startTs: 5_000),
            mkSession(id: "outside", startTs: 50_000),
        ])
        _ = try await store.upsertLiftSets([
            mkSet(id: "a", sessionId: "inside", ord: 0, setIndex: 1, primary: .lats, secondary: []),
            mkSet(id: "b", sessionId: "outside", ord: 0, setIndex: 1, primary: .lats, secondary: []),
        ])
        let counts = try await store.liftSetCounts(deviceId: dev, fromTs: 0, toTs: 9_999)
        XCTAssertEqual(counts.direct[.lats], 1)
    }

    // MARK: - Proximity to failure, reported separately

    // MARK: - Privacy: delete-means-gone

    /// Every lift table is deviceId-keyed and listed in `deviceScopedTables`, so forgetting a device
    /// clears the whole feature. The child tables (items, sets) are the ones a foreign-key-less schema
    /// would otherwise strand.
    func testLiftTablesAreDeviceScoped() {
        for t in ["liftExercise", "liftProgram", "liftProgramItem", "liftSession", "liftSet"] {
            XCTAssertTrue(DeviceRegistryStore.deviceScopedTables.contains(t),
                          "\(t) missing from deviceScopedTables — deleteAllData would leave it behind")
        }
    }

    // MARK: - Helpers

    private let dev = "my-whoop"
    private let sport = "Strength Training"

    private func mkProgram(id: String, name: String, updatedAt: Int,
                           archived: Bool = false) -> LiftProgramRow {
        LiftProgramRow(id: id, deviceId: dev, name: name, note: nil,
                       createdAt: 1, updatedAt: updatedAt, archived: archived)
    }

    private func mkItem(id: String, ord: Int, exercise: String = "Leg Press",
                        programId: String = "p1") -> LiftProgramItemRow {
        LiftProgramItemRow(id: id, deviceId: dev, programId: programId, ord: ord,
                           exercise: exercise, targetSets: 3,
                           targetRepsLow: 8, targetRepsHigh: 10, targetRpe: 7.5,
                           targetWeightKg: nil,
                           restSec: 180, note: "Lower slowly.")
    }

    private func mkSession(id: String, startTs: Int, endTs: Int? = nil,
                           programId: String? = "p1") -> LiftSessionRow {
        LiftSessionRow(id: id, deviceId: dev, startTs: startTs, endTs: endTs, sport: sport,
                       programId: programId, programName: "Upper A", sessionRpe: nil, note: nil)
    }

    private func mkSet(id: String, sessionId: String, ord: Int, setIndex: Int,
                       exercise: String = "Leg Press", weightKg: Double? = 60,
                       reps: Int? = 10, primary: LiftMuscle? = .quads,
                       secondary: [LiftMuscle] = [.glutes], rpe: Double? = 8,
                       isWarmup: Bool = false) -> LiftSetRow {
        LiftSetRow(id: id, deviceId: dev, sessionId: sessionId, ord: ord, exercise: exercise,
                   primaryMuscle: primary, secondaryMuscles: secondary, setIndex: setIndex,
                   weightKg: weightKg, reps: reps, rpe: rpe, isWarmup: isWarmup,
                   startTs: nil, endTs: nil, restSec: nil, note: nil)
    }
}
