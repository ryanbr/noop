package com.noop.ble

import com.noop.data.WhoopDao
import com.noop.data.WhoopRepository
import com.noop.protocol.Crc
import com.noop.protocol.Framing
import java.lang.reflect.Proxy
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Runs the actual suspend persistence path, including retirement while storage is blocked. */
class BackfillerRetirementTest {
    private fun end(trim: Long): ByteArray {
        val frame = ByteArray(29)
        frame[0] = 0xAA.toByte()
        frame[1] = 25
        frame[3] = Crc.crc8(byteArrayOf(25, 0)).toByte()
        frame[4] = 49
        frame[6] = 2
        val bytes = ByteBuffer.wrap(frame).order(ByteOrder.LITTLE_ENDIAN)
        bytes.putInt(7, (System.currentTimeMillis() / 1000).toInt())
        bytes.putInt(17, trim.toInt())
        bytes.putInt(25, Crc.crc32(frame, 4, 25).toInt())
        assertTrue(Framing.parseFrame(frame).ok)
        return frame
    }

    private fun record(): ByteArray {
        val json = javaClass.classLoader!!.getResourceAsStream("decoder_oracle.json")!!
            .bufferedReader().use { JSONObject(it.readText()) }
        val hex = json.getJSONArray("frames").getJSONObject(0).getString("hex")
        return hex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    }

    private fun repository(transactor: WhoopRepository.Transactor): WhoopRepository {
        val dao = Proxy.newProxyInstance(WhoopDao::class.java.classLoader, arrayOf(WhoopDao::class.java)) {
                _, method, args ->
            check(method.name.startsWith("insert")) { "unexpected DAO call ${method.name}" }
            (args!![0] as List<*>).map { 1L }
        } as WhoopDao
        return WhoopRepository(dao, transactor)
    }

    @Test(timeout = 10_000) fun dataThenDurableCursorThenAckAndFailedCursorHoldsAck() = runBlocking {
        val calls = mutableListOf<String>()
        val repo = repository(object : WhoopRepository.Transactor {
            override suspend fun <R> run(block: suspend () -> R): R = block().also { calls += "data" }
        })
        var failCursor = false
        val backfiller = Backfiller(repo, "test", object : TrimCursorStore {
            override suspend fun set(name: String, value: Long) {
                if (failCursor) error("disk full")
                calls += "cursor:$value"
            }
            override suspend fun get(name: String): Long? = null
        }, ackTrim = { trim, _ -> calls += "ack:$trim" })
        backfiller.begin()
        backfiller.ingest(record())
        backfiller.ingest(end(10))
        assertEquals(listOf("data", "cursor:10", "ack:10"), calls)
        failCursor = true
        backfiller.ingest(record())
        backfiller.ingest(end(11))
        assertEquals(listOf("data", "cursor:10", "ack:10", "data"), calls)
        assertTrue(backfiller.persistStalled)
    }

    @Test(timeout = 10_000) fun retirementDuringDataPersistHoldsCursorAndAckUntilSafeResume() = runBlocking {
        val gate = OffloadSession(60_000)
        val old = gate.begin(0, null)!!
        val entered = CompletableDeferred<Unit>()
        val resume = CompletableDeferred<Unit>()
        val calls = mutableListOf<String>()
        var blockStorage = true
        val repo = repository(object : WhoopRepository.Transactor {
            override suspend fun <R> run(block: suspend () -> R): R {
                val result = block()
                if (blockStorage) { entered.complete(Unit); resume.await() }
                calls += "data"
                return result
            }
        })
        val backfiller = Backfiller(repo, "test", object : TrimCursorStore {
            override suspend fun set(name: String, value: Long) { calls += "cursor:$value" }
            override suspend fun get(name: String): Long? = null
        }, ackTrim = { trim, _ -> calls += "ack:$trim" }, sessionActive = { gate.current() != null })
        backfiller.begin()
        backfiller.ingest(record())
        val worker = launch {
            assertTrue(gate.enter(old))
            try { backfiller.ingest(end(10)) } finally { gate.leave() }
        }
        entered.await()
        gate.retire()
        backfiller.timeoutFired()
        assertNull(gate.begin(60_000, null))
        resume.complete(Unit)
        worker.join()
        assertEquals(listOf("data"), calls)
        assertNull(backfiller.lastAckedTrim)
        blockStorage = false
        assertNotNull(gate.begin(61_000, null))
        backfiller.begin()
        backfiller.ingest(record())
        backfiller.ingest(end(10))
        assertEquals(listOf("data", "data", "cursor:10", "ack:10"), calls)
    }

    @Test(timeout = 10_000) fun retirementDuringCursorWriteCannotAckOrOverwriteReplacementCursor() = runBlocking {
        val gate = OffloadSession(60_000)
        val old = gate.begin(0, null)!!
        val entered = CompletableDeferred<Unit>()
        val resume = CompletableDeferred<Unit>()
        var durableCursor: Long? = null
        val acks = mutableListOf<Long>()
        var blockStorage = true
        val repo = repository(object : WhoopRepository.Transactor {
            override suspend fun <R> run(block: suspend () -> R): R = block()
        })
        val backfiller = Backfiller(repo, "test", object : TrimCursorStore {
            override suspend fun set(name: String, value: Long) {
                if (blockStorage) { entered.complete(Unit); resume.await() }
                durableCursor = value
            }
            override suspend fun get(name: String): Long? = durableCursor
        }, ackTrim = { trim, _ -> acks += trim }, sessionActive = { gate.current() != null })
        backfiller.begin()
        val worker = launch {
            assertTrue(gate.enter(old))
            try { backfiller.ingest(end(10)) } finally { gate.leave() }
        }
        entered.await()
        gate.retire()
        backfiller.timeoutFired()
        assertNull(gate.begin(60_000, null))
        resume.complete(Unit)
        worker.join()
        assertEquals(10L, durableCursor)
        assertTrue(acks.isEmpty())
        blockStorage = false
        assertNotNull(gate.begin(61_000, durableCursor))
        backfiller.begin()
        backfiller.ingest(end(11))
        assertEquals(11L, durableCursor)
        assertEquals(listOf(11L), acks)
    }
}
