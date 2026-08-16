package com.noop.analytics

/*
 * BreathProtocolCatalog.kt – mirror of Swift catalog.
 * Created: 2026-08-16
 * Last updated: 2026-08-16
 *
 * Technique list/timings inspired by publicly documented ANS breath protocols
 * (e.g. https://www.ultrahuman.com/blog/harness-the-power-of-breath-protocols-for-your-autonomic-nervous-system/)
 * and measured Presence Process guide tempos. Copy is original NOOP wording (non-clinical).
 */

object BreathProtocolCatalog {

    const val presenceIntroTitle: String = "The Presence Process"

    val presenceIntroBody: String = """
Consciously Connected Breathing (CCB): inhale and exhale in one continuous loop with no hold at the top or bottom. Find a comfortable rhythm — connectedness matters more than intensity. Typical practice is about 15 minutes, twice daily. Regular is the sustainable starter tempo; Mid is a quicker start for later rounds; Punching Through is only when you need to push through drowsiness or stuckness (not a beginner default).
""".trimIndent()

    /** All catalog entries in picker order (legacy NOOP paces first, then ANS, then Presence). */
    val all: List<BreathProtocol> by lazy {
        legacyNoop + ansPlayable + ansGuided + presence
    }

    fun protocolById(id: String): BreathProtocol? = all.firstOrNull { it.id == id }

    /** Pace pills shown in Breathe (playable + guided). Resonance stays a separate UI case. */
    val pickerProtocols: List<BreathProtocol> get() = all

    val watchSubsetIds: List<String> = listOf(
        "relax_4_6",
        "coherence_5_5",
        "box_4_4_4_4",
        "deep_4_2_6",
        "four_seven_eight",
        "coherent_6_6",
        "presence_regular",
        "presence_mid",
        "presence_punching",
    )

    val watchSubset: List<BreathProtocol>
        get() = watchSubsetIds.mapNotNull { protocolById(it) }

    // MARK: - Legacy NOOP

    private val legacyNoop: List<BreathProtocol> = listOf(
        BreathProtocol(
            id = "relax_4_6",
            title = "Relax 4-6",
            subtitle = "Long exhale · downshift to rest",
            edu = "A simple calming pace: inhale for 4 seconds, exhale for 6. The longer exhale tends to favour a rest-and-digest feel. Use it when you want an easy downshift without holds.",
            sessionHint = "Try 5–10 minutes.",
            mode = BreathProtocolMode.PLAYABLE,
            category = BreathProtocolCategory.ANS,
            recommendedDurationMs = 5 * 60_000,
            stages = listOf(
                BreathStage(BreathPhase.INHALE, 4_000),
                BreathStage(BreathPhase.EXHALE, 6_000),
            ),
        ),
        BreathProtocol(
            id = "coherence_5_5",
            title = "Coherence 5.5",
            subtitle = "Equal breath · ~5.5 br/min coherence",
            edu = "Equal inhale and exhale at about 5.5 breaths per minute — a common coherence / resonance starting point. Steady, balanced pacing for settling heart-rate variability during a session.",
            sessionHint = "Try about 10 minutes.",
            mode = BreathProtocolMode.PLAYABLE,
            category = BreathProtocolCategory.ANS,
            recommendedDurationMs = 10 * 60_000,
            stages = listOf(
                BreathStage(BreathPhase.INHALE, 5_500),
                BreathStage(BreathPhase.EXHALE, 5_500),
            ),
        ),
    )

    // MARK: - ANS playable

    private val ansPlayable: List<BreathProtocol> = listOf(
        BreathProtocol(
            id = "box_4_4_4_4",
            title = "Box 4-4-4-4",
            subtitle = "Square breath · steady focus",
            edu = "Box (square) breathing: inhale, hold, exhale, hold — each for 4 seconds. A structured rhythm often used for focus and settling under stress. Sit comfortably and keep the counts even.",
            sessionHint = "About 5 minutes per session; repeat as needed.",
            mode = BreathProtocolMode.PLAYABLE,
            category = BreathProtocolCategory.ANS,
            recommendedDurationMs = 5 * 60_000,
            stages = listOf(
                BreathStage(BreathPhase.INHALE, 4_000),
                BreathStage(BreathPhase.HOLD, 4_000),
                BreathStage(BreathPhase.EXHALE, 4_000),
                BreathStage(BreathPhase.HOLD, 4_000),
            ),
        ),
        BreathProtocol(
            id = "deep_4_2_6",
            title = "Deep Breathing",
            subtitle = "Slow inhale · soft hold · long exhale",
            edu = "Deep breathing with a short pause: inhale 4s, hold 2s, exhale 6s. Breathe through the nose when you can, fill the lungs without forcing, and let the longer exhale slow you down.",
            sessionHint = "5–10 minutes daily is a common starting point.",
            mode = BreathProtocolMode.PLAYABLE,
            category = BreathProtocolCategory.ANS,
            recommendedDurationMs = 5 * 60_000,
            stages = listOf(
                BreathStage(BreathPhase.INHALE, 4_000),
                BreathStage(BreathPhase.HOLD, 2_000),
                BreathStage(BreathPhase.EXHALE, 6_000),
            ),
        ),
        BreathProtocol(
            id = "diaphragmatic_4_2_6",
            title = "Diaphragmatic",
            subtitle = "Belly breath · soft pause",
            edu = "Diaphragmatic (belly) breathing: expand the abdomen on the inhale more than the chest, optional short hold, then gently contract on the exhale. Same 4–2–6 timing as deep breathing, with attention on the diaphragm.",
            sessionHint = "5–10 minutes daily.",
            mode = BreathProtocolMode.PLAYABLE,
            category = BreathProtocolCategory.ANS,
            recommendedDurationMs = 5 * 60_000,
            stages = listOf(
                BreathStage(BreathPhase.INHALE, 4_000, label = "Belly in"),
                BreathStage(BreathPhase.HOLD, 2_000),
                BreathStage(BreathPhase.EXHALE, 6_000, label = "Belly out"),
            ),
        ),
        BreathProtocol(
            id = "nadi_shodhana",
            title = "Alternate Nostril",
            subtitle = "Nadi Shodhana · left/right cycle",
            edu = "Alternate-nostril breathing: inhale left, hold, exhale right, inhale right, hold, exhale left — about 4 seconds each step. Use a finger to gently close one nostril at a time. Labels cue which side; go at a calm pace.",
            sessionHint = "5–10 minutes.",
            mode = BreathProtocolMode.PLAYABLE,
            category = BreathProtocolCategory.ANS,
            recommendedDurationMs = 5 * 60_000,
            stages = listOf(
                BreathStage(BreathPhase.INHALE, 4_000, label = "Inhale left"),
                BreathStage(BreathPhase.HOLD, 4_000),
                BreathStage(BreathPhase.EXHALE, 4_000, label = "Exhale right"),
                BreathStage(BreathPhase.INHALE, 4_000, label = "Inhale right"),
                BreathStage(BreathPhase.HOLD, 4_000),
                BreathStage(BreathPhase.EXHALE, 4_000, label = "Exhale left"),
            ),
        ),
        BreathProtocol(
            id = "four_seven_eight",
            title = "4-7-8",
            subtitle = "Inhale 4 · hold 7 · exhale 8",
            edu = "Classic 4-7-8: quiet nasal inhale for 4, hold for 7, long mouth exhale for 8. Often used to wind down. Start with a few cycles; stop if you feel light-headed.",
            caution = "If you feel dizzy or uncomfortable, stop and breathe normally.",
            sessionHint = "A few minutes is enough; build gradually.",
            mode = BreathProtocolMode.PLAYABLE,
            category = BreathProtocolCategory.ANS,
            recommendedDurationMs = 5 * 60_000,
            stages = listOf(
                BreathStage(BreathPhase.INHALE, 4_000),
                BreathStage(BreathPhase.HOLD, 7_000),
                BreathStage(BreathPhase.EXHALE, 8_000),
            ),
        ),
        BreathProtocol(
            id = "buteyko",
            title = "Buteyko",
            subtitle = "Gentle nasal · light air hunger",
            edu = "Buteyko-style reduced breathing: small nasal inhale (~2.5s), relaxed nasal exhale (~3.5s), short comfortable hold (~3.5s). Keep it quiet and light — not a big gasp.",
            caution = "Stay in a comfortable range; never force breath holds.",
            sessionHint = "3–20 minutes, as comfortable.",
            mode = BreathProtocolMode.PLAYABLE,
            category = BreathProtocolCategory.ANS,
            recommendedDurationMs = 5 * 60_000,
            stages = listOf(
                BreathStage(BreathPhase.INHALE, 2_500),
                BreathStage(BreathPhase.EXHALE, 3_500),
                BreathStage(BreathPhase.HOLD, 3_500),
            ),
        ),
        BreathProtocol(
            id = "tummo",
            title = "Tummo",
            subtitle = "Forced exhale · holds · slow in/out",
            edu = "A paced Tummo-inspired cycle using mid-range timings: short forced exhale, empty hold, slow inhale, full hold, slow exhale. Advanced and intense — keep sessions short and stop if strained.",
            caution = "Advanced. Avoid if pregnant, cardiovascular issues, or unwell. Not medical advice.",
            sessionHint = "5–10 minutes unless experienced.",
            mode = BreathProtocolMode.PLAYABLE,
            category = BreathProtocolCategory.ANS,
            recommendedDurationMs = 5 * 60_000,
            stages = listOf(
                BreathStage(BreathPhase.EXHALE, 1_000, label = "Force out"),
                BreathStage(BreathPhase.HOLD, 10_000, label = "Hold empty"),
                BreathStage(BreathPhase.INHALE, 7_000),
                BreathStage(BreathPhase.HOLD, 15_000, label = "Hold full"),
                BreathStage(BreathPhase.EXHALE, 7_000),
            ),
        ),
        BreathProtocol(
            id = "ujjayi",
            title = "Ujjayi",
            subtitle = "Ocean breath · soft throat",
            edu = "Ujjayi (ocean) breath: slightly constrict the throat so the breath sounds like distant waves. Equal slow inhale and exhale through the nose (~4.5s each).",
            sessionHint = "5–15 minutes.",
            mode = BreathProtocolMode.PLAYABLE,
            category = BreathProtocolCategory.ANS,
            recommendedDurationMs = 10 * 60_000,
            stages = listOf(
                BreathStage(BreathPhase.INHALE, 4_500),
                BreathStage(BreathPhase.EXHALE, 4_500),
            ),
        ),
        BreathProtocol(
            id = "bhastrika",
            title = "Bhastrika",
            subtitle = "Forceful 1s in · 1s out",
            edu = "Bhastrika (bellows): forceful 1-second nasal inhale and exhale. Energising and intense. Keep rounds short and rest between them.",
            caution = "Stop if dizzy. Avoid with high blood pressure, pregnancy, or recent surgery unless cleared by a clinician.",
            sessionHint = "Short rounds only.",
            mode = BreathProtocolMode.PLAYABLE,
            category = BreathProtocolCategory.ANS,
            recommendedDurationMs = 5 * 60_000,
            stages = listOf(
                BreathStage(BreathPhase.INHALE, 1_000),
                BreathStage(BreathPhase.EXHALE, 1_000),
            ),
        ),
        BreathProtocol(
            id = "qigong",
            title = "Qi Gong Breath",
            subtitle = "Slow in · soft holds · slow out",
            edu = "Gentle Qi Gong-style pacing: inhale ~4.5s, optional short hold, exhale ~4.5s, optional short hold. Soft belly focus; no force.",
            sessionHint = "15–30 minutes is traditional; start shorter.",
            mode = BreathProtocolMode.PLAYABLE,
            category = BreathProtocolCategory.ANS,
            recommendedDurationMs = 15 * 60_000,
            stages = listOf(
                BreathStage(BreathPhase.INHALE, 4_500),
                BreathStage(BreathPhase.HOLD, 1_500),
                BreathStage(BreathPhase.EXHALE, 4_500),
                BreathStage(BreathPhase.HOLD, 1_500),
            ),
        ),
        BreathProtocol(
            id = "soma",
            title = "Soma",
            subtitle = "2s in · 2s out · rhythmic",
            edu = "Simple rhythmic connected pacing at 2 seconds in and 2 seconds out — useful when you want a steady musical-feel loop without holds.",
            sessionHint = "Often 20+ minutes; pick a length that fits.",
            mode = BreathProtocolMode.PLAYABLE,
            category = BreathProtocolCategory.ANS,
            recommendedDurationMs = 10 * 60_000,
            stages = listOf(
                BreathStage(BreathPhase.INHALE, 2_000),
                BreathStage(BreathPhase.EXHALE, 2_000),
            ),
        ),
        BreathProtocol(
            id = "buteyko_reduced",
            title = "Buteyko Reduced",
            subtitle = "Lighter · longer soft hold",
            edu = "Reduced Buteyko-style: ~2s gentle inhale, ~3s exhale, then a 3–5s hold with mild air hunger only. Stay relaxed in the face and shoulders.",
            caution = "Never push into panic or strong air hunger.",
            sessionHint = "15–20 minutes if comfortable.",
            mode = BreathProtocolMode.PLAYABLE,
            category = BreathProtocolCategory.ANS,
            recommendedDurationMs = 15 * 60_000,
            stages = listOf(
                BreathStage(BreathPhase.INHALE, 2_000),
                BreathStage(BreathPhase.EXHALE, 3_000),
                BreathStage(BreathPhase.HOLD, 4_000),
            ),
        ),
        BreathProtocol(
            id = "coherent_6_6",
            title = "Coherent 6-6",
            subtitle = "6s in · 6s out · ~5 br/min",
            edu = "Coherent breathing at six seconds in and six seconds out (~5 breaths per minute). A slow equal pace aimed at calm and HRV-friendly rhythm — estimate only, not a clinical reading.",
            sessionHint = "Start around 10 minutes.",
            mode = BreathProtocolMode.PLAYABLE,
            category = BreathProtocolCategory.ANS,
            recommendedDurationMs = 10 * 60_000,
            stages = listOf(
                BreathStage(BreathPhase.INHALE, 6_000),
                BreathStage(BreathPhase.EXHALE, 6_000),
            ),
        ),
    )

    // MARK: - ANS guided (timer + edu only)

    private val ansGuided: List<BreathProtocol> = listOf(
        BreathProtocol(
            id = "kapalabhati",
            title = "Kapalabhati",
            subtitle = "Guided · rapid belly pulses",
            edu = "Kapalabhati uses rapid, active belly exhales with passive inhales. Timing varies by person — this mode gives you a timer and coaching text only, not a forced metronome. Practice seated, short rounds, rest between.",
            caution = "Skip if pregnant, dizzy, or have uncontrolled hypertension. Stop if strained.",
            sessionHint = "Short rounds (about 30–60s) with rests.",
            mode = BreathProtocolMode.GUIDED,
            category = BreathProtocolCategory.ANS,
            recommendedDurationMs = 5 * 60_000,
            stages = emptyList(),
        ),
        BreathProtocol(
            id = "holotropic",
            title = "Holotropic",
            subtitle = "Guided · continuous connected",
            edu = "Holotropic-style work is continuous, often rapid connected breathing in a supported setting. NOOP only offers a session timer and education — not an auto-pacer — because intensity varies widely and is normally facilitated.",
            caution = "Not for DIY high-intensity sessions if you have trauma history, cardiovascular issues, or pregnancy without professional guidance.",
            sessionHint = "Traditional sessions are long; use a short timer here as a check-in only.",
            mode = BreathProtocolMode.GUIDED,
            category = BreathProtocolCategory.ANS,
            recommendedDurationMs = 15 * 60_000,
            stages = emptyList(),
        ),
        BreathProtocol(
            id = "wim_hof",
            title = "Wim Hof",
            subtitle = "Guided · rounds + holds",
            edu = "Wim Hof–style rounds typically use ~30 deeper breaths, then an empty hold, then a recovery inhale hold (~15s). Because holds and intensity are personal, this entry is guided: follow a trusted protocol you already know; NOOP times the session and shows reminders — it does not force breath holds.",
            caution = "Never practice in water or while driving. Stop if dizzy. Not medical advice.",
            sessionHint = "About 15 minutes for a few rounds.",
            mode = BreathProtocolMode.GUIDED,
            category = BreathProtocolCategory.ANS,
            recommendedDurationMs = 15 * 60_000,
            stages = emptyList(),
        ),
        BreathProtocol(
            id = "shamanic",
            title = "Shamanic Breath",
            subtitle = "Guided · rhythmic rapid",
            edu = "Shamanic-style rhythmic breathing is context-dependent and often facilitated. Use this as a quiet timer with education only — set your own safe intensity.",
            caution = "Prefer guided settings for intense practice.",
            sessionHint = "Pick a length that feels safe.",
            mode = BreathProtocolMode.GUIDED,
            category = BreathProtocolCategory.ANS,
            recommendedDurationMs = 10 * 60_000,
            stages = emptyList(),
        ),
    )

    // MARK: - Presence Process

    private val presence: List<BreathProtocol> = listOf(
        BreathProtocol(
            id = "presence_regular",
            title = "Presence Regular",
            subtitle = "CCB · ~3.8s / 3.8s · ~7.8 br/min",
            edu = "Regular tempo (~3.8s in / 3.8s out) is the default sustainable pace for a first pass and for staying the full 15 minutes.",
            sessionHint = "15 minutes, twice daily (Presence Process frame).",
            mode = BreathProtocolMode.PLAYABLE,
            category = BreathProtocolCategory.PRESENCE,
            recommendedDurationMs = 15 * 60_000,
            stages = listOf(
                BreathStage(BreathPhase.INHALE, 3_800),
                BreathStage(BreathPhase.EXHALE, 3_800),
            ),
        ),
        BreathProtocol(
            id = "presence_mid",
            title = "Presence Mid",
            subtitle = "CCB · ~2.4s / 2.4s · ~12.4 br/min",
            edu = "Mid session tempo (~2.4s / 2.4s) is a starting pace for later passes through the procedure; once settled you may slow deeper or switch to Punching Through.",
            sessionHint = "15 minutes once you are using Mid as your starter.",
            mode = BreathProtocolMode.PLAYABLE,
            category = BreathProtocolCategory.PRESENCE,
            recommendedDurationMs = 15 * 60_000,
            stages = listOf(
                BreathStage(BreathPhase.INHALE, 2_400),
                BreathStage(BreathPhase.EXHALE, 2_400),
            ),
        ),
        BreathProtocol(
            id = "presence_punching",
            title = "Presence Punching",
            subtitle = "CCB · ~1.9s / 1.9s · push-through",
            edu = "Punching Through (~1.9s / 1.9s) is for sleepiness or feeling stuck — not the beginner default. After you are \u201cin it\u201d, you may return to a slower, deeper connected breath.",
            caution = "Not recommended as a beginner default unless the goal is to overcome drowsiness.",
            sessionHint = "Up to 15 minutes; ease off if strained.",
            mode = BreathProtocolMode.PLAYABLE,
            category = BreathProtocolCategory.PRESENCE,
            recommendedDurationMs = 15 * 60_000,
            stages = listOf(
                BreathStage(BreathPhase.INHALE, 1_900),
                BreathStage(BreathPhase.EXHALE, 1_900),
            ),
        ),
    )
}
