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

    /// Titles that match TWO rules whose needles do not contain each other, so the structural
    /// shadowing test cannot see them: "Rear Delt Fly" contains both "rear delt" and "fly", and
    /// whichever sits first in the table wins. Every one of these was wrong when first written.
    func testCompoundTitlesResolveToTheRearOrLegMovementNotTheGenericOne() {
        XCTAssertEqual(MuscleAttribution.muscles(for: "Rear Delt Fly"), [.shoulders, .upperBack],
                       "the generic chest 'fly' rule would file the opposite side of the body")
        XCTAssertEqual(MuscleAttribution.muscles(for: "Reverse Fly (Dumbbell)"), [.shoulders, .upperBack])
        XCTAssertEqual(MuscleAttribution.muscles(for: "Nordic Curl"), [.hamstrings],
                       "a nordic curl is hamstrings, not the biceps 'curl' rule")
        XCTAssertEqual(MuscleAttribution.muscles(for: "Jefferson Curl"), [.lowerBack, .hamstrings])
        XCTAssertEqual(MuscleAttribution.muscles(for: "Cable Fly"), [.chest], "a plain fly is still chest")
        XCTAssertEqual(MuscleAttribution.muscles(for: "Chest Fly"), [.chest])
    }

    /// A wrist curl is forearms. The rule for it existed but sat BELOW the generic biceps "curl",
    /// so it could never match the spelling the exercise is normally written with.
    func testWristCurlIsForearmsNotBiceps() {
        XCTAssertEqual(MuscleAttribution.muscles(for: "Wrist Curl"), [.forearms])
        XCTAssertEqual(MuscleAttribution.muscles(for: "Reverse Wrist Curl (Barbell)"), [.forearms])
    }

    /// These thirteen groups have no neck, and "Neck Curl" contains "curl", so it came out as biceps.
    /// A blank is the only honest answer: the table prefers a blank to a wrong muscle everywhere else,
    /// and an exercise the vocabulary cannot express is exactly where that has to hold.
    func testAnExerciseTheVocabularyCannotExpressAttributesNothing() {
        XCTAssertTrue(MuscleAttribution.muscles(for: "Neck Curl").isEmpty)
        XCTAssertTrue(MuscleAttribution.muscles(for: "Neck Extension").isEmpty)
        XCTAssertTrue(MuscleAttribution.muscles(for: "Weighted Neck Harness").isEmpty)
        XCTAssertEqual(MuscleAttribution.muscles(for: "Bicep Curl"), [.biceps],
                       "the guard must not swallow an ordinary curl")
    }

    /// Hevy writes it as one word. A rule that only matches the spaced spelling silently attributes
    /// nothing for the spelling the catalogue actually uses, which reads as an unknown lift.
    func testSkullcrusherMatchesBothSpellings() {
        XCTAssertEqual(MuscleAttribution.muscles(for: "Skullcrusher (Barbell)"), [.triceps])
        XCTAssertEqual(MuscleAttribution.muscles(for: "Skull Crusher"), [.triceps])
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
    ///
    /// What it does NOT catch: two rules whose needles do not contain each other, where a real title
    /// contains BOTH. "rear delt" and "fly" are disjoint, yet "Rear Delt Fly" matches whichever comes
    /// first — and it came out as chest until an example test was written for it. The example test
    /// above is the guard for that class; this one cannot be.
    func testNoRuleIsShadowedByAnEarlierOne() {
        let rules = MuscleAttribution.rules
        for (i, later) in rules.enumerated() {
            for earlier in rules[..<i] where later.0.contains(earlier.0) {
                XCTFail("'\(later.0)' is unreachable: '\(earlier.0)' matches it first")
            }
        }
    }
}
