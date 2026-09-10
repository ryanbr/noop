import WidgetKit
import SwiftUI

/// The widget extension entry point. Bundles the glanceable widget, the live-HR Live Activity,
/// the K10 Coach brief widget (stored morning brief on Lock Screen / Home Screen), and the
/// heart-rate trace widget (#1957), and the stress curve widget (#2040).
@main
struct NOOPWidgetBundle: WidgetBundle {
    var body: some Widget {
        NOOPWidget()
        NOOPLiveActivity()
        CoachBriefWidget()
        HeartRateWidget()
        StressWidget()
    }
}
