import Foundation

/// Stable, platform-neutral identity for an iOS Quick Launch destination.
struct LaunchItem: Identifiable, Equatable {
    let id: String
    let title: String
    let icon: String
}

extension LaunchItem {
    static let insights: [LaunchItem] = [
        LaunchItem(id: "insightsHub", title: "What Moves You", icon: "wand.and.sparkles"),
        LaunchItem(id: "intelligence", title: "Intelligence", icon: "brain.head.profile"),
        LaunchItem(id: "coach", title: "Coach", icon: "sparkles"),
        LaunchItem(id: "insights", title: "Insights", icon: "lightbulb.fill"),
        // Reuses the Insights destination under the more discoverable Journal name.
        LaunchItem(id: "journal", title: "Journal", icon: "square.and.pencil"),
        LaunchItem(id: "explore", title: "Explore", icon: "square.grid.2x2.fill"),
        LaunchItem(id: "compare", title: "Compare", icon: "rectangle.split.2x1.fill"),
    ]

    static let body: [LaunchItem] = [
        LaunchItem(id: "live", title: "Live", icon: "waveform.path.ecg"),
        LaunchItem(id: "workouts", title: "Workouts", icon: "figure.run"),
        LaunchItem(id: "health", title: "Health", icon: "heart.text.square.fill"),
        LaunchItem(id: "labBook", title: "Lab Book", icon: "books.vertical.fill"),
        LaunchItem(id: "stress", title: "Stress", icon: "bolt.heart.fill"),
        LaunchItem(id: "breathe", title: "Breathe", icon: "wind"),
        LaunchItem(id: "intervals", title: "Intervals", icon: "timer"),
        LaunchItem(id: "rhythm", title: "Rhythm", icon: "waveform.path"),
    ]

    static let data: [LaunchItem] = [
        LaunchItem(id: "fusedRecord", title: "Your Data", icon: "square.stack.3d.up.fill"),
        LaunchItem(id: "appleHealth", title: "Apple Health", icon: "heart.fill"),
        LaunchItem(id: "miBand", title: "Mi Band", icon: "figure.walk.motion"),
        LaunchItem(id: "dataSources", title: "Data Sources", icon: "externaldrive.fill"),
        LaunchItem(id: "backupSync", title: "Backup & Sync", icon: "externaldrive.fill.badge.icloud"),
        LaunchItem(id: "shortcuts", title: "Shortcuts", icon: "square.and.arrow.up.fill"),
    ]

    static let app: [LaunchItem] = [
        LaunchItem(id: "alarms", title: "Alarms", icon: "alarm.fill"),
        LaunchItem(id: "automations", title: "Automations", icon: "wand.and.stars"),
        LaunchItem(id: "testCentre", title: "Test Centre", icon: "stethoscope"),
        LaunchItem(id: "siri", title: "Siri", icon: "mic.fill"),
        LaunchItem(id: "settings", title: "Settings", icon: "gearshape.fill"),
    ]

    static let all: [LaunchItem] = insights + body + data + app

    static let defaultFavouriteIDs = [
        "settings", "backupSync", "workouts", "stress", "coach", "journal",
        "automations", "alarms", "compare",
    ]
}
