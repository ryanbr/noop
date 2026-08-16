import XCTest
@testable import Strand

/// Guards the #801 cycle-awareness profile gate. Cycle phase is read from the MENSTRUAL skin-temperature
/// shift, so the opt-in (the Health `CycleAwarenessOptInCard` and the Automations "Cycle awareness"
/// toggle) is only offered to profiles it can apply to and is NOT rendered for male profiles. Both
/// surfaces resolve their visibility through `ProfileStore.cycleAwarenessApplies`, so pinning that one
/// predicate keeps Health and Automations in lockstep and stops a male profile from enabling a feature
/// whose card it can never see.
final class CycleAwarenessGateTests: XCTestCase {

    /// Male profiles must NOT be offered the opt-in (the core of #801).
    func testMaleProfileIsExcluded() {
        XCTAssertFalse(ProfileStore.cycleAwarenessApplies(sex: "male"))
    }

    /// The profiles the menstrual-cycle read applies to (female / nonbinary) DO see the opt-in.
    func testFemaleAndNonbinaryAreIncluded() {
        XCTAssertTrue(ProfileStore.cycleAwarenessApplies(sex: "female"))
        XCTAssertTrue(ProfileStore.cycleAwarenessApplies(sex: "nonbinary"))
    }

    /// The gate is case- and whitespace-insensitive so a stored "Male"/" male " never slips through as
    /// non-male (the picker writes lowercase tokens today, but we don't want a casing change to leak it).
    func testGateNormalisesCaseAndWhitespace() {
        XCTAssertFalse(ProfileStore.cycleAwarenessApplies(sex: "Male"))
        XCTAssertFalse(ProfileStore.cycleAwarenessApplies(sex: "MALE"))
        XCTAssertFalse(ProfileStore.cycleAwarenessApplies(sex: "  male  "))
    }

    /// Fail OPEN, not closed: an unrecognised value still sees the opt-in rather than being silently
    /// excluded; only an explicit "male" is gated out.
    func testUnknownValueDefaultsToShowingTheOptIn() {
        XCTAssertTrue(ProfileStore.cycleAwarenessApplies(sex: ""))
        XCTAssertTrue(ProfileStore.cycleAwarenessApplies(sex: "intersex"))
    }

    /// The instance accessor reflects the live `sex` field, so the views (which read
    /// `model.profile.cycleAwarenessApplies`) track a profile change.
    @MainActor
    func testInstanceAccessorTracksTheStoredSex() {
        let store = ProfileStore()
        store.sex = "male"
        XCTAssertFalse(store.cycleAwarenessApplies)
        store.sex = "female"
        XCTAssertTrue(store.cycleAwarenessApplies)
    }

    /// #hide-cycle: the user's "not for me" opt-out suppresses the offer for an otherwise-eligible profile,
    /// and the gate is INDEPENDENT of age — it takes only sex + the hidden flag, never a birth date.
    func testHiddenSuppressesTheOfferForEligibleProfiles() {
        // Eligible + not hidden → visible (the default).
        XCTAssertTrue(ProfileStore.cycleAwarenessVisible(sex: "female", hidden: false))
        XCTAssertTrue(ProfileStore.cycleAwarenessVisible(sex: "nonbinary", hidden: false))
        // Eligible + hidden → suppressed by the user's own choice.
        XCTAssertFalse(ProfileStore.cycleAwarenessVisible(sex: "female", hidden: true))
        XCTAssertFalse(ProfileStore.cycleAwarenessVisible(sex: "nonbinary", hidden: true))
        // Ineligible (male) stays ineligible whatever the flag — the two conditions compose.
        XCTAssertFalse(ProfileStore.cycleAwarenessVisible(sex: "male", hidden: false))
        XCTAssertFalse(ProfileStore.cycleAwarenessVisible(sex: "male", hidden: true))
    }
}
