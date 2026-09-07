package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Exercise → muscle attribution. Kotlin twin of the macOS MuscleGroupsTests - same cases, same
 * assertions, so a rule that moves on one platform and not the other fails here.
 *
 * The ordering cases are the ones that matter. The rules are matched first-hit-wins on a normalised
 * name, so every generic word ("curl", "raise", "row", "press") has specific phrases that contain it
 * and must be decided first. A regression there does not crash or blank - it silently attributes leg
 * work to biceps, which is exactly the kind of confident wrong answer this project treats as worse
 * than nothing.
 */
class MuscleGroupsTest {

    @Test
    fun theLiftsFromARealLogAttributeCorrectly() {
        assertEquals(
            listOf(MuscleGroup.HAMSTRINGS, MuscleGroup.GLUTES),
            MuscleAttribution.muscles("Romanian Deadlift (Barbell)"),
        )
        assertEquals(
            listOf(MuscleGroup.QUADRICEPS, MuscleGroup.GLUTES),
            MuscleAttribution.muscles("Squat (Barbell)"),
        )
        assertEquals(
            listOf(MuscleGroup.UPPER_BACK, MuscleGroup.LATS),
            MuscleAttribution.muscles("Seated Cable Row - V Grip"),
        )
        assertEquals(listOf(MuscleGroup.BICEPS), MuscleAttribution.muscles("Bicep Curl (Dumbbell)"))
    }

    /**
     * "leg curl" contains "curl"; "romanian deadlift" contains "deadlift". If the generic rule won,
     * hamstring work would be filed under biceps and lower back.
     */
    @Test
    fun specificPhrasesBeatTheGenericWordTheyContain() {
        assertEquals(listOf(MuscleGroup.HAMSTRINGS), MuscleAttribution.muscles("Lying Leg Curl"))
        assertEquals(
            listOf(MuscleGroup.HAMSTRINGS, MuscleGroup.GLUTES),
            MuscleAttribution.muscles("Romanian Deadlift"),
        )
        assertEquals(listOf(MuscleGroup.CALVES), MuscleAttribution.muscles("Calf Raise (Machine)"))
        assertEquals(listOf(MuscleGroup.SHOULDERS), MuscleAttribution.muscles("Front Raise"))
        assertEquals(listOf(MuscleGroup.ABS), MuscleAttribution.muscles("Hanging Leg Raise"))
        assertEquals(
            listOf(MuscleGroup.SHOULDERS, MuscleGroup.UPPER_BACK),
            MuscleAttribution.muscles("Upright Row"),
        )
        assertEquals(
            listOf(MuscleGroup.BICEPS, MuscleGroup.FOREARMS),
            MuscleAttribution.muscles("Hammer Curl"),
        )
    }

    /**
     * Titles that match TWO rules whose needles do not contain each other, so the structural
     * shadowing test cannot see them: "Rear Delt Fly" contains both "rear delt" and "fly", and
     * whichever sits first in the table wins. Every one of these was wrong when first written.
     */
    @Test
    fun compoundTitlesResolveToTheRearOrLegMovementNotTheGenericOne() {
        val rear = listOf(MuscleGroup.SHOULDERS, MuscleGroup.UPPER_BACK)
        assertEquals(rear, MuscleAttribution.muscles("Rear Delt Fly"))
        assertEquals(rear, MuscleAttribution.muscles("Reverse Fly (Dumbbell)"))
        assertEquals(listOf(MuscleGroup.HAMSTRINGS), MuscleAttribution.muscles("Nordic Curl"))
        assertEquals(
            listOf(MuscleGroup.LOWER_BACK, MuscleGroup.HAMSTRINGS),
            MuscleAttribution.muscles("Jefferson Curl"),
        )
        assertEquals(listOf(MuscleGroup.CHEST), MuscleAttribution.muscles("Cable Fly"))
        assertEquals(listOf(MuscleGroup.CHEST), MuscleAttribution.muscles("Chest Fly"))
    }

    /**
     * A wrist curl is forearms. The rule for it existed but sat BELOW the generic biceps "curl", so
     * it could never match the spelling the exercise is normally written with.
     */
    @Test
    fun wristCurlIsForearmsNotBiceps() {
        assertEquals(listOf(MuscleGroup.FOREARMS), MuscleAttribution.muscles("Wrist Curl"))
        assertEquals(
            listOf(MuscleGroup.FOREARMS),
            MuscleAttribution.muscles("Reverse Wrist Curl (Barbell)"),
        )
    }

    /**
     * These thirteen groups have no neck, and "Neck Curl" contains "curl", so it came out as biceps.
     * A blank is the only honest answer: the table prefers a blank to a wrong muscle everywhere else,
     * and an exercise the vocabulary cannot express is exactly where that has to hold.
     */
    @Test
    fun anExerciseTheVocabularyCannotExpressAttributesNothing() {
        assertTrue(MuscleAttribution.muscles("Neck Curl").isEmpty())
        assertTrue(MuscleAttribution.muscles("Neck Extension").isEmpty())
        assertTrue(MuscleAttribution.muscles("Weighted Neck Harness").isEmpty())
        assertEquals(listOf(MuscleGroup.BICEPS), MuscleAttribution.muscles("Bicep Curl"))
    }

    /**
     * Hevy writes it as one word. A rule that only matches the spaced spelling silently attributes
     * nothing for the spelling the catalogue actually uses, which reads as an unknown lift.
     */
    @Test
    fun skullcrusherMatchesBothSpellings() {
        assertEquals(listOf(MuscleGroup.TRICEPS), MuscleAttribution.muscles("Skullcrusher (Barbell)"))
        assertEquals(listOf(MuscleGroup.TRICEPS), MuscleAttribution.muscles("Skull Crusher"))
    }

    /** Equipment parentheses, hyphens and case must not change the answer. */
    @Test
    fun normalisationIgnoresEquipmentPunctuationAndCase() {
        val expected = listOf(MuscleGroup.CHEST, MuscleGroup.TRICEPS)
        for (spelling in listOf(
            "Bench Press", "bench press", "Bench Press (Barbell)",
            "BENCH-PRESS", "Bench  Press   (Smith Machine)",
        )) {
            assertEquals(spelling, expected, MuscleAttribution.muscles(spelling))
        }
    }

    /**
     * An unrecognised lift attributes NOTHING. A wrong muscle is worse than a blank one: the blank
     * invites a look, the wrong one does not.
     */
    @Test
    fun anUnknownExerciseAttributesNothing() {
        assertTrue(MuscleAttribution.muscles("Kettlebell Flow").isEmpty())
        assertTrue(MuscleAttribution.muscles("").isEmpty())
        assertTrue(MuscleAttribution.muscles("   ").isEmpty())
        assertTrue(MuscleAttribution.muscles("???").isEmpty())
    }

    /**
     * Every rule must map to at least one group, and every needle must already be normalised - a rule
     * that is not would sit there matching nothing and look like an unknown lift.
     */
    @Test
    fun everyRuleIsWellFormed() {
        assertFalse(MuscleAttribution.rules.isEmpty())
        for ((needle, groups) in MuscleAttribution.rules) {
            assertFalse(needle.isEmpty())
            assertEquals(needle, MuscleAttribution.normalise(needle))
            assertFalse("rule '$needle' attributes nothing", groups.isEmpty())
        }
    }

    /**
     * Guards the ordering property itself rather than individual pairs: if a rule's needle contains
     * an earlier rule's needle, the earlier one wins and the later is dead.
     *
     * What it does NOT catch: two rules whose needles do not contain each other, where a real title
     * contains BOTH. "rear delt" and "fly" are disjoint, yet "Rear Delt Fly" matches whichever comes
     * first - and it came out as chest until an example test was written for it. The example test
     * above is the guard for that class; this one cannot be.
     */
    @Test
    fun noRuleIsShadowedByAnEarlierOne() {
        val rules = MuscleAttribution.rules
        for ((i, later) in rules.withIndex()) {
            for (earlier in rules.subList(0, i)) {
                assertFalse(
                    "'${later.first}' is unreachable: '${earlier.first}' matches it first",
                    later.first.contains(earlier.first),
                )
            }
        }
    }

    /**
     * The parity guard. The Swift table is the source of truth and the order IS the logic, so this
     * pins the row count and a handful of positions: a rule inserted or moved on one platform and not
     * the other changes an attribution silently, and nothing else in either suite would notice.
     */
    @Test
    fun theRuleTableMatchesTheSwiftSourceOfTruth() {
        assertEquals(66, MuscleAttribution.rules.size)
        assertEquals("leg curl", MuscleAttribution.rules.first().first)
        assertEquals("russian twist", MuscleAttribution.rules.last().first)
        val order = MuscleAttribution.rules.map { it.first }
        for ((specific, generic) in listOf(
            "leg curl" to "curl", "wrist" to "curl", "nordic curl" to "curl",
            "rear delt" to "fly", "reverse fly" to "fly", "upright row" to "row",
            "romanian deadlift" to "deadlift", "hack squat" to "squat", "chest fly" to "fly",
        )) {
            assertTrue(
                "'$specific' must be ordered before '$generic'",
                order.indexOf(specific) < order.indexOf(generic),
            )
        }
    }
}
