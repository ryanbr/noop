package com.noop.push

import java.net.UnknownHostException
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import okio.GzipSource
import okio.buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PushHttpTransportPolicyTest {
    @Test fun capabilityDnsFailureReturnsStructuredSafeDiagnostic() = runBlocking {
        val client = OkHttpClient.Builder()
            .addInterceptor { throw UnknownHostException("canary-secret.example") }
            .build()
        val endpoint = (PushEndpointPolicy.validate("https://receiver.example/push") as PushEndpointPolicy.Result.Valid).endpoint

        val result = PushHttpTransport(endpoint, "bearer-canary", client).capabilities()

        assertTrue(result is PushCapabilitiesResult.Rejected)
        val rejected = result as PushCapabilitiesResult.Rejected
        assertEquals(PushFailureCode.DNS_LOOKUP, rejected.failure?.code)
        assertFalse(rejected.reason.contains("canary", ignoreCase = true))
        assertFalse(rejected.reason.contains("receiver.example", ignoreCase = true))
    }

    @Test fun explicitConnectionTestIsGatedByNetworkPolicyBeforeAnyTransportIsCreated() {
        assertFalse(canStartPushConnectionTest(networkAvailable = false, endpointValid = true, tokenAvailable = true))
        assertFalse(canStartPushConnectionTest(networkAvailable = true, endpointValid = false, tokenAvailable = true))
        assertFalse(canStartPushConnectionTest(networkAvailable = true, endpointValid = true, tokenAvailable = false))
        assertTrue(canStartPushConnectionTest(networkAvailable = true, endpointValid = true, tokenAvailable = true))
    }

    @Test fun explicitConnectionTestOnlyReadsCapabilitiesAndNeverPostsHealthData() = runBlocking {
        var capabilityCalls = 0
        var postCalls = 0
        val expected = PushCapabilitiesResult.Available(
            PushCapabilities(setOf(PushAppendTable.HR_SAMPLE), emptySet()),
        )
        val endpoint = (PushEndpointPolicy.validate("https://receiver.example/push") as PushEndpointPolicy.Result.Valid).endpoint
        val tester = PushConnectionTester { capturedEndpoint, capturedToken ->
            assertEquals(endpoint, capturedEndpoint)
            assertEquals("secret", capturedToken)
            object : PushTransport {
                override suspend fun capabilities(): PushCapabilitiesResult {
                    capabilityCalls++
                    return expected
                }

                override suspend fun post(batch: PushBatch): PushTransportResponse {
                    postCalls++
                    error("connection test must not POST")
                }
            }
        }

        assertEquals(expected, tester.test(endpoint, "secret"))
        assertEquals(1, capabilityCalls)
        assertEquals(0, postCalls)
    }

    @Test fun authenticatedCapabilitiesStrictlyNarrowTheFixedV1Registry() = runBlocking {
        var method = ""
        var authorization: String? = null
        var acceptedVersions: String? = null
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            method = chain.request().method
            authorization = chain.request().header("Authorization")
            acceptedVersions = chain.request().header("NOOP-Push-Accept-Version")
            Response.Builder()
                .request(chain.request())
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("ok")
                .body(
                    """{"type":"capabilities","protocolVersion":"1.0","receiverStateId":"00000000-0000-4000-8000-000000000099","streams":["hrSample","journal"],"futureOptional":true}"""
                        .toResponseBody(),
                )
                .build()
        }.build()
        val endpoint = (PushEndpointPolicy.validate("https://receiver.example/push") as PushEndpointPolicy.Result.Valid).endpoint

        val result = PushHttpTransport(endpoint, "secret", client).capabilities()

        assertEquals("GET", method)
        assertEquals("Bearer secret", authorization)
        assertEquals("1.1, 1.0", acceptedVersions)
        assertEquals(
            PushCapabilitiesResult.Available(
                PushCapabilities(
                    appendTables = setOf(PushAppendTable.HR_SAMPLE),
                    mutableTables = setOf(PushMutableTable.JOURNAL),
                    receiverStateId = "00000000-0000-4000-8000-000000000099",
                ),
            ),
            result,
        )
    }

    @Test fun v11CapabilitiesSelectTheNewDailyMetricProjection() {
        val result = PushCapabilities.parse(
            """{"type":"capabilities","protocolVersion":"1.1","receiverStateId":"00000000-0000-4000-8000-000000000099","streams":["dailyMetric"]}"""
                .toByteArray(),
        )

        assertEquals("1.1", result.protocolVersion)
        assertEquals(setOf(PushMutableTable.DAILY_METRIC), result.mutableTables)
    }

    @Test fun receiverWithoutCapabilitiesFailsClosedBeforeHealthDataIsSent() = runBlocking {
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
                .code(405).message("legacy").body(ByteArray(0).toResponseBody()).build()
        }.build()
        val endpoint = (PushEndpointPolicy.validate("https://receiver.example/push") as PushEndpointPolicy.Result.Valid).endpoint

        val result = PushHttpTransport(endpoint, "secret", client).capabilities()

        assertTrue(result is PushCapabilitiesResult.Rejected)
        assertEquals(PushFailureCode.HTTP_CLIENT, (result as PushCapabilitiesResult.Rejected).failure?.code)
    }

    @Test fun malformedOrExpandingCapabilitiesFailClosed() = runBlocking {
        val bodies = listOf(
            """{"type":"capabilities","protocolVersion":"1.0","streams":["hrSample"]}""",
            """{"type":"capabilities","protocolVersion":"1.0","receiverStateId":"00000000-0000-4000-8000-000000000099","streams":["unknown"]}""",
            """{"type":"capabilities","protocolVersion":"1.0","receiverStateId":"00000000-0000-4000-8000-000000000099","streams":["hrSample","hrSample"]}""",
            """{"type":"capabilities","protocolVersion":"1.0","receiverStateId":"00000000-0000-4000-8000-000000000099","streams":"hrSample"}""",
        )
        val endpoint = (PushEndpointPolicy.validate("https://receiver.example/push") as PushEndpointPolicy.Result.Valid).endpoint
        for (body in bodies) {
            val client = OkHttpClient.Builder().addInterceptor { chain ->
                Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
                    .code(200).message("ok").body(body.toResponseBody()).build()
            }.build()
            val result = PushHttpTransport(endpoint, "secret", client).capabilities()
            assertTrue(result is PushCapabilitiesResult.Rejected && !result.retryable)
        }
    }

    @Test fun capabilityFailuresUseTheSameBoundedRetryPolicyAsBatchDelivery() = runBlocking {
        val endpoint = (PushEndpointPolicy.validate("https://receiver.example/push") as PushEndpointPolicy.Result.Valid).endpoint
        for ((status, expectedRetryable) in listOf(401 to false, 408 to true, 429 to true, 500 to true)) {
            val client = OkHttpClient.Builder().addInterceptor { chain ->
                Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
                    .code(status).message("response").body(ByteArray(0).toResponseBody()).build()
            }.build()

            val result = PushHttpTransport(endpoint, "secret", client).capabilities()

            assertTrue(result is PushCapabilitiesResult.Rejected)
            assertEquals(expectedRetryable, (result as PushCapabilitiesResult.Rejected).retryable)
        }
    }

    @Test fun gzipEncodingIsDeterministicAndBounded() {
        val decoded = ByteArray(PushProtocol.MAX_BODY_BYTES) { index -> (index * 31).toByte() }

        val first = PushHttpTransport.gzip(decoded)
        val retry = PushHttpTransport.gzip(decoded)

        assertTrue(first.size <= PushProtocol.MAX_WIRE_BODY_BYTES)
        assertTrue(first.contentEquals(retry))
    }

    @Test fun redirectsAreDisabledInBothDirections() {
        val client = PushHttpTransport.defaultClient()
        assertFalse(client.followRedirects)
        assertFalse(client.followSslRedirects)
    }

    @Test fun definitiveUnsupportedMediaTypeRetriesSameEntityOnceAsIdentity() = runBlocking {
        val encodings = mutableListOf<String?>()
        val decodedBodies = mutableListOf<ByteArray>()
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            val encoding = chain.request().header("Content-Encoding")
            encodings += encoding
            val wire = Buffer().also { chain.request().body!!.writeTo(it) }
            decodedBodies += if (encoding == "gzip") {
                GzipSource(wire).buffer().use { it.readByteArray() }
            } else {
                wire.readByteArray()
            }
            Response.Builder()
                .request(chain.request())
                .protocol(Protocol.HTTP_1_1)
                .code(if (encoding == "gzip") 415 else 200)
                .message("response")
                .body(ByteArray(0).toResponseBody())
                .build()
        }.build()
        val endpoint = (PushEndpointPolicy.validate("https://receiver.example/push") as PushEndpointPolicy.Result.Valid).endpoint

        val response = PushHttpTransport(endpoint, "secret", client).post(batch())

        assertEquals(200, response.statusCode)
        assertEquals(listOf("gzip", null), encodings)
        assertEquals(2, decodedBodies.size)
        assertTrue(decodedBodies[0].contentEquals(decodedBodies[1]))
    }

    @Test fun fallbackIsNotUsedForTransientErrors() = runBlocking {
        var calls = 0
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            calls++
            Response.Builder()
                .request(chain.request())
                .protocol(Protocol.HTTP_1_1)
                .code(500)
                .message("error")
                .body(ByteArray(0).toResponseBody())
                .build()
        }.build()
        val endpoint = (PushEndpointPolicy.validate("https://receiver.example/push") as PushEndpointPolicy.Result.Valid).endpoint

        val response = PushHttpTransport(endpoint, "secret", client).post(batch())

        assertEquals(500, response.statusCode)
        assertEquals(1, calls)
    }

    @Test fun redirectIsReturnedWithoutFollowingAndAuthorizationIsHeaderOnly() = runBlocking {
        var calls = 0
        var authorization: String? = null
        var contentEncoding: String? = null
        var contentType: String? = null
        var contentLength: Long? = null
        var sentBody = ""
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            calls++
            authorization = chain.request().header("Authorization")
            contentEncoding = chain.request().header("Content-Encoding")
            contentType = chain.request().body!!.contentType().toString()
            contentLength = chain.request().body!!.contentLength()
            sentBody = chain.request().body!!.let { body ->
                val buffer = Buffer()
                body.writeTo(buffer)
                GzipSource(buffer).buffer().use { it.readUtf8() }
            }
            Response.Builder()
                .request(chain.request())
                .protocol(Protocol.HTTP_1_1)
                .code(307)
                .message("redirect")
                .header("Location", "https://elsewhere.example/steal")
                .body(ByteArray(0).toResponseBody())
                .build()
        }.build()
        val endpoint = (PushEndpointPolicy.validate("https://receiver.example/push") as PushEndpointPolicy.Result.Valid).endpoint
        val response = PushHttpTransport(endpoint, "top-secret", client).post(batch())

        assertEquals(307, response.statusCode)
        assertEquals(1, calls)
        assertEquals("Bearer top-secret", authorization)
        assertEquals("gzip", contentEncoding)
        assertEquals("application/x-ndjson; charset=utf-8", contentType)
        assertTrue(contentLength!! > 0L)
        assertEquals("{}\n", sentBody)
        assertFalse(sentBody.contains("top-secret"))
    }

    @Test fun responseReadIsBoundedForAckAndErrorBodies() = runBlocking {
        val oversized = ByteArray(PushProtocol.MAX_ACK_BYTES + 500) { 'x'.code.toByte() }
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            Response.Builder()
                .request(chain.request())
                .protocol(Protocol.HTTP_1_1)
                .code(500)
                .message("error")
                .body(oversized.toResponseBody())
                .build()
        }.build()
        val endpoint = (PushEndpointPolicy.validate("https://receiver.example/push") as PushEndpointPolicy.Result.Valid).endpoint
        val response = PushHttpTransport(endpoint, "secret", client).post(batch())

        assertEquals(PushProtocol.MAX_ACK_BYTES + 1, response.body.size)
        assertTrue(response.body.size < oversized.size)
    }

    private fun batch() = PushBatch(
        protocolVersion = PushProtocol.VERSION,
        batchId = "00000000-0000-4000-8000-000000000001",
        sourceId = "00000000-0000-4000-8000-000000000002",
        table = PushAppendTable.HR_SAMPLE,
        deviceId = "strap",
        mode = "append",
        startCursor = null,
        endCursor = null,
        recordCount = 0,
        window = null,
        body = "{}\n".toByteArray(),
    )
}
