import XCTest
@testable import WhoopProtocol

/// Registry model-label → `DeviceFamily` resolution (#171). Mirrors the Android `RegistryModelFamilyTest`.
///
/// The device registry holds several historical spellings for the same hardware — the Add-Device
/// wizard's bare "4.0" / "5.0 MG", the full picker labels ("WHOOP 4.0" / "WHOOP 5.0 / MG"), and the
/// legacy seeded "my-whoop" row's bare "WHOOP". Call sites that compared ONE spelling silently missed
/// the others (issue #171: wizard-paired 4.0 straps decoded on the 5/MG /100 scale, ~8 °C skin temps
/// in the Deep Timeline). These tests pin the full label contract so a new spelling — or a regression
/// back to a single-spelling comparison — fails loudly.
final class RegistryModelFamilyTests: XCTestCase {

    // MARK: - WHOOP 4.0 — every stored spelling must positively identify (the #171 fix)

    func testWizardBare40LabelResolvesToWhoop4() {
        XCTAssertEqual(DeviceFamily.forRegistryModel("4.0"), .whoop4)
    }

    func testFullPicker40LabelResolvesToWhoop4() {
        XCTAssertEqual(DeviceFamily.forRegistryModel("WHOOP 4.0"), .whoop4)
    }

    // MARK: - WHOOP 5/MG — both spellings keep the /100 path

    func testWizard5MgLabelResolvesToWhoop5() {
        XCTAssertEqual(DeviceFamily.forRegistryModel("5.0 MG"), .whoop5)
        // "WHOOP 5.0 MG" is a spelling no writer produces today (the picker writes
        // "WHOOP 5.0 / MG"); it lands on the safe .whoop5 default, which happens to be correct.
        XCTAssertEqual(DeviceFamily.forRegistryModel("WHOOP 5.0 MG"), .whoop5)
        XCTAssertEqual(DeviceFamily.forRegistryModel("WHOOP 5.0 / MG"), .whoop5)
    }

    // MARK: - Legacy + unknowns — the prior .whoop5 fallback, unchanged

    /// The seeded "my-whoop" row predates the wizard and was written identically for 4.0 and 5/MG
    /// installs, so "WHOOP" carries no family information; it keeps the prior fallback.
    func testLegacySeededWhoopLabelKeepsWhoop5Fallback() {
        XCTAssertEqual(DeviceFamily.forRegistryModel("WHOOP"), .whoop5)
    }

    /// Model-ONLY resolution is brand-blind: an Oura/Garmin model string has no WHOOP spelling, so it
    /// lands on the `.whoop5` default. This is why a non-WHOOP device needs `forRegistryDevice` (#1086) —
    /// the brand is the evidence the model string lacks.
    func testNilEmptyAndGarbageFallBackToWhoop5() {
        XCTAssertEqual(DeviceFamily.forRegistryModel(nil), .whoop5)
        XCTAssertEqual(DeviceFamily.forRegistryModel(""), .whoop5)
        XCTAssertEqual(DeviceFamily.forRegistryModel("Oura Ring Gen3"), .whoop5)
        XCTAssertEqual(DeviceFamily.forRegistryModel("garmin-hrm"), .whoop5)
    }

    // MARK: - Brand-aware resolution (#1086) — a non-WHOOP brand must NOT resolve to a WHOOP family

    /// The core of #1086: an Oura ring carries `brand == "Oura"`, so it resolves to `nil` (not a WHOOP)
    /// instead of silently falling through to `.whoop5`, whatever its model string. Because the brand is
    /// tested BEFORE the model switch, every generation resolves to `nil` — no model-string enumeration
    /// to keep in sync with new rings (Oura Ring 3/4/5 and the cloud fallback are all one code path).
    func testNonWhoopBrandResolvesToNil() {
        for model in ["Oura Ring 3", "Oura Ring 4", "Oura Ring 5", "Oura (cloud)"] {
            XCTAssertNil(DeviceFamily.forRegistryDevice(model: model, brand: "Oura"),
                         "Oura model \(model) must not resolve to a WHOOP family")
        }
        XCTAssertNil(DeviceFamily.forRegistryDevice(model: nil, brand: "Garmin"))
        XCTAssertNil(DeviceFamily.forRegistryDevice(model: "Watch", brand: "Apple"))
    }

    /// A WHOOP brand still resolves by model spelling, exactly as `forRegistryModel` does.
    func testWhoopBrandResolvesByModel() {
        XCTAssertEqual(DeviceFamily.forRegistryDevice(model: "4.0", brand: "WHOOP"), .whoop4)
        XCTAssertEqual(DeviceFamily.forRegistryDevice(model: "WHOOP 4.0", brand: "WHOOP"), .whoop4)
        XCTAssertEqual(DeviceFamily.forRegistryDevice(model: "5.0 MG", brand: "WHOOP"), .whoop5)
        XCTAssertEqual(DeviceFamily.forRegistryDevice(model: "WHOOP 5.0 / MG", brand: "WHOOP"), .whoop5)
    }

    /// A nil/empty brand carries no non-WHOOP signal (legacy rows, WHOOP straps), so it defers to the
    /// model mapping — never `nil`.
    func testMissingBrandDefersToModel() {
        XCTAssertEqual(DeviceFamily.forRegistryDevice(model: "4.0", brand: nil), .whoop4)
        XCTAssertEqual(DeviceFamily.forRegistryDevice(model: "5.0 MG", brand: ""), .whoop5)
        XCTAssertEqual(DeviceFamily.forRegistryDevice(model: nil, brand: nil), .whoop5)
    }

    /// "No scoring change" half of #1086: the consumers that need a CONCRETE family coalesce a non-WHOOP
    /// `nil` to `.whoop5` (the non-4.0 skin-temp scale), so the family a non-WHOOP row is *treated as* is
    /// identical to before the brand-aware resolver existed. Guards the skin-temp/day-owner call sites
    /// against a scale regression.
    ///
    /// ⚠️ Deliberately scoped to those callers. It once said "every consumer", which was true when written
    /// and became wrong: an identity question ("is it a 5/MG?") must NOT coalesce — see
    /// `isWhoop5Registry` and the tests below.
    func testNonWhoopCoalescesToPriorLabel() {
        for model in ["Oura Ring 3", "Oura Ring 4", "Oura Ring 5"] {
            XCTAssertEqual(DeviceFamily.forRegistryDevice(model: model, brand: "Oura") ?? .whoop5,
                           DeviceFamily.forRegistryModel(model), "\(model) treated-as family must be unchanged")
        }
    }

    // MARK: - isWhoop5Registry — the identity question, which must never coalesce

    /// The defect this helper exists to prevent: a non-WHOOP brand must answer NO, whatever its model
    /// string — including the ones `forRegistryModel` maps to `.whoop5` by fall-through. Written against
    /// the real registry row of an Oura Gen3 (`brand "Oura"`, `model "Oura Ring 3"`), which under the old
    /// `forRegistryDevice(…) ?? .whoop5 == .whoop5` shape answered YES and inherited WHOOP-5 empty-state
    /// copy pointing at an R-R/RSA estimate the ring's banked stream can never produce.
    func testIsWhoop5RegistryIsFalseForNonWhoopBrands() {
        for model in ["Oura Ring 3", "Oura Ring 4", "Oura Ring 5", "Oura (cloud)", nil] {
            XCTAssertFalse(DeviceFamily.isWhoop5Registry(model: model, brand: "Oura"),
                           "Oura model \(model ?? "nil") must not be treated as a WHOOP 5")
        }
        XCTAssertFalse(DeviceFamily.isWhoop5Registry(model: "Watch", brand: "Apple"))
        XCTAssertFalse(DeviceFamily.isWhoop5Registry(model: nil, brand: "Garmin"))
    }

    /// A real WHOOP 5/MG still answers YES, so #623's empty-state copy is unchanged for the straps it was
    /// written for — the whole point of fixing this narrowly.
    func testIsWhoop5RegistryIsTrueForWhoop5() {
        XCTAssertTrue(DeviceFamily.isWhoop5Registry(model: "5.0 MG", brand: "WHOOP"))
        XCTAssertTrue(DeviceFamily.isWhoop5Registry(model: "WHOOP 5.0 / MG", brand: "WHOOP"))
        // Legacy rows: no brand recorded, so the model mapping decides — including the bare-"WHOOP"
        // fall-through that #171 documents as 5.0-family.
        XCTAssertTrue(DeviceFamily.isWhoop5Registry(model: "WHOOP", brand: nil))
        XCTAssertTrue(DeviceFamily.isWhoop5Registry(model: nil, brand: ""))
    }

    /// A WHOOP 4.0 answers NO — it is not the 5/MG family — which is what keeps a 4.0-v24 that banks SpO2
    /// on the generic empty copy rather than "unsupported on this strap".
    func testIsWhoop5RegistryIsFalseForWhoop4() {
        XCTAssertFalse(DeviceFamily.isWhoop5Registry(model: "4.0", brand: "WHOOP"))
        XCTAssertFalse(DeviceFamily.isWhoop5Registry(model: "WHOOP 4.0", brand: nil))
    }
}
