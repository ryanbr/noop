package com.noop.push

import java.net.IDN
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.URI
import java.util.Locale

/** Security boundary for the user-supplied destination. Validation happens before DNS or HTTP. */
object PushEndpointPolicy {
    data class ValidEndpoint(val url: String, val host: String)

    /**
     * Why a destination was refused. A code rather than a sentence: [validate] has no Context, and
     * the message is user-facing, so the wording is resolved against string resources at the call
     * site the same way [pushFailureMessage] resolves the transport failure taxonomy.
     */
    enum class Problem {
        MALFORMED_URL,
        MISSING_SCHEME,
        UNSUPPORTED_SCHEME,
        USER_INFO_NOT_ALLOWED,
        FRAGMENT_NOT_ALLOWED,
        MISSING_HOST,
        INVALID_HOST,
        INVALID_PORT,
        HTTP_REQUIRES_LOCAL_ADDRESS,
    }

    sealed interface Result {
        data class Valid(val endpoint: ValidEndpoint) : Result
        data class Invalid(val problem: Problem) : Result
    }

    fun validate(raw: String): Result {
        val uri = runCatching { URI(raw.trim()) }.getOrNull()
            ?: return Result.Invalid(Problem.MALFORMED_URL)
        val scheme = uri.scheme?.lowercase(Locale.ROOT)
            ?: return Result.Invalid(Problem.MISSING_SCHEME)
        if (scheme != "http" && scheme != "https") return Result.Invalid(Problem.UNSUPPORTED_SCHEME)
        if (uri.rawUserInfo != null) return Result.Invalid(Problem.USER_INFO_NOT_ALLOWED)
        if (uri.rawFragment != null) return Result.Invalid(Problem.FRAGMENT_NOT_ALLOWED)
        val rawHost = uri.host?.removePrefix("[")?.removeSuffix("]")?.lowercase(Locale.ROOT)
            ?: return Result.Invalid(Problem.MISSING_HOST)
        val asciiHost = if (':' in rawHost) rawHost else runCatching { IDN.toASCII(rawHost) }.getOrNull()
            ?: return Result.Invalid(Problem.INVALID_HOST)
        if (uri.port !in -1..65535) return Result.Invalid(Problem.INVALID_PORT)

        val literal = parseLiteralAddress(asciiHost)
        val literalAllowed = literal?.let(::isLocalAddress) == true
        if (scheme == "http" && !literalAllowed) {
            return Result.Invalid(Problem.HTTP_REQUIRES_LOCAL_ADDRESS)
        }

        val defaultPort = (scheme == "https" && uri.port == 443) || (scheme == "http" && uri.port == 80)
        val authorityHost = if (asciiHost.contains(':')) "[$asciiHost]" else asciiHost
        val authority = authorityHost + if (uri.port >= 0 && !defaultPort) ":${uri.port}" else ""
        val path = uri.rawPath.takeUnless { it.isNullOrEmpty() } ?: "/"
        val normalized = buildString {
            append(scheme).append("://").append(authority).append(path)
            uri.rawQuery?.let { append('?').append(it) }
        }
        return Result.Valid(ValidEndpoint(normalized, asciiHost))
    }

    internal fun isLocalAddress(address: InetAddress): Boolean {
        if (address.isLoopbackAddress || address.isLinkLocalAddress) {
            return true
        }
        if (address is Inet6Address) {
            val first = address.address.first().toInt() and 0xff
            return first and 0xfe == 0xfc // fc00::/7 ULA
        }
        if (address is Inet4Address) {
            val b = address.address.map { it.toInt() and 0xff }
            return b[0] == 10 || (b[0] == 172 && b[1] in 16..31) ||
                (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
        }
        return false
    }

    private fun parseLiteralAddress(host: String): InetAddress? {
        val looksV6 = ':' in host
        val looksV4 = host.matches(Regex("[0-9.]+"))
        if (!looksV4 && !looksV6) return null // Never DNS-resolve while validating user input.
        return runCatching { InetAddress.getByName(host) }.getOrNull()
    }
}
