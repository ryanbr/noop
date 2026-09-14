package com.noop.data

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test
import java.lang.reflect.Proxy

class AutoWorkoutDismissedUnionTest {

    @Test fun dismissalUnionIncludesActiveArchivedAndCanonicalComputedNamespaces() = runBlocking {
        val requested = mutableListOf<String>()
        val rows = mapOf(
            "whoop-active-noop" to listOf(DismissedWorkout("whoop-active-noop", 100L, 200L)),
            "whoop-archived-noop" to listOf(DismissedWorkout("whoop-archived-noop", 300L, 400L)),
            "my-whoop-noop" to listOf(DismissedWorkout("my-whoop-noop", 500L, 600L)),
        )
        val paired = listOf(
            pairedWhoop("whoop-active", "active", 1L),
            pairedWhoop("whoop-archived", "archived", 2L),
            PairedDeviceRow(
                id = "oura-ring", brand = "Oura", model = "Ring", nickname = null,
                sourceKind = "oura", capabilities = "hr", status = "paired",
                addedAt = 3L, lastSeenAt = 3L,
            ),
        )
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                "pairedDevices" -> paired
                "dismissedWorkouts" -> {
                    val id = args!![0] as String
                    requested += id
                    rows[id].orEmpty()
                }
                else -> throw AssertionError("unexpected DAO call ${method.name}")
            }
        } as WhoopDao

        val result = WhoopRepository(dao).dismissedDetectedUnion("whoop-active")

        assertEquals(
            listOf("whoop-active-noop", "whoop-archived-noop", "my-whoop-noop"),
            requested,
        )
        assertEquals(listOf(100L, 300L, 500L), result.map { it.startTs })
    }

    private fun pairedWhoop(id: String, status: String, addedAt: Long) = PairedDeviceRow(
        id = id,
        brand = "WHOOP",
        model = "5.0",
        nickname = null,
        sourceKind = "historyBLE",
        capabilities = "hr",
        status = status,
        addedAt = addedAt,
        lastSeenAt = addedAt,
    )
}
