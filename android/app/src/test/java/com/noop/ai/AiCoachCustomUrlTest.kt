package com.noop.ai

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * #1074: the Custom base URL normalises so the derived /chat/completions and /models endpoints
 * resolve whether the user pastes the API root or the full chat URL — the latter previously broke
 * the model scan (it hit .../chat/completions/models).
 */
class AiCoachCustomUrlTest {

    @Test fun apiRootIsKeptAsIs() {
        assertEquals("https://api.deepseek.com", AiCoach.normalizeCustomBaseUrl("https://api.deepseek.com"))
        assertEquals("https://api.deepseek.com/v1", AiCoach.normalizeCustomBaseUrl("https://api.deepseek.com/v1"))
    }

    @Test fun trailingSlashTrimmed() {
        assertEquals("https://api.deepseek.com/v1", AiCoach.normalizeCustomBaseUrl("https://api.deepseek.com/v1/"))
    }

    @Test fun pastedFullChatUrlIsStrippedToTheBase() {
        assertEquals("https://api.deepseek.com/v1",
            AiCoach.normalizeCustomBaseUrl("https://api.deepseek.com/v1/chat/completions"))
        assertEquals("https://api.deepseek.com",
            AiCoach.normalizeCustomBaseUrl("https://api.deepseek.com/chat/completions"))
        // trailing slash on the pasted chat URL too
        assertEquals("https://api.deepseek.com/v1",
            AiCoach.normalizeCustomBaseUrl("https://api.deepseek.com/v1/chat/completions/"))
    }

    @Test fun localServerRootUnaffected() {
        assertEquals("http://192.168.1.10:11434/v1",
            AiCoach.normalizeCustomBaseUrl("http://192.168.1.10:11434/v1"))
    }
}
