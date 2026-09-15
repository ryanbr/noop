import Foundation
import UserNotifications

/// A local, opt-in morning briefing. It uses only already-scored on-device values and never calls a
/// provider; a missing metric is omitted instead of guessed.
enum DailyCoachNotifier {
    enum TrainingBand: Equatable {
        case recovery, controlled, harder
    }

    struct Brief: Equatable {
        let charge: Int?
        let rest: Int?
        let hrvMs: Int?
        let restingHR: Int?
        let sleepHours: Int?
        let trainingBand: TrainingBand?
    }

    private static let lastDayKey = "behavior.dailyCoachLastDay"

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func makeBrief(recovery: Double?, rest: Double?, hrv: Double?, restingHR: Int?,
                          sleepMinutes: Double?) -> Brief? {
        let charge = recovery.map { Int($0.rounded()) }
        let roundedRest = rest.map { Int($0.rounded()) }
        let hrvMs = hrv.map { Int($0.rounded()) }
        let sleepHours = sleepMinutes.map { Int(($0 / 60).rounded()) }
        guard charge != nil || roundedRest != nil || hrvMs != nil || restingHR != nil || sleepHours != nil else {
            return nil
        }
        let trainingBand = charge.map {
            switch $0 {
            case 67...: return TrainingBand.harder
            case 34..<67: return TrainingBand.controlled
            default: return TrainingBand.recovery
            }
        }
        return Brief(charge: charge, rest: roundedRest, hrvMs: hrvMs, restingHR: restingHR,
                     sleepHours: sleepHours, trainingBand: trainingBand)
    }

    static func onMorning(day: String, recovery: Double?, rest: Double?, hrv: Double?,
                          restingHR: Int?, sleepMinutes: Double?, enabled: Bool) {
        let d = UserDefaults.standard
        guard enabled, d.string(forKey: lastDayKey) != day,
              let brief = makeBrief(recovery: recovery, rest: rest, hrv: hrv,
                                    restingHR: restingHR, sleepMinutes: sleepMinutes) else { return }
        var parts: [String] = []
        if let charge = brief.charge { parts.append("\(String(localized: "Charge")) \(charge)") }
        if let rest = brief.rest { parts.append("\(String(localized: "Rest")) \(rest)") }
        if let hrv = brief.hrvMs { parts.append("\(String(localized: "HRV")) \(hrv) ms") }
        if let restingHR = brief.restingHR { parts.append("\(String(localized: "RHR")) \(restingHR) bpm") }
        if let sleepHours = brief.sleepHours { parts.append("\(String(localized: "Sleep")) \(sleepHours) h") }
        let training: String?
        switch brief.trainingBand {
        case .some(.harder):
            training = String(localized: "Your signals are aligned and your load is supported. A harder session is well backed today.")
        case .some(.controlled):
            training = String(localized: "One of your signals is flagging. You can train, but keep it controlled and bank the recovery.")
        case .some(.recovery):
            training = String(localized: "Several signals are down at once. Treat today as recovery - easy movement, real sleep tonight.")
        case .none:
            training = nil
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Morning brief")
            content.body = parts.joined(separator: " · ") + (training.map { ". \($0)" } ?? "")
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
