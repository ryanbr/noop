import XCTest
@testable import StrandImport

/// Exercise → muscle attribution.
///
/// The ordering cases are the ones that matter. The rules are matched first-hit-wins on a normalised
/// name, so every generic word ("curl", "raise", "row", "press") has specific phrases that contain it
/// and must be decided first. A regression there does not crash or blank — it silently attributes leg
/// work to biceps, which is exactly the kind of confident wrong answer this project treats as worse
/// than nothing.
final class MuscleGroupsTests: XCTestCase {

    func testTheLiftsFromARealLogAttributeCorrectly() {
        XCTAssertEqual(MuscleAttribution.muscles(for: "Romanian Deadlift (Barbell)"),
                       [.hamstrings, .glutes])
        XCTAssertEqual(MuscleAttribution.muscles(for: "Squat (Barbell)"), [.quadriceps, .glutes])
        XCTAssertEqual(MuscleAttribution.muscles(for: "Seated Cable Row - V Grip"),
                       [.upperBack, .lats])
        XCTAssertEqual(MuscleAttribution.muscles(for: "Bicep Curl (Dumbbell)"), [.biceps])
    }

    /// "leg curl" contains "curl"; "romanian deadlift" contains "deadlift". If the generic rule won,
    /// hamstring work would be filed under biceps and lower back.
    func testSpecificPhrasesBeatTheGenericWordTheyContain() {
        XCTAssertEqual(MuscleAttribution.muscles(for: "Lying Leg Curl"), [.hamstrings],
                       "leg curl must not fall through to the biceps 'curl' rule")
        XCTAssertEqual(MuscleAttribution.muscles(for: "Romanian Deadlift"), [.hamstrings, .glutes],
                       "must not fall through to the generic deadlift rule")
        XCTAssertEqual(MuscleAttribution.muscles(for: "Calf Raise (Machine)"), [.calves],
                       "calf raise must not fall through to a shoulder 'raise'")
        XCTAssertEqual(MuscleAttribution.muscles(for: "Front Raise"), [.shoulders])
        XCTAssertEqual(MuscleAttribution.muscles(for: "Hanging Leg Raise"), [.abs],
                       "a hanging leg raise is trunk work, not quads")
        XCTAssertEqual(MuscleAttribution.muscles(for: "Upright Row"), [.shoulders, .upperBack],
                       "upright row must not fall through to the back 'row' rule")
        XCTAssertEqual(MuscleAttribution.muscles(for: "Hammer Curl"), [.biceps, .forearms])
    }

    /// Equipment parentheses, hyphens and case must not change the answer.
    func testNormalisationIgnoresEquipmentPunctuationAndCase() {
        let expected: [MuscleGroup] = [.chest, .triceps]
        for spelling in ["Bench Press", "bench press", "Bench Press (Barbell)",
                         "BENCH-PRESS", "Bench  Press   (Smith Machine)"] {
            XCTAssertEqual(MuscleAttribution.muscles(for: spelling), expected, spelling)
        }
    }

    /// An unrecognised lift attributes NOTHING. A wrong muscle is worse than a blank one: the blank
    /// invites a look, the wrong one does not.
    func testAnUnknownExerciseAttributesNothing() {
        XCTAssertTrue(MuscleAttribution.muscles(for: "Kettlebell Flow").isEmpty)
        XCTAssertTrue(MuscleAttribution.muscles(for: "").isEmpty)
        XCTAssertTrue(MuscleAttribution.muscles(for: "   ").isEmpty)
        XCTAssertTrue(MuscleAttribution.muscles(for: "???").isEmpty)
    }

    /// Every rule must map to at least one group, and every group named must be a real case — a typo
    /// in the table would otherwise sit there attributing nothing and look like an unknown lift.
    func testEveryRuleIsWellFormed() {
        XCTAssertFalse(MuscleAttribution.rules.isEmpty)
        for (needle, groups) in MuscleAttribution.rules {
            XCTAssertFalse(needle.isEmpty)
            XCTAssertEqual(needle, MuscleAttribution.normalise(needle),
                           "rule '\(needle)' must already be in normalised form or it can never match")
            XCTAssertFalse(groups.isEmpty, "rule '\(needle)' attributes nothing")
        }
    }

    /// Guards the ordering property itself rather than individual pairs: if a rule's needle contains
    /// an earlier rule's needle, the earlier one wins and the later is dead. This catches a new rule
    /// appended in the wrong place, which no example-based test would.
    func testNoRuleIsShadowedByAnEarlierOne() {
        let rules = MuscleAttribution.rules
        for (i, later) in rules.enumerated() {
            for earlier in rules[..<i] where later.0.contains(earlier.0) {
                XCTFail("'\(later.0)' is unreachable: '\(earlier.0)' matches it first")
            }
        }
    }
}
