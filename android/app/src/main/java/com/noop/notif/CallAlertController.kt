package com.noop.notif

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.noop.NoopApplication
import com.noop.ui.NotifPrefs

internal enum class CallAlertSource {
    PHONE,
    VOIP,
}

/**
 * One local scheduler for all active calls.
 *
 * Phone and VoIP notifications can arrive from different Android callbacks. They therefore share
 * one token set and one haptic scheduler so an overlapping call cannot create two independent
 * reminder loops. No call number, contact, or notification body is retained here.
 */
internal object CallAlertController {
    private const val MAX_RING_WINDOW_MS = 5 * 60_000L

    private val handler = Handler(Looper.getMainLooper())
    private val policy = CallAlertPolicy()
    private val activeTokens = linkedSetOf<String>()
    private var buzzCount = 0
    private var lastBuzzAtMs: Long? = null
    private var appContext: Context? = null

    private val repeatRunnable = object : Runnable {
        override fun run() {
            appContext?.let(::maybeBuzz)
        }
    }

    /** Self-heals if Android misses a call-ended or notification-removed callback. */
    private val maxRingRunnable = Runnable { stopAll() }

    @Synchronized
    fun start(context: Context, source: CallAlertSource, key: String = source.name): Boolean {
        if (!sourceEnabled(context, source)) return false

        appContext = context.applicationContext
        val token = "${source.name}:$key"
        val wasInactive = activeTokens.isEmpty()
        activeTokens.add(token)

        // Re-arm the watchdog on every source update. The watchdog only clears the call state;
        // it never sends a haptic itself.
        handler.removeCallbacks(maxRingRunnable)
        handler.postDelayed(maxRingRunnable, MAX_RING_WINDOW_MS)

        if (wasInactive) {
            buzzCount = 0
            lastBuzzAtMs = null
            handler.removeCallbacks(repeatRunnable)
            maybeBuzz(context.applicationContext)
        }
        return true
    }

    @Synchronized
    fun stop(source: CallAlertSource, key: String = source.name) {
        activeTokens.remove("${source.name}:$key")
        if (activeTokens.isEmpty()) resetLoop()
    }

    @Synchronized
    fun stopSource(source: CallAlertSource) {
        activeTokens.removeAll { it.startsWith("${source.name}:") }
        if (activeTokens.isEmpty()) resetLoop()
    }

    @Synchronized
    fun stopAll() {
        activeTokens.clear()
        resetLoop()
    }

    private fun maybeBuzz(context: Context) {
        pruneDisabledSources(context)
        if (activeTokens.isEmpty()) return

        val now = System.currentTimeMillis()
        if (!policy.shouldBuzz(true, buzzCount, lastBuzzAtMs, now)) return

        val ble = (context.applicationContext as? NoopApplication)?.ble ?: run {
            scheduleNext()
            return
        }

        // A live-HR shortcut can report `bonded` without having the encrypted WHOOP command link.
        // Haptics require the genuine encrypted bond, otherwise the command is silently lost.
        if (!deliveryAllowed(context, ble)) {
            scheduleNext()
            return
        }

        // Keep all hardware-specific haptic encoding inside WhoopBleClient.buzz(). The call layer
        // must never duplicate WHOOP 4 vs 5/MG opcodes or packet framing.
        ble.buzz(NotifPrefs.callLoops(context))
        buzzCount += 1
        lastBuzzAtMs = now
        scheduleNext()
    }

    private fun scheduleNext() {
        handler.removeCallbacks(repeatRunnable)
        val delay = policy.nextDelayMs(buzzCount) ?: return
        if (activeTokens.isNotEmpty()) handler.postDelayed(repeatRunnable, delay)
    }

    private fun resetLoop() {
        handler.removeCallbacks(repeatRunnable)
        handler.removeCallbacks(maxRingRunnable)
        buzzCount = 0
        lastBuzzAtMs = null
    }

    private fun pruneDisabledSources(context: Context) {
        activeTokens.removeAll { token ->
            val source = if (token.startsWith("${CallAlertSource.PHONE.name}:")) {
                CallAlertSource.PHONE
            } else {
                CallAlertSource.VOIP
            }
            !sourceEnabled(context, source)
        }
        if (activeTokens.isEmpty()) resetLoop()
    }

    private fun sourceEnabled(context: Context, source: CallAlertSource): Boolean {
        if (!NotifPrefs.getBool(context, NotifPrefs.MASTER, false)) return false
        if (!NotifPrefs.getBool(context, NotifPrefs.CALLS_MASTER, false)) return false
        return when (source) {
            CallAlertSource.PHONE -> NotifPrefs.getBool(context, NotifPrefs.CALLS_PHONE, false)
            CallAlertSource.VOIP -> NotifPrefs.getBool(context, NotifPrefs.CALLS_VOIP, false)
        }
    }

    private fun deliveryAllowed(
        context: Context,
        ble: com.noop.ble.WhoopBleClient,
    ): Boolean {
        if (!NotifPrefs.getBool(context, NotifPrefs.MASTER, false)) return false
        if (!NotifPrefs.getBool(context, NotifPrefs.CALLS_MASTER, false)) return false
        if (NotifPrefs.inQuietHours(context)) return false

        val state = ble.state.value
        if (!state.connected || !state.encryptedBond) return false
        if (NotifPrefs.getBool(context, NotifPrefs.WORN, true) && !state.worn) return false
        return true
    }
}
