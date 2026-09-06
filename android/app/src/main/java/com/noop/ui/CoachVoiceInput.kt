package com.noop.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.core.content.ContextCompat

/**
 * K4: On-device speech-to-text wrapper for the Coach composer (Android).
 *
 * Design contract (see PRD-K4):
 * - **No raw audio egress.** Android's [SpeechRecognizer] runs on-device for the locales the
 *   platform supports; the intent is configured with [RecognizerIntent.EXTRA_PREFER_OFFLINE] = true
 *   so the platform prefers the on-device recognizer when available. Only the resulting TEXT
 *   ever reaches the AI provider, via the same channel a typed question uses.
 * - The mic button lives in the Coach composer; this class is the single source of truth for
 *   start/stop/permission state.
 * - Mirrors the iOS `CoachVoiceInput` (SFSpeechRecognizer) twin — feature-level parity, the
 *   transcript text is the same kind of string a typed question produces.
 *
 * Usage:
 * 1. [isPermissionGranted] / [checkPermission] gate whether the mic button is enabled.
 * 2. [start] begins a session; [onPartial] fires with the live transcript.
 * 3. [stop] finalizes and returns the final text via [onFinal].
 * 4. [destroy] releases the recognizer (call from Compose `DisposableEffect` or `onCleared`).
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
     * Begin a recognition session. The platform SpeechRecognizer is created on the main thread
     * (per its contract) and configured to prefer the on-device engine.
     */
    fun start() {
        if (isRecording) return
        if (!isPermissionGranted()) {
            onError("Microphone permission not granted.")
            return
        }
        // SpeechRecognizer must be created on the main thread; this class is called from Compose
        // which runs there, so we're safe.
        recognizer?.destroy()
        recognizer = SpeechRecognizer.createSpeechRecognizer(context)

        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            // K4 hard constraint: prefer the on-device recognizer so audio doesn't leave the device.
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
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
        SpeechRecognizer.ERROR_NO_MATCH -> "No speech was heard."
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "No speech was heard."
        SpeechRecognizer.ERROR_AUDIO -> "Audio recording failed."
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "Speech recognizer is busy. Try again."
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Microphone permission denied."
        SpeechRecognizer.ERROR_CLIENT -> "Voice input failed. Try again."
        SpeechRecognizer.ERROR_SERVER -> "On-device speech is unavailable for this locale."
        else -> "Voice input failed. Try again."
    }
}
