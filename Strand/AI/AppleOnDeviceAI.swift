import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device language model (Foundation Models, iOS 26 / macOS 26+) as the coach's
/// AI. No key and no network: the prompt and the answer never leave the device.
///
/// When the switch is on, `AICoachEngine` routes every request here instead of the chosen cloud
/// provider (chat, the brief, the morning brief, the history summary). The model's context window is
/// small (about 4k tokens in and out together), so instructions and prompt are kept short and the data
/// context is trimmed from the end; the TODAY line and week comparison ride first so they survive.
enum AppleOnDeviceAI {
    static let enabledKey = "ai.appleOnDevice"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Budgets that leave room for a reply inside the model's window.
    static let maxInstructionChars = 3200
    static let maxPromptChars = 4200

    /// A stalled generation must not leave the coach "Thinking" forever.
    static let respondTimeoutSeconds: Double = 60
    static let timeoutMessage = "Apple's on-device model took too long to answer. Try again, or ask a shorter question."

    enum Status: String {
        case available, notEnabled, notReady, deviceNotEligible, unsupportedOS, unavailable
    }

    static var status: Status {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
            case .unavailable(.modelNotReady): return .notReady
            case .unavailable(.deviceNotEligible): return .deviceNotEligible
            default: return .unavailable
            }
        }
        #endif
        return .unsupportedOS
    }

    static func message(for status: Status) -> String {
        switch status {
        case .available: return "Apple's on-device model is ready."
        case .notEnabled: return "Turn on Apple Intelligence in Settings to use the on-device model."
        case .notReady: return "Apple's on-device model is still downloading. Try again in a little while."
        case .deviceNotEligible: return "This device can't run Apple's on-device model."
        case .unsupportedOS, .unavailable: return "Apple's on-device model needs iOS 26 or later with Apple Intelligence."
        }
    }

    /// The short coaching rules sent as instructions. Plain text replies, no tool calls.
    static let instructions = """
    You are a supportive recovery and performance coach inside a wearable app. You may be given the \
    user's own data: charge (0-100, daily readiness), effort (0-100, daily cardio load), rest (sleep \
    hours and quality), HRV, resting heart rate, and recent workouts. A dash means NOT MEASURED, never zero.
    Rules:
    - Read today's numbers from the TODAY line and quote them exactly. Do not invent numbers.
    - Charge 67-100: fine to push. 34-66: keep it controlled. 0-33: recovery only (easy Zone 2, mobility, sleep).
    - Give a concrete plan for today and one tip, in short paragraphs or a short list.
    - Do not repeat the section labels from the data (TODAY, THE WEEK, Recent days).
    - You are not a doctor. Never diagnose. Mention seeing a professional only if the user describes symptoms.
    - Reply in plain text with light Markdown (bold, short lists). No tables, no code.
    """

    /// Flatten the chat into one prompt that fits the budget: the first user turn (it carries the data
    /// context) is trimmed from its end, then the most recent turns are added newest-last while they fit.
    static func buildPrompt(messages: [(role: ChatMessage.Role, content: String)],
                            budget: Int = maxPromptChars) -> String {
        guard let firstIdx = messages.firstIndex(where: { $0.role == .user }) else { return "" }
        let first = messages[firstIdx].content
        let rest = Array(messages[(firstIdx + 1)...])
        // Keep up to the last 4 later turns, each capped, newest last.
        var tail: [String] = []
        var used = 0
        for m in rest.suffix(4).reversed() {
            let who = m.role == .assistant ? "Coach" : "User"
            let text = String(m.content.prefix(600))
            let line = "\(who): \(text)"
            if used + line.count > budget / 3 { break }
            tail.insert(line, at: 0)
            used += line.count + 2
        }
        let room = max(800, budget - used - 40)
        var head = first
        if head.count > room {
            // The question is at the end of the first turn ("---\n\nQuestion: …"); keep it whole.
            if let r = head.range(of: "\n\n---\n\n", options: .backwards) {
                let question = String(head[r.lowerBound...])
                let ctx = String(head[..<r.lowerBound].prefix(max(200, room - question.count)))
                head = ctx + question
            } else {
                head = String(head.prefix(room))
            }
        }
        return ([head] + tail).joined(separator: "\n\n")
    }

    /// Answer `messages` with the on-device model. Throws `AICoachError` with a readable message.
    static func respond(messages: [(role: ChatMessage.Role, content: String)],
                        temperature: Double = 0.6) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let st = status
            guard st == .available else { throw AICoachError.emptyReply(message(for: st)) }
            var budget = maxPromptChars
            for attempt in 0..<2 {
                let prompt = buildPrompt(messages: messages, budget: budget)
                do {
                    let rules = String(instructions.prefix(maxInstructionChars))
                    let content = try await withTimeout(respondTimeoutSeconds) { () async throws -> String in
                        let session = LanguageModelSession(instructions: rules)
                        return try await session.respond(to: prompt,
                                                         options: GenerationOptions(temperature: temperature)).content
                    }
                    let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { throw AICoachError.emptyReply("Apple's on-device model gave an empty reply. Try again.") }
                    return text
                } catch let error as LanguageModelSession.GenerationError {
                    switch error {
                    case .exceededContextWindowSize:
                        if attempt == 0 { budget = maxPromptChars / 2; continue }
                        throw AICoachError.emptyReply("That was too long for Apple's on-device model. Clear the conversation or ask a shorter question.")
                    case .guardrailViolation:
                        throw AICoachError.emptyReply("Apple's on-device model declined to answer that. Try wording it differently.")
                    default:
                        throw AICoachError.emptyReply("Apple's on-device model couldn't answer: \(error.localizedDescription)")
                    }
                }
            }
        }
        #endif
        throw AICoachError.emptyReply(message(for: .unsupportedOS))
    }

    /// Runs `operation`, or throws `timeoutMessage` once `seconds` pass first. The caller is released
    /// at the deadline even if the operation ignores cancellation, which a task-group race would not
    /// do: the group waits for every child before it returns.
    static func withTimeout<T>(_ seconds: Double,
                               _ operation: @escaping () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let once = ResumeOnce()
            let work = Task {
                do {
                    let value = try await operation()
                    if once.claim() { cont.resume(returning: value) }
                } catch {
                    if once.claim() { cont.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.claim() {
                    work.cancel()
                    cont.resume(throwing: AICoachError.emptyReply(timeoutMessage))
                }
            }
        }
    }

    /// Lets exactly one of the answer and the deadline resume the continuation.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
