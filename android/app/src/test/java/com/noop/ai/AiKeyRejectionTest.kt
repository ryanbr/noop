package com.noop.ai

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The coach shows the chat as soon as ANY key is stored, and a wrong key is still a stored key, so a
 * rejection is the one failure whose repair the wearer cannot reach on their own. The UI opens a key
 * field on exactly this classification, which makes it load-bearing rather than cosmetic: widen it and
 * a rate limit starts demanding a new key, narrow it and the trap comes back.
 *
 * The same table is asserted in Swift `AICoachErrorTests.testIsKeyRejection`, so the two platforms
 * cannot start disagreeing about which failures are the wearer's to fix.
 */
class AiKeyRejectionTest {

    @Test fun isKeyRejectionMatchesTheSharedTable() {
        for ((code, want) in CASES) {
            assertEquals("HTTP $code", want, AiCoach.isKeyRejection(code))
        }
    }

    private companion object {
        val CASES = listOf(
            // Unauthorized and Forbidden are the two the providers use for a bad or revoked key.
            401 to true,
            403 to true,
            // Success is not a failure at all.
            200 to false,
            // The request's problem, not the key's: a model that does not exist reaches here.
            400 to false,
            // Payment and quota read like an account problem, and a new key does not answer either.
            402 to false,
            404 to false,
            408 to false,
            429 to false,
            // The provider's problem. Retyping a key would send the wearer chasing the wrong thing.
            500 to false,
            502 to false,
            503 to false,
            599 to false,
            // Nothing outside the range gets a free pass either.
            0 to false,
            -1 to false,
        )
    }
}
