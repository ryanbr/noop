package com.noop.push

import kotlinx.coroutines.CancellationException
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** Coordinates bounded Room snapshots and transport without holding a database read across network I/O. */
class PushCoordinator(
    private val source: PushSnapshotSource,
    private val transport: PushTransport,
    private val progress: PushProgressStore,
    private val sourceId: String,
    private val today: () -> LocalDate,
    private val zoneId: ZoneId,
    private val destinationStillCurrent: () -> Boolean = { true },
) {
    suspend fun pushAppend(table: PushAppendTable, deviceId: String): PushResult {
        val stored = try {
            progress.cursor(table, deviceId)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATABASE))
        }
        val effective = if (stored == null || stored.rowId <= 0) {
            null
        } else {
            val atCursor = try {
                source.appendRecordAt(table, deviceId, stored.rowId)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (invalid: PushProtocolException) {
                return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
            } catch (_: Throwable) {
                return rejected(PushFailure(PushFailureCode.LOCAL_DATABASE))
            }
            val fingerprint = atCursor?.let { PushProtocol.keyFingerprint(table, deviceId, it.key) }
            if (fingerprint == stored.naturalKeyFingerprint) stored else null
        }
        val rows = try {
            source.appendRows(table, deviceId, effective?.rowId ?: 0L, PushProtocol.MAX_RECORDS + 1)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (invalid: PushProtocolException) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
        } catch (_: Throwable) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATABASE))
        }
        if (rows.isEmpty()) return PushResult.NoData
        val batch = try {
            PushProtocol.appendBatch(table, sourceId, deviceId, effective, rows)
        } catch (t: PushProtocolException) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
        }
        val accepted = deliver(batch)
        if (accepted !is PushResult.Accepted) return accepted
        val end = batch.endCursor ?: return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
        return try {
            progress.saveCursor(table, deviceId, end)
            accepted.copy(hasMore = rows.size > batch.recordCount)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (invalid: PushProtocolException) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
        } catch (_: Throwable) {
            // The endpoint may have applied the bytes. Keeping the old cursor safely repeats the same upserts.
            rejected(PushFailure(PushFailureCode.LOCAL_DATABASE))
        }
    }

    suspend fun pushMutable(table: PushMutableTable, deviceId: String): PushResult {
        val fullWindow = PushWindow.ending(today(), zoneId)
        val rows = try {
            source.mutableRows(
                table, deviceId, fullWindow, PushProtocol.MAX_MUTABLE_SNAPSHOT_RECORDS + 1,
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (invalid: PushProtocolException) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
        } catch (_: Throwable) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATABASE))
        }
        if (rows.size > PushProtocol.MAX_MUTABLE_SNAPSHOT_RECORDS) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
        }
        var encodedBytes = 0L
        val days = generateSequence(LocalDate.parse(fullWindow.fromDay)) { previous ->
            previous.plusDays(1).takeUnless { it.isAfter(LocalDate.parse(fullWindow.toDay)) }
        }.toList()
        val recordsByDay = days.associateWith { mutableListOf<PushMutableRecord>() }
        for (record in rows) {
            val size = try {
                PushProtocol.mutableRecordEncodedSize(table, record)
            } catch (t: PushProtocolException) {
                return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
            }
            encodedBytes += size
            if (encodedBytes > PushProtocol.MAX_MUTABLE_SNAPSHOT_ENCODED_BYTES) {
                return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
            }
            val day = try {
                mutableRecordDay(table, record)
            } catch (_: PushProtocolException) {
                return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
            }
            val bucket = recordsByDay[day]
                ?: return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
            bucket += record
        }
        val currentHashes = try {
            recordsByDay.mapKeys { (day, _) -> day.toString() }
                .mapValues { (_, dayRows) -> PushProtocol.mutableSnapshotHash(table, dayRows) }
        } catch (_: PushProtocolException) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
        }
        val previousHashes = try {
            progress.window(table, deviceId)?.dayHashes.orEmpty()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATABASE))
        }
        val changedDays = days.filter { day -> previousHashes[day.toString()] != currentHashes[day.toString()] }
        if (changedDays.isEmpty()) return PushResult.NoData
        val window = PushWindow.days(changedDays.first(), changedDays.last(), zoneId)
        val changedRows = days.asSequence()
            .filter { it >= changedDays.first() && it <= changedDays.last() }
            .flatMap { recordsByDay.getValue(it).asSequence() }
            .toList()
        val batches = try {
            PushProtocol.mutableBatches(table, sourceId, deviceId, window, changedRows)
        } catch (t: PushProtocolException) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
        }
        for (batch in batches) {
            val accepted = deliver(batch)
            if (accepted !is PushResult.Accepted) return accepted
        }
        val replacementId = batches.first().replacementId ?: batches.first().batchId
        return try {
            progress.saveWindow(
                table,
                deviceId,
                PushWindowProgress(fullWindow, replacementId, currentHashes),
            )
            PushResult.Accepted(
                batchId = replacementId,
                recordCount = changedRows.size,
                hasMore = false,
                batchCount = batches.size,
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            rejected(PushFailure(PushFailureCode.LOCAL_DATABASE))
        }
    }

    private fun mutableRecordDay(table: PushMutableTable, record: PushMutableRecord): LocalDate = when (table) {
        PushMutableTable.DAILY_METRIC, PushMutableTable.JOURNAL -> {
            val value = record.key["day"] as? String
                ?: throw PushProtocolException("mutable day key is not a string")
            runCatching { LocalDate.parse(value) }
                .getOrElse { throw PushProtocolException("mutable day key is invalid") }
        }
        PushMutableTable.SLEEP_SESSION, PushMutableTable.WORKOUT -> {
            val value = record.key["startTs"]
            val timestamp = when (value) {
                is Byte, is Short, is Int, is Long -> (value as Number).toLong()
                else -> throw PushProtocolException("mutable startTs key is not an integer")
            }
            runCatching { Instant.ofEpochSecond(timestamp).atZone(zoneId).toLocalDate() }
                .getOrElse { throw PushProtocolException("mutable startTs key is invalid") }
        }
    }

    /** One append page and one checksum-minimized mutable replacement per actual source device. */
    suspend fun pushKnownDevices(
        startDeviceIndex: Int = 0,
        maxDevices: Int = Int.MAX_VALUE,
        capabilities: PushCapabilities = PushCapabilities.ALL,
    ): PushRunResult {
        require(startDeviceIndex >= 0)
        require(maxDevices > 0)
        if (capabilities.isEmpty) {
            return PushRunResult(
                acceptedBatches = 0,
                acceptedRecords = 0,
                rejectedBatches = 0,
                hasMoreAppendRows = false,
            )
        }
        val devices = try {
            val live = source.knownDeviceIds(capabilities).filter(String::isNotBlank).distinct()
            live.forEach { progress.rememberDeviceId(it) }
            (live + progress.knownDeviceIds()).filter(String::isNotBlank).distinct().sorted()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            val failure = PushFailure(PushFailureCode.LOCAL_DATABASE)
            return PushRunResult(acceptedBatches = 0, acceptedRecords = 0, rejectedBatches = 1, hasMoreAppendRows = false, hasRetryableFailure = true, failure = failure)
        }
        if (devices.isEmpty()) return PushRunResult(acceptedBatches = 0, acceptedRecords = 0, rejectedBatches = 0, hasMoreAppendRows = false)
        val start = startDeviceIndex % devices.size
        val selectedCount = minOf(maxDevices, devices.size)
        val selectedDevices = (0 until selectedCount).map { devices[(start + it) % devices.size] }
        val nextDeviceIndex = (start + selectedCount) % devices.size
        var accepted = 0
        var acceptedRecords = 0
        var rejected = 0
        var more = false
        var retryableFailure = false
        var selectedFailure: PushFailure? = null
        for (deviceId in selectedDevices) {
            for (table in PushAppendTable.entries.filter { it in capabilities.appendTables }) {
                when (val result = pushAppend(table, deviceId)) {
                    is PushResult.Accepted -> {
                        accepted += result.batchCount
                        acceptedRecords += result.recordCount
                        more = more || result.hasMore
                    }
                    is PushResult.Rejected -> {
                        rejected += 1
                        if (selectedFailure == null || result.retryable && !retryableFailure) {
                            selectedFailure = result.failure
                        }
                        retryableFailure = retryableFailure || result.retryable
                    }
                    PushResult.NoData -> Unit
                }
            }
            for (table in PushMutableTable.entries.filter { it in capabilities.mutableTables }) {
                when (val result = pushMutable(table, deviceId)) {
                    is PushResult.Accepted -> {
                        accepted += result.batchCount
                        acceptedRecords += result.recordCount
                    }
                    is PushResult.Rejected -> {
                        rejected += 1
                        if (selectedFailure == null || result.retryable && !retryableFailure) {
                            selectedFailure = result.failure
                        }
                        retryableFailure = retryableFailure || result.retryable
                    }
                    PushResult.NoData -> Unit
                }
            }
        }
        return PushRunResult(
            acceptedBatches = accepted,
            acceptedRecords = acceptedRecords,
            rejectedBatches = rejected,
            hasMoreAppendRows = more,
            hasRetryableFailure = retryableFailure,
            nextDeviceIndex = nextDeviceIndex,
            hasMoreDevices = devices.size > selectedCount,
            failure = selectedFailure,
        )
    }

    private suspend fun deliver(batch: PushBatch): PushResult {
        if (!destinationStillCurrent()) {
            throw CancellationException("push destination changed")
        }
        val response = try {
            transport.post(batch)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (transport: PushTransportException) {
            return rejected(transport.failure)
        } catch (_: Throwable) {
            return rejected(PushFailure(PushFailureCode.NETWORK_IO))
        }
        if (response.body.size > PushProtocol.MAX_ACK_BYTES) {
            return rejected(PushFailure(PushFailureCode.ACK_INVALID))
        }
        if (response.statusCode !in 200..299) {
            return rejected(
                PushFailure.http(response.statusCode, PushError.parseCode(response.body, batch.protocolVersion)),
            )
        }
        val ack = try {
            PushAck.parse(response.body)
        } catch (t: PushProtocolException) {
            return rejected(PushFailure(PushFailureCode.ACK_INVALID))
        }
        if (!ack.exactlyMatches(batch)) {
            return rejected(PushFailure(PushFailureCode.ACK_INVALID))
        }
        return PushResult.Accepted(batch.batchId, batch.recordCount, hasMore = false)
    }

    private fun rejected(failure: PushFailure) =
        PushResult.Rejected(failure.safeCode, failure.retryable, failure)
}
