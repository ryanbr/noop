import Foundation

/// The AIProviderClient backed by the in-process llama.cpp engine. Ensures the pinned model is present
/// and loaded, then streams tokens. No network, no key.
struct OnDeviceClient: AIProviderClient {
    static let shared = OnDeviceClient()

    private var model: BundledModel { ModelCatalog.coach }

    /// Real token streaming: load-if-needed then relay the engine's AsyncStream as chunks.
    func stream(key: String, model modelId: String, systemPrompt: String,
                messages: [(role: ChatMessage.Role, content: String)],
                session: URLSession) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let fileURL = ModelStorage.fileURL(for: model)
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    continuation.finish(throwing: AICoachError.modelNotDownloaded); return
                }
                do {
                    try await LlamaEngine.shared.load(modelURL: fileURL, model: model)
                } catch {
                    continuation.finish(throwing: error); return
                }
                for await piece in LlamaEngine.shared.generate(systemPrompt: systemPrompt, messages: messages) {
                    if Task.isCancelled { break }
                    continuation.yield(piece)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Non-streaming path (kept for protocol completeness): drain the stream into one string.
    func send(key: String, model modelId: String, systemPrompt: String,
              messages: [(role: ChatMessage.Role, content: String)], session: URLSession) async throws -> String {
        var out = ""
        for try await piece in stream(key: key, model: modelId, systemPrompt: systemPrompt,
                                      messages: messages, session: session) { out += piece }
        return out
    }

    func fetchModels(key: String, session: URLSession) async throws -> [String] { [model.id] }
}
