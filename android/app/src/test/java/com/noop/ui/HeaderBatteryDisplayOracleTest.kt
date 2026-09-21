package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins [HeaderBatteryDisplay.resolve] against the iOS `LiquidTodayView.StrapBatteryDisplay.resolve` twin
 * BY ORACLE: the expected lines below are the verbatim stdout of the Swift enum compiled standalone
 * (`swiftc -O twin.swift main.swift`) over the same grid — every `activeIsWhoop` × `connected` × strap %
 * × ring % combination, with the strap's charging bit at nil and the ring's at false, which the Android
 * ring never drew. `pct` prints as a Swift Double (`0.0`, `72.4`), matched by Kotlin's `Double.toString`.
 * Regenerate the literal from the Swift side; never edit it to make this pass.
 */
class HeaderBatteryDisplayOracleTest {

    private fun show(s: HeaderBatteryDisplay.State): String = when (s) {
        HeaderBatteryDisplay.State.Offline -> "Offline"
        HeaderBatteryDisplay.State.Pending -> "Pending"
        HeaderBatteryDisplay.State.NotActiveDevice -> "NotActiveDevice"
        is HeaderBatteryDisplay.State.Charge -> "Charge(pct:${s.pct},isRing:${s.isRing})"
    }

    private val expected = listOf(
        "true true nil nil -> Pending",
        "true true nil 0 -> Pending",
        "true true nil 93 -> Pending",
        "true true 0.0 nil -> Charge(pct:0.0,isRing:false)",
        "true true 0.0 0 -> Charge(pct:0.0,isRing:false)",
        "true true 0.0 93 -> Charge(pct:0.0,isRing:false)",
        "true true 11.0 nil -> Charge(pct:11.0,isRing:false)",
        "true true 11.0 0 -> Charge(pct:11.0,isRing:false)",
        "true true 11.0 93 -> Charge(pct:11.0,isRing:false)",
        "true true 72.4 nil -> Charge(pct:72.4,isRing:false)",
        "true true 72.4 0 -> Charge(pct:72.4,isRing:false)",
        "true true 72.4 93 -> Charge(pct:72.4,isRing:false)",
        "true true 100.0 nil -> Charge(pct:100.0,isRing:false)",
        "true true 100.0 0 -> Charge(pct:100.0,isRing:false)",
        "true true 100.0 93 -> Charge(pct:100.0,isRing:false)",
        "true false nil nil -> Offline",
        "true false nil 0 -> Offline",
        "true false nil 93 -> Offline",
        "true false 0.0 nil -> Offline",
        "true false 0.0 0 -> Offline",
        "true false 0.0 93 -> Offline",
        "true false 11.0 nil -> Offline",
        "true false 11.0 0 -> Offline",
        "true false 11.0 93 -> Offline",
        "true false 72.4 nil -> Offline",
        "true false 72.4 0 -> Offline",
        "true false 72.4 93 -> Offline",
        "true false 100.0 nil -> Offline",
        "true false 100.0 0 -> Offline",
        "true false 100.0 93 -> Offline",
        "false true nil nil -> NotActiveDevice",
        "false true nil 0 -> Charge(pct:0.0,isRing:true)",
        "false true nil 93 -> Charge(pct:93.0,isRing:true)",
        "false true 0.0 nil -> NotActiveDevice",
        "false true 0.0 0 -> Charge(pct:0.0,isRing:true)",
        "false true 0.0 93 -> Charge(pct:93.0,isRing:true)",
        "false true 11.0 nil -> NotActiveDevice",
        "false true 11.0 0 -> Charge(pct:0.0,isRing:true)",
        "false true 11.0 93 -> Charge(pct:93.0,isRing:true)",
        "false true 72.4 nil -> NotActiveDevice",
        "false true 72.4 0 -> Charge(pct:0.0,isRing:true)",
        "false true 72.4 93 -> Charge(pct:93.0,isRing:true)",
        "false true 100.0 nil -> NotActiveDevice",
        "false true 100.0 0 -> Charge(pct:0.0,isRing:true)",
        "false true 100.0 93 -> Charge(pct:93.0,isRing:true)",
        "false false nil nil -> NotActiveDevice",
        "false false nil 0 -> Charge(pct:0.0,isRing:true)",
        "false false nil 93 -> Charge(pct:93.0,isRing:true)",
        "false false 0.0 nil -> NotActiveDevice",
        "false false 0.0 0 -> Charge(pct:0.0,isRing:true)",
        "false false 0.0 93 -> Charge(pct:93.0,isRing:true)",
        "false false 11.0 nil -> NotActiveDevice",
        "false false 11.0 0 -> Charge(pct:0.0,isRing:true)",
        "false false 11.0 93 -> Charge(pct:93.0,isRing:true)",
        "false false 72.4 nil -> NotActiveDevice",
        "false false 72.4 0 -> Charge(pct:0.0,isRing:true)",
        "false false 72.4 93 -> Charge(pct:93.0,isRing:true)",
        "false false 100.0 nil -> NotActiveDevice",
        "false false 100.0 0 -> Charge(pct:0.0,isRing:true)",
        "false false 100.0 93 -> Charge(pct:93.0,isRing:true)",
    )

    @Test fun `resolve matches the Swift twin over the whole grid`() {
        val strap = listOf<Double?>(null, 0.0, 11.0, 72.4, 100.0)
        val ring = listOf<Int?>(null, 0, 93)
        val actual = mutableListOf<String>()
        for (w in listOf(true, false)) for (c in listOf(true, false)) for (s in strap) for (r in ring) {
            val d = HeaderBatteryDisplay.resolve(activeIsWhoop = w, connected = c, strapPct = s, ringPct = r)
            actual += "$w $c ${s ?: "nil"} ${r ?: "nil"} -> ${show(d)}"
        }
        assertEquals(expected.joinToString("\n"), actual.joinToString("\n"))
    }

    // MARK: the cases #2208 / #2216 were about, named so a failure reads as the regression it is

    /** Hiding the strap's number under a ring was right; hiding the RING's was only ever a limitation of
     *  the control. A ring that has reported its charge this link is drawn as the ring's. */
    @Test fun `ring active draws the ring's own charge, not the strap's stale one`() {
        assertEquals(HeaderBatteryDisplay.State.Charge(93.0, isRing = true),
            HeaderBatteryDisplay.resolve(activeIsWhoop = false, connected = true, strapPct = 72.4, ringPct = 93))
    }

    /** `ouraBatteryPct` is null with no live ring source (#2075), so a generic strap or a machine — which
     *  never write it — keep the control off the header exactly as before. */
    @Test fun `ring active with no ring charge yet is still not drawn`() {
        assertEquals(HeaderBatteryDisplay.State.NotActiveDevice,
            HeaderBatteryDisplay.resolve(activeIsWhoop = false, connected = true, strapPct = 72.4, ringPct = null))
    }

    /** A not-active answer is not an offline answer: the strap that IS active and disconnected is offline,
     *  a real claim worth making; a strap that is not the active device says nothing. */
    @Test fun `not active is not the same answer as offline`() {
        assertEquals(HeaderBatteryDisplay.State.Offline,
            HeaderBatteryDisplay.resolve(activeIsWhoop = true, connected = false, strapPct = 72.0, ringPct = null))
        assertEquals(HeaderBatteryDisplay.State.NotActiveDevice,
            HeaderBatteryDisplay.resolve(activeIsWhoop = false, connected = true, strapPct = 72.0, ringPct = null))
    }
}
