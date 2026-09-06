import WidgetKit
import SwiftUI

/// The widget extension entry point. Bundles the glanceable widget, the live-HR Live Activity,
/// and the K10 Coach brief widget (stored morning brief on Lock Screen / Home Screen).
@main
struct NOOPWidgetBundle: WidgetBundle {
    var body: some Widget {
        NOOPWidget()
        NOOPLiveActivity()
        CoachBriefWidget()
    }
}
