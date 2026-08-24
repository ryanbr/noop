package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The registered migration chain must have no holes and must reach [WhoopDatabase.SCHEMA_VERSION].
 *
 * The existing migration tests each assert one migration's SQL and its start/end versions. None of them
 * asserts that it is REGISTERED, so a migration could be written, tested, reviewed and still left out of
 * `addMigrations(...)`. Sabotage confirmed it: removing an entry from the chain left the whole suite
 * green, and removing an OLDER entry did too — this was a property of the suite, not of any one change.
 *
 * The consequence is bounded but real. There is deliberately no destructive fallback, so a hole makes
 * Room throw on upgrade rather than silently rebuild — a loud failure for every existing user on the
 * version that ships it. With `exportSchema=false` nothing else catches it first.
 *
 * Android-only by nature: GRDB registers migrations by name in one sequential `migrator` block, so a
 * Swift migration cannot be declared-but-unregistered the way a Room one can.
 */
class WhoopDatabaseMigrationChainTest {

    private val chain = WhoopDatabase.ALL_MIGRATIONS.sortedBy { it.startVersion }

    /** Every step must advance, and no two may start from the same version. */
    @Test
    fun eachMigrationAdvancesAndNoTwoStartFromTheSameVersion() {
        for (m in chain) {
            assertTrue("migration ${m.startVersion}->${m.endVersion} does not advance",
                       m.endVersion > m.startVersion)
        }
        val starts = chain.map { it.startVersion }
        assertEquals("two migrations start from the same version: $starts",
                     starts.size, starts.toSet().size)
    }

    /**
     * No holes. Walk the chain from its lowest start version and require each migration to begin exactly
     * where the previous one ended.
     *
     * Deliberately anchored to the chain's own lowest version rather than 1: v1 predates this regime and
     * has no upgrade path, so asserting coverage from 1 would be asserting something untrue.
     */
    @Test
    fun theChainHasNoHoles() {
        assertTrue("no migrations registered at all", chain.isNotEmpty())
        var reached = chain.first().startVersion
        for (m in chain) {
            assertEquals(
                "hole in the migration chain: nothing upgrades $reached -> ${m.startVersion}",
                reached, m.startVersion,
            )
            reached = m.endVersion
        }
    }

    /**
     * The chain must end exactly at the database's declared version.
     *
     * Catches the other half of the mistake: bumping [WhoopDatabase.SCHEMA_VERSION] and forgetting the
     * migration, which fails the same way on upgrade.
     */
    @Test
    fun theChainReachesTheDeclaredSchemaVersion() {
        // Guarded like theChainHasNoHoles: an empty chain should fail with this message rather than
        // throw NoSuchElementException out of last(), which reads as a broken test rather than a
        // broken chain — and an empty chain is exactly the catastrophic case worth naming clearly.
        assertTrue("no migrations registered at all", chain.isNotEmpty())
        assertEquals(
            "chain ends at ${chain.last().endVersion} but SCHEMA_VERSION is ${WhoopDatabase.SCHEMA_VERSION}",
            WhoopDatabase.SCHEMA_VERSION, chain.last().endVersion,
        )
    }
}
