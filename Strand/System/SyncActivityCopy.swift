import Foundation

/// The words and phase the strap-sync Live Activity shows, resolved here — platform-neutral, no
/// ActivityKit — so the mapping is covered by `StrandTests` (which runs on the macOS leg only). The iOS
/// controller turns a `Line` into the activity's content state; the widget renders the strings as-is.
///
/// Same honesty rules as `SyncChipState.resolve`: a chunk COUNT rather than a percent (the strap never
/// says how much is pending), a zero backlog dropped rather than rendered, and "interrupted" only when
/// `LiveState.lastSyncError` says the idle watchdog ended the offload — every other end completed.
enum SyncActivityCopy {
    enum Phase: String {
        case connecting, syncing, done, interrupted
    }

    struct Line: Equatable {
        let phase: Phase
        let chunks: Int
        let status: String
        let detail: String?
    }

    static func connecting() -> Line {
        Line(phase: .connecting, chunks: 0, status: String(localized: "Waiting for your strap…"), detail: nil)
    }

    static func syncing(chunks: Int, pagesBehind: Int?) -> Line {
        let behind = pagesBehind.flatMap { $0 > 0 ? $0 : nil }
        return Line(phase: .syncing, chunks: chunks,
                    status: chunks > 0 ? String(localized: "Syncing… \(chunks) chunks") : String(localized: "Syncing…"),
                    detail: behind.map { String(localized: "\($0) pages behind at connect") })
    }

    static func final(lastSyncError: String?, chunks: Int) -> Line {
        if lastSyncError != nil {
            return Line(phase: .interrupted, chunks: chunks,
                        status: String(localized: "Sync interrupted"),
                        detail: chunks > 0 ? String(localized: "\(chunks) chunks pulled") : nil)
        }
        return Line(phase: .done, chunks: chunks,
                    status: chunks > 0 ? String(localized: "Synced · \(chunks) chunks") : String(localized: "Synced"),
                    detail: nil)
    }

    static func notStarted() -> Line {
        Line(phase: .interrupted, chunks: 0, status: String(localized: "Sync didn't start"), detail: nil)
    }
}
