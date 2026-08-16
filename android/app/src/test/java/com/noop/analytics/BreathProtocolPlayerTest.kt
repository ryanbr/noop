package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Golden vectors for content-driven breath protocols (holds + Presence tempos).
 * Fixtures mirror BreathProtocolPlayerTests.swift for cross-platform parity.
 */
class BreathProtocolPlayerTest {

    @Test
    fun test_box_one_cycle_cues() {
        val proto = BreathProtocolCatalog.protocolById("box_4_4_4_4")!!
        val cues = BreathProtocolPlayer.schedule(proto, sessionMs = 16_000)
        assertEquals(
            listOf(
                BreathCue(0, BreathPhase.INHALE, 1),
                BreathCue(4_000, BreathPhase.HOLD, 0),
                BreathCue(8_000, BreathPhase.EXHALE, 2),
                BreathCue(12_000, BreathPhase.HOLD, 0),
            ),
            cues,
        )
    }

    @Test
    fun test_deep_and_478() {
        val deep = BreathProtocolCatalog.protocolById("deep_4_2_6")!!
        assertEquals(
            listOf(
                BreathCue(0, BreathPhase.INHALE, 1),
                BreathCue(4_000, BreathPhase.HOLD, 0),
                BreathCue(6_000, BreathPhase.EXHALE, 2),
            ),
            BreathProtocolPlayer.schedule(deep, sessionMs = 12_000),
        )
        val fse = BreathProtocolCatalog.protocolById("four_seven_eight")!!
        val cues = BreathProtocolPlayer.schedule(fse, sessionMs = 19_000)
        assertEquals(listOf(0, 4_000, 11_000), cues.map { it.offsetMs })
        assertEquals(
            listOf(BreathPhase.INHALE, BreathPhase.HOLD, BreathPhase.EXHALE),
            cues.map { it.phase },
        )
    }

    @Test
    fun test_nadi_labels_and_cycle() {
        val proto = BreathProtocolCatalog.protocolById("nadi_shodhana")!!
        assertEquals(24_000, proto.cycleDurationMs)
        val cues = BreathProtocolPlayer.schedule(proto, sessionMs = 24_000)
        assertEquals(6, cues.size)
        assertEquals("Inhale left", cues[0].label)
        assertEquals("Exhale right", cues[2].label)
        assertEquals("Exhale left", cues[5].label)
    }

    @Test
    fun test_presence_regular_and_punching() {
        val reg = BreathProtocolCatalog.protocolById("presence_regular")!!
        val cues = BreathProtocolPlayer.schedule(reg, sessionMs = 7_600)
        assertEquals(
            listOf(
                BreathCue(0, BreathPhase.INHALE, 1),
                BreathCue(3_800, BreathPhase.EXHALE, 2),
            ),
            cues,
        )
        val punch = BreathProtocolCatalog.protocolById("presence_punching")!!
        assertEquals(3_800, punch.cycleDurationMs)
        val pc = BreathProtocolPlayer.schedule(punch, sessionMs = 3_800)
        assertEquals(BreathPhase.INHALE, pc.first().phase)
        assertEquals(1_900, pc[1].offsetMs)
    }

    @Test
    fun test_guided_schedules_empty() {
        for (id in listOf("kapalabhati", "holotropic", "wim_hof", "shamanic")) {
            val proto = BreathProtocolCatalog.protocolById(id)!!
            assertEquals(BreathProtocolMode.GUIDED, proto.mode)
            assertTrue(BreathProtocolPlayer.schedule(proto, sessionMs = 60_000).isEmpty())
        }
    }

    @Test
    fun test_catalog_contains_expected_ids() {
        val ids = BreathProtocolCatalog.all.map { it.id }.toSet()
        for (need in listOf(
            "relax_4_6",
            "coherence_5_5",
            "box_4_4_4_4",
            "presence_regular",
            "presence_mid",
            "presence_punching",
            "coherent_6_6",
            "wim_hof",
        )) {
            assertTrue("missing $need", ids.contains(need))
        }
    }
}
