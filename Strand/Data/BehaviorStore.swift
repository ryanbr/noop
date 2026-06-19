import Foundation
import Combine

/// Settings for the strap's physical inputs and the Mac/coaching automations built on top of the
/// live event + biometric stream. UserDefaults-backed (single-user, on-device).
@MainActor
final class BehaviorStore: ObservableObject {

    // MARK: Double-tap → Mac action
    @Published var doubleTapAction: MacActionKind { didSet { d.set(doubleTapAction.rawValue, forKey: K.dtAction) } }
    @Published var doubleTapShortcut: String { didSet { d.set(doubleTapShortcut, forKey: K.dtShortcut) } }

    // MARK: Wear automation
    /// Lock the Mac when the strap comes off the wrist.
    @Published var autoLockOnWristOff: Bool { didSet { d.set(autoLockOnWristOff, forKey: K.autoLock) } }
    /// Run a Shortcut when the strap comes off (presence automation: Focus, pause media, set away…).
    @Published var wristOffShortcut: String { didSet { d.set(wristOffShortcut, forKey: K.wristOffShortcut) } }
    /// Run a Shortcut when the strap goes back on the wrist.
    @Published var wristOnShortcut: String { didSet { d.set(wristOnShortcut, forKey: K.wristOnShortcut) } }

    // MARK: HR-zone haptic coaching (during a live session)
    @Published var zoneCoaching: Bool { didSet { d.set(zoneCoaching, forKey: K.zoneCoaching) } }
    /// Experimental: gentle buzz when a resting stress spike is detected (HRV drops while HR is calm).
    @Published var stressNudge: Bool { didSet { d.set(stressNudge, forKey: K.stress) } }

    // MARK: Haptic biofeedback — Stress check-ins (L3)
    //
    // The v5 "stress check-ins (haptic)" master toggle + sub-toggles. Default OFF (opt-in, manual-first).
    // These MIRROR the keys `BiofeedbackPrefs` reads/writes (the controller + central L3 hook use that
    // value type); exposing them here gives the Settings group an `@Published` binding without a second
    // source of truth — the keys are identical, so a write through either path is seen by both. The
    // central L3 hook (Wave 3) reads `BiofeedbackPrefs.stressConfig()`.
    @Published var stressCheckIn: Bool { didSet { d.set(stressCheckIn, forKey: K.stressCheckIn) } }
    @Published var stressAutoNudge: Bool { didSet { d.set(stressAutoNudge, forKey: K.stressAutoNudge) } }
    @Published var stressQuietHours: Bool { didSet { d.set(stressQuietHours, forKey: K.stressQuietHours) } }
    @Published var stressUseResonancePace: Bool { didSet { d.set(stressUseResonancePace, forKey: K.stressUseResonance) } }

    // MARK: Smart alarm
    @Published var smartAlarmEnabled: Bool { didSet { d.set(smartAlarmEnabled, forKey: K.alarmOn) } }
    /// Target wake time, minutes since local midnight.
    @Published var smartAlarmMinutes: Int { didSet { d.set(smartAlarmMinutes, forKey: K.alarmTime) } }

    // MARK: Illness early-warning
    @Published var illnessWatch: Bool { didSet { d.set(illnessWatch, forKey: K.illness) } }

    // MARK: Strap battery alerts
    /// Notify on low strap battery (≤15%) and full charge (100%). Default ON (#368).
    @Published var batteryAlerts: Bool { didSet { d.set(batteryAlerts, forKey: K.batteryAlerts) } }

    private let d = UserDefaults.standard
    private enum K {
        static let dtAction = "behavior.doubleTapAction"
        static let dtShortcut = "behavior.doubleTapShortcut"
        static let autoLock = "behavior.autoLockOnWristOff"
        static let wristOffShortcut = "behavior.wristOffShortcut"
        static let wristOnShortcut = "behavior.wristOnShortcut"
        static let zoneCoaching = "behavior.zoneCoaching"
        static let stress = "behavior.stressNudge"
        // Haptic biofeedback L3 — keys MATCH BiofeedbackPrefs (one source of truth, two readers).
        static let stressCheckIn = "biofeedback.stressCheckIn"
        static let stressAutoNudge = "biofeedback.stressAutoNudge"
        static let stressQuietHours = "biofeedback.stressQuietHours"
        static let stressUseResonance = "biofeedback.stressUseResonancePace"
        static let alarmOn = "behavior.smartAlarmEnabled"
        static let alarmTime = "behavior.smartAlarmMinutes"
        // "behavior.smartAlarmWindow" retired: it was stored but never read (no wake-window
        // watcher ever shipped). The defaults key is left orphaned on purpose — harmless, and
        // preserved should a real light-sleep watcher ever land.
        static let illness = "behavior.illnessWatch"
        static let batteryAlerts = "behavior.batteryAlerts"
    }

    init() {
        doubleTapAction = MacActionKind(rawValue: d.string(forKey: K.dtAction) ?? "") ?? .none
        doubleTapShortcut = d.string(forKey: K.dtShortcut) ?? ""
        autoLockOnWristOff = d.object(forKey: K.autoLock) as? Bool ?? false
        wristOffShortcut = d.string(forKey: K.wristOffShortcut) ?? ""
        wristOnShortcut = d.string(forKey: K.wristOnShortcut) ?? ""
        zoneCoaching = d.object(forKey: K.zoneCoaching) as? Bool ?? false
        stressNudge = d.object(forKey: K.stress) as? Bool ?? false
        stressCheckIn = d.object(forKey: K.stressCheckIn) as? Bool ?? false
        stressAutoNudge = d.object(forKey: K.stressAutoNudge) as? Bool ?? false
        stressQuietHours = d.object(forKey: K.stressQuietHours) as? Bool ?? true
        stressUseResonancePace = d.object(forKey: K.stressUseResonance) as? Bool ?? true
        smartAlarmEnabled = d.object(forKey: K.alarmOn) as? Bool ?? false
        smartAlarmMinutes = d.object(forKey: K.alarmTime) as? Int ?? 7 * 60       // 07:00
        illnessWatch = d.object(forKey: K.illness) as? Bool ?? false
        batteryAlerts = d.object(forKey: K.batteryAlerts) as? Bool ?? true
    }
}
