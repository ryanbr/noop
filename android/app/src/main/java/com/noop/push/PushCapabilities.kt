package com.noop.push

import org.json.JSONArray
import org.json.JSONObject

/** A receiver may only narrow the fixed v1 registry for its selected minor version, never name new data. */
data class PushCapabilities(
    val appendTables: Set<PushAppendTable>,
    val mutableTables: Set<PushMutableTable>,
    val protocolVersion: String = PushProtocol.VERSION,
    val receiverStateId: String = UNSCOPED_RECEIVER_STATE_ID,
) {
    val isEmpty: Boolean get() = appendTables.isEmpty() && mutableTables.isEmpty()
    val wireNames: List<String> get() =
        PushAppendTable.entries.filter { it in appendTables }.map { it.wireName } +
            PushMutableTable.entries.filter { it in mutableTables }.map { it.wireName }

    companion object {
        /** Test/local default. Network capability documents must always provide a real receiver state id. */
        const val UNSCOPED_RECEIVER_STATE_ID = "00000000-0000-4000-8000-000000000000"
        val ALL = PushCapabilities(PushAppendTable.entries.toSet(), PushMutableTable.entries.toSet())

        fun parse(bytes: ByteArray): PushCapabilities {
            if (bytes.size > PushProtocol.MAX_ACK_BYTES) {
                throw PushProtocolException("capabilities exceed size limit")
            }
            val obj = try {
                JSONObject(bytes.toString(Charsets.UTF_8))
            } catch (_: Throwable) {
                throw PushProtocolException("capabilities are not valid JSON")
            }
            val required = setOf("type", "protocolVersion", "receiverStateId", "streams")
            val actualMembers = obj.keys().asSequence().toSet()
            if (!actualMembers.containsAll(required)) {
                throw PushProtocolException("capabilities are missing required members")
            }
            if (actualMembers.any { it in PushProtocol.FORBIDDEN_REMOTE_CONTROL_MEMBERS }) {
                throw PushProtocolException("capabilities contain forbidden remote-control metadata")
            }
            val protocolVersion = obj.opt("protocolVersion") as? String
            if (obj.opt("type") != "capabilities" || protocolVersion == null || protocolVersion !in PushProtocol.SUPPORTED_VERSIONS) {
                throw PushProtocolException("unsupported capability document")
            }
            val receiverStateId = (obj.opt("receiverStateId") as? String)?.takeIf(::isCanonicalUuid)
                ?: throw PushProtocolException("capabilities.receiverStateId must be a canonical UUID")
            val array = obj.opt("streams") as? JSONArray
                ?: throw PushProtocolException("capabilities.streams must be an array")
            val appendByName = PushAppendTable.entries.associateBy { it.wireName }
            val mutableByName = PushMutableTable.entries.associateBy { it.wireName }
            val seen = mutableSetOf<String>()
            val append = linkedSetOf<PushAppendTable>()
            val mutable = linkedSetOf<PushMutableTable>()
            for (index in 0 until array.length()) {
                val name = array.opt(index) as? String
                    ?: throw PushProtocolException("capability stream names must be strings")
                if (!seen.add(name)) throw PushProtocolException("duplicate capability stream")
                when (val table = appendByName[name] ?: mutableByName[name]) {
                    is PushAppendTable -> append += table
                    is PushMutableTable -> mutable += table
                    else -> throw PushProtocolException("unknown capability stream")
                }
            }
            return PushCapabilities(append, mutable, protocolVersion!!, receiverStateId)
        }

        private fun isCanonicalUuid(value: String): Boolean = runCatching {
            java.util.UUID.fromString(value).toString() == value
        }.getOrDefault(false)
    }
}

internal class PushConnectionTester(
    private val transportFactory: (PushEndpointPolicy.ValidEndpoint, String) -> PushTransport =
        { endpoint, token -> PushHttpTransport(endpoint, token) },
) {
    suspend fun test(
        endpoint: PushEndpointPolicy.ValidEndpoint,
        token: String,
    ): PushCapabilitiesResult = try {
        transportFactory(endpoint, token).capabilities()
    } catch (cancelled: kotlinx.coroutines.CancellationException) {
        throw cancelled
    } catch (_: Throwable) {
        val failure = PushFailure(PushFailureCode.NETWORK_IO)
        PushCapabilitiesResult.Rejected(failure.safeCode, failure.retryable, failure)
    }
}

internal fun canStartPushConnectionTest(
    networkAvailable: Boolean,
    endpointValid: Boolean,
    tokenAvailable: Boolean,
): Boolean = networkAvailable && endpointValid && tokenAvailable

sealed interface PushCapabilitiesResult {
    data class Available(val capabilities: PushCapabilities) : PushCapabilitiesResult
    data class Rejected(
        val reason: String,
        val retryable: Boolean,
        val failure: PushFailure? = null,
    ) : PushCapabilitiesResult
}
