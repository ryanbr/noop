import XCTest
@testable import WhoopStore

/// The `settings.json` codec + UserDefaults round trip for #1000 ("restore doesn't bring back
/// settings/weight/height"). These run headlessly (`swift test --filter BackupSettingsTests`); the
/// full ZIP-container round trip through `DataBackup` lives in the app target's
/// `BackupSyncRoundTripTests` (central build).
final class BackupSettingsTests: XCTestCase {

    // MARK: - Encode / decode round trip

    func testEncodeDecodeRoundTripsEveryWhitelistedKey() throws {
        let values: [String: Any] = [
            "profile.age": 34,
            "profile.sex": "female",
            "profile.weightKg": 62.5,
            "profile.heightCm": 168.0,
            "profile.waistCm": 71.0,
            "profile.hrMax": 191,
            "units.system": "imperial",
            "units.temperature": "celsius",
            "effort.scale": "whoop",
            // #today-hosted-cards: the one layout pref carried, a JSON [String] stored under the String kind.
            "today.hostedCards": "[\"sleep.sleepMarks\"]",
        ]
        let data = try XCTUnwrap(BackupSettings.encode(values))
        let back = BackupSettings.decode(data)

        XCTAssertEqual(back["profile.age"] as? Int, 34)
        XCTAssertEqual(back["profile.sex"] as? String, "female")
        XCTAssertEqual(back["profile.weightKg"] as? Double, 62.5)
        XCTAssertEqual(back["profile.heightCm"] as? Double, 168.0)
        XCTAssertEqual(back["profile.waistCm"] as? Double, 71.0)
        XCTAssertEqual(back["profile.hrMax"] as? Int, 191)
        XCTAssertEqual(back["units.system"] as? String, "imperial")
        XCTAssertEqual(back["units.temperature"] as? String, "celsius")
        XCTAssertEqual(back["effort.scale"] as? String, "whoop")
        XCTAssertEqual(back["today.hostedCards"] as? String, "[\"sleep.sleepMarks\"]")
        XCTAssertEqual(back.count, values.count, "Nothing extra should appear")
    }

    func testEncodeIsDeterministic() throws {
        let values: [String: Any] = ["profile.age": 40, "profile.sex": "male", "profile.weightKg": 80.0]
        let a = try XCTUnwrap(BackupSettings.encode(values))
        let b = try XCTUnwrap(BackupSettings.encode(values))
        XCTAssertEqual(a, b, "Same settings must produce identical bytes (.sortedKeys)")
    }

    // MARK: - Whitelist enforcement (the anonymity/scope gate)

    func testNonWhitelistedKeysAreDroppedOnEncodeAndDecode() throws {
        // Encode side: anything sensitive or device-specific never reaches the JSON.
        let dirty: [String: Any] = [
            "profile.age": 30,
            "device.peripheralId": "AA:BB:CC:DD:EE:FF",
            "noop.acceptedTermsVersion": "3",
            "sync.cursor": 12345,
            "profile.avatarImageData": "base64…",
        ]
        let data = try XCTUnwrap(BackupSettings.encode(dirty))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("peripheralId"))
        XCTAssertFalse(json.contains("cursor"))
        XCTAssertFalse(json.contains("avatar"))
        XCTAssertFalse(json.contains("acceptedTerms"))

        // Decode side: a hand-crafted settings.json can't smuggle keys in either.
        let crafted = Data(#"{"profile.age": 28, "injected.key": "evil", "profile.sex": "male"}"#.utf8)
        let back = BackupSettings.decode(crafted)
        XCTAssertNil(back["injected.key"])
        XCTAssertEqual(back["profile.age"] as? Int, 28)
        XCTAssertEqual(back["profile.sex"] as? String, "male")
    }

    func testWrongTypedValuesAreDroppedNotCoerced() {
        // Strings where numbers belong, numbers where strings belong, booleans posing as ints.
        let crafted = Data(#"{"profile.age": true, "profile.sex": 5, "profile.weightKg": "heavy", "profile.hrMax": 185}"#.utf8)
        let back = BackupSettings.decode(crafted)
        XCTAssertNil(back["profile.age"], "JSON true must never become age 1")
        XCTAssertNil(back["profile.sex"])
        XCTAssertNil(back["profile.weightKg"])
        XCTAssertEqual(back["profile.hrMax"] as? Int, 185, "Valid siblings still decode")
    }

    func testIntegralDoubleDecodesToIntForIntKeys() {
        // Android writes JSON numbers; 34.0 for an int-kind key must land as Int 34.
        let crafted = Data(#"{"profile.age": 34.0}"#.utf8)
        XCTAssertEqual(BackupSettings.decode(crafted)["profile.age"] as? Int, 34)
    }

    // MARK: - Degradation

    func testGarbageAndNonObjectJsonDecodeToEmpty() {
        XCTAssertTrue(BackupSettings.decode(Data("not json at all".utf8)).isEmpty)
        XCTAssertTrue(BackupSettings.decode(Data("[1,2,3]".utf8)).isEmpty)
        XCTAssertTrue(BackupSettings.decode(Data()).isEmpty)
    }

    func testEncodeReturnsNilWhenNothingWhitelistedIsPresent() {
        XCTAssertNil(BackupSettings.encode([:]))
        XCTAssertNil(BackupSettings.encode(["unrelated.key": 1]))
    }

    // MARK: - UserDefaults snapshot / apply (the platform boundary)

    func testSnapshotOmitsUnsetKeysAndMapsHrMaxOverride() throws {
        let defaults = try freshDefaults()
        defaults.set(29, forKey: "profile.age")
        defaults.set(82.5, forKey: "profile.weightKg")
        defaults.set(198, forKey: "profile.hrMaxOverride") // storage key, not the canonical name
        defaults.set("imperial", forKey: "units.system")

        let snap = BackupSettings.snapshot(from: defaults)
        XCTAssertEqual(snap["profile.age"] as? Int, 29)
        XCTAssertEqual(snap["profile.weightKg"] as? Double, 82.5)
        XCTAssertEqual(snap["profile.hrMax"] as? Int, 198, "hrMaxOverride surfaces under the canonical key")
        XCTAssertEqual(snap["units.system"] as? String, "imperial")
        XCTAssertNil(snap["profile.heightCm"], "Never-set keys are omitted, not defaulted")
        XCTAssertNil(snap["profile.sex"])
    }

    func testApplyWritesPlatformKeysAndLeavesUntouchedKeysAlone() throws {
        let defaults = try freshDefaults()
        defaults.set(175.0, forKey: "profile.heightCm") // pre-existing target value, not in payload

        BackupSettings.apply([
            "profile.age": 41,
            "profile.hrMax": 187,
            "units.temperature": "fahrenheit",
        ], to: defaults)

        XCTAssertEqual(defaults.object(forKey: "profile.age") as? Int, 41)
        XCTAssertEqual(defaults.object(forKey: "profile.hrMaxOverride") as? Int, 187,
                       "Canonical profile.hrMax lands on the profile.hrMaxOverride storage key")
        XCTAssertEqual(defaults.string(forKey: "units.temperature"), "fahrenheit")
        XCTAssertEqual(defaults.object(forKey: "profile.heightCm") as? Double, 175.0,
                       "Keys absent from the payload keep the target's value")
        XCTAssertNil(defaults.object(forKey: "profile.hrMax"),
                     "The canonical name itself is never written to defaults")
    }

    /// #146: applying a restored age must clear a pre-existing `profile.dateOfBirth`, so the target's
    /// old DOB can't silently override the restore — `ProfileStore` re-derives the DOB from the
    /// restored age on the forced post-restore relaunch.
    func testApplyClearsStaleDateOfBirthWhenAgeRestored() throws {
        let defaults = try freshDefaults()
        defaults.set(Date(timeIntervalSince1970: 0), forKey: "profile.dateOfBirth") // target's own DOB

        BackupSettings.apply(["profile.age": 44], to: defaults)

        XCTAssertEqual(defaults.object(forKey: "profile.age") as? Int, 44)
        XCTAssertNil(defaults.object(forKey: "profile.dateOfBirth"),
                     "A restored age must clear the target's stale DOB so it re-derives from the restore")
    }

    /// A restore payload with no age must leave a target's date of birth alone.
    func testApplyLeavesDateOfBirthWhenNoAgeInPayload() throws {
        let defaults = try freshDefaults()
        let dob = Date(timeIntervalSince1970: 500_000_000)
        defaults.set(dob, forKey: "profile.dateOfBirth")

        BackupSettings.apply(["profile.weightKg": 70.0], to: defaults)

        XCTAssertEqual(defaults.object(forKey: "profile.dateOfBirth") as? Date, dob,
                       "No age in the payload → the target's DOB is untouched")
    }

    func testFullExportImportShapedRoundTripThroughDefaults() throws {
        // Device A: user-set values → snapshot → encode (what export writes into the zip).
        let deviceA = try freshDefaults()
        deviceA.set(52, forKey: "profile.age")
        deviceA.set("nonbinary", forKey: "profile.sex")
        deviceA.set(90.25, forKey: "profile.weightKg")
        deviceA.set(0, forKey: "profile.hrMaxOverride") // explicit "auto" is still a value
        let payload = try XCTUnwrap(BackupSettings.encode(BackupSettings.snapshot(from: deviceA)))

        // Device B: decode → apply (what restore does after the DB swap succeeds).
        let deviceB = try freshDefaults()
        BackupSettings.apply(BackupSettings.decode(payload), to: deviceB)

        XCTAssertEqual(deviceB.object(forKey: "profile.age") as? Int, 52)
        XCTAssertEqual(deviceB.string(forKey: "profile.sex"), "nonbinary")
        XCTAssertEqual(deviceB.object(forKey: "profile.weightKg") as? Double, 90.25)
        XCTAssertEqual(deviceB.object(forKey: "profile.hrMaxOverride") as? Int, 0)
    }

    // MARK: - Suite-scoped defaults (never the test runner's real domain)

    private var suites: [String] = []

    private func freshDefaults() throws -> UserDefaults {
        let name = "BackupSettingsTests-\(UUID().uuidString)"
        guard let d = UserDefaults(suiteName: name) else {
            throw XCTSkip("Couldn't create a suite-scoped UserDefaults")
        }
        suites.append(name)
        return d
    }

    override func tearDown() {
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suites = []
        super.tearDown()
    }
}
