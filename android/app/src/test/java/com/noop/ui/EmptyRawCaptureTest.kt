package com.noop.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * An EMPTY 5/MG raw capture must report as no capture, not as a successful share.
 *
 * Field report: a capture left running overnight produced a 282-byte file — the three header comment
 * lines and not one frame. The share path gated on the capture file EXISTING, and existence proves
 * nothing was recorded: `startWhoop5BackfillCapture` opens in APPEND mode, which creates the file the
 * moment capture starts.
 *
 * The cause is upstream and known: the puffin notify characteristics are subscribed only in the
 * CLIENT_HELLO-ack branch, so a 5/MG that never completes its handshake (#1635) can never deliver a
 * frame to the writer. `noCaptureMsgText` already explains exactly that — it simply never ran, because
 * the empty file looked like a capture. This is the gate that lets it run.
 */
class EmptyRawCaptureTest {

    @Test
    fun `a capture file that exists but holds no frames is not a capture`() {
        // The reported night: capture started (so the file exists) and recorded nothing.
        assertFalse(LogExport.captureHasFrames(mainBytes = 0L, prevBytes = 0L))
    }

    @Test
    fun `a capture with frames in the live file counts`() {
        assertTrue(LogExport.captureHasFrames(mainBytes = 4_096L, prevBytes = 0L))
    }

    @Test
    fun `a capture whose only frames are in the ROTATED generation still counts`() {
        // The live file can be freshly rotated and empty while the previous generation holds the
        // material — dropping that would discard exactly the long-run capture this feature exists for.
        assertTrue(LogExport.captureHasFrames(mainBytes = 0L, prevBytes = 4_096L))
    }

    @Test
    fun `absent files report as no capture`() {
        // File.length() is 0 for a file that does not exist, so the old existence check is subsumed
        // rather than replaced — a never-started capture still reports as no capture.
        assertFalse(LogExport.captureHasFrames(mainBytes = 0L, prevBytes = 0L))
    }

    @Test
    fun `the same rule guards the detailed capture log and the scheduled drop`() {
        // Both had the identical exists()-not-content flaw: the log writer opens on demand too, and the
        // scheduled auto-export would otherwise write a zero-byte .bin into every drop, forever. One
        // predicate now decides all three, so a future caller cannot get a fourth one subtly different.
        assertFalse(LogExport.captureHasFrames(0L, 0L))
        assertTrue(LogExport.captureHasFrames(1L, 0L))
        assertTrue(LogExport.captureHasFrames(0L, 1L))
    }

    /**
     * The message the gate now lets through, for the night that was actually reported: capture on,
     * strap connected, no encrypted bond. It must not tell the wearer to wait for a sync their strap
     * cannot reach — they already waited all night.
     */
    @Test
    fun `an unbonded strap is told why, not told to wait`() {
        val msg = LogExport.noCaptureMsgText(
            whoop5Connected = true, captureEnabled = true, encryptedBond = false, sharingLog = false,
        )
        assertTrue(msg.contains("encrypted pairing"))
        assertFalse("waiting is not the remedy when the strap cannot pair",
                    msg.contains("Let a 5/MG history sync run"))
    }
}
