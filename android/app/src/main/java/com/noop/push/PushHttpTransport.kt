package com.noop.push

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.RequestBody
import okio.Buffer
import okio.BufferedSink
import okio.GzipSink
import okio.buffer
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Minimal HTTP adapter: no redirects, no logging, and bounded acknowledgement/error reads. */
class PushHttpTransport(
    private val endpoint: PushEndpointPolicy.ValidEndpoint,
    private val bearerToken: String,
    private val client: OkHttpClient = defaultClient(),
    private val onBatchStart: (PushBatch) -> Unit = {},
) : PushTransport {
    override suspend fun capabilities(): PushCapabilitiesResult {
        val request = Request.Builder()
            .url(endpoint.url)
            .header("Authorization", "Bearer $bearerToken")
            .header("Accept", "application/json")
            .header(ACCEPT_VERSION_HEADER, PushProtocol.SUPPORTED_VERSIONS.joinToString(", "))
            .get()
            .build()
        val response = try {
            executeRequest(request)
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (failure: PushTransportException) {
            return PushCapabilitiesResult.Rejected(
                failure.failure.safeCode,
                failure.failure.retryable,
                failure.failure,
            )
        } catch (_: Throwable) {
            val failure = PushFailure(PushFailureCode.NETWORK_IO)
            return PushCapabilitiesResult.Rejected(failure.safeCode, failure.retryable, failure)
        }
        if (response.statusCode !in 200..299) {
            val failure = PushFailure.http(response.statusCode, PushError.parseCode(response.body))
            return PushCapabilitiesResult.Rejected(failure.safeCode, failure.retryable, failure)
        }
        return try {
            PushCapabilitiesResult.Available(PushCapabilities.parse(response.body))
        } catch (invalid: PushProtocolException) {
            val failure = PushFailure(PushFailureCode.CAPABILITIES_INVALID)
            PushCapabilitiesResult.Rejected(failure.safeCode, failure.retryable, failure)
        }
    }

    override suspend fun post(batch: PushBatch): PushTransportResponse {
        runCatching { onBatchStart(batch) }
        val compressedBody = gzip(batch.body)
        val compressed = execute(compressedBody, contentEncoding = "gzip")
        if (compressed.statusCode != 415) return compressed
        // Protocol 1.0 allowed identity requests. A definitive media-type rejection is the only
        // signal that permits one compatibility attempt with the exact same decoded entity.
        return execute(batch.body, contentEncoding = null)
    }

    private suspend fun execute(body: ByteArray, contentEncoding: String?): PushTransportResponse {
        val request = Request.Builder()
            .url(endpoint.url)
            .header("Authorization", "Bearer $bearerToken")
            .header("Accept", "application/json")
            .apply { if (contentEncoding != null) header("Content-Encoding", contentEncoding) }
            .post(FixedRequestBody(body))
            .build()
        return executeRequest(request)
    }

    private suspend fun executeRequest(request: Request): PushTransportResponse {
        try {
            return client.newCall(request).await().use { response ->
                val bytes = response.body?.byteStream()?.use { input ->
                    val bounded = ByteArray(PushProtocol.MAX_ACK_BYTES + 1)
                    var total = 0
                    while (total < bounded.size) {
                        val read = input.read(bounded, total, bounded.size - total)
                        if (read < 0) break
                        total += read
                    }
                    bounded.copyOf(total)
                } ?: ByteArray(0)
                PushTransportResponse(response.code, bytes)
            }
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (failure: PushTransportException) {
            throw failure
        } catch (io: IOException) {
            throw PushTransportException(classifyPushTransportFailure(io), io)
        }
    }

    /** Cancelling WorkManager cancels the active socket instead of waiting for the blocking timeout. */
    @OptIn(ExperimentalCoroutinesApi::class)
    private suspend fun Call.await(): Response = suspendCancellableCoroutine { continuation ->
        continuation.invokeOnCancellation { cancel() }
        enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (continuation.isActive) continuation.resumeWithException(e)
            }

            override fun onResponse(call: Call, response: Response) {
                if (continuation.isActive) {
                    continuation.resume(response) { response.close() }
                } else {
                    response.close()
                }
            }
        })
    }

    companion object {
        const val ACCEPT_VERSION_HEADER = "NOOP-Push-Accept-Version"
        private val NDJSON = "application/x-ndjson; charset=utf-8".toMediaType()
        internal fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .followRedirects(false)
            .followSslRedirects(false)
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS)
            .writeTimeout(15, TimeUnit.SECONDS)
            .callTimeout(15, TimeUnit.SECONDS)
            .build()

        /** Compresses only the already bounded decoded entity and rejects unexpected wire expansion. */
        internal fun gzip(decoded: ByteArray): ByteArray {
            require(decoded.size <= PushProtocol.MAX_BODY_BYTES) { "decoded push body exceeds limit" }
            val buffer = Buffer()
            GzipSink(buffer).buffer().use { it.write(decoded) }
            check(buffer.size <= PushProtocol.MAX_WIRE_BODY_BYTES) { "gzip push body exceeds wire limit" }
            return buffer.readByteArray()
        }

        private class FixedRequestBody(private val bytes: ByteArray) : RequestBody() {
            override fun contentType() = NDJSON
            override fun contentLength(): Long = bytes.size.toLong()
            override fun writeTo(sink: BufferedSink) {
                sink.write(bytes)
            }
        }
    }
}
