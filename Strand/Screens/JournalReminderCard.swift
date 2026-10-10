import SwiftUI
import StrandDesign

// MARK: - Journal widget (Today screen) — #627
//
// A persistent Today widget for the Journal: a WHOOP-style strip of the last `stripDays` days
// (filled = a journal entry that day, today ringed) plus an always-present tap-through to the journal.
// The Journal (behavioural logging that feeds Insights / "What Moves You") is otherwise only reachable
// inside the Insights screen, which isn't a primary destination — easy to forget, and the only proactive
// prompt is the once-a-morning sleep sheet — missed on any day you don't open Sleep. This surfaces it on
// Today where it can't be missed, and doubles as the "direct link to Insights" the report (#627) asked for.
//
// Opt-out via `PuffinExperiment.journalReminderKey` (default ON — the same key also gates the Android
// morning sleep sheet twin). Read-only: it never writes a journal entry. Twin of Android
// `JournalReminderCard` (android/.../ui/JournalReminder.kt). Design-Reset compliant — a flat accent-tinted
// NoopCard, NoopMetrics / StrandPalette / StrandFont tokens, matching the other Today cards.

struct JournalReminderCard: View {

    @EnvironmentObject var repo: Repository
    @EnvironmentObject var router: NavRouter

    /// Default ON so the reminder works out of the box; the Settings toggle / this key opt out.
    @AppStorage(PuffinExperiment.journalReminderKey) private var reminderEnabled = true

    /// Which of the last `stripDays` day-keys carry a native journal entry. nil = still loading / read
    /// error → render nothing (never a misleading all-empty strip).
    @State private var loggedDays: Set<String>?

    private static let stripDays = 7

    var body: some View {
        if reminderEnabled {
            // A VStack, not a Group: a Group hands its modifiers to its children, and before the first load
            // there is no child, so the `.task` below never ran, `loggedDays` stayed nil and the card never
            // appeared. The stack is a view of its own even while empty, so the load always starts.
            VStack(spacing: 0) {
                if let logged = loggedDays {
                    card(logged)
                }
            }
            // Re-read whenever a sync bumps refreshSeq or the toggle flips (mirrors AutoWorkoutCard's task
            // id), so the strip and the "logged today" state stay current after the user logs and comes back.
            .task(id: JournalReminderLoadKey(seq: repo.refreshSeq, enabled: reminderEnabled)) {
                await reload()
            }
        }
    }

    private func card(_ logged: Set<String>) -> some View {
        let keys = Self.dayKeys()
        let todayKey = keys.last ?? ""
        let todayLogged = logged.contains(todayKey)
        // A recent PAST day with no entry — surfaces the tap-a-bar-to-backfill interaction once today is
        // done (#656). Accent while anything is actionable; calm secondary once fully caught up.
        let hasMissed = keys.contains { $0 != todayKey && !logged.contains($0) }
        let subtitle: String = !todayLogged ? String(localized: "Log today's journal")
            : hasMissed ? String(localized: "Tap a day to catch up")
            : String(localized: "Logged today")
        // No outer Button: each bar is its own tap target that deep-links the journal to THAT day (#656),
        // and nested SwiftUI buttons don't work — so header + subtitle carry their own onTapGesture (→
        // today) and the bars carry theirs. The regions are non-overlapping in the VStack, so a tap lands
        // on exactly one. Tapping a bar does NOT set today, so a bar's day always wins.
        return NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(spacing: NoopMetrics.space2) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 18))
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text(String(localized: "Journal"))
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                .onTapGesture { router.openJournal() }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(Text(String(localized: "Journal")))
                .accessibilityHint(Text(String(localized: "Open journal")))
                // The last-N-days strip: one equal-width bar per day, each its own tap target. Filled =
                // logged; today is ringed. Tapping a bar deep-links the journal to that day (#656).
                HStack(spacing: 6) {
                    ForEach(keys.indices, id: \.self) { i in
                        let key = keys[i]
                        let off = Self.stripDays - 1 - i          // keys[0] = 6 days ago … last = today
                        let isLogged = logged.contains(key)
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: 22)                    // taller invisible tap target
                            .overlay {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(isLogged ? StrandPalette.accent : StrandPalette.textTertiary.opacity(0.22))
                                    .frame(height: 10)
                                    .overlay {
                                        if off == 0, !isLogged {
                                            RoundedRectangle(cornerRadius: 3)
                                                .strokeBorder(StrandPalette.accent, lineWidth: 1)
                                        }
                                    }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { router.openJournal(day: off) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel(Self.barLabel(off))
                    }
                }
                Text(subtitle)
                    .font(StrandFont.footnote)
                    .foregroundStyle((!todayLogged || hasMissed) ? StrandPalette.accent : StrandPalette.textSecondary)
                    .contentShape(Rectangle())
                    .onTapGesture { router.openJournal() }
                    .accessibilityAddTraits(.isButton)   // it opens the journal — announce it as one
            }
        }
    }

    /// Screen-reader label for a strip bar (#656): the day it deep-links to. Twin of JournalLogCard's
    /// day-picker labels; "%lld days ago" is a String Catalog key so it stays localized.
    private static func barLabel(_ offset: Int) -> LocalizedStringKey {
        switch offset {
        case 0: return "Today"
        case 1: return "Yesterday"
        default: return "\(offset) days ago"
        }
    }

    private func reload() async {
        guard reminderEnabled else { loggedDays = nil; return }
        let keys = Self.dayKeys()
        loggedDays = await repo.nativeJournalDays(from: keys.first ?? "", to: keys.last ?? "")
    }

    /// The `stripDays` local-day keys (yyyy-MM-dd), oldest → today, matching Android's `journalDayKey`
    /// (civil-day arithmetic via Calendar so a DST edge can't mislabel a day).
    private static func dayKeys() -> [String] {
        let cal = Calendar.current
        let today = Date()
        return (0..<stripDays).reversed().map { n in
            Repository.localDayKey(cal.date(byAdding: .day, value: -n, to: today) ?? today)
        }
    }
}

/// Reload key: a sync (seq) or toggle flip re-reads completion. Mirrors `AutoWorkoutLoadKey`.
private struct JournalReminderLoadKey: Equatable {
    let seq: Int
    let enabled: Bool
}
