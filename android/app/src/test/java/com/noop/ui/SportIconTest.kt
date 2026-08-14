package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/** Pins the per-sport iconography (parity with the iOS SportIcon catalogue): sports that used to fall
 *  back to the generic dumbbell now resolve to their own Material glyph, and free-typed / auto-detected
 *  labels still resolve via the fuzzy matcher. Compares ImageVector.name (stable "Filled.X"). */
class SportIconTest {

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
