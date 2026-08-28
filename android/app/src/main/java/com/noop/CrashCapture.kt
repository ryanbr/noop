package com.noop

import android.content.Context
import android.os.Build
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.security.MessageDigest

/**
 * Captures the last uncaught exception to a file so a crash that only reproduces on a user's own
 * device — a deterministic crash on a specific data shape, like the Insights tab (#224/#267) — lands
 * in the shareable strap log instead of being lost to a logcat no one can reach without adb. The
 * handler records the trace, then chains to the previous handler so the process still dies normally
 * (we never swallow the crash). [LogExport] appends [lastCrash] to the strap log header.
 */
object CrashCapture {
    private const val FILE = "last_crash.txt"
    private const val PREFS = "noop_crash_capture"
    private const val ACKNOWLEDGED = "acknowledged_fingerprint"

    fun install(context: Context) {
        val appContext = context.applicationContext
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            // The handler itself must never throw, or we replace one crash with another.
            runCatching {
                val sw = StringWriter()
                throwable.printStackTrace(PrintWriter(sw))
                val text = buildString {
                    append(crashHeader(
                        whenText = java.util.Date().toString(),
                        threadName = thread.name,
                        appVersion = BuildConfig.VERSION_NAME,
                        versionCode = BuildConfig.VERSION_CODE,
                        packageName = appContext.packageName,
                        androidRelease = Build.VERSION.RELEASE,
                        sdk = Build.VERSION.SDK_INT,
                        manufacturer = Build.MANUFACTURER,
                        model = Build.MODEL,
                    ))
                    appendLine(sw.toString())
                }
                File(appContext.filesDir, FILE).writeText(text)
            }
            previous?.uncaughtException(thread, throwable)
        }
    }

    /** The captured crash text, or null if there hasn't been one. Surfaced by [LogExport]. */
    fun lastCrash(context: Context): String? {
        val f = File(context.applicationContext.filesDir, FILE)
        if (!f.exists()) return null
        return runCatching { f.readText() }.getOrNull()?.ifBlank { null }
    }

    /**
     * A crash not yet dismissed by the user, shown before launch touches the database or BLE stack.
     *
     * TOTAL, like [lastCrash] beside it: this is the FIRST thing `MainActivity.onCreate` runs, so a
     * throw here does not degrade the recovery screen — it stops the app starting at all, on every
     * launch, with no screen left to explain why. A crash-recovery feature that bricks startup is a
     * worse failure than the crash it exists to report, so any failure reading the acknowledgement
     * yields null and normal startup proceeds.
     */
    fun pendingCrash(context: Context): String? = runCatching {
        val crash = lastCrash(context) ?: return@runCatching null
        val acknowledged = context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(ACKNOWLEDGED, null)
        crash.takeIf { isPending(fingerprint(it), acknowledged) }
    }.getOrNull()

    /**
     * Keep the crash for diagnostics, but allow the next launch attempt to continue.
     *
     * `commit()` rather than `apply()`: the caller recreates the Activity immediately, and a process
     * death between the two would lose an asynchronous write and put the same crash back in front of
     * the user. The write is one small string on a path taken once per crash, so paying for durability
     * here costs nothing measurable and removes the only way this can repeat itself.
     */
    fun acknowledge(context: Context, crash: String) {
        runCatching {
            context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putString(ACKNOWLEDGED, fingerprint(crash)).commit()
        }
    }

    internal fun isPending(fingerprint: String, acknowledged: String?) = fingerprint != acknowledged

    internal fun fingerprint(text: String): String = MessageDigest.getInstance("SHA-256")
        .digest(text.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }

    internal fun crashHeader(
        whenText: String,
        threadName: String,
        appVersion: String,
        versionCode: Int,
        packageName: String,
        androidRelease: String,
        sdk: Int,
        manufacturer: String,
        model: String,
    ) = buildString {
        appendLine("when:   $whenText")
        appendLine("app:    $appVersion ($versionCode) · $packageName")
        appendLine("os:     Android $androidRelease (API $sdk)")
        appendLine("device: $manufacturer $model")
        appendLine("thread: $threadName")
    }
}
