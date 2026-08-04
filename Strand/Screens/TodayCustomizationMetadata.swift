import SwiftUI
import StrandDesign

extension TodaySection {
    var customizationIcon: String {
        switch self {
        case .hero: return "gauge.with.dots.needle.67percent"
        case .liveSession: return "figure.run.circle"
        case .synthesis: return "sparkles"
        case .keyMetrics: return "square.grid.2x2"
        case .workouts: return "figure.run"
        case .heartRate: return "waveform.path.ecg"
        case .recoveryVitals: return "heart.text.square"
        case .yourCards: return "rectangle.stack"
        case .journal: return "book.closed"
        }
    }

    var customizationTint: Color {
        switch self {
        case .hero: return StrandPalette.chargeColor
        case .liveSession: return StrandPalette.metricCyan
        case .synthesis: return StrandPalette.accent
        case .keyMetrics: return StrandPalette.metricPurple
        case .workouts: return StrandPalette.effortColor
        case .heartRate: return StrandPalette.metricRose
        case .recoveryVitals: return StrandPalette.metricCyan
        case .yourCards: return StrandPalette.accent
        case .journal: return StrandPalette.metricAmber
        }
    }
}

extension KeyMetric {
    var customizationIcon: String {
        switch self {
        case .charge: return "bolt.heart"
        case .effort: return "figure.run"
        case .rest: return "moon.stars"
        case .hrv: return "waveform.path.ecg"
        case .restingHr: return "heart.fill"
        case .bloodOxygen: return "drop.fill"
        case .respiratory: return "lungs.fill"
        case .steps: return "figure.walk"
        case .weight: return "scalemass"
        case .calories: return "flame.fill"
        }
    }

    var customizationTint: Color {
        switch self {
        case .charge: return StrandPalette.chargeColor
        case .effort: return StrandPalette.effortColor
        case .rest, .hrv: return StrandPalette.metricPurple
        case .restingHr: return StrandPalette.metricRose
        case .bloodOxygen, .steps: return StrandPalette.metricCyan
        case .respiratory, .weight: return StrandPalette.accent
        case .calories: return StrandPalette.metricAmber
        }
    }
}

extension DashboardCard {
    var customizationTint: Color {
        switch self {
        case .stress, .respiratory: return StrandPalette.accent
        case .fitnessAge: return StrandPalette.chargeColor
        case .vitality, .hrv: return StrandPalette.metricPurple
        case .restingHr: return StrandPalette.metricRose
        case .steps, .bloodOxygen, .hydration: return StrandPalette.metricCyan
        case .skinTemp, .calories: return StrandPalette.metricAmber
        case .sleep: return StrandPalette.restColor
        case .coupled: return StrandPalette.chargeColor
        }
    }
}
