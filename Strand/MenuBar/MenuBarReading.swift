import Combine
import Foundation

/// What the menu-bar label draws: the heart rate it shows and whether a strap is linked.
///
/// WHY THIS EXISTS. `MenuBarExtra` renders its label into the status item's image and title on every update of its
/// scene and on every change the label observes, whether or not the drawing changed. Each render makes macOS repaint
/// a snapshot of the item for every menu bar it shows in, and each repaint sets the item's view to that menu bar's
/// appearance. A test on macOS 27.2 found eight snapshots of one item on a single display, half light and half dark,
/// so a repaint flips the view's appearance back and forth, and `MenuBarExtra` answers every flip with another render.
/// The label used to observe `AppModel`, `LiveState` and `Repository` whole, and the app scene observed `AppModel`, so
/// any of their published changes, well over a hundred properties between them, set that off. A 5 s sample of NOOP
/// using a quarter of a core had the status item's repaints and those renders at the top of its main thread, with
/// WindowServer about 15% of a core busier.
///
/// So the label observes one value, and a new one arrives only when what it draws changes, at most once a second
/// (`drawn`). The app scene holds `AppModel` without observing it (`StrandApp`).
struct MenuBarReading: Equatable {
    /// The heart rate the label shows (`displayHR(bpm:heartRate:lastRR:)`), or nil for the dash.
    let displayHR: Int?
    let connected: Bool

    init(bpm: Int?, heartRate: Int?, lastRR: Int?, connected: Bool) {
        displayHR = Self.displayHR(bpm: bpm, heartRate: heartRate, lastRR: lastRR)
        self.connected = connected
    }

    /// HR to display: the spike-filtered median (`AppModel.bpm`, #39) when available, else reported, else R-R.
    /// The menu-bar label and its popover both show this one number.
    static func displayHR(bpm: Int?, heartRate: Int?, lastRR: Int?) -> Int? {
        if let bpm, bpm > 0 { return bpm }
        if let heartRate, heartRate > 0 { return heartRate }
        if let lastRR, lastRR > 0 { return Int((60_000.0 / Double(lastRR)).rounded()) }
        return nil
    }

    // A glanceable HR-zone estimate using a typical adult max (~190 bpm). The full
    // profile-aware zoning lives on the main screens; the menu bar only needs a tint.
    private static let assumedHrMax: Double = 190

    /// HR zone 1...5 from %max, or nil when there's no live reading.
    var zone: Int? {
        guard let displayHR else { return nil }
        let pct = Double(displayHR) / Self.assumedHrMax
        switch pct {
        case ..<0.60: return 1
        case ..<0.70: return 2
        case ..<0.80: return 3
        case ..<0.90: return 4
        default:      return 5
        }
    }

    /// The readings worth drawing: at most one per `interval`, the latest winning, and never the one already on
    /// screen. The median can settle on a new value every beat, and a flapping link changes on every edge.
    static func drawn(_ readings: AnyPublisher<MenuBarReading, Never>,
                      atMostEvery interval: DispatchQueue.SchedulerTimeType.Stride = .seconds(1))
        -> AnyPublisher<MenuBarReading, Never> {
        readings
            .throttle(for: interval, scheduler: DispatchQueue.main, latest: true)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}
