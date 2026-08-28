package com.noop.push

import android.content.Context
import com.noop.R
import java.io.EOFException
import java.io.IOException
import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.security.cert.CertificateException
import javax.net.ssl.SSLException
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLPeerUnverifiedException

enum class PushFailureCode {
    DNS_LOOKUP,
    TLS_CERTIFICATE,
    TLS_HANDSHAKE,
    NETWORK_TIMEOUT,
    CONNECTION_REFUSED,
    NETWORK_UNREACHABLE,
    CONNECTION_RESET,
    NETWORK_IO,
    HTTP_AUTH,
    HTTP_NOT_FOUND,
    HTTP_TIMEOUT,
    HTTP_TOO_LARGE,
    HTTP_MEDIA_TYPE,
    HTTP_PROTOCOL_REJECTED,
    HTTP_RATE_LIMIT,
    HTTP_SERVER,
    HTTP_CLIENT,
    CAPABILITIES_INVALID,
    ACK_INVALID,
    LOCAL_DATA,
    LOCAL_DATABASE,
}

data class PushFailure(
    val code: PushFailureCode,
    val httpStatus: Int? = null,
    val receiverCode: String? = null,
) {
    val safeCode: String get() = buildString {
        append(code.name.lowercase())
        httpStatus?.let { append(":http_").append(it) }
        receiverCode?.let { append(":receiver_").append(it) }
    }

    val retryable: Boolean get() = when (code) {
        PushFailureCode.DNS_LOOKUP,
        PushFailureCode.TLS_HANDSHAKE,
        PushFailureCode.NETWORK_TIMEOUT,
        PushFailureCode.CONNECTION_REFUSED,
        PushFailureCode.NETWORK_UNREACHABLE,
        PushFailureCode.CONNECTION_RESET,
        PushFailureCode.NETWORK_IO,
        PushFailureCode.HTTP_TIMEOUT,
        PushFailureCode.HTTP_RATE_LIMIT,
        PushFailureCode.HTTP_SERVER,
        PushFailureCode.LOCAL_DATABASE,
        -> true
        else -> false
    }

    companion object {
        fun http(status: Int, receiverCode: String? = null): PushFailure = PushFailure(
            code = when (status) {
                401, 403 -> PushFailureCode.HTTP_AUTH
                404 -> PushFailureCode.HTTP_NOT_FOUND
                408 -> PushFailureCode.HTTP_TIMEOUT
                413 -> PushFailureCode.HTTP_TOO_LARGE
                415 -> PushFailureCode.HTTP_MEDIA_TYPE
                400, 409, 422 -> PushFailureCode.HTTP_PROTOCOL_REJECTED
                429 -> PushFailureCode.HTTP_RATE_LIMIT
                in 500..599 -> PushFailureCode.HTTP_SERVER
                else -> PushFailureCode.HTTP_CLIENT
            },
            httpStatus = status,
            receiverCode = receiverCode,
        )
    }
}

/** Carries only a stable category; the platform cause is never rendered or persisted. */
class PushTransportException(
    val failure: PushFailure,
    cause: Throwable? = null,
) : IOException(failure.safeCode, cause)

internal fun classifyPushTransportFailure(throwable: Throwable): PushFailure {
    val causes = mutableListOf<Throwable>()
    var current: Throwable? = throwable
    while (current != null && causes.size < 16 && current !in causes) {
        causes += current
        current = current.cause
    }
    fun has(type: Class<out Throwable>) = causes.any(type::isInstance)
    fun messageContains(vararg needles: String) = causes.any { cause ->
        val message = cause.message.orEmpty().lowercase()
        needles.any(message::contains)
    }
    val code = when {
        has(UnknownHostException::class.java) -> PushFailureCode.DNS_LOOKUP
        has(SSLPeerUnverifiedException::class.java) || has(CertificateException::class.java) ->
            PushFailureCode.TLS_CERTIFICATE
        has(SSLHandshakeException::class.java) || has(SSLException::class.java) -> PushFailureCode.TLS_HANDSHAKE
        has(SocketTimeoutException::class.java) || has(InterruptedIOException::class.java) ->
            PushFailureCode.NETWORK_TIMEOUT
        has(NoRouteToHostException::class.java) || messageContains("no route", "unreachable") ->
            PushFailureCode.NETWORK_UNREACHABLE
        has(ConnectException::class.java) && messageContains("refused", "econnrefused") ->
            PushFailureCode.CONNECTION_REFUSED
        has(EOFException::class.java) ||
            (has(SocketException::class.java) && messageContains("reset", "broken pipe", "unexpected end")) ->
            PushFailureCode.CONNECTION_RESET
        else -> PushFailureCode.NETWORK_IO
    }
    return PushFailure(code)
}

/**
 * Wording for a refused destination. Kept beside [pushFailureMessage] so both user-facing message
 * taxonomies resolve the same way; [PushEndpointPolicy] itself stays free of Android types.
 */
internal fun pushEndpointProblemMessage(
    context: Context,
    problem: PushEndpointPolicy.Problem,
): String = when (problem) {
    PushEndpointPolicy.Problem.MALFORMED_URL -> context.getString(R.string.push_endpoint_error_malformed)
    PushEndpointPolicy.Problem.MISSING_SCHEME -> context.getString(R.string.push_endpoint_error_missing_scheme)
    PushEndpointPolicy.Problem.UNSUPPORTED_SCHEME ->
        context.getString(R.string.push_endpoint_error_unsupported_scheme)
    PushEndpointPolicy.Problem.USER_INFO_NOT_ALLOWED -> context.getString(R.string.push_endpoint_error_user_info)
    PushEndpointPolicy.Problem.FRAGMENT_NOT_ALLOWED -> context.getString(R.string.push_endpoint_error_fragment)
    PushEndpointPolicy.Problem.MISSING_HOST -> context.getString(R.string.push_endpoint_error_missing_host)
    PushEndpointPolicy.Problem.INVALID_HOST -> context.getString(R.string.push_endpoint_error_invalid_host)
    PushEndpointPolicy.Problem.INVALID_PORT -> context.getString(R.string.push_endpoint_error_invalid_port)
    PushEndpointPolicy.Problem.HTTP_REQUIRES_LOCAL_ADDRESS ->
        context.getString(R.string.push_endpoint_error_http_requires_local)
}

internal fun pushFailureMessage(context: Context, failure: PushFailure): String {
    val base = when (failure.code) {
        PushFailureCode.DNS_LOOKUP -> context.getString(R.string.push_error_dns)
        PushFailureCode.TLS_CERTIFICATE -> context.getString(R.string.push_error_tls_certificate)
        PushFailureCode.TLS_HANDSHAKE -> context.getString(R.string.push_error_tls_handshake)
        PushFailureCode.NETWORK_TIMEOUT -> context.getString(R.string.push_error_network_timeout)
        PushFailureCode.CONNECTION_REFUSED -> context.getString(R.string.push_error_connection_refused)
        PushFailureCode.NETWORK_UNREACHABLE -> context.getString(R.string.push_error_network_unreachable)
        PushFailureCode.CONNECTION_RESET -> context.getString(R.string.push_error_connection_reset)
        PushFailureCode.NETWORK_IO -> context.getString(R.string.push_error_network_io)
        PushFailureCode.HTTP_AUTH -> context.getString(R.string.push_error_http_auth, failure.httpStatus ?: 401)
        PushFailureCode.HTTP_NOT_FOUND -> context.getString(R.string.push_error_http_not_found, failure.httpStatus ?: 404)
        PushFailureCode.HTTP_TIMEOUT -> context.getString(R.string.push_error_http_timeout, failure.httpStatus ?: 408)
        PushFailureCode.HTTP_TOO_LARGE -> context.getString(R.string.push_error_http_too_large, failure.httpStatus ?: 413)
        PushFailureCode.HTTP_MEDIA_TYPE -> context.getString(R.string.push_error_http_media_type, failure.httpStatus ?: 415)
        PushFailureCode.HTTP_PROTOCOL_REJECTED ->
            context.getString(R.string.push_error_http_protocol, failure.httpStatus ?: 422)
        PushFailureCode.HTTP_RATE_LIMIT -> context.getString(R.string.push_error_http_rate_limit, failure.httpStatus ?: 429)
        PushFailureCode.HTTP_SERVER -> context.getString(R.string.push_error_http_server, failure.httpStatus ?: 500)
        PushFailureCode.HTTP_CLIENT -> context.getString(R.string.push_error_http_client, failure.httpStatus ?: 400)
        PushFailureCode.CAPABILITIES_INVALID -> context.getString(R.string.push_error_capabilities_invalid)
        PushFailureCode.ACK_INVALID -> context.getString(R.string.push_error_ack_invalid)
        PushFailureCode.LOCAL_DATA -> context.getString(R.string.push_error_local_data)
        PushFailureCode.LOCAL_DATABASE -> context.getString(R.string.push_error_local_database)
    }
    return failure.receiverCode?.let { "$base ($it)" } ?: base
}
