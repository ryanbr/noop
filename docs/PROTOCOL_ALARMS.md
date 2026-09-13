# WHOOP alarm configuration and execution

Applicability: [central scope and compatibility](PROTOCOL.md#scope-and-compatibility).

This companion to the [command reference](PROTOCOL_COMMANDS.md#haptics-and-alarms) applies to the reference baseline. Earlier device observations remain separately scoped; the contracts below do not establish a successful physical wake on this version.


Alarm configuration supports six IDs, 1–6. SET uses revision 4 and the following 21-byte body; GET takes `[4, ID]` and, for a valid ID, returns the same 21-byte record. Multibyte fields are little-endian.

| Offset | Width | Field |
|---:|---:|---|
| 0 | 1 | Revision 4 |
| 1 | 1 | Alarm ID |
| 2 | 4 | Epoch seconds |
| 6 | 2 | Fractional ticks, using the clock's 1/32768-second convention |
| 8 | 8 | Waveform effects |
| 16 | 2 | Effect-loop control |
| 18 | 1 | Overall repeat count |
| 19 | 1 | Duration |
| 20 | 1 | Crescendo: 0 ordinary pattern, 1 staged crescendo control |

The earlier NOOP 20-byte alarm model receives a zero byte at offset 20 from format-1 padding. With the same sequence and other fields, it produces the same padded body as explicitly supplying crescendo zero. The newly described field does not show that earlier transmitted requests were too short or explain an unsuccessful wake by itself.

SET requires seconds strictly later than the strap's current seconds: a larger fractional value within the same second is insufficient. Each effect byte must be at most 251, repeat count must be below 8, and crescendo must be 0 or 1. When repeats equal 7, duration must be 30–120 inclusive; this interval is not imposed by this validator for repeats 0–6. A parser-accepted effect or duration is not a guarantee of a useful physical waveform. The full effect vocabulary, physical intensity and every operating limit remain unresolved.

SET's response body is `[4, validation detail]`. This detail is distinct from the outer command result:

| Detail | Meaning |
|---:|---|
| 1 | Input passed validation |
| 2 | Effect byte out of range |
| 3 | Repeat count out of range |
| 4 | Duration out of range for repeat count 7 |
| 10 | Time is not later than the current whole second |
| 11 | Alarm ID out of range |
| 12 | Crescendo out of range |

Validation failures return outer failure. Detail 1 can accompany outer success **or failure**, because saving the record can still fail. The alarm-set event 56 is not an independent proof that storage succeeded.

SET saves the pattern portion before the time portion. A pattern-write failure prevents the time write; a time-write failure can leave the new pattern with the previous schedule. Alarm records use nonvolatile storage, but writes are not established as atomic and survival of a particular power interruption has not been validated. GET reloads storage, yet failed reads can substitute zeros while GET still reports success. An all-zero time can therefore mean cleared/unset state or a storage-read fallback. Do not treat it as a separate storage-health result. Invalid-ID/revision failure bodies are not usable alarm records.

### Disable, due processing and manual run

DISABLE uses `[2, ID]` for one alarm or `[2,255]` for all six. Its outer result reflects storage success/failure, and its body carries revision 2. All-ID disable attempts every slot even after an individual write fails, retaining a failure result if any write fails. Failure can therefore follow partial clearing; read back individual slots when their state matters. Disabling clears the saved record; it does not substitute for stopping an already active haptic effect.

Due processing compares the alarm's whole seconds with the strap clock. Fractional ticks are retained but do not make this due check subsecond-precise. The scan cadence is nominally about half a second; exact intervals and worst-case latency remain unresolved. A due alarm is copied into active state and its stored record is cleared before haptic completion: it is a **one-shot schedule**, not a daily recurrence. Repeat count controls waveform repetition. Storage-clear failure remains separate. Simultaneous due slots share one execution context: the highest due ID in the ascending scan replaces the shared fields; independent simultaneous playback is not guaranteed.

RUN uses `[2, ID]` and requires an existing nonzero stored time. It does not apply SET's future-time check. A valid initial response is outer pending with body `[2,0]`; an invalid/unset ID fails with `[2,11]`. The later response body is `[2, detail]`, with outer success only when detail equals 5. Timeout returns failure with `[2,7]`. The timeout's wall-clock duration is not specified here. RUN's active execution path also clears the selected saved record, so it is not a guaranteed nondestructive preview of a future schedule.

Strap-triggered execution emits event 57; app-triggered RUN emits event 58. Ordinary pattern and crescendo paths are distinct. These events identify execution requests; they do not independently prove motor movement or that a person woke up. Haptic callbacks, driver errors, concurrent UI work and full crescendo timing still impose unresolved boundaries. Earlier alarm arming acknowledgements remain useful but do not establish an observed strap-driven wake.


## Busy execution and stop completion

Alarm schedules share one active execution context. When multiple alarms become
due in the same scan, the last slot scanned replaces the shared alarm fields;
separate execution of every due alarm is not guaranteed. Avoid overlapping
schedules and overlapping manual haptic requests.

An active alarm can still allow schedule scanning. A newly due alarm may be
consumed while its start request is ignored by the busy state. Its fields may
also replace fields used by the active execution. A successful schedule write
therefore does not guarantee later vibration.

Stopping haptics is asynchronous. Distinguish the initial pending response from
the final result. Stop completion and start completion have different success
conditions; the stop response contains the revision alone. Stopping the current
effect does not disable stored alarms or establish that no pending request remains.

The notification-haptic body contains a revision, eight effect bytes, a
little-endian loop-control field and an overall repeat byte. The start response
contains revision and detail. Preserve the operation-specific response layout.

Crescendo uses staged control. Physical intensity, reliable stage timing and
motor output are not established by an accepted request. Short durations are
not established safe crescendo settings. In a later stage, the remaining duration
is calculated as unsigned 32-bit `duration - 20`, then multiplied by ten for a
timer count with the same wrapping arithmetic; a zero count becomes one. Durations
below 20 are not rejected when repeats are below 7, so acceptance does not prevent
this underflow. An independently armed total-duration stop can intervene first;
the arithmetic is not evidence of an extremely long physical buzz.

A start timeout can submit up to three retries before returning timeout detail 7.
The app must not interpret each retry as a separate alarm or immediately issue
another start while awaiting the correlated completion. Complete driver callback
behavior and the first crescendo stage's duration remain unresolved.

Schedules are read from storage during scanning. After restart, execution still
depends on readable retained schedules, a correct clock and the application
reaching the scanning state. Reboot survival and wake latency require separate
validation. No automatic ECG or sensor-request cleanup on disconnect is promised.

Command 122 takes revision 1 alone. Initial pending and final success/failure all carry the one-byte body `[1]`; unsupported revision also fails with `[1]`. The final result is operation-specific and must not be inferred from the start response detail. Command 19 takes 12 bytes and returns revision plus detail; its final success uses detail 5, as does manual RUN.

NOOP’s single-notification command-19 body is `01 2F 98 00 00 00 00 00 00 00 00 00`:
revision 1, effects `[47,152,0,0,0,0,0,0]`, zero effect-loop control and zero repeats.


The nominal half-second scan scale comes from five received timer ticks followed
by event dispatch. Interrupt handling restarts the timer, so this is not an exact
free-running scan period, motor-start deadline or wake guarantee. Oscillator error,
interrupt handling and scheduling can affect the actual interval.
