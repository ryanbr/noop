package com.noop

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CrashCaptureTest {
    @Test
    fun unchangedCrashIsShownUntilAcknowledged() {
        val fingerprint = CrashCapture.fingerprint("stack trace")
        assertTrue(CrashCapture.isPending(fingerprint, null))
        assertTrue(CrashCapture.isPending(fingerprint, "older crash"))
        assertFalse(CrashCapture.isPending(fingerprint, fingerprint))
    }

    @Test
    fun fingerprintIsStableAndDistinguishesNewCrashes() {
        assertEquals(CrashCapture.fingerprint("same"), CrashCapture.fingerprint("same"))
        assertNotEquals(CrashCapture.fingerprint("first"), CrashCapture.fingerprint("second"))
    }

    @Test
    fun crashHeaderIdentifiesBuildAndAndroidDevice() {
        val header = CrashCapture.crashHeader(
            whenText = "Fri Aug 28 18:23:24 GMT+02:00 2026",
            threadName = "DefaultDispatcher-worker-6",
            appVersion = "10.6.1-staging",
            versionCode = 388,
            packageName = "com.noop.whoop.staging",
            androidRelease = "16",
            sdk = 36,
            manufacturer = "Google",
            model = "Pixel 9",
        )
        assertTrue(header.contains("app:    10.6.1-staging (388) · com.noop.whoop.staging"))
        assertTrue(header.contains("os:     Android 16 (API 36)"))
        assertTrue(header.contains("device: Google Pixel 9"))
        assertTrue(header.contains("thread: DefaultDispatcher-worker-6"))
    }

    // ---- hardening (follow-up to the recovery screen) ----

    /**
     * The acknowledgement fingerprint is taken on the RAW crash, and the screen shows a REDACTED copy.
     * If the two ever swap, the hashes stop matching and the recovery screen reappears on every launch
     * forever — the exact loop the fingerprint exists to prevent, and invisible until someone crashes
     * with a MAC in the message.
     */
    @Test fun redactingForDisplayWouldChangeTheFingerprint() {
        val raw = "when: now\nthread: main\njava.lang.IllegalStateException: no device FD:12:34:56:78:9A"
        val shown = com.noop.ble.redactStrapLogPii(raw)
        assertNotEquals("redaction must actually change this fixture, or the test proves nothing", raw, shown)
        assertNotEquals(
            "so acknowledge() must be given the RAW text, never the shown one",
            CrashCapture.fingerprint(raw),
            CrashCapture.fingerprint(shown),
        )
    }

    /** What the screen renders must carry no MAC, whatever the exception message held. */
    @Test fun theShownCrashHasItsMacMasked() {
        val raw = "java.lang.IllegalStateException: no device FD:12:34:56:78:9A"
        val shown = com.noop.ble.redactStrapLogPii(raw)
        assertFalse("a full MAC must not survive to the clipboard", shown.contains("FD:12:34:56:78:9A"))
        assertTrue("and the masked shape is what the rest of the export uses", shown.contains("••"))
    }

    // ---- pre-upgrade suppression ----

    /**
     * The capture handler has written last_crash.txt since June; the screen that surfaces it landed in
     * August. Without this gate, the first launch after upgrading opened on "NOOP stopped unexpectedly"
     * for a crash survived weeks earlier — found in the field on a staging build that had not crashed at
     * all, showing a 53-day-old file.
     */
    @Test fun aCrashWrittenBeforeTheCurrentInstallIsNotSurfaced() {
        val installed = 1_700_000_000_000L
        assertTrue("a crash from the replaced build is not news",
            CrashCapture.isPreUpgradeCrash(crashModifiedMs = installed - 1, lastUpdateMs = installed))
        assertFalse("a crash from the build in use IS news",
            CrashCapture.isPreUpgradeCrash(crashModifiedMs = installed + 1, lastUpdateMs = installed))
        assertFalse("a crash written exactly at install time is kept — the boundary belongs to the new build",
            CrashCapture.isPreUpgradeCrash(crashModifiedMs = installed, lastUpdateMs = installed))
    }

    /**
     * Fails toward SHOWING. The screen exists to report crashes, so an occasional stale one is a smaller
     * failure than silently swallowing a real one, and the acknowledgement fingerprint caps it at a single
     * screen either way.
     */
    @Test fun anUnknownTimestampKeepsTheOldBehaviour() {
        assertFalse("no install time -> show", CrashCapture.isPreUpgradeCrash(1_000L, 0L))
        assertFalse("no crash mtime -> show", CrashCapture.isPreUpgradeCrash(0L, 1_000L))
        assertFalse("neither known -> show", CrashCapture.isPreUpgradeCrash(0L, 0L))
    }
}
