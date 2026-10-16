#if os(iOS)
import ActivityKit
struct WorkoutActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var training: TrainingDisplay
        var labels: [String: String]
    }
    var sessionID: String
}
#endif
