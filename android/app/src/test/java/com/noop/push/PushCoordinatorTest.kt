package com.noop.push

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId

class PushCoordinatorTest {
    /**
     * A PINNED "today" for every coordinator built in this file.
     *
     * `PushCoordinator` defaults to `LocalDate.now()` and `PushWindow` spans `today.minusDays(13)`, so a
     * test that omits it silently depends on the wall clock. The journal fixtures here are dated
     * 2026-08-18, which sat inside that window until 2026-09-01 and then fell out: CI was green at
     * 23:21Z on 31 Aug and red at 00:13Z on 1 Sep, with `expected:<[journal]> but was:<[]>`. Nothing had
     * changed but the date. Pin it, and the suite asserts the coordinator's behaviour rather than the
     * calendar's.
     */
    private val pinnedToday = { LocalDate.of(2026, 8, 18) }

    @Test
    fun endpointChangeFencesRemainingPostsToCapturedDestination() = runBlocking {
        val settings = SelfHostedPushSettings.forTest(
            SelfHostedPushSettingsTest.FakePushPrefs(),
            SelfHostedPushSettingsTest.FakePushPrefs(),
        )
        val first = (PushEndpointPolicy.validate("https://one.example/push") as PushEndpointPolicy.Result.Valid).endpoint
        val second = (PushEndpointPolicy.validate("https://two.example/push") as PushEndpointPolicy.Result.Valid).endpoint
        settings.saveEndpoint(first.url)
        settings.saveToken("secret")
        assertTrue(settings.setEnabled(true))
        val source = FakePushSource(
            append = mutableMapOf(
                key(PushAppendTable.HR_SAMPLE, "a") to mutableListOf(hr(1, 100)),
                key(PushAppendTable.BATTERY, "a") to mutableListOf(
                    PushAppendRecord(2, linkedMapOf("ts" to 101L), linkedMapOf("soc" to 80.0, "mv" to null, "charging" to false)),
                ),
            ),
        )
        val transport = object : PushTransport {
            var posts = 0
            override suspend fun post(batch: PushBatch): PushTransportResponse {
                posts++
                if (posts == 1) settings.saveEndpoint(second.url)
                return PushTransportResponse(200, PushAck.fromBatch(batch).encode())
            }
        }

        try {
            PushCoordinator(
                source, transport, MemoryProgress(), SOURCE_A, pinnedToday, ZoneId.of("UTC"),
                destinationStillCurrent = { settings.enabledEndpoint() == first },
            ).pushKnownDevices(
                capabilities = PushCapabilities(
                    appendTables = setOf(PushAppendTable.HR_SAMPLE, PushAppendTable.BATTERY),
                    mutableTables = emptySet(),
                ),
            )
        } catch (_: kotlinx.coroutines.CancellationException) {
            // Destination rotation deliberately aborts the captured run before another POST.
        }

        assertEquals(1, transport.posts)
    }

    @Test
    fun exactAckIsRequiredBeforeCursorAdvances() = runBlocking {
        val row = hr(1, 100)
        val source = FakePushSource(append = mutableMapOf(key(PushAppendTable.HR_SAMPLE, "a") to mutableListOf(row)))
        val progress = MemoryProgress()
        val partial = AckingTransport { batch -> PushAck.fromBatch(batch).copy(acceptedRows = 0) }

        val result = PushCoordinator(source, partial, progress, SOURCE_A, pinnedToday, ZoneId.of("UTC")).pushAppend(PushAppendTable.HR_SAMPLE, "a")

        assertTrue(result is PushResult.Rejected)
        assertTrue(progress.cursors.isEmpty())
    }

    @Test
    fun acceptedStatusAndFullCursorFingerprintMustMatch() = runBlocking {
        val row = hr(1, 100)
        val source = FakePushSource(append = mutableMapOf(key(PushAppendTable.HR_SAMPLE, "a") to mutableListOf(row)))
        val progress = MemoryProgress()
        val wrongStatus = AckingTransport { batch -> PushAck.fromBatch(batch).copy(status = "partial") }

        val result = PushCoordinator(source, wrongStatus, progress, SOURCE_A, pinnedToday, ZoneId.of("UTC"))
            .pushAppend(PushAppendTable.HR_SAMPLE, "a")

        assertTrue(result is PushResult.Rejected)
        assertTrue(progress.cursors.isEmpty())
    }

    @Test
    fun malformedAckLeavesProgressAndRetryBytesUnchanged() = runBlocking {
        val source = FakePushSource(
            append = mutableMapOf(key(PushAppendTable.HR_SAMPLE, "a") to mutableListOf(hr(1, 100))),
        )
        val progress = MemoryProgress()
        val malformed = object : PushTransport {
            val bodies = mutableListOf<ByteArray>()
            override suspend fun post(batch: PushBatch): PushTransportResponse {
                bodies += batch.body.copyOf()
                return PushTransportResponse(200, "{not-json".toByteArray())
            }
        }
        val coordinator = PushCoordinator(source, malformed, progress, SOURCE_A, pinnedToday, ZoneId.of("UTC"))

        coordinator.pushAppend(PushAppendTable.HR_SAMPLE, "a")
        coordinator.pushAppend(PushAppendTable.HR_SAMPLE, "a")

        assertTrue(progress.cursors.isEmpty())
        assertArrayEquals(malformed.bodies[0], malformed.bodies[1])
    }

    @Test
    fun oversizedAckIsRejectedBeforeParsing() = runBlocking {
        val source = FakePushSource(
            append = mutableMapOf(key(PushAppendTable.HR_SAMPLE, "a") to mutableListOf(hr(1, 100))),
        )
        val progress = MemoryProgress()
        val transport = object : PushTransport {
            override suspend fun post(batch: PushBatch) = PushTransportResponse(
                200,
                ByteArray(PushProtocol.MAX_ACK_BYTES + 1) { 'x'.code.toByte() },
            )
        }

        val result = PushCoordinator(source, transport, progress, SOURCE_A, pinnedToday, ZoneId.of("UTC")).pushAppend(PushAppendTable.HR_SAMPLE, "a")

        assertTrue(result is PushResult.Rejected)
        assertTrue(progress.cursors.isEmpty())
    }

    @Test
    fun ackWithUndocumentedCommandIsRejectedWithoutAdvancing() = runBlocking {
        val source = FakePushSource(
            append = mutableMapOf(key(PushAppendTable.HR_SAMPLE, "a") to mutableListOf(hr(1, 100))),
        )
        val progress = MemoryProgress()
        val transport = object : PushTransport {
            override suspend fun post(batch: PushBatch): PushTransportResponse {
                val accepted = PushAck.fromBatch(batch).encode().toString(Charsets.UTF_8)
                val withCommand = accepted.dropLast(1) + ",\"command\":\"delete-local-data\"}"
                return PushTransportResponse(200, withCommand.toByteArray())
            }
        }

        val result = PushCoordinator(source, transport, progress, SOURCE_A, pinnedToday, ZoneId.of("UTC"))
            .pushAppend(PushAppendTable.HR_SAMPLE, "a")

        assertTrue(result is PushResult.Rejected)
        assertTrue(progress.cursors.isEmpty())
    }

    @Test
    fun httpAndTransportFailuresNeverAdvanceAndRetryOnlyTransientClasses() = runBlocking {
        val expected = listOf(401 to false, 408 to true, 429 to true, 500 to true)
        for ((status, retryable) in expected) {
            val source = FakePushSource(
                append = mutableMapOf(key(PushAppendTable.HR_SAMPLE, "a") to mutableListOf(hr(1, 100))),
            )
            val progress = MemoryProgress()
            val transport = object : PushTransport {
                override suspend fun post(batch: PushBatch) = PushTransportResponse(status, ByteArray(0))
            }

            val result = PushCoordinator(source, transport, progress, SOURCE_A, pinnedToday, ZoneId.of("UTC"))
                .pushAppend(PushAppendTable.HR_SAMPLE, "a")

            assertTrue("HTTP $status", result is PushResult.Rejected && result.retryable == retryable)
            assertTrue("HTTP $status moved cursor", progress.cursors.isEmpty())
        }

        val progress = MemoryProgress()
        val throwing = object : PushTransport {
            override suspend fun post(batch: PushBatch): PushTransportResponse = throw java.io.IOException("timeout")
        }
        val result = PushCoordinator(
            FakePushSource(
                append = mutableMapOf(key(PushAppendTable.HR_SAMPLE, "a") to mutableListOf(hr(1, 100))),
            ),
            throwing,
            progress,
            SOURCE_A,
            pinnedToday,
            ZoneId.of("UTC"),
        ).pushAppend(PushAppendTable.HR_SAMPLE, "a")
        assertTrue(result is PushResult.Rejected && result.retryable)
        assertTrue(progress.cursors.isEmpty())
    }

    @Test
    fun emptyMutableWindowPropagatesDeletionAndAdvancesOnlyOnExactAck() = runBlocking {
        val source = FakePushSource()
        val progress = MemoryProgress()
        val transport = AckingTransport()
        val coordinator = PushCoordinator(
            source,
            transport,
            progress,
            SOURCE_A,
            today = { LocalDate.of(2026, 8, 18) },
            zoneId = ZoneId.of("Europe/Berlin"),
        )

        val result = coordinator.pushMutable(PushMutableTable.JOURNAL, "noop-journal")

        assertTrue(result is PushResult.Accepted)
        assertEquals(0, transport.batches.single().recordCount)
        assertEquals("replace_window", transport.batches.single().mode)
        assertEquals("2026-08-05", transport.batches.single().window?.fromDay)
        assertEquals(
            transport.batches.single().replacementId,
            progress.windows[key(PushMutableTable.JOURNAL, "noop-journal")]?.batchId,
        )
        assertEquals(14, progress.windows[key(PushMutableTable.JOURNAL, "noop-journal")]?.dayHashes?.size)
    }

    @Test
    fun unchangedMutableDaysSkipEveryHttpBatch() = runBlocking {
        val source = FakePushSource(
            mutable = mutableMapOf(
                key(PushMutableTable.JOURNAL, "a") to mutableListOf(journal("2026-08-18", "coffee")),
            ),
        )
        val progress = MemoryProgress()
        val today = { LocalDate.of(2026, 8, 18) }
        val first = AckingTransport()
        val coordinator = PushCoordinator(source, first, progress, SOURCE_A, today, ZoneId.of("UTC"))

        assertTrue(coordinator.pushMutable(PushMutableTable.JOURNAL, "a") is PushResult.Accepted)
        assertEquals(1, first.batches.size)

        val unchanged = AckingTransport()
        val result = PushCoordinator(source, unchanged, progress, SOURCE_A, today, ZoneId.of("UTC"))
            .pushMutable(PushMutableTable.JOURNAL, "a")

        assertEquals(PushResult.NoData, result)
        assertTrue(unchanged.batches.isEmpty())
    }

    @Test
    fun oneChangedDaySendsOnlyThatAuthoritativeDay() = runBlocking {
        val source = FakePushSource(
            mutable = mutableMapOf(
                key(PushMutableTable.JOURNAL, "a") to mutableListOf(
                    journal("2026-08-17", "coffee", notes = "old"),
                    journal("2026-08-18", "exercise", notes = "same"),
                ),
            ),
        )
        val progress = MemoryProgress()
        val today = { LocalDate.of(2026, 8, 18) }
        PushCoordinator(source, AckingTransport(), progress, SOURCE_A, today, ZoneId.of("UTC"))
            .pushMutable(PushMutableTable.JOURNAL, "a")
        source.mutable.getValue(key(PushMutableTable.JOURNAL, "a"))[0] =
            journal("2026-08-17", "coffee", notes = "changed")

        val changed = AckingTransport()
        val result = PushCoordinator(source, changed, progress, SOURCE_A, today, ZoneId.of("UTC"))
            .pushMutable(PushMutableTable.JOURNAL, "a")

        assertTrue(result is PushResult.Accepted)
        val batch = changed.batches.single()
        assertEquals("2026-08-17", batch.window?.fromDay)
        assertEquals("2026-08-17", batch.window?.toDay)
        assertEquals(1, batch.recordCount)
        assertTrue(batch.body.toString(Charsets.UTF_8).contains("changed"))
        assertFalse(batch.body.toString(Charsets.UTF_8).contains("exercise"))
    }

    @Test
    fun legacyWindowProgressWithoutDailyHashesForcesOneFullBaseline() = runBlocking {
        val source = FakePushSource(
            mutable = mutableMapOf(
                key(PushMutableTable.JOURNAL, "a") to mutableListOf(journal("2026-08-18", "coffee")),
            ),
        )
        val progress = MemoryProgress().apply {
            windows[key(PushMutableTable.JOURNAL, "a")] = PushWindowProgress(
                PushWindow.days(LocalDate.of(2026, 8, 5), LocalDate.of(2026, 8, 18), ZoneId.of("UTC")),
                "legacy-batch",
            )
        }
        val transport = AckingTransport()

        PushCoordinator(
            source, transport, progress, SOURCE_A,
            today = { LocalDate.of(2026, 8, 18) }, zoneId = ZoneId.of("UTC"),
        ).pushMutable(PushMutableTable.JOURNAL, "a")

        assertEquals("2026-08-05", transport.batches.single().window?.fromDay)
        assertEquals("2026-08-18", transport.batches.single().window?.toDay)
        assertEquals(14, progress.windows.getValue(key(PushMutableTable.JOURNAL, "a")).dayHashes.size)
    }

    @Test
    fun timestampSelectedStreamUsesLocalMidnightForChangedDay() = runBlocking {
        val zone = ZoneId.of("Europe/Berlin")
        val day = LocalDate.of(2026, 8, 17)
        val startTs = day.atTime(23, 30).atZone(zone).toEpochSecond()
        val source = FakePushSource(
            mutable = mutableMapOf(
                key(PushMutableTable.SLEEP_SESSION, "a") to mutableListOf(sleep(startTs, efficiency = 0.80)),
            ),
        )
        val progress = MemoryProgress()
        val today = { LocalDate.of(2026, 8, 18) }
        PushCoordinator(source, AckingTransport(), progress, SOURCE_A, today, zone)
            .pushMutable(PushMutableTable.SLEEP_SESSION, "a")
        source.mutable.getValue(key(PushMutableTable.SLEEP_SESSION, "a"))[0] =
            sleep(startTs, efficiency = 0.90)

        val changed = AckingTransport()
        PushCoordinator(source, changed, progress, SOURCE_A, today, zone)
            .pushMutable(PushMutableTable.SLEEP_SESSION, "a")

        val window = changed.batches.single().window ?: error("missing window")
        assertEquals(day.toString(), window.fromDay)
        assertEquals(day.toString(), window.toDay)
        assertEquals(day.atStartOfDay(zone).toEpochSecond(), window.startTsInclusive)
        assertEquals(day.plusDays(1).atStartOfDay(zone).toEpochSecond(), window.endTsExclusive)
    }

    @Test
    fun deletingLastRowSendsOneEmptyDayAndFailedAckKeepsOldHash() = runBlocking {
        val source = FakePushSource(
            mutable = mutableMapOf(
                key(PushMutableTable.JOURNAL, "a") to mutableListOf(journal("2026-08-17", "coffee")),
            ),
        )
        val progress = MemoryProgress()
        val today = { LocalDate.of(2026, 8, 18) }
        PushCoordinator(source, AckingTransport(), progress, SOURCE_A, today, ZoneId.of("UTC"))
            .pushMutable(PushMutableTable.JOURNAL, "a")
        val acceptedHashes = progress.windows.getValue(key(PushMutableTable.JOURNAL, "a")).dayHashes
        source.mutable.getValue(key(PushMutableTable.JOURNAL, "a")).clear()
        val rejecting = object : PushTransport {
            val batches = mutableListOf<PushBatch>()
            override suspend fun post(batch: PushBatch): PushTransportResponse {
                batches += batch
                return PushTransportResponse(500, ByteArray(0))
            }
        }

        val rejected = PushCoordinator(source, rejecting, progress, SOURCE_A, today, ZoneId.of("UTC"))
            .pushMutable(PushMutableTable.JOURNAL, "a")

        assertTrue(rejected is PushResult.Rejected)
        assertEquals("2026-08-17", rejecting.batches.single().window?.fromDay)
        assertEquals(0, rejecting.batches.single().recordCount)
        assertEquals(acceptedHashes, progress.windows.getValue(key(PushMutableTable.JOURNAL, "a")).dayHashes)

        val retry = AckingTransport()
        PushCoordinator(source, retry, progress, SOURCE_A, today, ZoneId.of("UTC"))
            .pushMutable(PushMutableTable.JOURNAL, "a")
        assertEquals("2026-08-17", retry.batches.single().window?.fromDay)
        assertEquals(0, retry.batches.single().recordCount)
    }

    @Test
    fun databaseSnapshotEndsBeforeTransportStarts() = runBlocking {
        val source = FakePushSource(
            append = mutableMapOf(key(PushAppendTable.HR_SAMPLE, "a") to mutableListOf(hr(1, 100))),
        )
        val transport = object : PushTransport {
            override suspend fun post(batch: PushBatch): PushTransportResponse {
                assertFalse("database read transaction must be closed before HTTP", source.reading)
                return PushTransportResponse(200, PushAck.fromBatch(batch).encode())
            }
        }

        PushCoordinator(source, transport, MemoryProgress(), SOURCE_A, pinnedToday, ZoneId.of("UTC"))
            .pushAppend(PushAppendTable.HR_SAMPLE, "a")
        Unit
    }

    @Test
    fun oversizedMutableWindowFailsBeforeHttpWithoutUnboundedAccumulation() = runBlocking {
        val huge = PushMutableRecord(
            linkedMapOf("day" to "2026-08-18", "question" to "large"),
            linkedMapOf(
                "answeredYes" to true,
                "notes" to "x".repeat(PushProtocol.MAX_MUTABLE_SNAPSHOT_ENCODED_BYTES + 1),
                "numericValue" to null,
            ),
        )
        val source = FakePushSource(
            mutable = mutableMapOf(key(PushMutableTable.JOURNAL, "a") to mutableListOf(huge)),
        )
        val transport = AckingTransport()

        val result = PushCoordinator(source, transport, MemoryProgress(), SOURCE_A, pinnedToday, ZoneId.of("UTC"))
            .pushMutable(PushMutableTable.JOURNAL, "a")

        assertTrue(result is PushResult.Rejected && !result.retryable)
        assertTrue(transport.batches.isEmpty())
    }

    @Test
    fun daoPreflightRejectionIsPermanentAndNeverStartsHttp() = runBlocking {
        val source = FakePushSource().apply {
            appendRowsFailure = PushProtocolException("snapshot exceeds local memory limit")
        }
        val transport = AckingTransport()

        val result = PushCoordinator(source, transport, MemoryProgress(), SOURCE_A, pinnedToday, ZoneId.of("UTC"))
            .pushAppend(PushAppendTable.EVENT, "a")

        assertTrue(result is PushResult.Rejected && !result.retryable)
        assertTrue(transport.batches.isEmpty())
    }

    @Test
    fun mutableDaoProtocolRejectionIsPermanentAndNeverStartsHttp() = runBlocking {
        val source = FakePushSource().apply {
            mutableRowsFailure = PushProtocolException("snapshot exceeds local memory limit")
        }
        val transport = AckingTransport()

        val result = PushCoordinator(source, transport, MemoryProgress(), SOURCE_A, pinnedToday, ZoneId.of("UTC"))
            .pushMutable(PushMutableTable.JOURNAL, "a")

        assertTrue(result is PushResult.Rejected && !result.retryable)
        assertTrue(transport.batches.isEmpty())
    }

    @Test
    fun boundedDeviceRotationGuaranteesLaterDeviceProgress() = runBlocking {
        val source = FakePushSource(
            append = mutableMapOf(
                key(PushAppendTable.HR_SAMPLE, "a") to mutableListOf(hr(1, 100)),
                key(PushAppendTable.HR_SAMPLE, "b") to mutableListOf(hr(2, 200)),
            ),
        )
        val progress = MemoryProgress()
        val firstTransport = AckingTransport()
        val first = PushCoordinator(source, firstTransport, progress, SOURCE_A, pinnedToday, ZoneId.of("UTC"))
            .pushKnownDevices(startDeviceIndex = 0, maxDevices = 1)

        assertTrue(first.hasMoreDevices)
        assertEquals(1, first.acceptedRecords)
        assertEquals(1, first.nextDeviceIndex)
        assertTrue(firstTransport.batches.isNotEmpty())
        assertTrue(firstTransport.batches.all { it.deviceId == "a" })

        val secondTransport = AckingTransport()
        val second = PushCoordinator(source, secondTransport, progress, SOURCE_A, pinnedToday, ZoneId.of("UTC"))
            .pushKnownDevices(startDeviceIndex = first.nextDeviceIndex, maxDevices = 1)

        assertEquals(0, second.nextDeviceIndex)
        assertTrue(secondTransport.batches.isNotEmpty())
        assertTrue(secondTransport.batches.all { it.deviceId == "b" })
    }

    @Test
    fun rememberedDeviceSendsEmptyReplacementAfterItsLastMutableRowIsDeleted() = runBlocking {
        val source = FakePushSource(
            mutable = mutableMapOf(
                key(PushMutableTable.JOURNAL, "noop-journal") to mutableListOf(
                    PushMutableRecord(
                        linkedMapOf("day" to "2026-08-18", "question" to "caffeine"),
                        linkedMapOf("answeredYes" to true, "notes" to null, "numericValue" to null),
                    ),
                ),
            ),
        )
        val progress = MemoryProgress()
        PushCoordinator(source, AckingTransport(), progress, SOURCE_A, pinnedToday, ZoneId.of("UTC"))
            .pushKnownDevices()
        source.mutable.remove(key(PushMutableTable.JOURNAL, "noop-journal"))

        val afterDelete = AckingTransport()
        PushCoordinator(source, afterDelete, progress, SOURCE_A, pinnedToday, ZoneId.of("UTC"))
            .pushKnownDevices()

        val journal = afterDelete.batches.single {
            it.deviceId == "noop-journal" && it.table == PushMutableTable.JOURNAL
        }
        assertEquals(0, journal.recordCount)
        assertEquals("replace_window", journal.mode)
    }

    @Test
    fun capabilitiesPreventEveryUnsupportedStreamSnapshotAndPost() = runBlocking {
        val source = FakePushSource(
            append = mutableMapOf(key(PushAppendTable.HR_SAMPLE, "a") to mutableListOf(hr(1, 10))),
            mutable = mutableMapOf(
                key(PushMutableTable.JOURNAL, "a") to mutableListOf(
                    PushMutableRecord(
                        linkedMapOf("day" to "2026-08-18", "question" to "coffee"),
                        linkedMapOf("answeredYes" to true, "notes" to null, "numericValue" to null),
                    ),
                ),
            ),
        )
        val transport = AckingTransport()
        val capabilities = PushCapabilities(
            appendTables = emptySet(),
            mutableTables = setOf(PushMutableTable.JOURNAL),
        )

        PushCoordinator(source, transport, MemoryProgress(), SOURCE_A, pinnedToday, ZoneId.of("UTC"))
            .pushKnownDevices(capabilities = capabilities)

        assertEquals(emptyList<PushAppendTable>(), source.appendTablesRead)
        assertEquals(listOf(PushMutableTable.JOURNAL), source.mutableTablesRead)
        assertEquals(capabilities, source.deviceDiscoveryCapabilities)
        assertEquals(listOf("journal"), transport.batches.map { it.table.wireName })
    }

    @Test
    fun emptyCapabilitiesAvoidEvenDeviceDiscovery() = runBlocking {
        val source = FakePushSource().apply { knownDeviceIdsFailure = AssertionError("Room must stay unopened") }

        val result = PushCoordinator(source, AckingTransport(), MemoryProgress(), SOURCE_A, pinnedToday, ZoneId.of("UTC"))
            .pushKnownDevices(capabilities = PushCapabilities(emptySet(), emptySet()))

        assertEquals(0, result.acceptedBatches)
        assertEquals(0, result.rejectedBatches)
    }

    @Test
    fun structuredTransportFailureSurvivesCoordinatorAggregation() = runBlocking {
        val source = FakePushSource(
            append = mutableMapOf(key(PushAppendTable.HR_SAMPLE, "a") to mutableListOf(hr(1, 10))),
        )
        val transport = object : PushTransport {
            override suspend fun post(batch: PushBatch): PushTransportResponse {
                throw PushTransportException(PushFailure(PushFailureCode.CONNECTION_REFUSED))
            }
        }

        val result = PushCoordinator(source, transport, MemoryProgress(), SOURCE_A, pinnedToday, ZoneId.of("UTC"))
            .pushKnownDevices(
                capabilities = PushCapabilities(setOf(PushAppendTable.HR_SAMPLE), emptySet()),
            )

        assertTrue(result.hasRetryableFailure)
        assertEquals(PushFailureCode.CONNECTION_REFUSED, result.failure?.code)
    }

    @Test
    fun boundedReceiverErrorCodeSurvivesHttpRejection() = runBlocking {
        val source = FakePushSource(
            append = mutableMapOf(key(PushAppendTable.HR_SAMPLE, "a") to mutableListOf(hr(1, 10))),
        )
        val transport = object : PushTransport {
            override suspend fun post(batch: PushBatch) = PushTransportResponse(
                422,
                """{"type":"error","protocolVersion":"1.0","code":"registry_mismatch","ignored":true}"""
                    .toByteArray(),
            )
        }

        val result = PushCoordinator(source, transport, MemoryProgress(), SOURCE_A, pinnedToday, ZoneId.of("UTC"))
            .pushKnownDevices(capabilities = PushCapabilities(setOf(PushAppendTable.HR_SAMPLE), emptySet()))

        assertEquals("registry_mismatch", result.failure?.receiverCode)
        assertFalse(result.hasRetryableFailure)
    }
}

internal fun key(table: PushTable, deviceId: String) = "${table.wireName}|$deviceId"

internal fun hr(rowId: Long, ts: Long) = PushAppendRecord(
    rowId,
    linkedMapOf("ts" to ts),
    linkedMapOf("bpm" to 60),
)

internal fun journal(day: String, question: String, notes: String? = null) = PushMutableRecord(
    linkedMapOf("day" to day, "question" to question),
    linkedMapOf("answeredYes" to true, "notes" to notes, "numericValue" to null),
)

internal fun sleep(startTs: Long, efficiency: Double) = PushMutableRecord(
    linkedMapOf("startTs" to startTs),
    linkedMapOf(
        "endTs" to startTs + 8 * 60 * 60,
        "efficiency" to efficiency,
        "restingHr" to null,
        "avgHrv" to null,
        "stagesJSON" to null,
        "userEdited" to false,
        "startTsAdjusted" to null,
        "motionJSON" to null,
        "sleepStateJSON" to null,
        "stagingSparse" to null,
    ),
)

internal class FakePushSource(
    val append: MutableMap<String, MutableList<PushAppendRecord>> = mutableMapOf(),
    val mutable: MutableMap<String, MutableList<PushMutableRecord>> = mutableMapOf(),
) : PushSnapshotSource {
    val afterCursors = mutableListOf<Long>()
    val appendTablesRead = mutableListOf<PushAppendTable>()
    val mutableTablesRead = mutableListOf<PushMutableTable>()
    var reading = false
    var appendRowsFailure: Throwable? = null
    var mutableRowsFailure: Throwable? = null
    var knownDeviceIdsFailure: Throwable? = null
    var deviceDiscoveryCapabilities: PushCapabilities? = null

    override suspend fun knownDeviceIds(capabilities: PushCapabilities): List<String> {
        deviceDiscoveryCapabilities = capabilities
        knownDeviceIdsFailure?.let { throw it }
        val supportedNames = capabilities.appendTables.map { it.wireName }.toSet() +
            capabilities.mutableTables.map { it.wireName }
        return (append.keys + mutable.keys)
            .filter { it.substringBefore('|') in supportedNames }
            .map { it.substringAfter('|') }
            .distinct()
            .sorted()
    }

    override suspend fun appendRecordAt(
        table: PushAppendTable,
        deviceId: String,
        rowId: Long,
    ): PushAppendRecord? = append[key(table, deviceId)]?.firstOrNull { it.rowId == rowId }

    override suspend fun appendRows(
        table: PushAppendTable,
        deviceId: String,
        afterRowId: Long,
        limit: Int,
    ): List<PushAppendRecord> {
        appendTablesRead += table
        appendRowsFailure?.let { throw it }
        reading = true
        return try {
            afterCursors += afterRowId
            append[key(table, deviceId)].orEmpty().filter { it.rowId > afterRowId }.take(limit)
        } finally {
            reading = false
        }
    }

    override suspend fun mutableRows(
        table: PushMutableTable,
        deviceId: String,
        window: PushWindow,
        limit: Int,
    ): List<PushMutableRecord> {
        mutableTablesRead += table
        mutableRowsFailure?.let { throw it }
        return mutable[key(table, deviceId)].orEmpty().take(limit)
    }
}

internal class MemoryProgress : PushProgressStore {
    val devices = mutableSetOf<String>()
    val cursors = mutableMapOf<String, PushCursor>()
    val windows = mutableMapOf<String, PushWindowProgress>()

    override suspend fun knownDeviceIds(): Set<String> = devices.toSet()
    override suspend fun rememberDeviceId(deviceId: String) { devices += deviceId }

    override suspend fun cursor(table: PushAppendTable, deviceId: String): PushCursor? = cursors[key(table, deviceId)]
    override suspend fun saveCursor(table: PushAppendTable, deviceId: String, cursor: PushCursor) {
        cursors[key(table, deviceId)] = cursor
    }

    override suspend fun window(table: PushMutableTable, deviceId: String): PushWindowProgress? =
        windows[key(table, deviceId)]

    override suspend fun saveWindow(table: PushMutableTable, deviceId: String, progress: PushWindowProgress) {
        windows[key(table, deviceId)] = progress
    }
}

internal class AckingTransport(
    private val ack: (PushBatch) -> PushAck = { PushAck.fromBatch(it) },
) : PushTransport {
    val batches = mutableListOf<PushBatch>()
    val bodies = mutableListOf<ByteArray>()

    override suspend fun post(batch: PushBatch): PushTransportResponse {
        batches += batch
        bodies += batch.body.copyOf()
        return PushTransportResponse(200, ack(batch).encode())
    }
}
