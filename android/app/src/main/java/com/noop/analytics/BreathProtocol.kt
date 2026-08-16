package com.noop.analytics

/*
 * BreathProtocol.kt — content-driven breath sessions (stages + catalog + player).
 * Created: 2026-08-16
 * Last updated: 2026-08-16
 *
 * Faithful Kotlin mirror of StrandAnalytics BreathProtocol*.swift — keep schedules
 * byte-identical (golden-vector tests).
 */

enum class BreathProtocolMode {
    PLAYABLE,
    GUIDED,
}

enum class BreathProtocolCategory {
    ANS,
    PRESENCE,
    BIOFEEDBACK,
}

data class BreathStage(
    val type: BreathPhase,
    val durationMs: Int,
    val label: String? = null,
) {
    init {
        require(durationMs >= 0)
    }
}

data class BreathProtocol(
    val id: String,
    val title: String,
    val subtitle: String,
    val edu: String,
    val caution: String? = null,
    val sessionHint: String? = null,
    val mode: BreathProtocolMode,
    val category: BreathProtocolCategory,
    val recommendedDurationMs: Int,
    val stages: List<BreathStage> = emptyList(),
) {
    val cycleDurationMs: Int get() = stages.sumOf { it.durationMs }
}

object BreathProtocolPlayer {
    const val HOLD_LOOPS: Int = 0
    const val TEXT_ONLY_LOOPS: Int = 0

    fun loops(forPhase: BreathPhase): Int = when (forPhase) {
        BreathPhase.INHALE -> BreathPacer.INHALE_LOOPS
        BreathPhase.EXHALE -> BreathPacer.EXHALE_LOOPS
        BreathPhase.HOLD, BreathPhase.TEXT_ONLY -> 0
    }

    fun schedule(proto: BreathProtocol, sessionMs: Int): List<BreathCue> {
        if (proto.mode != BreathProtocolMode.PLAYABLE) return emptyList()
        if (sessionMs < 1) return emptyList()
        val stages = proto.stages.filter { it.durationMs > 0 }
        if (stages.isEmpty()) return emptyList()
        val cycleMs = stages.sumOf { it.durationMs }
        if (cycleMs <= 0) return emptyList()

        val out = ArrayList<BreathCue>()
        var base = 0
        var guardCycles = 0
        val maxCycles = maxOf(1, (sessionMs / cycleMs) + 2)
        while (base < sessionMs && guardCycles < maxCycles) {
            var offset = base
            for (stage in stages) {
                if (offset >= sessionMs) break
                out.add(
                    BreathCue(
                        offsetMs = offset,
                        phase = stage.type,
                        loops = loops(stage.type),
                        label = stage.label,
                    ),
                )
                offset += stage.durationMs
            }
            base += cycleMs
            guardCycles += 1
        }
        return out
    }
}
