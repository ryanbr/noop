# NOOP Next — call haptics and notification UX

NOOP should feel like a focused wearable companion: phone events are detected locally, evaluated by a small policy engine, and delivered to the WHOOP through the existing BLE transport.

## Call-alert behaviour

- Immediate haptic when an enabled native phone or VoIP call begins.
- Repeat every 6 seconds while the call remains active.
- Maximum 6 haptic deliveries per call cycle.
- Duplicate ringing events are idempotent.
- A disconnected WHOOP does not consume a delivery slot; the alert retries after reconnection.
- A five-minute watchdog clears a leaked active-call token if Android misses an end/removal callback.
- Respect notification master, call master, source switches, quiet hours, and wear gating.
- GSM phone calls remain on the native phone-state path; app notifications are handled by NotificationListenerService.
- Haptic encoding remains inside `WhoopBleClient.buzz()`, allowing WHOOP 4.0 and WHOOP 5/MG transports to stay hardware-specific.

## Current UI

The Android notification screen already uses the vNext control-centre layout:

1. Wrist-alert readiness and connection status.
2. Calls with independent Phone / VoIP controls.
3. Physical Test Buzz action.
4. App alerts grouped by category with per-app patterns.
5. Behaviour rules: wear gating, quiet hours, alarms/timers, other apps.
6. Permissions and privacy diagnostics.

The important path is deliberately visible: **phone event → NOOP detects → policy allows → encrypted WHOOP link → haptic delivered**.

## WHOOP 5/MG research

Current reverse-engineering work indicates that WHOOP 4.0 and WHOOP 5/MG do not use the same haptic opcode. WHOOP 4.0 uses `RUN_HAPTICS_PATTERN` (79), while the current NOOP research notes identify the 5/MG "maverick" haptic command as `0x13`. Keep that mapping inside the BLE client and never duplicate protocol bytes in the notification layer.

The Android notification code gates delivery on `LiveState.encryptedBond`, not merely the looser `bonded` signal. This prevents a 5/MG live-HR-only connection from being treated as a command-capable link.

## Reliability acceptance tests

1. Incoming GSM call produces an immediate WHOOP buzz.
2. A ringing call produces reminders at the finite cadence.
3. Ending the call stops reminders immediately.
4. Duplicate RINGING events never create a haptic storm.
5. Disconnect/reconnect during ringing does not lose a delivery slot.
6. Quiet hours suppress call haptics.
7. Wear gating suppresses haptics when the strap is not worn.
8. A missed stop callback self-heals after the watchdog.
9. Simultaneous GSM and VoIP sources share one scheduler.
10. WHOOP 4.0 and WHOOP 5/MG continue using their existing hardware-specific BLE haptic implementations.

## Privacy

Notification text, phone numbers, and call logs remain on-device. The call-alert path requires no cloud relay.
