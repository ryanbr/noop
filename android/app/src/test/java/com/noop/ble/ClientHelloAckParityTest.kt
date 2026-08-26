package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Byte-identical parity oracle for [completionIsClientHelloAck] against the Swift
 * `ClientHelloOutcome.isAck`. The expected block is the verbatim stdout of the compiled Swift twin over
 * the full 16-row input space, so a one-sided edit to either platform fails here rather than drifting.
 */
class ClientHelloAckParityTest {
    @Test
    fun `the full truth table matches the Swift twin`() {
        val out = StringBuilder()
        for (a in listOf(false, true)) for (b in listOf(false, true))
            for (c in listOf(false, true)) for (d in listOf(false, true))
                out.append("$a$b$c$d=${completionIsClientHelloAck(a, b, c, d)}\n")
        // trimStart: the raw literal opens with a newline that the Swift stdout does not have.
        assertEquals(SWIFT.trimStart('\n'), out.toString())
    }

    private companion object {
        const val SWIFT = """
falsefalsefalsefalse=false
falsefalsefalsetrue=false
falsefalsetruefalse=false
falsefalsetruetrue=false
falsetruefalsefalse=false
falsetruefalsetrue=false
falsetruetruefalse=false
falsetruetruetrue=false
truefalsefalsefalse=false
truefalsefalsetrue=false
truefalsetruefalse=false
truefalsetruetrue=false
truetruefalsefalse=false
truetruefalsetrue=true
truetruetruefalse=false
truetruetruetrue=false
"""
    }
}
