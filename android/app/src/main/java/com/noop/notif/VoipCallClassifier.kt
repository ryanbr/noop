package com.noop.notif

import android.app.Notification
import android.os.Build

/**
 * Strict, privacy-preserving VoIP call detection for NotificationListenerService.
 *
 * We intentionally inspect only package identity, notification category/flags, and the public
 * Notification.CallStyle type. We never inspect title, text, people, caller names, or extras.
 * Android documents CATEGORY_CALL as the category for incoming voice/video calls, while CallStyle
 * is the platform's dedicated call notification style on API 31+.
 */
internal object VoipCallClassifier {
    const val CATEGORY_CALL = "call"

    private val knownVoipPackages = setOf(
        "com.whatsapp",
        "org.thoughtcrime.securesms",
        "org.telegram.messenger",
        "com.microsoft.teams",
        "us.zoom.videomeetings",
        "com.google.android.apps.tachyon",
        "com.google.android.apps.meetings",
        "com.facebook.orca",
        "com.discord",
        "com.instagram.android",
    )

    data class Metadata(
        val category: String?,
        val isOngoing: Boolean,
        val isForegroundService: Boolean,
        val isGroupSummary: Boolean,
        val isCallStyle: Boolean,
    )

    fun isKnownVoipPackage(packageName: String): Boolean = packageName in knownVoipPackages

    fun isIncomingCallNotification(packageName: String, metadata: Metadata): Boolean {
        if (!isKnownVoipPackage(packageName)) return false
        if (metadata.isForegroundService || metadata.isGroupSummary || metadata.isOngoing) return false
        // Prefer Android's explicit CallStyle signal when available; otherwise fall back to the
        // documented CATEGORY_CALL contract used by older Android and third-party VoIP apps.
        return metadata.isCallStyle || metadata.category == CATEGORY_CALL
    }

    fun metadataOf(notification: Notification, isOngoing: Boolean): Metadata =
        Metadata(
            category = notification.category,
            isOngoing = isOngoing,
            isForegroundService = (notification.flags and Notification.FLAG_FOREGROUND_SERVICE) != 0,
            isGroupSummary = (notification.flags and Notification.FLAG_GROUP_SUMMARY) != 0,
            isCallStyle = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && notification.style is Notification.CallStyle,
        )
}
