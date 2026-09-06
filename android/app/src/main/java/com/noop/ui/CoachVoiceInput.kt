package com.noop.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.core.content.ContextCompat

/**
 * K4: On-device speech-to-text wrapper for the Coach composer (Android).
 *
 * Design contract (see PRD-K4):
 * - **No raw audio egress.** Uses [SpeechRecognizer.createOnDeviceSpeechRecognizer] (API 31+)
 *   behind an [SpeechRecognizer.isOnDeviceRecognitionAvailable] gate, so audio is GUARANTEED to
 *   stay on-device — not merely "preferred". On API < 31 the on-device-only APIs don't exist, so
 *   voice is disabled entirely (matching iOS, which disables voice when
 *   `supportsOnDeviceRecognition` is false for the locale). Only the resulting TEXT ever reaches
 *   the AI provider, via the same channel a typed question uses.
 * - The mic button lives in the Coach composer; this class is the single source of truth for
 *   start/stop/permission state.
 * - Mirrors the iOS `CoachVoiceInput` (SFSpeechRecognizer) twin — feature-level parity, the
 *   transcript text is the same kind of string a typed question produces.
 *
 * Usage:
 * 1. [isAvailable] gates whether the mic button is shown at all (API 31+ + on-device support).
 * 2. [isPermissionGranted] / [checkPermission] gate whether the mic button is enabled.
 * 3. [start] begins a session; [onPartial] fires with the live transcript.
 * 4. [stop] finalizes and returns the final text via [onFinal].
 * 5. [destroy] releases the recognizer (call from Compose `DisposableEffect` or `onCleared`).
 *
 * This class is NOT a ViewModel — it's a lightweight controller owned by the Compose layer
 * (the mic button), because SpeechRecognizer must be created and destroyed on the main thread
 * and tied to the Activity lifecycle, not the ViewModel's wider scope.
 */
class CoachVoiceInput(
    private val context: Context,
    private val onPartial: (String) -> Unit,
    private val onFinal: (String) -> Unit,
    private val onError: (String) -> Unit,
) {

    private var recognizer: SpeechRecognizer? = null
    private var isRecording: Boolean = false

    /**
     * Whether on-device speech recognition is available on this device + locale.
     * Requires API 31+ (`createOnDeviceSpeechRecognizer` / `isOnDeviceRecognitionAvailable`).
     * Below API 31, the on-device-only APIs don't exist, so voice is disabled — matching iOS,
     * which disables voice when `supportsOnDeviceRecognition` is false.
     */
    fun isAvailable(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            SpeechRecognizer.isOnDeviceRecognitionAvailable(context)

    /** Whether RECORD_AUDIO is already granted. */
    fun isPermissionGranted(): Boolean =
        ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.RECORD_AUDIO,
        ) == PackageManager.PERMISSION_GRANTED

    /** The runtime permission to request for voice input. */
    val requiredPermission: String = Manifest.permission.RECORD_AUDIO

    /** Whether a recognition session is currently active. */
    fun recording(): Boolean = isRecording

    /**
     * Begin a recognition session. The on-device SpeechRecognizer is created on the main thread
     * (per its contract). Uses [createOnDeviceSpeechRecognizer] so audio is guaranteed to stay
     * on-device — no server fallback is possible.
     */
    fun start() {
        if (isRecording) return
        if (!isAvailable()) {
            onError("On-device speech recognition is not available on this device or locale.")
            return
        }
        if (!isPermissionGranted()) {
            onError("Microphone permission not granted.")
            return
        }
        // SpeechRecognizer must be created on the main thread; this class is called from Compose
        // which runs there, so we're safe.
        recognizer?.destroy()
        recognizer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        } else {
            // Unreachable: isAvailable() gates on API 31+ above.
            return
        }

        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            // Partial results so the composer updates live as the user speaks.
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            // Use the device's current locale.
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, java.util.Locale.getDefault().toLanguageTag())
        }

        recognizer?.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}

            override fun onError(error: Int) {
                isRecording = false
                onError(mapError(error))
            }

            override fun onResults(results: Bundle?) {
                isRecording = false
                val text = results
                    ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    ?.firstOrNull()
                    .orEmpty()
                onFinal(text)
            }

            override fun onPartialResults(partialResults: Bundle?) {
                val text = partialResults
                    ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    ?.firstOrNull()
                    .orEmpty()
                if (text.isNotEmpty()) onPartial(text)
            }

            override fun onEvent(eventType: Int, params: Bundle?) {}
        })

        recognizer?.startListening(intent)
        isRecording = true
    }

    /** Stop the active session. The final result (if any) arrives via [onFinal]. */
    fun stop() {
        if (!isRecording) return
        isRecording = false
        recognizer?.stopListening()
    }

    /** Release the recognizer. Safe to call multiple times. */
    fun destroy() {
        isRecording = false
        recognizer?.destroy()
        recognizer = null
    }

    /** Map platform error codes to a short human-readable message. */
    private fun mapError(error: Int): String = when (error) {
        SpeechRecognizer.ERROR_NO_MATCH -> context.getString(R.string.coach_voice_error_no_speech)
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> context.getString(R.string.coach_voice_error_no_speech)
        SpeechRecognizer.ERROR_AUDIO -> context.getString(R.string.coach_voice_error_audio)
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> context.getString(R.string.coach_voice_error_busy)
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> context.getString(R.string.coach_voice_error_permission)
        SpeechRecognizer.ERROR_CLIENT -> context.getString(R.string.coach_voice_error_generic)
        SpeechRecognizer.ERROR_SERVER -> context.getString(R.string.coach_voice_error_server)
        else -> context.getString(R.string.coach_voice_error_generic)
    }
}
