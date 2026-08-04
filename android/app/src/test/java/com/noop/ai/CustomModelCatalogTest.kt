package com.noop.ai

import org.junit.Assert.assertEquals
import org.junit.Test

class CustomModelCatalogTest {

    @Test
    fun `custom provider keeps gateway catalog models`() {
        val body = """
            {
              "service": "Gateway",
              "catalog": [
                {"tool": "OpenAI", "models": ["gpt-5", "gpt-5.5"]},
                {"tool": "Other", "models": ["claude-sonnet-4-6@default", "gpt-5"]}
              ]
            }
        """.trimIndent()

        assertEquals(
            listOf("gpt-5", "gpt-5.5", "claude-sonnet-4-6@default"),
            AiCoach.parseOpenAiCompatibleModels(AiProvider.CUSTOM, body),
        )
    }

    @Test
    fun `openai provider still filters data envelope to chat models`() {
        val body = """
            {
              "data": [
                {"id": "gpt-5"},
                {"id": "o4-mini"},
                {"id": "text-embedding-3-large"}
              ]
            }
        """.trimIndent()

        assertEquals(
            listOf("gpt-5", "o4-mini"),
            AiCoach.parseOpenAiCompatibleModels(AiProvider.OPENAI, body),
        )
    }
}
