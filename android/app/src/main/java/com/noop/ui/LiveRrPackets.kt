package com.noop.ui

import com.noop.ble.LiveState
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.mapNotNull

/**
 * The one way to consume live R-R packets: key on [LiveState.rrSeq], deliver [LiveState.rr]. Keying
 * on the `rr` value instead silently drops a second identical consecutive packet — lost real beats
 * for anything that accumulates successive differences (spot HRV, Breathe's session RMSSD). Filters
 * empty packets. Removes the value-equality drop, not StateFlow conflation. Twin of Swift
 * `View.onRRPackets`.
 */
fun Flow<LiveState>.rrPackets(): Flow<List<Int>> =
    map { it.rrSeq to it.rr }
        .distinctUntilChanged()
        .mapNotNull { (_, rr) -> rr.takeIf { it.isNotEmpty() } }
