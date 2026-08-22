package com.noop.notif

/** Pure, deterministic cadence rules for incoming-call haptics. */
internal data class CallAlertPolicy(
    val repeatIntervalMs: Long = 6_000L,
    val maxBuzzes: Int = 6,
) {
    init {
        require(repeatIntervalMs > 0) { "repeatIntervalMs must be positive" }
        require(maxBuzzes >= 1) { "maxBuzzes must be at least 1" }
    }

    fun shouldBuzz(
        active: Boolean,
        buzzCount: Int,
        lastBuzzAtMs: Long?,
        nowMs: Long,
    ): Boolean {
        if (!active || buzzCount >= maxBuzzes) return false
        return lastBuzzAtMs == null || nowMs - lastBuzzAtMs >= repeatIntervalMs
    }

    fun nextDelayMs(buzzCount: Int): Long? =
        if (buzzCount < maxBuzzes) repeatIntervalMs else null
}
