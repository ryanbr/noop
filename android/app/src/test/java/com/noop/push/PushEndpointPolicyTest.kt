package com.noop.push

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PushEndpointPolicyTest {
    @Test fun httpsPublicEndpointIsAllowedAndNormalized() {
        val valid = PushEndpointPolicy.validate(" HTTPS://Example.COM:443/push ") as PushEndpointPolicy.Result.Valid
        assertEquals("https://example.com/push", valid.endpoint.url)
    }

    @Test fun publicHttpIsRejectedBeforeAnyResolution() {
        assertTrue(PushEndpointPolicy.validate("http://example.com/push") is PushEndpointPolicy.Result.Invalid)
    }

    @Test fun privateAndLoopbackIpv4HttpAreAllowed() {
        listOf("10.1.2.3", "172.16.1.2", "172.31.255.2", "192.168.4.2", "127.0.0.1", "169.254.1.2").forEach {
            assertTrue(it, PushEndpointPolicy.validate("http://$it:8080/push") is PushEndpointPolicy.Result.Valid)
        }
    }

    @Test fun publicAndNearBoundaryIpv4HttpAreRejected() {
        listOf("8.8.8.8", "172.15.255.255", "172.32.0.1", "192.169.1.1").forEach {
            assertTrue(it, PushEndpointPolicy.validate("http://$it/push") is PushEndpointPolicy.Result.Invalid)
        }
    }

    @Test fun ipv6UlaLinkLocalAndLoopbackHttpAreAllowed() {
        listOf("[fc00::1]", "[fd12::1]", "[fe80::1]", "[::1]").forEach {
            assertTrue(it, PushEndpointPolicy.validate("http://$it/push") is PushEndpointPolicy.Result.Valid)
        }
    }

    @Test fun publicIpv6HttpIsRejected() {
        listOf("[2001:4860:4860::8888]", "[fec0::1]", "[::]").forEach {
            assertTrue(it, PushEndpointPolicy.validate("http://$it/") is PushEndpointPolicy.Result.Invalid)
        }
    }

    @Test fun cleartextHostnamesAreRejectedToRemoveDnsRebindingAndPreResolution() {
        listOf("localhost", "receiver.local", "private.example").forEach {
            assertTrue(PushEndpointPolicy.validate("http://$it/push") is PushEndpointPolicy.Result.Invalid)
        }
    }

    @Test fun unsafeUrlShapesAreRejected() {
        listOf(
            "ftp://192.168.1.2/push",
            "http://user:pass@192.168.1.2/push",
            "http://192.168.1.2/push#secret",
            "not a url",
        ).forEach { assertTrue(it, PushEndpointPolicy.validate(it) is PushEndpointPolicy.Result.Invalid) }
    }

    /**
     * The refusal code is what the settings screen turns into wording, so a shape silently mapping to
     * the wrong one would show the user a message that does not match what they typed.
     */
    @Test fun eachRejectedShapeReportsItsOwnProblem() {
        mapOf(
            "http://192.168.1.2/push" to null,
            "" to PushEndpointPolicy.Problem.MISSING_SCHEME,
            "ftp://192.168.1.2/push" to PushEndpointPolicy.Problem.UNSUPPORTED_SCHEME,
            "http://user:pass@192.168.1.2/push" to PushEndpointPolicy.Problem.USER_INFO_NOT_ALLOWED,
            "http://192.168.1.2/push#secret" to PushEndpointPolicy.Problem.FRAGMENT_NOT_ALLOWED,
            "https:///push" to PushEndpointPolicy.Problem.MISSING_HOST,
            "http://example.com/push" to PushEndpointPolicy.Problem.HTTP_REQUIRES_LOCAL_ADDRESS,
            "not a url" to PushEndpointPolicy.Problem.MALFORMED_URL,
        ).forEach { (raw, expected) ->
            when (val result = PushEndpointPolicy.validate(raw)) {
                is PushEndpointPolicy.Result.Valid -> assertEquals(raw, null, expected)
                is PushEndpointPolicy.Result.Invalid -> assertEquals(raw, expected, result.problem)
            }
        }
    }
}
