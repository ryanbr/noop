package com.noop.ble

import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

class OuraLastSeenTest {
    @Test fun failedAttemptsDoNotRecordSightings() = runBlocking {
        var sightings = 0
        SourceCoordinator.ouraSightings(flowOf(
            OuraLiveSource.LinkPhase.DISCONNECTED,
            OuraLiveSource.LinkPhase.CONNECTING,
            OuraLiveSource.LinkPhase.AUTHENTICATING,
            OuraLiveSource.LinkPhase.DISCONNECTED,
        )).collect { sightings++ }
        assertEquals(0, sightings)
    }

    @Test fun reconnectsRefreshButDuplicatePublicationsDoNot() = runBlocking {
        var clock = 100L
        val lastSeen = mutableMapOf("oura-observed" to 1L, "oura-other" to 1L)
        val recorded = mutableListOf<Long>()
        val phases = flow {
            emit(OuraLiveSource.LinkPhase.AUTHENTICATED)
            clock = 200
            emit(OuraLiveSource.LinkPhase.AUTHENTICATED)
            emit(OuraLiveSource.LinkPhase.DISCONNECTED)
            emit(OuraLiveSource.LinkPhase.AUTHENTICATING)
            emit(OuraLiveSource.LinkPhase.AUTHENTICATED)
        }
        SourceCoordinator.ouraSightings(phases).collect {
            lastSeen["oura-observed"] = clock
            recorded += clock
        }
        assertEquals(listOf(100L, 200L), recorded)
        assertEquals(200L, lastSeen["oura-observed"])
        assertEquals(1L, lastSeen["oura-other"])
    }

    @Test fun alreadyAuthenticatedSourceIsSeenOnCollection() = runBlocking {
        var sightings = 0
        SourceCoordinator.ouraSightings(flowOf(OuraLiveSource.LinkPhase.AUTHENTICATED))
            .collect { sightings++ }
        assertEquals(1, sightings)
    }
}
