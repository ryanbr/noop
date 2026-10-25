package com.noop.ble

import com.noop.protocol.DeviceFamily

/**
 * Monotonic progress deadline and retirement fence for the Android offload drain.
 * A retired persist may finish, but a replacement cannot start until it has left the fence.
 * Tokens also fence handler work (timeouts, completion and queued acknowledgements).
 */
internal class OffloadSession(private val timeoutMs: Long) {
    private var sequence = 0L
    private var active: Long? = null
    private var workers = 0
    private var progressAtMs = 0L
    private var lastTrim: Long? = null

    @Synchronized fun current(): Long? = active

    @Synchronized fun generation(): Long = sequence

    @Synchronized fun begin(nowMs: Long, previousTrim: Long?): Long? {
        if (workers != 0 || active != null) return null
        progressAtMs = nowMs
        lastTrim = previousTrim
        return (++sequence).also { active = it }
    }

    @Synchronized fun isCurrent(token: Long): Boolean = active == token

    @Synchronized fun enter(token: Long): Boolean {
        if (active != token) return false
        workers++
        return true
    }

    @Synchronized fun leave() { check(workers > 0); workers-- }

    @Synchronized fun hasWorker(): Boolean = workers != 0

    @Synchronized fun retire() { active = null; sequence++ }

    /** Frame activity is used only by the existing 5/MG idle policy. */
    @Synchronized fun frameReceived(token: Long, nowMs: Long, family: DeviceFamily) {
        if (active == token && family == DeviceFamily.WHOOP5) progressAtMs = nowMs
    }

    /** Called only after decoded rows, rejects and the trim cursor are durable. */
    @Synchronized fun cursorCommitted(token: Long, trim: Long, nowMs: Long) {
        if (active != token || trim == lastTrim || trim == 0xFFFFFFFFL) return
        lastTrim = trim
        progressAtMs = nowMs
    }

    @Synchronized fun remainingMs(token: Long, nowMs: Long): Long? =
        if (active != token) null else (timeoutMs - (nowMs - progressAtMs)).coerceAtLeast(0L)
}

/** A process-local budget: reconnecting must not grant a stalled offload unlimited fresh retries. */
internal class OffloadRecoveryBudget(private val limit: Int = 2) {
    private var attempts = 0
    fun resetByUser() { attempts = 0 }
    fun take(): Boolean = if (attempts < limit) { attempts++; true } else false
}
