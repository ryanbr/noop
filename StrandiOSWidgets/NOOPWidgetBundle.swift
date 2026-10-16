import WidgetKit
import SwiftUI

/// The widget extension entry point. Bundles the glanceable widget, the live-HR Live Activity,
/// the K10 Coach brief widget (stored morning brief on Lock Screen / Home Screen), the
/// heart-rate trace widget (#1957), the stress curve widget (#2040), the Lift Log session
/// Live Activity, and the strap-sync Live Activity.
@main
struct NOOPWidgetBundle: WidgetBundle {
    var body: some Widget {
        TrainingWidget()
        NOOPWidget()
        NOOPLiveActivity()
        CoachBriefWidget()
        HeartRateWidget()
        StressWidget()
        LiftLiveActivity()
        WorkoutLiveActivity()
        SyncLiveActivity()
    }
}
