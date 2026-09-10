package com.noop.analytics

/**
 * WHOOP-style step-day boundaries. A physiological step day starts at the onset of the main sleep
 * and ends at the next main-sleep onset; the delta is still attributed to the later counter sample.
 * We deliberately do not mask the sleep span: a real walk during a long night-time wake remains a
 * walk, while the shared activity-class and tick-rate gates continue to reject non-locomotion.
 */
object PhysiologicalSteps {

    enum class SleepKind { MAIN_SLEEP, NAP, UNCLASSIFIED }

    data class SleepBlock(
        val onset: Long,
        val end: Long,
        /** Stable identity lets a user-edited onset move an existing boundary instead of adding one. */
        val id: String = onset.toString(),
        val editedOnset: Long? = null,
        val kind: SleepKind = SleepKind.UNCLASSIFIED,
    ) {
        val effectiveOnset: Long get() = editedOnset ?: onset
    }

    /** The one open physiological cycle. Absence of a newly detected night never creates a calendar cycle. */
    data class CycleBoundary(val sleepId: String, val onset: Long)

    data class CycleWindow(val sleepId: String, val onset: Long, val endExclusive: Long)

    data class OwnerSegment(val owner: String, val onset: Long, val endExclusive: Long)
    data class OwnerCoverage(
        val owner: String,
        val onset: Long,
        val endExclusive: Long,
        val priority: Int,
    )

    fun shouldReadCounterPredecessor(segmentIndex: Int): Boolean = segmentIndex == 0

    private const val MIN_MAIN_SLEEP_SECONDS = 3 * 3_600L


    /**
     * Apply the same user-visible main-vs-nap shape used by the sleep surfaces: only the canonical overnight
     * group can be MAIN, it must total at least three hours, and every other/twinless-explicit block is NAP.
     */
    fun classifyForCycle(
        blocks: List<SleepBlock>,
        tzOffsetSeconds: Long,
        habitualMidsleepSec: Long?,
    ): List<SleepBlock> {
        if (blocks.isEmpty()) return emptyList()
        val explicitMain = blocks.indices.filter { blocks[it].kind == SleepKind.MAIN_SLEEP }
        val selectable = blocks.indices.filter { blocks[it].kind != SleepKind.NAP }
        val selectedOriginalIndices = if (explicitMain.isNotEmpty()) {
            explicitMain
        } else {
            val selectableNightBlocks = selectable.map {
                val b = blocks[it]
                SleepStageTotals.NightBlock(b.effectiveOnset, b.end)
            }
            // Eliminate nap-shaped GROUPS before choosing a winner. Otherwise a six-hour afternoon nap can
            // win the generic duration scorer, fail the daytime guard, and hide a valid shorter night.
            val eligible = SleepStageTotals.bridgedNightGroups(selectableNightBlocks, tzOffsetSeconds)
                .filter { group ->
                    val total = group.indices.sumOf { i -> selectableNightBlocks[i].durationS.coerceAtLeast(0L) }
                    val onset = group.indices.minOfOrNull { selectableNightBlocks[it].start }
                    total >= MIN_MAIN_SLEEP_SECONDS && onset != null &&
                        SleepStageTotals.isOvernightOnset(onset, tzOffsetSeconds)
                }
                .flatMap { it.indices }
                .distinct()
            SleepStageTotals.mainNightGroupIndices(
                eligible.map { selectableIndex ->
                    val original = selectable[selectableIndex]
                    val b = blocks[original]
                    SleepStageTotals.NightBlock(b.effectiveOnset, b.end)
                },
                tzOffsetSeconds,
                habitualMidsleepSec,
            ).orEmpty().map { selectedIndex ->
                selectable[eligible[selectedIndex]]
            }
        }.toHashSet()
        return blocks.mapIndexed { index, block ->
            block.copy(kind = if (index in selectedOriginalIndices) SleepKind.MAIN_SLEEP else SleepKind.NAP)
        }
    }

    /** Use the exact same main-night/group selector as the Sleep screen and daily sleep aggregate. */
    fun mainSleepOnset(
        blocks: List<SleepBlock>,
        tzOffsetSeconds: Long,
        habitualMidsleepSec: Long?,
    ): Long? {
        val eligible = classifyForCycle(blocks, tzOffsetSeconds, habitualMidsleepSec)
            .filter { it.kind == SleepKind.MAIN_SLEEP }
        val indices = SleepStageTotals.mainNightGroupIndices(
            eligible.map { SleepStageTotals.NightBlock(it.effectiveOnset, it.end) },
            tzOffsetSeconds,
            habitualMidsleepSec,
        ) ?: return null
        return indices.minOfOrNull { eligible[it].effectiveOnset }
    }

    /**
     * Build historical sleep-to-sleep windows without inventing rows at midnight. The final observed
     * boundary alone owns the open tail to [now], including days on which no new sleep was detected.
     */
    fun cycleWindows(boundaries: List<CycleBoundary>, now: Long): List<CycleWindow> {
        val ordered = boundaries.asSequence()
            .filter { it.onset <= now }
            .distinctBy { it.sleepId }
            .sortedBy { it.onset }
            .toList()
        return ordered.mapIndexedNotNull { index, boundary ->
            val end = ordered.getOrNull(index + 1)?.onset ?: now
            if (end <= boundary.onset) null else CycleWindow(boundary.sleepId, boundary.onset, end)
        }
    }

    /** Split at local midnights and merge adjacent same-owner slices; counters never cross device seams. */
    fun ownerSegments(
        window: CycleWindow,
        ownerByDay: Map<String, String>,
        tzOffsetSeconds: Long,
        fallbackOwner: String,
    ): List<OwnerSegment> {
        if (window.endExclusive <= window.onset) return emptyList()
        val out = ArrayList<OwnerSegment>()
        var cursor = window.onset
        var lastOwner = fallbackOwner
        while (cursor < window.endExclusive) {
            val day = AnalyticsEngine.dayString(cursor, tzOffsetSeconds)
            val local = cursor + tzOffsetSeconds
            val dayNumber = Math.floorDiv(local, SleepStageTotals.SECONDS_PER_DAY)
            val dayStart = dayNumber * SleepStageTotals.SECONDS_PER_DAY - tzOffsetSeconds
            // The sleep-owner owns the partial onset day. Calendar owner changes take effect only at a
            // midnight seam, never retroactively before the boundary sleep began.
            val owner = if (cursor == window.onset && cursor > dayStart) {
                fallbackOwner
            } else {
                ownerByDay[day] ?: lastOwner
            }
            val nextMidnight = (dayNumber + 1) * SleepStageTotals.SECONDS_PER_DAY - tzOffsetSeconds
            val end = minOf(window.endExclusive, nextMidnight)
            val previous = out.lastOrNull()
            if (previous != null && previous.owner == owner && previous.endExclusive == cursor) {
                out[out.lastIndex] = previous.copy(endExclusive = end)
            } else {
                out += OwnerSegment(owner, cursor, end)
            }
            lastOwner = owner
            cursor = end
        }
        return out
    }

    /**
     * Timestamp coverage wins at every seam; priority resolves overlap, so two worn straps never add.
     * Each coverage is a continuous first..last ownership span by design: an internal sample/radio gap
     * creates no seam and therefore cannot hand the interval to a lower-priority concurrently worn strap.
     */
    fun ownerSegmentsFromCoverage(
        window: CycleWindow,
        coverage: List<OwnerCoverage>,
        fallbackOwner: String,
    ): List<OwnerSegment> {
        if (window.endExclusive <= window.onset) return emptyList()
        val clipped = coverage.mapNotNull {
            val start = maxOf(window.onset, it.onset)
            val end = minOf(window.endExclusive, it.endExclusive)
            if (end <= start) null else it.copy(onset = start, endExclusive = end)
        }
        val seams = buildSet {
            add(window.onset)
            add(window.endExclusive)
            clipped.forEach { add(it.onset); add(it.endExclusive) }
        }.sorted()
        val out = ArrayList<OwnerSegment>()
        var lastOwner = fallbackOwner
        for (i in 0 until seams.lastIndex) {
            val start = seams[i]
            val end = seams[i + 1]
            val owner = clipped.asSequence()
                .filter { start >= it.onset && start < it.endExclusive }
                .minWithOrNull(compareBy<OwnerCoverage> { it.priority }.thenBy { it.owner })
                ?.owner ?: lastOwner
            val previous = out.lastOrNull()
            if (previous != null && previous.owner == owner && previous.endExclusive == start) {
                out[out.lastIndex] = previous.copy(endExclusive = end)
            } else {
                out += OwnerSegment(owner, start, end)
            }
            lastOwner = owner
        }
        return out
    }

    /** Resolve the next observed onset, or [now] for the currently open physiological cycle. */
    fun cycleEnd(day: String, onsetByDay: Map<String, Long>, now: Long): Long {
        val onset = onsetByDay[day] ?: return now
        return onsetByDay.values.asSequence()
            .filter { it > onset && it <= now }
            .minOrNull()
            ?: now
    }

}
