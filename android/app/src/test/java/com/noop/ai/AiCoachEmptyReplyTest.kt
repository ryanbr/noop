package com.noop.ai

import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1074: when an OpenAI-compatible provider returns a 200 with empty assistant content, surface the
 * provider's own error (some servers put it in a 200 body, e.g. a hand-set model they don't offer)
 * instead of a blanket "empty reply" that hides the cause.
 */
class AiCoachEmptyReplyTest {

    @Test
    fun surfacesProviderErrorFromA200Body() {
        val msg = AiCoach.emptyReplyMessage("""{"error":{"message":"Model Not Exist"}}""")
        assertTrue("should surface the provider's real message", msg.contains("Model Not Exist"))
    }

    @Test
    fun fallsBackToModelHintWhenNoProviderError() {
        val msg = AiCoach.emptyReplyMessage("{}")
        assertTrue("no provider error → point at the hand-set model", msg.contains("model name"))
    }

    @Test
    fun malformedBodyStillGivesTheFallback() {
        val msg = AiCoach.emptyReplyMessage("not json at all")
        assertTrue(msg.contains("model name"))
    }
}
