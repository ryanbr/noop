package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/** Pins the per-sport iconography (parity with the iOS SportIcon catalogue): sports that used to fall
 *  back to the generic dumbbell now resolve to their own Material glyph, and free-typed / auto-detected
 *  labels still resolve via the fuzzy matcher. Compares ImageVector.name (stable "Filled.X"). */
class SportIconTest {

    /** #2260. Horseback Polo used to take the swimming-pool glyph, because the fuzzy matcher tested
     *  `contains("polo")` for water polo's sake. Water polo is matched exactly before the fuzzy runs,
     *  so the loose token only ever needed to catch the run-together free-text spelling. */
    @Test fun polo_doesNotTakeTheWaterPoloGlyph() {
        assertNotEquals(sportIcon("Water polo"), sportIcon("Polo"))
        assertEquals(sportIcon("Water polo"), sportIcon("waterpolo"))
    }

    /** #2260. Muay Thai was missing from a martial-arts token list that already had jiu, judo and
     *  karate, so it fell to the generic dumbbell while its neighbours resolved. */
    @Test fun muayThai_resolvesWithTheOtherMartialArts() {
        assertEquals(sportIcon("Judo"), sportIcon("Muay Thai"))
        assertEquals(sportIcon("Jiu jitsu"), sportIcon("Muay Thai"))
    }

    @Test fun formerlyGenericSports_nowHaveDistinctGlyphs() {
        val cases = mapOf(
            "Rugby" to "Filled.SportsRugby",
            "Ice Hockey" to "Filled.SportsHockey",
            "Field hockey" to "Filled.SportsHockey",
            "Lacrosse" to "Filled.SportsHockey",
            "Handball" to "Filled.SportsHandball",
            "Cricket" to "Filled.SportsCricket",
            "Surfing" to "Filled.Surfing",
            "Kayaking" to "Filled.Kayaking",
            "Sailing" to "Filled.Sailing",
            "Scuba diving" to "Filled.ScubaDiving",
            "Ice skating" to "Filled.IceSkating",
            "Inline skating" to "Filled.Skateboarding",
            "Snowshoeing" to "Filled.Snowshoeing",
            "Hiking" to "Filled.Hiking",
            "American football" to "Filled.SportsFootball",
        )
        cases.forEach { (sport, icon) -> assertEquals(sport, icon, sportIcon(sport).name) }
    }

    @Test fun freeTypedLabels_resolveViaFuzzy() {
        assertEquals("Filled.SportsRugby", sportIcon("touch rugby").name)
        assertEquals("Filled.SportsHockey", sportIcon("field hockey scrimmage").name)
        assertEquals("Filled.Surfing", sportIcon("dawn surf session").name)
    }
}
