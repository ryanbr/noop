package com.noop.protocol

/**
 * Whether a historical record's layout version is one this platform has NO field map for, and so should be
 * reported to the user as undecodable. Kotlin twin of the Swift `historicalLayoutIsUnmapped`.
 *
 * #1992. The old form of this question listed the signature field of every mapped layout and warned when a
 * record carried none of them: `heart_rate`, then `gravity_x` once v25 was mapped, then `ppg_waveform` once
 * v26 was. A list like that has to be extended by hand every time NOOP learns a layout, and twice it
 * silently was not. #156 was v25 and v26 being reported as undecodable after they had been decoding for
 * releases.
 *
 * On WHOOP 5.0/MG the question is asked of [MAPPED_WHOOP5_HISTORICAL_VERSIONS], the set this platform's
 * decoder dispatches on. Note that set is DELIBERATELY narrower here than Swift's: Android has no v20/v21
 * historical branch, so a v20 record genuinely is undecodable on this side and genuinely should be
 * reported. The two platforms answering differently for v20 is correct, and is the divergence itself
 * rather than a bug in this function.
 *
 * WHOOP 4.0 keeps the field test. There is no equivalent dispatch set on that side, and every layout it
 * does map emits one of the three names.
 */
fun historicalLayoutIsUnmapped(
    version: Int,
    family: DeviceFamily,
    hasHeartRate: Boolean,
    hasGravity: Boolean,
    hasPpgWaveform: Boolean,
): Boolean = when (family) {
    DeviceFamily.WHOOP5 -> version !in MAPPED_WHOOP5_HISTORICAL_VERSIONS
    DeviceFamily.WHOOP4 -> !hasHeartRate && !hasGravity && !hasPpgWaveform
}

/**
 * The offload frontier: how far through the strap's banked history NOOP has got, as a unix time. Twin of
 * the Swift `offloadFrontier`.
 *
 * #1992. This used to be the newest HR row alone. A record in a layout with no field map on this platform
 * is archived and acked but becomes no rows, so on a strap whose NEWEST records are one of those the row
 * frontier can never reach the strap's newest banked record. The auto-continue gate measures its backlog as
 * `strapNewest - frontier`, so the gap stayed open, the gate kept answering "backlog remains", and the
 * offload re-kicked to its cap on every connection: real radio and decode cost, for records already
 * consumed.
 *
 * [consumedTo] is the section-end time of the last acked chunk, which comes from the HISTORY_END metadata
 * and is therefore independent of what the records inside it decoded to.
 *
 * Taking the LATER of the two is what makes this safe. It can only ever close a gap, never open one, so a
 * strap that genuinely has backlog is unaffected: its acked sections end behind its newest banked record by
 * definition, and the row frontier still speaks for everything that did decode.
 */
fun offloadFrontier(rowFrontier: Long?, consumedTo: Long?): Long? = when {
    rowFrontier == null -> consumedTo
    consumedTo == null -> rowFrontier
    else -> maxOf(rowFrontier, consumedTo)
}
