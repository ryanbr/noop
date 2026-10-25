package com.noop.protocol

/**
 * How well this platform handles a historical record's layout version, for the strap-log line that tells a
 * user why their nights are not staging. Kotlin twin of the Swift `HistoricalLayoutSupport`.
 *
 * The negative cases are kept apart because they are different facts with different remedies, and the
 * single line that used to cover both stated one of them wrongly. See [historicalLayoutSupport].
 */
enum class HistoricalLayoutSupport {
    /** The layout decodes and the record carries a named signal NOOP scores from. */
    SUPPORTED,

    /**
     * The layout decodes, but this record carries no per-second heart rate and no motion, so a night made
     * only of these cannot be staged. What is missing is the meaning of the channels, not the layout.
     */
    DECODES_WITHOUT_NAMED_SIGNAL,

    /** This platform has no field map for the layout at all; the record does not decode. */
    UNMAPPED,

    /**
     * The layout decodes, carries no scoreable signal, AND its whole payload is persisted in a stream of
     * its own, so there is nothing missing and nothing for the user to report (#2847).
     *
     * This exists because the line for [DECODES_WITHOUT_NAMED_SIGNAL] asks the user to report the layout
     * on #1992, and for a layout NOOP decodes, stores and deliberately scores nothing from, that request
     * is for a report about working software. The MG ECG record is the case: it reaches NOOP only because
     * the user took a reading, it is banked whole in `ecgWaveformSample`, and #752 is what keeps anything
     * from being derived off it.
     *
     * WHAT THIS GIVES UP, stated rather than hidden: the staging half of the other line is true of these
     * records too, so a night made ONLY of them could not be staged and this case says nothing about
     * that. The trade is deliberate, because such a night does not occur: an ECG reading lasts at most the
     * strap's own ten minutes and the strap keeps banking its ordinary per-second records throughout, so a
     * real offload carrying ECG records carries v18 records as well.
     */
    DECODES_INTO_ITS_OWN_STREAM,
}

/**
 * The 5/MG layouts whose ENTIRE payload is persisted in a stream of its own, so a record of one is neither
 * unmapped nor missing anything. Only v16, the flash-banked ECG record (#2847): it is banked whole in
 * `ecgWaveformSample`, and it carries no per-second heart rate or motion to score.
 *
 * v26 is NOT here and must not be added. Its waveform is persisted the same way, but it also decodes
 * `ppg_waveform`, which the field test already counts as a named signal, so it answers SUPPORTED and needs
 * no special case. Keyed on the version rather than on a caller-supplied flag because the answer is a
 * property of the LAYOUT, which is the question this whole function asks. Swift twin:
 * `whoop5HistoricalVersionsWithOwnStream`.
 */
private val WHOOP5_HISTORICAL_VERSIONS_WITH_OWN_STREAM: Set<Int> = setOf(16)

/**
 * Classify a historical record's layout version. Twin of the Swift `historicalLayoutSupport`.
 *
 * #1992. This used to be one question, "did the record decode any of `heart_rate`, `gravity_x` or
 * `ppg_waveform`?", and one message, which said NOOP could not decode the layout. That is a list which has
 * to be extended by hand every time NOOP learns a layout, and twice it silently was not: #156 was v25 and
 * v26 being reported as undecodable after they had been decoding for releases.
 *
 * Simply suppressing the line for a mapped-but-unscoreable layout would be the wrong correction, because
 * the SECOND half of what it said is true: those records really do carry no heart rate or motion, and a
 * night made only of them really cannot be staged. So the question splits.
 *
 * Note [MAPPED_WHOOP5_HISTORICAL_VERSIONS] is DELIBERATELY narrower here than Swift's: Android has no
 * v20/v21 historical branch, so a v20 record genuinely does not decode on this side and genuinely is
 * UNMAPPED, where Swift answers DECODES_WITHOUT_NAMED_SIGNAL for the same version. The platforms differing
 * there is the divergence itself, not a bug in this function, and both sides pin their own answer.
 */
fun historicalLayoutSupport(
    version: Int,
    family: DeviceFamily,
    hasHeartRate: Boolean,
    hasGravity: Boolean,
    hasPpgWaveform: Boolean,
): HistoricalLayoutSupport {
    val carriesNamedSignal = hasHeartRate || hasGravity || hasPpgWaveform
    return when (family) {
        DeviceFamily.WHOOP5 ->
            if (version !in MAPPED_WHOOP5_HISTORICAL_VERSIONS) HistoricalLayoutSupport.UNMAPPED
            else if (carriesNamedSignal) HistoricalLayoutSupport.SUPPORTED
            else if (version in WHOOP5_HISTORICAL_VERSIONS_WITH_OWN_STREAM)
                HistoricalLayoutSupport.DECODES_INTO_ITS_OWN_STREAM
            else HistoricalLayoutSupport.DECODES_WITHOUT_NAMED_SIGNAL
        DeviceFamily.WHOOP4 ->
            if (carriesNamedSignal) HistoricalLayoutSupport.SUPPORTED else HistoricalLayoutSupport.UNMAPPED
    }
}
