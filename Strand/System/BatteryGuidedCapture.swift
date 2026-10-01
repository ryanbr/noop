import Foundation
import StrandAnalytics

// BatteryGuidedCapture.swift - the guided "wear it N days, then Report" flow for the Battery test mode
// (#713, Test Centre). The days-twin of the Sleep nights flow (GuidedCapture / GuidedCaptureProgress).
// Arming reuses the existing scheduled-export engine (ScheduledDebugExport) rather than its own
// scheduler, so a redacted bundle drops each morning while the mode runs; the day count is derived from
// TestCentre.startedAt(.battery) against the registry default, so there is no extra persisted clock to
// drift. The pure status formatter is split out so it is unit-testable without a live clock. No em-dashes.
@MainActor
enum BatteryGuidedCapture {

    /// Arm the guided window: enable the daily scheduled export so the Battery bundle drops each morning
    /// for the duration. ScheduledDebugExport owns the BGTask / macOS timer; we only flip it on.
    static func arm() {
        ScheduledDebugExport.setEnabled(true)
    }

    /// Disarm when the user ends the Battery mode. The Test Centre Battery row owns this flag while the
    /// mode is on; flipping it off here is the days-twin of ending a Sleep capture.
    static func disarm() {
        ScheduledDebugExport.setEnabled(false)
    }

    /// "Capturing day K of N" status for the Test Centre Battery row. K is full-days-elapsed + 1, capped
    /// at N; once N whole days have passed it reads complete. Pure (now injected) so it is testable.
    static func statusText(startedAt: Date?, target: Int, now: Date = Date()) -> String {
        guard let startedAt else { return "Not started" }
        let elapsedDays = Int(now.timeIntervalSince(startedAt) / 86400)
        if elapsedDays >= target { return "Capture complete, \(target) of \(target) days" }
        return "Capturing day \(elapsedDays + 1) of \(target)"
    }
}
