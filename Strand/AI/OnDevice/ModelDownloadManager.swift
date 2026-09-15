import Foundation
import CryptoKit
import Combine

enum ModelDownloadState: Equatable {
    case absent
    case downloading(progress: Double)
    case verifying
    case ready
    case failed(String)
}

/// Abstraction over the actual network fetch so the state machine is unit-testable without a server.
protocol ModelFileFetcher {
    /// Download `url` to a temporary file, reporting fractional progress, and return the temp URL.
    func fetch(from url: URL, progress: @escaping (Double) -> Void) async throws -> URL
}

/// Production fetcher: URLSession download with progress via a delegate. Resumes from where a dropped
/// transfer left off: on a network failure it captures the server's resume data and the NEXT fetch
/// continues instead of restarting the ~2 GB download (Hugging Face's CDN supports range requests). The
/// fetcher is held for the download manager's lifetime, so the resume data survives across retries.
/// (Full background-session survival across app suspension is a further follow-up.)
final class URLSessionModelFetcher: NSObject, ModelFileFetcher, URLSessionDownloadDelegate {
    private var progressHandler: ((Double) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    private var resumeData: Data?
    private var resumeURL: URL?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    func fetch(from url: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        self.progressHandler = progress
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let task: URLSessionDownloadTask
            if let data = resumeData, resumeURL == url {
                task = session.downloadTask(withResumeData: data)   // continue a dropped transfer
            } else {
                task = session.downloadTask(with: url)
            }
            resumeData = nil          // consumed; a fresh failure will repopulate it
            resumeURL = url
            task.resume()
        }
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite e: Int64) {
        if e > 0 { progressHandler?(Double(w) / Double(e)) }
    }
    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo loc: URL) {
        // Move out of the delegate's temp dir immediately (it is deleted when this returns).
        guard let cont = continuation else { return }
        continuation = nil; resumeData = nil
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gguf")
        do { try FileManager.default.moveItem(at: loc, to: dst); cont.resume(returning: dst) }
        catch { cont.resume(throwing: error) }
    }
    func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError err: Error?) {
        guard let err, let cont = continuation else { return }
        continuation = nil
        // Stash the server's resume data so the next fetch continues the download instead of restarting.
        resumeData = (err as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        cont.resume(throwing: err)
    }
}

/// Owns the on-device model file lifecycle: download → verify → ready, plus delete. `@MainActor` so the
/// `@Published` state drives SwiftUI directly. All decision logic is here and unit-tested via a stub fetcher.
@MainActor
final class ModelDownloadManager: ObservableObject {
    @Published private(set) var state: ModelDownloadState
    let model: BundledModel
    private let fetcher: ModelFileFetcher
    private var task: Task<Void, Never>?

    init(model: BundledModel = ModelCatalog.coach, fetcher: ModelFileFetcher = URLSessionModelFetcher()) {
        self.model = model
        self.fetcher = fetcher
        self.state = ModelStorage.isPresent(model) ? .ready : .absent
    }

    func refreshPresence() {
        if case .downloading = state { return }
        if case .verifying = state { return }
        state = ModelStorage.isPresent(model) ? .ready : .absent
    }

    func startDownload() { task = Task { await runDownload() } }

    /// Test seam: run the download synchronously to completion.
    func startDownloadAndWait() async { await runDownload() }

    #if DEBUG
    func setStateForTesting(_ s: ModelDownloadState) { state = s }
    #endif

    func cancel() {
        task?.cancel()
        task = nil
        state = ModelStorage.isPresent(model) ? .ready : .absent
    }

    func deleteModel() {
        task?.cancel(); task = nil
        try? FileManager.default.removeItem(at: ModelStorage.fileURL(for: model))
        state = .absent
    }

    private func runDownload() async {
        state = .downloading(progress: 0)
        do {
            let tmp = try await fetcher.fetch(from: model.url) { [weak self] p in
                Task { @MainActor in
                    guard let self else { return }
                    if case .downloading = self.state { self.state = .downloading(progress: p) }
                }
            }
            try Task.checkCancellation()
            state = .verifying
            guard let hex = Self.sha256Hex(ofFileAt: tmp), hex == model.sha256.lowercased() else {
                try? FileManager.default.removeItem(at: tmp)
                state = .failed("Downloaded file failed integrity check. Delete and retry.")
                return
            }
            try ModelStorage.ensureDirectory()
            let dst = ModelStorage.fileURL(for: model)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: tmp, to: dst)
            state = .ready
        } catch is CancellationError {
            state = ModelStorage.isPresent(model) ? .ready : .absent
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Stream a file through SHA-256 so a 2 GB model is never fully resident in memory.
    static func sha256Hex(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = (try? handle.read(upToCount: 1 << 20)) ?? nil
            guard let chunk, !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
