package com.noop.testcentre

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.widget.Toast
import com.noop.ui.LogExport

/**
 * Drives the in-app "Report" action on Android (spec section 5.2), twin of
 * Strand/System/TestReportFlow.swift. Pure decisions live in Plan (unit-tested); run() shares the
 * already-redacted .zip through the existing chooser, opens the prefilled issue and toasts. The bundle
 * is redacted by TestBundleAssembler (meta.redaction="v2"); this flow never re-scrubs.
 *
 * The caller assembles the already-redacted, already-capped entries (the Group D orchestrator composes
 * TestBundleAssembler.redactEntries + capEntries + meta.json) and hands them here, so this file depends
 * only on the Group A/B/C contracts and stays compilable on its own.
 */
object TestReportFlow {

    object Plan {
        /** noop-<profile>-<platform>-v<version>-<yyMMdd-HHmm>.zip. Stamp via LogExport so the filename
         *  matches the export layer exactly (LogExport.timestamp is the Android FileExport twin). */
        fun bundleName(profile: TestDomain, platform: String, version: String,
                       nowMs: Long = System.currentTimeMillis()): String {
            val stamp = java.text.SimpleDateFormat("yyMMdd-HHmm", java.util.Locale.US).format(nowMs)
            return "noop-${profile.id}-$platform-v$version-$stamp.zip"
        }

        /** Identical copy to the Swift toast so testers see the same wording on every platform. */
        fun attachToast(savedName: String): String =
            "Saved as $savedName. On the next screen tap the paperclip and pick it."

        /** Android is a mobile platform, so it offers the Copy-report.txt fallback. */
        fun offersCopyFallback(platform: String): Boolean =
            platform.lowercase() == "android" || platform.lowercase() == "ios"
    }

    /** The review gate is mandatory and not skippable (spec section 12). */
    fun shouldProceed(gate: ReportReviewGate): Boolean = gate.isCleared

    /** Share the already-redacted bundle, open the prefilled issue, toast, and prime the copy fallback.
     *  `entries` is the redacted, capped bundle the caller assembled. Review-before-share is mandatory:
     *  nothing is shared until the gate is cleared (spec section 12).
     *
     *  Suspend (#646/#651): [LogExport.exportBundle] moved its zip build + write off the caller's
     *  dispatcher, so this now awaits it rather than blocking Main on a multi-MB bundle. */
    suspend fun run(context: Context, profile: TestDomain, title: String,
            version: String, platform: String, osVersion: String,
            gate: ReportReviewGate,
            entries: List<Pair<String, ByteArray>>) {
        runCatching {
            if (!shouldProceed(gate)) return@runCatching
            val name = Plan.bundleName(profile, platform, version)
            LogExport.exportBundle(context, entries, name)              // existing ACTION_SEND chooser
            // CAPTURE-A (#812): prefill the issue `log` body from the already-redacted report.txt so a
            // submission without the .zip attached still carries the diagnostic trace (incl. the universal
            // dayOwner line). The bundle is already v2-redacted; this reuses that text verbatim.
            val reportText = entries.firstOrNull { it.first == "report.txt" }?.second?.let { String(it) }
            TestReportLink.openReport(context, profile, title, version, platform, osVersion,
                reportText = reportText)
            Toast.makeText(context, Plan.attachToast(name), Toast.LENGTH_LONG).show()
            if (Plan.offersCopyFallback(platform)) {
                val report = entries.firstOrNull { it.first == "report.txt" }?.second
                if (report != null) {
                    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    cm.setPrimaryClip(ClipData.newPlainText("report.txt", String(report)))
                }
            }
        }.onFailure {
            Toast.makeText(context, "Couldn't build the report: ${it.message}", Toast.LENGTH_LONG).show()
        }
    }
}
