#if os(iOS)
import AppIntents
import Foundation

/// The same intent is compiled into app and extension; LiveActivityIntent executes in the app process.
@MainActor
enum TrainingIntentHandler {
    static var perform: ((String, String, Int, String) async throws -> Void)?
}

enum TrainingAction: String, AppEnum {
    case start, pause, resume, requestEnd, confirmEnd, cancelEnd
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Action"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .start: "Start", .pause: "Pause", .resume: "Resume",
        .requestEnd: "End training", .confirmEnd: "Yes, end training", .cancelEnd: "Cancel"
    ]
}

struct TrainingActionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Control training"
    static var openAppWhenRun = false
    @Parameter(title: "Action", default: .pause) var action: TrainingAction
    @Parameter(title: "Session", default: "") var sessionID: String
    @Parameter(title: "Favorite", default: -1) var favorite: Int
    @Parameter(title: "Confirmation", default: "") var token: String
    init() {}
    init(_ action: TrainingAction, sessionID: String = "", favorite: Int = -1, token: String = "") {
        self.action = action; self.sessionID = sessionID; self.favorite = favorite; self.token = token
    }
    @MainActor
    func perform() async throws -> some IntentResult {
        guard let handler = TrainingIntentHandler.perform else { throw CocoaError(.featureUnsupported) }
        try await handler(action.rawValue, sessionID, favorite, token)
        return .result()
    }
}

enum TrainingFavoriteSlot: Int, AppEnum {
    case first = 0, second = 1, third = 2
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Training favorite"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .first: "Favorite 1", .second: "Favorite 2", .third: "Favorite 3"
    ]
}
struct TrainingWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Training favorite"
    @Parameter(title: "Favorite", default: .first) var favorite: TrainingFavoriteSlot
}
#endif
