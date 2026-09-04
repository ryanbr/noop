import Foundation
import UserNotifications

/// A local, opt-in morning briefing. It uses only already-scored on-device values and never calls a
/// provider; a missing metric is omitted instead of guessed.
enum DailyCoachNotifier {
    private static let lastDayKey = "behavior.dailyCoachLastDay"

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func onMorning(day: String, recovery: Double?, hrv: Double?, restingHR: Int?, sleepMinutes: Double?, enabled: Bool) {
        let d = UserDefaults.standard
        guard enabled, d.string(forKey: lastDayKey) != day,
              recovery != nil || hrv != nil || sleepMinutes != nil else { return }
        var parts: [String] = []
        if let recovery { parts.append("Recovery \(Int(recovery.rounded()))") }
        if let hrv { parts.append("HRV \(Int(hrv.rounded())) ms") }
        if let restingHR { parts.append("RHR \(restingHR) bpm") }
        if let sleepMinutes { parts.append("Sleep \(Int((sleepMinutes / 60).rounded())) h") }
        let training: String
        switch recovery ?? 50 {
        case 67...: training = "Training: a quality or harder session is reasonable if you feel well."
        case 34..<67: training = "Training: keep it controlled; favour volume or technique over intensity."
        default: training = "Training: favour recovery, easy movement and extra rest today."
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = "Daily Coach"
            content.body = parts.joined(separator: " · ") + ". " + training
            content.sound = .default
            centerAdd(content, day: day)
        }
    }

    private static func centerAdd(_ content: UNMutableNotificationContent, day: String) {
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "daily-coach", content: content, trigger: nil)) { error in
            guard error == nil else { return }
            UserDefaults.standard.set(day, forKey: lastDayKey)
        }
    }
}
