package com.noop.ble

import java.util.ArrayDeque

/**
 * Serial ownership gate and queue for historical frames.
 *
 * Enqueueing and the empty-queue ownership handoff share one monitor. A producer therefore either
 * leaves work for the current drain or receives a lease and starts the replacement drain; it can
 * never enqueue into the gap between an empty poll and ownership release.
 *
 * [reset] advances the generation. A coroutine from the previous connection can then neither poll
 * frames from the new connection nor release its owner, even if its `finally` block runs late.
 */
internal class BackfillDrainGate<T> {
    internal data class Lease internal constructor(
        internal val generation: Long,
        internal val ownerId: Long,
    )

    private val lock = Any()
    private val pending = ArrayDeque<T>()
    private var generation = 0L
    private var nextOwnerId = 0L
    private var owner: Lease? = null

    /** Enqueue [item], returning a lease only when the caller must start the serial drain. */
    fun enqueue(item: T): Lease? = synchronized(lock) {
        pending.addLast(item)
        if (owner != null) return@synchronized null
        Lease(generation, ++nextOwnerId).also { owner = it }
    }

    /**
     * Return the next item for [lease]. An empty queue releases ownership atomically; a stale lease
     * returns null without touching the current connection's owner or queue.
     */
    fun pollOrRelease(lease: Lease): T? = synchronized(lock) {
        if (owner != lease) return@synchronized null
        if (pending.isEmpty()) {
            owner = null
            null
        } else {
            pending.removeFirst()
        }
    }

    /** Release [lease] after an exceptional drain exit. Stale releases are intentionally no-ops. */
    fun release(lease: Lease) = synchronized(lock) {
        if (owner == lease) owner = null
    }

    /** Drop queued frames without invalidating the current connection's drain owner. */
    fun clear() = synchronized(lock) {
        pending.clear()
    }

    /** Begin a new connection generation and invalidate every lease and frame from the old one. */
    fun reset() = synchronized(lock) {
        generation += 1
        owner = null
        pending.clear()
    }
}
