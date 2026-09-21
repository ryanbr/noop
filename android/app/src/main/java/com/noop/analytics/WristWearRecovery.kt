package com.noop.analytics

import com.noop.data.HrSample

/**
 * Reconcile a missing WRIST_ON event using five minutes of valid HR with no gap over five seconds.
 * Only an unpaired OFF tail uses this evidence; explicit OFF/ON pairs and sleep/HR-gap gates remain.
 * Returns the first observed sample of the confirmed run. Mirrors Swift WristWearRecovery.
 */
object WristWearRecovery {
    const val confirmationSeconds = 5L * 60
    const val maximumGapSeconds = 5L

    fun firstSustainedHR(hr: List<HrSample>, after: Long, before: Long): Long? {
        // Invalid wins conflicting duplicate timestamps, independent of input order.
        val validByTimestamp = HashMap<Long, Boolean>()
        for (sample in hr) {
            if (sample.ts <= after || sample.ts >= before) continue
            validByTimestamp[sample.ts] = (validByTimestamp[sample.ts] ?: true) && sample.bpm in 30..220
        }
        var start: Long? = null
        var previous: Long? = null
        for (ts in validByTimestamp.keys.sorted()) {
            if (validByTimestamp[ts] != true) {
                start = null; previous = null
                continue
            }
            if (previous == null || ts - previous > maximumGapSeconds) start = ts
            previous = ts
            if (start != null && ts - start >= confirmationSeconds) return start
        }
        return null
    }
}
