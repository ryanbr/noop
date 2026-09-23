package com.noop.oura

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Oracle test for the SpO2 channel resolver and its strap-log line.
 *
 * WHY AN ORACLE AND NOT A HAND-WRITTEN EXPECTATION. The defect this whole type fixes was two numbers
 * three orders of magnitude apart being printed under the same words. Two platforms hand-writing
 * "what we call this channel" is how that comes back — one side says "perfusion", the other "DC", and
 * nobody notices until a reporter pastes a log and is told the wrong thing. So the literals below are
 * NOT written by hand: they are the verbatim stdout of the SHIPPED Swift function, captured with
 *
 *     swift build   # in Packages/OuraProtocol
 *     swiftc -O -I <build>/Products/Debug -L <build>/Products/Debug -lOuraProtocol main.swift -o oracle
 *     ./oracle
 *
 * where main.swift prints `value|unit|channel|OuraSpO2Channel.firstDecodedLogLine(value:unit:)` for
 * each row. Re-capture and re-paste if the Swift side ever changes; do not edit these by eye.
 *
 * NOTE ON DIRECTION: this guards Kotlin against the Swift of the day. `OuraSpO2ChannelTests` on the
 * Swift side pins the same dispositions, which is what stops Swift drifting silently.
 */
class OuraSpO2ChannelOracleTest {

    /** `value|unit|channel|line` — verbatim Swift stdout. */
    private val oracle = listOf(
        """93|raw|percentage|first SpO2 percentage decoded (last night) - 93 % (channel "raw")""",
        """94|raw|percentage|first SpO2 percentage decoded (last night) - 94 % (channel "raw")""",
        """98|raw|percentage|first SpO2 percentage decoded (last night) - 98 % (channel "raw")""",
        """0|raw|percentage|first SpO2 percentage decoded (last night) - 0 % (channel "raw")""",
        """100|raw|percentage|first SpO2 percentage decoded (last night) - 100 % (channel "raw")""",
        """101144|dc_raw|perfusion|first SpO2 raw DC perfusion (NOT a percentage) decoded (last night) - 101144 (channel "dc_raw")""",
        """-288|dc_raw|perfusion|first SpO2 raw DC perfusion (NOT a percentage) decoded (last night) - -288 (channel "dc_raw")""",
        """41132|dc_raw|perfusion|first SpO2 raw DC perfusion (NOT a percentage) decoded (last night) - 41132 (channel "dc_raw")""",
        """65815|dc_raw|perfusion|first SpO2 raw DC perfusion (NOT a percentage) decoded (last night) - 65815 (channel "dc_raw")""",
        """208|dc_raw|perfusion|first SpO2 raw DC perfusion (NOT a percentage) decoded (last night) - 208 (channel "dc_raw")""",
        """1|raw_adc|percentage|first SpO2 percentage decoded (last night) - 1 % (channel "raw_adc")""",
        """2||percentage|first SpO2 percentage decoded (last night) - 2 % (channel "")""",
        """3|DC_RAW|percentage|first SpO2 percentage decoded (last night) - 3 % (channel "DC_RAW")""",
    )

    @Test
    fun kotlinMatchesTheSwiftOracleRowForRow() {
        for (row in oracle) {
            val parts = row.split("|", limit = 4)
            val value = parts[0].toInt()
            val unit = parts[1]
            val expectedChannel = parts[2]
            val expectedLine = parts[3]

            assertEquals(
                "channel for unit \"$unit\"",
                expectedChannel,
                OuraSpO2Channel.forUnit(unit).name.lowercase(),
            )
            assertEquals(
                "log line for $value ($unit)",
                expectedLine,
                OuraSpO2Channel.firstDecodedLogLine(value, unit),
            )
        }
    }

    /** The sample accessor and the resolver must not be able to disagree. */
    @Test
    fun sampleAccessorMatchesTheResolver() {
        assertEquals(OuraSpO2Channel.PERCENTAGE, OuraSpO2(ringTimestamp = 1L, value = 93).channel)
        assertEquals(
            OuraSpO2Channel.PERFUSION,
            OuraSpO2(ringTimestamp = 1L, value = 101144, unit = "dc_raw").channel,
        )
    }

    /**
     * The decoders really do stamp those tags — without this the resolver could be right about strings
     * nothing produces. Mirrors the Swift `testDecodedSpO2*` cases.
     */
    @Test
    fun decodersProduceTheChannelsTheResolverNames() {
        val perSample = OuraDecoders.decodeSpO2PerSample(
            OuraRecord(type = 0x6F, ringTimestamp = 100L, payload = intArrayOf(0x00, 95, 96, 97)),
        )
        assertEquals(true, perSample!!.isNotEmpty())
        assertEquals(true, perSample.all { it.channel == OuraSpO2Channel.PERCENTAGE })

        val dc = OuraDecoders.decodeSpO2DC(
            OuraRecord(
                type = 0x77,
                ringTimestamp = 100L,
                payload = intArrayOf(0x40, 0x2C, 0xA0, 0x00, 0x05),
            ),
        )
        assertEquals(true, dc!!.isNotEmpty())
        assertEquals(true, dc.all { it.channel == OuraSpO2Channel.PERFUSION })

        val stable = OuraDecoders.decodeSpO2Stable(
            OuraRecord(type = 0x7B, ringTimestamp = 100L, payload = intArrayOf(0x00, 0x60)),
        )
        assertEquals(OuraSpO2Channel.PERCENTAGE, stable!!.channel)
    }
}
