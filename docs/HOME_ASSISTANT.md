# iOS Home Assistant export

The iOS Home Assistant integration is configured by the device owner. It has no NOOP-operated
intermediary and is off until enabled.

## Configure the connection

1. In NOOP, open **More → Home Assistant**.
2. Enter the base URL of the Home Assistant instance, without an `/api` suffix. Use HTTPS when the
   instance is reachable beyond a trusted private network.
3. Paste a Home Assistant long-lived access token and choose **Save connection**. NOOP stores the
   token in iOS Keychain; it is not written to app preferences or the URL.
4. Choose **Test connection**. This checks the authenticated Home Assistant API root and sends no
   health data.
5. Choose **Send latest data now** to publish the latest available metrics. To send after later
   local data refreshes, turn on **Automatically export after data refresh**. This switch is off by
   default and can be turned off at any time.

## Published entities

NOOP writes state-backed sensors with stable IDs: `sensor.noop_recovery`, `sensor.noop_strain`,
`sensor.noop_sleep_hours`, `sensor.noop_sleep_efficiency`, `sensor.noop_hrv`,
`sensor.noop_resting_hr`, `sensor.noop_steps`, `sensor.noop_spo2`,
`sensor.noop_respiratory_rate`, `sensor.noop_skin_temp_deviation`,
`sensor.noop_strap_battery`, `sensor.noop_last_sync`, and `sensor.noop_status`. When known, it also
writes `binary_sensor.noop_strap_charging`. Missing measurements are omitted. The API creates
state-backed entities when they are first published; these are not managed through Home Assistant's
entity registry and may need to be republished after a Home Assistant restart.

The integration writes only the latest daily summary, one recent heart-rate sample as an attribute,
and the current battery state. It does not upload historical samples, query HA state, invoke HA
services, or receive commands. See the precise boundary in [`SCOPE.md`](SCOPE.md#ios-home-assistant-export)
and [`PRIVACY_SECURITY.md`](PRIVACY_SECURITY.md#11e-home-assistant-export-ios-off-by-default).
