import Foundation
import WhoopStore

/// Converts the values already banked by NOOP into Home Assistant state updates.
/// Kept pure so sensor names, units, and unavailable-value handling can be verified without a strap.
enum HomeAssistantPayload {
    static func states(day: DailyMetric, recentHeartRate: Int?, batterySoc: Double?, charging: Bool?)
        -> [HomeAssistantAPIClient.StateUpdate] {
        var result: [HomeAssistantAPIClient.StateUpdate] = []

        func add(_ id: String, _ name: String, _ value: String?, unit: String? = nil) {
            guard let value else { return }
            var attributes: [String: Any] = [
                "friendly_name": "NOOP \(name)",
                "noop_day": day.day,
                "state_class": "measurement"
            ]
            if let unit { attributes["unit_of_measurement"] = unit }
            result.append(.init(entityID: "sensor.noop_\(id)", state: value, attributes: attributes))
        }

        func decimal(_ value: Double?) -> String? {
            guard let value, value.isFinite else { return nil }
            return String(value)
        }

        // Keep the stable entity IDs and units in sync with the existing NOOP MQTT package in
        // home-assistant/packages/noop_health.yaml. Direct REST export is the transport here, but HA
        // and Jarvis should see the same canonical sensors as the MQTT bridge.
        add("recovery", "Recovery", decimal(day.recovery), unit: "%")
        add("strain", "Strain", decimal(day.strain))
        add("sleep_hours", "Sleep Hours",
            day.totalSleepMin.flatMap { $0.isFinite ? String($0 / 60) : nil }, unit: "h")
        add("sleep_efficiency", "Sleep Efficiency",
            day.efficiency.flatMap { $0.isFinite ? String(($0 * 1_000).rounded() / 10) : nil }, unit: "%")
        add("hrv", "HRV", decimal(day.avgHrv), unit: "ms")
        add("resting_hr", "Resting HR", day.restingHr.map(String.init), unit: "bpm")
        add("steps", "Steps", day.steps.map(String.init), unit: "steps")
        add("spo2", "SpO2", decimal(day.spo2Pct), unit: "%")
        add("respiratory_rate", "Respiratory Rate", decimal(day.respRateBpm), unit: "rpm")
        add("skin_temp_deviation", "Skin Temp Deviation", decimal(day.skinTempDevC), unit: "°C")
        add("strap_battery", "Strap Battery",
            batterySoc.flatMap { $0.isFinite ? String(($0 * 10).rounded() / 10) : nil }, unit: "%")

        let generatedAt = ISO8601DateFormatter().string(from: Date())
        result.append(.init(entityID: "sensor.noop_last_sync", state: generatedAt,
                            attributes: ["friendly_name": "NOOP Last Sync", "device_class": "timestamp"]))
        var statusAttributes: [String: Any] = ["friendly_name": "NOOP Status", "noop_day": day.day]
        if let recentHeartRate { statusAttributes["heart_rate_bpm"] = recentHeartRate }
        result.append(.init(entityID: "sensor.noop_status", state: "ok",
                            attributes: statusAttributes))

        if let charging {
            result.append(.init(entityID: "binary_sensor.noop_strap_charging",
                                state: charging ? "on" : "off",
                                attributes: ["friendly_name": "NOOP Strap Charging",
                                             "device_class": "battery_charging",
                                             "noop_day": day.day]))
        }
        return result
    }
}
