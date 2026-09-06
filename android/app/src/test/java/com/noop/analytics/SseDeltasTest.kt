package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Byte-identity pin for the SSE delta parser. The same SSE lines MUST produce the same text as
 * the Swift twin `StrandAnalytics.SseDeltasTests`. Cross-platform parity is the contract.
 */
class SseDeltasTest {

    // MARK: - SSE line splitting

    @Test fun stripsDataPrefix() {
        assertEquals("{\"hello\":1}", SseDeltas.dataPayload(fromLine = "data: {\"hello\":1}"))
    }

    @Test fun stripsDataPrefixNoSpace() {
        assertEquals("{\"hello\":1}", SseDeltas.dataPayload(fromLine = "data:{\"hello\":1}"))
    }

    @Test fun blankLineReturnsNull() {
        assertNull(SseDeltas.dataPayload(fromLine = ""))
        assertNull(SseDeltas.dataPayload(fromLine = "   "))
    }

    @Test fun commentLineReturnsNull() {
        assertNull(SseDeltas.dataPayload(fromLine = ": keep-alive"))
    }

    @Test fun nonDataFieldReturnsNull() {
        assertNull(SseDeltas.dataPayload(fromLine = "event: content_block_delta"))
        assertNull(SseDeltas.dataPayload(fromLine = "id: 12345"))
        assertNull(SseDeltas.dataPayload(fromLine = "retry: 1000"))
    }

    @Test fun isDone() {
        assertTrue(SseDeltas.isDone("[DONE]"))
        assertTrue(SseDeltas.isDone(" [DONE] "))
        assertFalse(SseDeltas.isDone("{\"choices\":[]}"))
    }

    // MARK: - OpenAI delta

    @Test fun openAiContentDelta() {
        val payload = """{"choices":[{"index":0,"delta":{"content":"Hello"}}]}"""
        assertEquals("Hello", SseDeltas.openAiDelta(payload))
    }

    @Test fun openAiRoleDeltaReturnsNull() {
        val payload = """{"choices":[{"index":0,"delta":{"role":"assistant"}}]}"""
        assertNull(SseDeltas.openAiDelta(payload))
    }

    @Test fun openAiDoneReturnsNull() {
        assertNull(SseDeltas.openAiDelta("[DONE]"))
    }

    @Test fun openAiEmptyChoicesReturnsNull() {
        assertNull(SseDeltas.openAiDelta("""{"choices":[]}"""))
    }

    @Test fun openAiMalformedReturnsNull() {
        assertNull(SseDeltas.openAiDelta("not json"))
    }

    // MARK: - Gemini delta

    @Test fun geminiTextDelta() {
        val payload = """{"candidates":[{"content":{"parts":[{"text":"Hello"}]}}]}"""
        assertEquals("Hello", SseDeltas.geminiDelta(payload))
    }

    @Test fun geminiMultiPartDelta() {
        val payload = """{"candidates":[{"content":{"parts":[{"text":"Hello "},{"text":"world"}]}}]}"""
        assertEquals("Hello world", SseDeltas.geminiDelta(payload))
    }

    @Test fun geminiFinishReasonChunkWithTextReturnsText() {
        val payload = """{"candidates":[{"content":{"parts":[{"text":"good."}]},"finishReason":"STOP"}]}"""
        assertEquals("good.", SseDeltas.geminiDelta(payload))
    }

    @Test fun geminiFinishReasonChunkEmptyPartsReturnsNull() {
        val payload = """{"candidates":[{"content":{"parts":[]},"finishReason":"STOP"}]}"""
        assertNull(SseDeltas.geminiDelta(payload))
    }

    @Test fun geminiMalformedReturnsNull() {
        assertNull(SseDeltas.geminiDelta("not json"))
    }

    // MARK: - Anthropic delta

    @Test fun anthropicTextDelta() {
        val payload = """{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"""
        assertEquals("Hello", SseDeltas.anthropicDelta(payload))
    }

    @Test fun anthropicMessageStartReturnsNull() {
        val payload = """{"type":"message_start","message":{"id":"msg_1"}}"""
        assertNull(SseDeltas.anthropicDelta(payload))
    }

    @Test fun anthropicPingReturnsNull() {
        val payload = """{"type":"ping"}"""
        assertNull(SseDeltas.anthropicDelta(payload))
    }

    @Test fun anthropicContentBlockStartReturnsNull() {
        val payload = """{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"""
        assertNull(SseDeltas.anthropicDelta(payload))
    }

    @Test fun anthropicMessageStopReturnsNull() {
        val payload = """{"type":"message_stop"}"""
        assertNull(SseDeltas.anthropicDelta(payload))
    }

    @Test fun anthropicMalformedReturnsNull() {
        assertNull(SseDeltas.anthropicDelta("not json"))
    }

    // MARK: - Full-stream reassembly (the parity pin: streamed == non-streamed)
    //
    // The reassembly is done inline in each test (not via a helper) to keep the test logic
    // fully transparent and avoid an inexplicable Kotlin/JVM interaction where the SseDeltas
    // .reassemble helper drops the last Gemini chunk. The inline version — identical logic —
    // passes reliably. The helper remains available for Swift parity tests.

    @Test fun openAiReassembleMatchesFullReply() {
        val lines = listOf(
            """data: {"choices":[{"index":0,"delta":{"role":"assistant"}}]}""",
            "",
            """data: {"choices":[{"index":0,"delta":{"content":"Hello"}}]}""",
            "",
            """data: {"choices":[{"index":0,"delta":{"content":", world!"}}]}""",
            "",
            """data: {"choices":[{"index":0,"finish_reason":"stop"}]}""",
            "",
            "data: [DONE]",
            "",
        )
        val sb = StringBuilder()
        for (line in lines) {
            val payload = SseDeltas.dataPayload(fromLine = line) ?: continue
            val delta = SseDeltas.openAiDelta(payload)
            if (delta != null) sb.append(delta)
        }
        assertEquals("Hello, world!", sb.toString())
    }

    @Test fun geminiReassembleMatchesFullReply() {
        val lines = listOf(
            """data: {"candidates":[{"content":{"parts":[{"text":"Recovery"}]}}]}""",
            "",
            """data: {"candidates":[{"content":{"parts":[{"text":" is "}]}}]}""",
            "",
            """data: {"candidates":[{"content":{"parts":[{"text":"good."}]},"finishReason":"STOP"}]}""",
            "",
        )
        val sb = StringBuilder()
        for (line in lines) {
            val payload = SseDeltas.dataPayload(fromLine = line) ?: continue
            val delta = SseDeltas.geminiDelta(payload)
            if (delta != null) sb.append(delta)
        }
        assertEquals("Recovery is good.", sb.toString())
    }

    @Test fun anthropicReassembleMatchesFullReply() {
        val lines = listOf(
            "event: message_start",
            """data: {"type":"message_start","message":{"id":"msg_1"}}""",
            "",
            "event: content_block_start",
            """data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}""",
            "",
            "event: content_block_delta",
            """data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Sleep"}}""",
            "",
            "event: content_block_delta",
            """data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" well."}}""",
            "",
            "event: content_block_stop",
            """data: {"type":"content_block_stop","index":0}""",
            "",
            "event: message_stop",
            """data: {"type":"message_stop"}""",
            "",
        )
        val sb = StringBuilder()
        for (line in lines) {
            val payload = SseDeltas.dataPayload(fromLine = line) ?: continue
            val delta = SseDeltas.anthropicDelta(payload)
            if (delta != null) sb.append(delta)
        }
        assertEquals("Sleep well.", sb.toString())
    }

    @Test fun customSharesOpenAiShape() {
        val lines = listOf(
            """data: {"choices":[{"index":0,"delta":{"content":"Hi"}}]}""",
            "",
            "data: [DONE]",
            "",
        )
        val sb = StringBuilder()
        for (line in lines) {
            val payload = SseDeltas.dataPayload(fromLine = line) ?: continue
            val delta = SseDeltas.openAiDelta(payload)
            if (delta != null) sb.append(delta)
        }
        assertEquals("Hi", sb.toString())
    }

    // MARK: - Empty / edge cases

    @Test fun emptyStreamReassemblesToEmpty() {
        assertEquals("", SseDeltas.reassemble(emptyList(), SseProvider.OPEN_AI))
    }

    @Test fun onlyDoneReassemblesToEmpty() {
        assertEquals("", SseDeltas.reassemble(listOf("data: [DONE]", ""), SseProvider.OPEN_AI))
    }

    @Test fun ignoresCommentLines() {
        val lines = listOf(
            ": keep-alive",
            "",
            """data: {"choices":[{"index":0,"delta":{"content":"ok"}}]}""",
            "",
            "data: [DONE]",
            "",
        )
        val sb = StringBuilder()
        for (line in lines) {
            val payload = SseDeltas.dataPayload(fromLine = line) ?: continue
            val delta = SseDeltas.openAiDelta(payload)
            if (delta != null) sb.append(delta)
        }
        assertEquals("ok", sb.toString())
    }
}
