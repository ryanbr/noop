package com.noop.ai

/**
 * One turn in the coach conversation.
 *
 * @param id stable identifier (UUID string). Used by K1 streaming to find and replace the
 *   placeholder assistant message as chunks arrive. Defaults to a new UUID so existing callers
 *   are unaffected.
 * @param role "user" or "assistant" — the only two roles the UI history carries. The
 *   system prompt is supplied separately by [AiCoach] and is never stored here.
 * @param text plain-text message body.
 */
data class ChatMsg(
    val id: String = java.util.UUID.randomUUID().toString(),
    val role: String, // "user" | "assistant"
    val text: String,
)
