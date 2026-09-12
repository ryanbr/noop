# On-Device Bundled LLM Coach Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a fifth AI Coach provider that runs a ~3B GGUF LLM entirely on-device (iOS) via in-process llama.cpp, downloaded once on first run, streaming replies, with no server and no API key.

**Architecture:** A new `AIProvider.onDevice` case is backed by an `OnDeviceClient` conforming to the existing `AIProviderClient` protocol, so it drops into the existing `AICoachEngine` and `CoachView` unchanged. `OnDeviceClient` drives a `LlamaEngine` Swift actor wrapping llama.cpp (Metal). A `ModelDownloadManager` fetches + SHA-256-verifies the GGUF on first run. All native code is iOS-only and excluded from the macOS target; all decision logic is pure and unit-tested on the macOS `StrandTests` target.

**Tech Stack:** Swift 6 / SwiftUI, llama.cpp (prebuilt xcframework via a local SPM binaryTarget), CryptoKit (SHA-256), URLSession background download, XcodeGen (`project.yml`).

## Global Constraints

- **Platform:** iOS only (`NOOPiOS` target, deployment target 17.0). All new code must keep the macOS `Strand` target and `StrandTests` (macOS) compiling — native llama.cpp code is excluded from macOS and platform-guarded with `#if os(iOS)`.
- **Module name is `Strand`**, product is `NOOP`. Tests use `@testable import Strand`.
- **`project.yml` is the source of truth** — run `xcodegen generate` after any target/file/package change. `Strand.xcodeproj` is generated (gitignored).
- **Offline by design:** the only new network egress is the one-time, user-initiated model download of public weights. No user data leaves the device. Coach inference is 100% offline.
- **Supply-chain:** pin the llama.cpp binary artifact by exact URL **and** SHA-256 checksum (mirrors the `exactVersion` pinning of `MarkdownUI`/`ZIPFoundation`). No committed binary blobs, no `from:` version ranges.
- **BLE safety contract is unrelated here** — no BLE changes.
- **Not a medical device** — no diagnostic/medical copy in UI strings.
- **Pinned model (verbatim into `ModelCatalog`):** Llama-3.2-3B-Instruct Q4_K_M, `contextLength = 4096`, downloaded directly from a pinned HuggingFace resolve URL; app never hosts weights.
- **Test commands:** macOS app tests run via `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test` (run `xcodegen generate` first). New pure-logic tests live in `StrandTests/`.

## File Structure

**New files:**
- `Strand/AI/OnDevice/ModelCatalog.swift` — `BundledModel` struct, the pinned default model, `ModelStorage` (on-disk path helpers), `deviceMeetsRequirements(physicalMemory:)`. Pure, macOS + iOS.
- `Strand/AI/OnDevice/ModelDownloadManager.swift` — `@MainActor ObservableObject` download state machine, SHA-256 verify, delete. Pure (injected downloader), macOS + iOS.
- `Strand/AI/OnDevice/LlamaEngine.swift` — Swift `actor` wrapping llama.cpp. **iOS only** (excluded from macOS target).
- `Strand/AI/OnDevice/OnDeviceClient.swift` — `AIProviderClient` conformance. **iOS only** (excluded from macOS target).
- `Packages/LlamaCpp/Package.swift` — local SPM package declaring the pinned llama.cpp binary xcframework target.
- `StrandTests/OnDeviceModelCatalogTests.swift`, `StrandTests/ModelDownloadManagerTests.swift`, `StrandTests/AICoachStreamingTests.swift`, `StrandTests/OnDeviceProviderGatingTests.swift` — new tests.

**Modified files:**
- `Strand/AI/AIProvider.swift` — add `.onDevice` case (first), platform-guarded `client`/`available`/`defaultProvider`, streaming protocol method + default.
- `Strand/AI/AICoach.swift` — `ChatMessage.text` → `var`; new `AICoachError` cases; `sendStreaming(_:)`, `stop()`, own the `ModelDownloadManager`, on-device-aware `isConfigured`; on-device privacy note.
- `Strand/Screens/CoachView.swift` — on-device setup card, Stop button, streaming render already works via message mutation, on-device privacy copy.
- `project.yml` — new `LlamaCpp` package, add it to `NOOPiOS` deps, exclude the two native files from macOS `Strand` target, add the increased-memory entitlement to `NOOPiOS`.

---

### Task 1: New `AICoachError` cases

**Files:**
- Modify: `Strand/AI/AICoach.swift` (the `AICoachError` enum, ~lines 110-141)
- Test: `StrandTests/OnDeviceModelCatalogTests.swift` (create — shared file for Task 1 + Task 2 pure error/catalog tests)

**Interfaces:**
- Produces: `AICoachError.modelNotDownloaded`, `.modelLoadFailed(String)`, `.generationFailed(String)`, `.deviceUnsupported` — each with a non-empty `errorDescription`.

- [ ] **Step 1: Write the failing test**

Create `StrandTests/OnDeviceModelCatalogTests.swift`:

```swift
import XCTest
@testable import Strand

final class OnDeviceCoachErrorTests: XCTestCase {
    func testNewErrorCasesHaveMessages() {
        let cases: [AICoachError] = [
            .modelNotDownloaded,
            .modelLoadFailed("boom"),
            .generationFailed("mid-stream"),
            .deviceUnsupported
        ]
        for e in cases {
            XCTAssertFalse((e.errorDescription ?? "").isEmpty, "\(e) has empty description")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/OnDeviceCoachErrorTests`
Expected: FAIL to compile — `modelNotDownloaded` is not a member of `AICoachError`.

- [ ] **Step 3: Add the cases**

In `Strand/AI/AICoach.swift`, add to the `AICoachError` enum cases:

```swift
    case modelNotDownloaded
    case modelLoadFailed(String)
    case generationFailed(String)
    case deviceUnsupported
```

And add to the `errorDescription` switch:

```swift
        case .modelNotDownloaded:
            return "Download the on-device coach model first, then ask again."
        case .modelLoadFailed(let detail):
            let extra = detail.isEmpty ? "" : " — \(detail)"
            return "Couldn't load the on-device model\(extra). Try re-downloading it."
        case .generationFailed(let detail):
            let extra = detail.isEmpty ? "" : " — \(detail)"
            return "The on-device coach stopped unexpectedly\(extra). Try again."
        case .deviceUnsupported:
            return "This \(Platform.deviceNounPhrase) doesn't have enough memory to run the on-device coach. Use a cloud provider instead."
```

Note: `Platform.deviceNounPhrase` is already used elsewhere in the codebase (see `CoachView.swift`). If it is not importable in this file, substitute the literal `"device"`.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/OnDeviceCoachErrorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Strand/AI/AICoach.swift StrandTests/OnDeviceModelCatalogTests.swift
git commit -m "coach: add on-device AICoachError cases"
```

---

### Task 2: `ModelCatalog`, `ModelStorage`, device gate

**Files:**
- Create: `Strand/AI/OnDevice/ModelCatalog.swift`
- Test: `StrandTests/OnDeviceModelCatalogTests.swift` (append)

**Interfaces:**
- Produces:
  - `struct BundledModel { let id: String; let displayName: String; let url: URL; let sha256: String; let sizeBytes: Int64; let contextLength: Int; let chatTemplate: String }`
  - `enum ModelCatalog { static let coach: BundledModel; static func deviceMeetsRequirements(physicalMemory: UInt64) -> Bool }`
  - `enum ModelStorage { static func directory() -> URL; static func fileURL(for: BundledModel) -> URL; static func isPresent(_: BundledModel) -> Bool }`

- [ ] **Step 1: Write the failing test**

Append to `StrandTests/OnDeviceModelCatalogTests.swift`:

```swift
final class ModelCatalogTests: XCTestCase {
    func testCoachModelIsWellFormed() {
        let m = ModelCatalog.coach
        XCTAssertFalse(m.id.isEmpty)
        XCTAssertFalse(m.displayName.isEmpty)
        XCTAssertEqual(m.url.scheme, "https")
        XCTAssertEqual(m.sha256.count, 64, "SHA-256 hex must be 64 chars")
        XCTAssertTrue(m.sha256.allSatisfy { $0.isHexDigit })
        XCTAssertGreaterThan(m.sizeBytes, 0)
        XCTAssertEqual(m.contextLength, 4096)
        XCTAssertFalse(m.chatTemplate.isEmpty)
    }

    func testDeviceGateBoundary() {
        let sixGB: UInt64 = 6 * 1024 * 1024 * 1024
        XCTAssertFalse(ModelCatalog.deviceMeetsRequirements(physicalMemory: sixGB - 1))
        XCTAssertTrue(ModelCatalog.deviceMeetsRequirements(physicalMemory: sixGB))
        XCTAssertTrue(ModelCatalog.deviceMeetsRequirements(physicalMemory: 8 * 1024 * 1024 * 1024))
    }

    func testStorageFileURLUsesModelId() {
        let url = ModelStorage.fileURL(for: ModelCatalog.coach)
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".gguf"))
        XCTAssertTrue(url.lastPathComponent.contains(ModelCatalog.coach.id))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/ModelCatalogTests`
Expected: FAIL to compile — `ModelCatalog`/`ModelStorage` undefined.

- [ ] **Step 3: Create the implementation**

Create `Strand/AI/OnDevice/ModelCatalog.swift`:

```swift
import Foundation

/// A pinned on-device model: where to fetch it, how to verify it, and the runtime parameters the
/// engine needs. Only a factual pointer + checksum is committed — never the weights themselves.
struct BundledModel {
    let id: String            // filename stem, e.g. "llama-3.2-3b-instruct-q4_k_m"
    let displayName: String   // shown in the picker / setup card
    let url: URL              // pinned HuggingFace resolve URL for the .gguf
    let sha256: String        // 64 lowercase hex chars; verified after download
    let sizeBytes: Int64      // approximate download size, shown in the confirm UI
    let contextLength: Int    // llama_context n_ctx
    let chatTemplate: String  // template id for llama_chat_apply_template ("llama3", "phi3", …)
}

/// The single bundled coach model. To change models, update EVERY field (URL + sha256 must match).
enum ModelCatalog {
    static let coach = BundledModel(
        id: "llama-3.2-3b-instruct-q4_k_m",
        displayName: "On-device Coach (Llama 3.2 3B)",
        // Pinned resolve URL. VERIFY the sha256 below against the actual file before shipping:
        //   curl -L <url> -o m.gguf && shasum -a 256 m.gguf
        url: URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!,
        sha256: "0000000000000000000000000000000000000000000000000000000000000000", // FILL from shasum before merge
        sizeBytes: 2_019_377_408,
        contextLength: 4096,
        chatTemplate: "llama3"
    )

    /// Minimum installed RAM to run the 3B model without jetsam risk. ~6 GB covers iPhone 15/16-class
    /// devices; confirmed against real-device measurement during implementation.
    static let minPhysicalMemory: UInt64 = 6 * 1024 * 1024 * 1024

    static func deviceMeetsRequirements(physicalMemory: UInt64) -> Bool {
        physicalMemory >= minPhysicalMemory
    }

    /// Convenience for callers using the live device value.
    static func deviceMeetsRequirements() -> Bool {
        deviceMeetsRequirements(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }
}

/// On-disk location for downloaded model files: Application Support/OnDeviceModels, excluded from backup.
enum ModelStorage {
    static func directory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("OnDeviceModels", isDirectory: true)
    }

    static func fileURL(for model: BundledModel) -> URL {
        directory().appendingPathComponent(model.id + ".gguf", isDirectory: false)
    }

    static func isPresent(_ model: BundledModel) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: model).path)
    }

    /// Create the directory if needed and mark it excluded from iCloud/iTunes backup.
    static func ensureDirectory() throws {
        let dir = directory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = dir
        try? mutable.setResourceValues(values)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/ModelCatalogTests`
Expected: PASS. (The placeholder sha256 is still 64 hex chars, so the format test passes; the real value is filled before merge.)

- [ ] **Step 5: Commit**

```bash
git add Strand/AI/OnDevice/ModelCatalog.swift StrandTests/OnDeviceModelCatalogTests.swift project.yml
git commit -m "coach: add on-device ModelCatalog + storage + device gate"
```

---

### Task 3: `ModelDownloadManager` state machine + SHA-256 verify

**Files:**
- Create: `Strand/AI/OnDevice/ModelDownloadManager.swift`
- Test: `StrandTests/ModelDownloadManagerTests.swift`

**Interfaces:**
- Consumes: `ModelCatalog.coach`, `ModelStorage`.
- Produces:
  - `enum ModelDownloadState: Equatable { case absent; case downloading(progress: Double); case verifying; case ready; case failed(String) }`
  - `protocol ModelFileFetcher { func fetch(from: URL, progress: @escaping (Double) -> Void) async throws -> URL }` (returns a temp file URL)
  - `@MainActor final class ModelDownloadManager: ObservableObject { @Published var state; init(model:fetcher:); func refreshPresence(); func startDownload(); func cancel(); func deleteModel(); static func sha256Hex(ofFileAt:) -> String? }`

- [ ] **Step 1: Write the failing test**

Create `StrandTests/ModelDownloadManagerTests.swift`:

```swift
import XCTest
import CryptoKit
@testable import Strand

/// A fetcher we fully control: hands back a temp file with chosen bytes, or throws.
private final class StubFetcher: ModelFileFetcher {
    var bytes: Data
    var error: Error?
    init(bytes: Data = Data([0x1, 0x2, 0x3]), error: Error? = nil) { self.bytes = bytes; self.error = error }
    func fetch(from url: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        if let error { throw error }
        progress(0.5); progress(1.0)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".gguf")
        try bytes.write(to: tmp)
        return tmp
    }
}

@MainActor
final class ModelDownloadManagerTests: XCTestCase {

    private func model(matching bytes: Data) -> BundledModel {
        let hex = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        var m = ModelCatalog.coach
        return BundledModel(id: "test-model", displayName: m.displayName, url: m.url,
                            sha256: hex, sizeBytes: Int64(bytes.count),
                            contextLength: m.contextLength, chatTemplate: m.chatTemplate)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: ModelStorage.directory())
        super.tearDown()
    }

    func testSuccessfulDownloadVerifiesAndBecomesReady() async {
        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let m = model(matching: bytes)
        let mgr = ModelDownloadManager(model: m, fetcher: StubFetcher(bytes: bytes))
        await mgr.startDownloadAndWait()
        XCTAssertEqual(mgr.state, .ready)
        XCTAssertTrue(ModelStorage.isPresent(m))
    }

    func testChecksumMismatchFailsAndDeletesFile() async {
        let m = model(matching: Data([0x1]))                 // expects hash of [0x1]
        let mgr = ModelDownloadManager(model: m, fetcher: StubFetcher(bytes: Data([0x2]))) // delivers [0x2]
        await mgr.startDownloadAndWait()
        if case .failed = mgr.state {} else { XCTFail("expected .failed, got \(mgr.state)") }
        XCTAssertFalse(ModelStorage.isPresent(m))
    }

    func testFetchErrorBecomesFailed() async {
        let m = model(matching: Data([0x1]))
        let mgr = ModelDownloadManager(model: m,
            fetcher: StubFetcher(error: URLError(.notConnectedToInternet)))
        await mgr.startDownloadAndWait()
        if case .failed = mgr.state {} else { XCTFail("expected .failed") }
    }

    func testDeleteReturnsToAbsent() async {
        let bytes = Data([0xAB])
        let m = model(matching: bytes)
        let mgr = ModelDownloadManager(model: m, fetcher: StubFetcher(bytes: bytes))
        await mgr.startDownloadAndWait()
        mgr.deleteModel()
        XCTAssertEqual(mgr.state, .absent)
        XCTAssertFalse(ModelStorage.isPresent(m))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/ModelDownloadManagerTests`
Expected: FAIL to compile — `ModelDownloadManager`, `ModelFileFetcher`, `startDownloadAndWait` undefined.

- [ ] **Step 3: Create the implementation**

Create `Strand/AI/OnDevice/ModelDownloadManager.swift`:

```swift
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

/// Production fetcher: URLSession download with progress via a delegate. Resume support is added in the
/// live path; the protocol keeps the state machine independent of it.
final class URLSessionModelFetcher: NSObject, ModelFileFetcher, URLSessionDownloadDelegate {
    private var progressHandler: ((Double) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    func fetch(from url: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        self.progressHandler = progress
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite e: Int64) {
        if e > 0 { progressHandler?(Double(w) / Double(e)) }
    }
    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo loc: URL) {
        // Move out of the delegate's temp dir immediately (it is deleted when this returns).
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gguf")
        do { try FileManager.default.moveItem(at: loc, to: dst); continuation?.resume(returning: dst) }
        catch { continuation?.resume(throwing: error) }
        continuation = nil
    }
    func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError err: Error?) {
        if let err { continuation?.resume(throwing: err); continuation = nil }
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/ModelDownloadManagerTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Strand/AI/OnDevice/ModelDownloadManager.swift StrandTests/ModelDownloadManagerTests.swift
git commit -m "coach: add ModelDownloadManager with SHA-256 verify"
```

---

### Task 4: Streaming protocol method + adapting default

**Files:**
- Modify: `Strand/AI/AIProvider.swift` (the `AIProviderClient` protocol + a new extension)
- Test: `StrandTests/AICoachStreamingTests.swift` (create)

**Interfaces:**
- Produces: on `AIProviderClient`:
  - `func stream(key: String, model: String, systemPrompt: String, messages: [(role: ChatMessage.Role, content: String)], session: URLSession) -> AsyncThrowingStream<String, Error>`
  - a protocol-extension default that wraps `send(...)` into exactly one yielded chunk.

- [ ] **Step 1: Write the failing test**

Create `StrandTests/AICoachStreamingTests.swift`:

```swift
import XCTest
import Foundation
@testable import Strand

/// A client whose send() returns a canned string, to prove the default stream() yields it as one chunk.
private struct OneShotClient: AIProviderClient {
    let reply: String
    func send(key: String, model: String, systemPrompt: String,
              messages: [(role: ChatMessage.Role, content: String)], session: URLSession) async throws -> String {
        reply
    }
    func fetchModels(key: String, session: URLSession) async throws -> [String] { [] }
}

final class StreamingAdapterTests: XCTestCase {
    func testDefaultStreamYieldsWholeReplyAsOneChunk() async throws {
        let client = OneShotClient(reply: "Hello world")
        var chunks: [String] = []
        for try await c in client.stream(key: "", model: "m", systemPrompt: "s",
                                         messages: [(.user, "hi")], session: .shared) {
            chunks.append(c)
        }
        XCTAssertEqual(chunks, ["Hello world"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/StreamingAdapterTests`
Expected: FAIL to compile — `stream(...)` is not a member of `AIProviderClient`.

- [ ] **Step 3: Add the protocol method + default**

In `Strand/AI/AIProvider.swift`, add to the `AIProviderClient` protocol:

```swift
    /// Stream a chat turn as incremental text chunks. Cloud clients inherit the default below (one
    /// chunk); only the on-device client overrides this to emit true token-by-token output.
    func stream(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession
    ) -> AsyncThrowingStream<String, Error>
```

Add a new extension below the protocol:

```swift
extension AIProviderClient {
    func stream(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let full = try await send(key: key, model: model, systemPrompt: systemPrompt,
                                              messages: messages, session: session)
                    continuation.yield(full)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/StreamingAdapterTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Strand/AI/AIProvider.swift StrandTests/AICoachStreamingTests.swift
git commit -m "coach: add streaming method to AIProviderClient with wrapping default"
```

---

### Task 5: `AICoachEngine.sendStreaming` + `stop()` + `ChatMessage.text` mutable

**Files:**
- Modify: `Strand/AI/AICoach.swift` (`ChatMessage` struct; `AICoachEngine` — add `sendStreaming`, `stop`, a `genTask` handle)
- Test: `StrandTests/AICoachStreamingTests.swift` (append)

**Interfaces:**
- Consumes: `AIProviderClient.stream(...)` (Task 4); `ChatMessage`.
- Produces: `AICoachEngine.sendStreaming(_ userText: String) async` (appends a user turn, then an empty assistant turn whose `.text` grows as chunks arrive); `AICoachEngine.stop()`; `ChatMessage.text` becomes `var`.

**Note on testability:** `sendStreaming` must be drivable with an injected client. If `AICoachEngine` currently always resolves `provider.client`, add a test-only override seam mirroring the existing `#if DEBUG fetchModelsOverride` pattern:

```swift
#if DEBUG
var streamOverride: ((_ wire: [(role: ChatMessage.Role, content: String)]) -> AsyncThrowingStream<String, Error>)?
#endif
```

- [ ] **Step 1: Write the failing test**

Append to `StrandTests/AICoachStreamingTests.swift`:

```swift
@MainActor
final class SendStreamingTests: XCTestCase {
    func testStreamingAccumulatesChunksIntoOneAssistantMessage() async {
        let engine = AICoachEngine(repo: .previewEmpty)   // see note below
        #if DEBUG
        engine.streamOverride = { _ in
            AsyncThrowingStream { c in
                c.yield("He"); c.yield("llo"); c.finish()
            }
        }
        #endif
        await engine.sendStreaming("hi")
        XCTAssertEqual(engine.messages.last?.role, .assistant)
        XCTAssertEqual(engine.messages.last?.text, "Hello")
        XCTAssertFalse(engine.sending)
    }
}
```

If a `Repository` test double is not readily available, this test may construct the engine via the same helper the existing `AICoachPromptAndStressTests` uses (inspect that file for the pattern — reuse it rather than inventing `.previewEmpty`). The assertion set stays identical.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/SendStreamingTests`
Expected: FAIL to compile — `sendStreaming`, `streamOverride` undefined.

- [ ] **Step 3: Implement**

In `Strand/AI/AICoach.swift`, change `ChatMessage`:

```swift
struct ChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant }
    let id: UUID
    let role: Role
    var text: String            // was `let` — streaming mutates this in place

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}
```

Add to `AICoachEngine` (near `send`):

```swift
    private var genTask: Task<Void, Never>?

    #if DEBUG
    /// Test seam: stand in for the provider's streaming call. Production leaves this nil.
    var streamOverride: ((_ wire: [(role: ChatMessage.Role, content: String)]) -> AsyncThrowingStream<String, Error>)?
    #endif

    /// Streaming send: append the user turn, build context, append an empty assistant turn, then grow
    /// its text as chunks arrive. Uses `stream(...)` for EVERY provider — cloud providers resolve to one
    /// chunk, the on-device provider streams token-by-token. Never throws; failures land in `errorText`.
    func sendStreaming(_ userText: String) async {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorText = AICoachError.emptyQuestion.errorDescription; return }
        guard let key = resolvedKey else { errorText = AICoachError.noKey.errorDescription; return }

        errorText = nil
        messages.append(ChatMessage(role: .user, text: trimmed))
        sending = true
        defer { sending = false }

        let context = dataConsent ? await buildFullContext() : noConsentNote
        let wire = wireMessages(context: context)

        let assistantId = UUID()
        messages.append(ChatMessage(id: assistantId, role: .assistant, text: ""))

        let stream: AsyncThrowingStream<String, Error>
        #if DEBUG
        if let streamOverride { stream = streamOverride(wire) }
        else { stream = provider.client.stream(key: key, model: model, systemPrompt: systemPrompt, messages: wire, session: session) }
        #else
        stream = provider.client.stream(key: key, model: model, systemPrompt: systemPrompt, messages: wire, session: session)
        #endif

        let handle = Task { @MainActor in
            do {
                for try await chunk in stream {
                    if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
                        messages[idx].text += chunk
                    }
                }
            } catch let e as AICoachError {
                errorText = e.errorDescription
            } catch is CancellationError {
                // user pressed Stop — keep whatever streamed so far
            } catch {
                errorText = AICoachError.network(error.localizedDescription).errorDescription
            }
            // Drop an empty assistant bubble if nothing arrived and there's an error to show instead.
            if let idx = messages.firstIndex(where: { $0.id == assistantId }),
               messages[idx].text.isEmpty {
                messages.remove(at: idx)
            }
        }
        genTask = handle
        await handle.value
        genTask = nil
    }

    /// Cancel an in-flight streaming generation (Stop button). Safe to call when idle.
    func stop() {
        genTask?.cancel()
        genTask = nil
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/SendStreamingTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Strand/AI/AICoach.swift StrandTests/AICoachStreamingTests.swift
git commit -m "coach: add sendStreaming + stop() with mutable ChatMessage.text"
```

---

### Task 6: `AIProvider.onDevice` case, platform-gated availability & default, on-device `isConfigured`

**Files:**
- Modify: `Strand/AI/AIProvider.swift` (enum case + `displayName`/`defaultModel`/`modelOptions`/`endpoint`/`modelsEndpoint`/`client`, add `available` + `defaultProvider`)
- Modify: `Strand/AI/AICoach.swift` (`AICoachEngine` owns `ModelDownloadManager`; `isConfigured` on-device branch; default provider)
- Test: `StrandTests/OnDeviceProviderGatingTests.swift` (create)

**Interfaces:**
- Consumes: `ModelDownloadManager` (Task 3), `ModelCatalog`.
- Produces: `AIProvider.onDevice`; `AIProvider.available: [AIProvider]`; `AIProvider.defaultProvider: AIProvider`; `AICoachEngine.modelDownloads: ModelDownloadManager`; `isConfigured` returns true for `.onDevice` iff `modelDownloads.state == .ready`.

- [ ] **Step 1: Write the failing test**

Create `StrandTests/OnDeviceProviderGatingTests.swift`:

```swift
import XCTest
@testable import Strand

@MainActor
final class OnDeviceProviderGatingTests: XCTestCase {
    func testOnDeviceIsFirstCaseAndInAllCases() {
        XCTAssertEqual(AIProvider.allCases.first, .onDevice)
    }

    func testIsConfiguredTracksDownloadReadiness() {
        let engine = AICoachEngine(repo: .previewEmpty)   // reuse existing test helper if different
        engine.provider = .onDevice
        // Fresh install: model absent → not configured.
        engine.modelDownloads.setStateForTesting(.absent)
        XCTAssertFalse(engine.isConfigured)
        engine.modelDownloads.setStateForTesting(.ready)
        XCTAssertTrue(engine.isConfigured)
    }

    #if os(iOS)
    func testDefaultProviderIsOnDeviceOniOS() {
        XCTAssertEqual(AIProvider.defaultProvider, .onDevice)
    }
    #else
    func testOnDeviceHiddenFromPickerOnMac() {
        XCTAssertFalse(AIProvider.available.contains(.onDevice))
        XCTAssertEqual(AIProvider.defaultProvider, .openAI)
    }
    #endif
}
```

Add a tiny test seam to `ModelDownloadManager` (guarded so it never ships in a way that matters):

```swift
    #if DEBUG
    func setStateForTesting(_ s: ModelDownloadState) { state = s }
    #endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/OnDeviceProviderGatingTests`
Expected: FAIL to compile — `.onDevice`, `available`, `defaultProvider`, `modelDownloads`, `setStateForTesting` undefined.

- [ ] **Step 3: Implement enum + engine wiring**

In `Strand/AI/AIProvider.swift`, add `onDevice` as the FIRST case:

```swift
enum AIProvider: String, CaseIterable, Identifiable {
    case onDevice
    case openAI
    case anthropic
    case gemini
    case custom
```

Extend each switch with `.onDevice`:

```swift
    var displayName: String {
        switch self {
        case .onDevice:  return "On-device (no setup, fully private)"
        ...
    var defaultModel: String {
        switch self {
        case .onDevice:  return ModelCatalog.coach.id
        ...
    var modelOptions: [String] {
        switch self {
        case .onDevice:  return [ModelCatalog.coach.id]
        ...
    var endpoint: URL {
        switch self {
        case .onDevice:  return URL(string: "file:///on-device")!   // unused; inference is in-process
        ...
    var modelsEndpoint: URL {
        switch self {
        case .onDevice:  return URL(string: "file:///on-device")!   // unused
        ...
    var client: any AIProviderClient {
        switch self {
        case .onDevice:
            #if os(iOS)
            return OnDeviceClient.shared
            #else
            return UnavailableOnDeviceClient()
            #endif
        ...
```

Add the platform-gated availability + default, and the macOS stub client, at the bottom of the file:

```swift
extension AIProvider {
    /// Providers shown in the picker. The on-device provider is iOS-only; macOS keeps the cloud set.
    static var available: [AIProvider] {
        #if os(iOS)
        return allCases
        #else
        return allCases.filter { $0 != .onDevice }
        #endif
    }

    /// The provider a fresh install starts on: on-device (zero-setup) on iOS, OpenAI on macOS.
    static var defaultProvider: AIProvider {
        #if os(iOS)
        return .onDevice
        #else
        return .openAI
        #endif
    }
}

#if !os(iOS)
/// macOS stand-in so `AIProvider.onDevice.client` type-checks in the shared enum. Never selectable on
/// macOS (filtered out of `available`); if somehow invoked it fails clearly rather than doing anything.
struct UnavailableOnDeviceClient: AIProviderClient {
    func send(key: String, model: String, systemPrompt: String,
              messages: [(role: ChatMessage.Role, content: String)], session: URLSession) async throws -> String {
        throw AICoachError.deviceUnsupported
    }
    func fetchModels(key: String, session: URLSession) async throws -> [String] { [ModelCatalog.coach.id] }
}
#endif
```

In `Strand/AI/AICoach.swift` `AICoachEngine`:

1. Add the property and construct it in `init`:

```swift
    /// Owns the on-device model file lifecycle (download/verify/delete). Drives the on-device setup card
    /// and gates `isConfigured` for the on-device provider.
    let modelDownloads = ModelDownloadManager()
```

2. Change the default provider fallback in `init` from `?? .openAI` to `?? AIProvider.defaultProvider`.

3. Update `isConfigured`:

```swift
    var isConfigured: Bool {
        switch provider {
        case .onDevice: return modelDownloads.state == .ready
        case .custom:   return customConnected
        default:        return hasKey
        }
    }
```

4. Update `resolvedKey` so the on-device provider needs no key (like `.custom`): in the final `return`, treat `.onDevice` the same as `.custom` — return `""` when no stored key applies:

```swift
        return (provider == .custom || provider == .onDevice) ? "" : nil
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/OnDeviceProviderGatingTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Strand/AI/AIProvider.swift Strand/AI/AICoach.swift StrandTests/OnDeviceProviderGatingTests.swift Strand/AI/OnDevice/ModelDownloadManager.swift
git commit -m "coach: add onDevice provider case, platform gating, download-aware isConfigured"
```

---

### Task 7: Vendor llama.cpp as a pinned SPM binary xcframework

**Files:**
- Create: `Packages/LlamaCpp/Package.swift`
- Modify: `project.yml` (add `LlamaCpp` package; add it to `NOOPiOS` dependencies; exclude the two native files from the macOS `Strand` target)

**Interfaces:**
- Produces: an importable `llama` module for iOS device + simulator, available only to `NOOPiOS`.

**Background:** llama.cpp's CI publishes a prebuilt `llama-b<NNNN>-xcframework.zip` per release. We pin one by URL + SHA-256 via an SPM `binaryTarget`. This matches the repo's "pin exact, no committed binaries" convention: our `Package.swift` is original; the artifact is fetched and checksum-verified by SPM.

- [ ] **Step 1: Determine the pinned artifact + checksum**

Choose a recent stable llama.cpp release that publishes an xcframework asset. Compute the SwiftPM checksum:

```bash
curl -L -o llama.xcframework.zip \
  https://github.com/ggml-org/llama.cpp/releases/download/b<NNNN>/llama-b<NNNN>-xcframework.zip
swift package compute-checksum llama.xcframework.zip
```

Record the URL and the printed checksum for Step 2.

- [ ] **Step 2: Create the local package**

Create `Packages/LlamaCpp/Package.swift`:

```swift
// swift-tools-version:5.9
import PackageDescription

// Wraps the pinned llama.cpp prebuilt xcframework. URL + checksum are pinned EXACTLY (supply-chain:
// a clean resolve can't pull a different artifact). To bump llama.cpp, update BOTH fields together.
let package = Package(
    name: "LlamaCpp",
    platforms: [.iOS(.v17)],
    products: [.library(name: "LlamaCpp", targets: ["LlamaCpp"])],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b<NNNN>/llama-b<NNNN>-xcframework.zip",
            checksum: "<swift-package-compute-checksum output>"
        ),
        .target(name: "LlamaCpp", dependencies: ["llama"], path: "Sources/LlamaCpp")
    ]
)
```

Create `Packages/LlamaCpp/Sources/LlamaCpp/Exports.swift`:

```swift
// Re-export the binary module so app code writes `import LlamaCpp`.
@_exported import llama
```

- [ ] **Step 3: Wire into project.yml**

In `project.yml` `packages:` add:

```yaml
  # Prebuilt llama.cpp xcframework (Metal) for the on-device Coach. Local package pins the binary
  # artifact by URL + checksum (see Packages/LlamaCpp/Package.swift). iOS-only.
  LlamaCpp:
    path: Packages/LlamaCpp
```

In the `NOOPiOS` target `dependencies:` add:

```yaml
      - package: LlamaCpp
```

In the macOS `Strand` target `sources:` `excludes:` list, add the two native files (they must NOT compile on macOS):

```yaml
          - "AI/OnDevice/LlamaEngine.swift"
          - "AI/OnDevice/OnDeviceClient.swift"
```

- [ ] **Step 4: Verify both targets still build**

Run:
```bash
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```
Expected: both compile. (The native files don't exist yet — that's fine; the excludes and package resolve are what's being verified. If the iOS build fails to *resolve* `LlamaCpp`, fix the URL/checksum before proceeding.)

- [ ] **Step 5: Commit**

```bash
git add Packages/LlamaCpp/Package.swift Packages/LlamaCpp/Sources/LlamaCpp/Exports.swift project.yml
git commit -m "coach: vendor pinned llama.cpp xcframework for iOS on-device coach"
```

---

### Task 8: `LlamaEngine` actor (iOS-only, device-verified)

**Files:**
- Create: `Strand/AI/OnDevice/LlamaEngine.swift`

**Interfaces:**
- Consumes: `import LlamaCpp`, `BundledModel`.
- Produces:
  - `actor LlamaEngine { static let shared: LlamaEngine; func load(modelURL: URL, model: BundledModel) async throws; func unload(); func generate(systemPrompt: String, messages: [(role: ChatMessage.Role, content: String)]) -> AsyncStream<String> }`

**Important:** This file wraps the llama.cpp C API. Exact symbol names track the pinned llama.cpp `b<NNNN>` release; verify against its headers. There is **no CI unit test** for this file — it is validated by the device smoke test in Task 12. Keep it minimal and defensive (no force-unwraps around C pointers; every failure path returns/throws a Swift error).

- [ ] **Step 1: Implement the actor**

Create `Strand/AI/OnDevice/LlamaEngine.swift` (the whole file is one step — it is not unit-tested, so there is no red/green cycle; correctness is proven on device in Task 12):

```swift
import Foundation
import LlamaCpp

/// In-process llama.cpp wrapper. An actor so the C context is never touched concurrently. iOS-only.
actor LlamaEngine {
    static let shared = LlamaEngine()

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var loadedModel: BundledModel?

    /// Load a GGUF into a llama context with Metal enabled. Idempotent: reloads only when the target
    /// differs from what's loaded. Throws `AICoachError.modelLoadFailed` on any C failure.
    func load(modelURL: URL, model: BundledModel) async throws {
        if loadedModel?.id == model.id, ctx != nil { return }
        unload()

        llama_backend_init()

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = -1                    // all layers on the Metal GPU
        guard let m = llama_model_load_from_file(modelURL.path, mparams) else {
            throw AICoachError.modelLoadFailed("could not open \(model.id)")
        }

        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(model.contextLength)
        cparams.n_batch = 512
        guard let c = llama_init_from_model(m, cparams) else {
            llama_model_free(m)
            throw AICoachError.modelLoadFailed("could not create context")
        }

        self.model = m
        self.ctx = c
        self.vocab = llama_model_get_vocab(m)
        self.loadedModel = model
    }

    /// Free the context + model. Safe to call when nothing is loaded.
    func unload() {
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        ctx = nil; model = nil; vocab = nil; loadedModel = nil
    }

    var isLoaded: Bool { ctx != nil }

    /// Generate a reply, yielding detokenized text pieces as they are produced. Stops on EOS, the
    /// context limit, `maxTokens`, or Task cancellation. Applies the model's chat template.
    func generate(systemPrompt: String,
                  messages: [(role: ChatMessage.Role, content: String)]) -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task {
                guard let ctx = self.ctx, let vocab = self.vocab, let model = self.model else {
                    continuation.finish(); return
                }
                let maxTokens = 512

                // 1. Build the prompt via the model's chat template.
                let prompt = self.applyTemplate(model: model, systemPrompt: systemPrompt, messages: messages)

                // 2. Tokenize.
                var tokens = self.tokenize(vocab: vocab, text: prompt, addBOS: true)
                guard !tokens.isEmpty else { continuation.finish(); return }

                // 3. Prefill.
                var batch = llama_batch_get_one(&tokens, Int32(tokens.count))
                if llama_decode(ctx, batch) != 0 { continuation.finish(); return }

                // 4. Sampler chain (greedy-ish: top-k / top-p / temp). Freed at the end.
                let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
                llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
                llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.95, 1))
                llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.7))
                llama_sampler_chain_add(sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED))
                defer { llama_sampler_free(sampler) }

                var generated = 0
                while generated < maxTokens {
                    if Task.isCancelled { break }
                    let next = llama_sampler_sample(sampler, ctx, -1)
                    if llama_vocab_is_eog(vocab, next) { break }

                    if let piece = self.pieceToString(vocab: vocab, token: next), !piece.isEmpty {
                        continuation.yield(piece)
                    }
                    var one = next
                    batch = llama_batch_get_one(&one, 1)
                    if llama_decode(ctx, batch) != 0 { break }
                    generated += 1
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - C helpers (exact symbols track the pinned llama.cpp release; verify vs its headers)

    private func applyTemplate(model: OpaquePointer, systemPrompt: String,
                               messages: [(role: ChatMessage.Role, content: String)]) -> String {
        var chat: [llama_chat_message] = []
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        func cstr(_ s: String) -> UnsafeMutablePointer<CChar> { let p = strdup(s)!; cStrings.append(p); return p }
        chat.append(llama_chat_message(role: cstr("system"), content: cstr(systemPrompt)))
        for m in messages { chat.append(llama_chat_message(role: cstr(m.role.rawValue), content: cstr(m.content))) }
        defer { cStrings.forEach { free($0) } }

        let tmpl = llama_model_chat_template(model, nil)
        var buf = [CChar](repeating: 0, count: 32_768)
        let n = llama_chat_apply_template(tmpl, &chat, chat.count, true, &buf, Int32(buf.count))
        if n <= 0 { return systemPrompt + "\n\n" + (messages.last?.content ?? "") }
        return String(cString: buf)
    }

    private func tokenize(vocab: OpaquePointer, text: String, addBOS: Bool) -> [llama_token] {
        let utf8 = Array(text.utf8CString)
        let cap = Int32(utf8.count + 8)
        var out = [llama_token](repeating: 0, count: Int(cap))
        let n = llama_tokenize(vocab, text, Int32(strlen(text)), &out, cap, addBOS, true)
        if n < 0 { return [] }
        return Array(out.prefix(Int(n)))
    }

    private func pieceToString(vocab: OpaquePointer, token: llama_token) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        let n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, true)
        if n <= 0 { return nil }
        return buf.withUnsafeBufferPointer { p in
            String(decoding: UnsafeRawBufferPointer(start: p.baseAddress, count: Int(n)), as: UTF8.self)
        }
    }
}
```

- [ ] **Step 2: Verify it compiles for iOS**

Run:
```bash
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```
Expected: compiles. If any llama.cpp symbol name mismatches the pinned release, fix it against that release's `llama.h` (the wrappers are intentionally thin, so fixes are local).

- [ ] **Step 3: Commit**

```bash
git add Strand/AI/OnDevice/LlamaEngine.swift
git commit -m "coach: add LlamaEngine actor wrapping llama.cpp (iOS)"
```

---

### Task 9: `OnDeviceClient` conforming to `AIProviderClient` (iOS-only)

**Files:**
- Create: `Strand/AI/OnDevice/OnDeviceClient.swift`

**Interfaces:**
- Consumes: `LlamaEngine.shared`, `ModelCatalog`, `ModelStorage`, `AIProviderClient`.
- Produces: `struct OnDeviceClient: AIProviderClient { static let shared: OnDeviceClient }` overriding `stream(...)` with real token streaming, plus `send(...)` (concatenates the stream) and `fetchModels(...)` (the single catalog id).

- [ ] **Step 1: Implement**

Create `Strand/AI/OnDevice/OnDeviceClient.swift` (not CI-unit-tested — exercised on device in Task 12):

```swift
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
                for await piece in await LlamaEngine.shared.generate(systemPrompt: systemPrompt, messages: messages) {
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
```

- [ ] **Step 2: Verify iOS build**

Run:
```bash
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```
Expected: iOS build links `OnDeviceClient.shared` in `AIProvider.client`; macOS build still compiles (uses `UnavailableOnDeviceClient`).

- [ ] **Step 3: Commit**

```bash
git add Strand/AI/OnDevice/OnDeviceClient.swift
git commit -m "coach: add OnDeviceClient streaming via LlamaEngine (iOS)"
```

---

### Task 10: CoachView — on-device setup card, streaming send, Stop button, privacy copy

**Files:**
- Modify: `Strand/Screens/CoachView.swift`

**Interfaces:**
- Consumes: `coach.provider`, `coach.isConfigured`, `coach.modelDownloads` (`state`, `startDownload()`, `cancel()`, `deleteModel()`), `coach.sendStreaming(_:)`, `coach.stop()`, `ModelCatalog.coach`, `ModelCatalog.deviceMeetsRequirements()`, `AIProvider.available`.

**Note:** `CoachView` is shared by macOS + iOS. The on-device card is only reachable when `provider == .onDevice`, which macOS filters out of `available`, so the card is effectively iOS-only at runtime while the code compiles on both. Reference `coach.modelDownloads` (compiles on both since `ModelDownloadManager` is cross-platform).

- [ ] **Step 1: Point the picker at `AIProvider.available`**

Find the provider Picker (around line 224):

```swift
                    Picker("Provider", selection: $coach.provider) {
                        ForEach(AIProvider.allCases) { p in
```

Change `AIProvider.allCases` → `AIProvider.available`.

- [ ] **Step 2: Add the on-device setup card branch**

In the setup card body, add a branch that renders when `coach.provider == .onDevice` INSTEAD of the API-key field (mirror how `provider == .custom` branches today, around lines 235-280). Insert:

```swift
                if coach.provider == .onDevice {
                    onDeviceSetupSection
                } else if coach.provider == .custom {
                    // …existing custom URL field…
                }
```

Add the section as a computed view on `CoachView`:

```swift
    @ViewBuilder
    private var onDeviceSetupSection: some View {
        let m = ModelCatalog.coach
        VStack(alignment: .leading, spacing: 10) {
            if !ModelCatalog.deviceMeetsRequirements() {
                Text("This \(Platform.deviceNounPhrase) doesn't have enough memory to run the on-device coach. Pick a cloud provider above instead.")
                    .strandCaption()
            } else {
                switch coach.modelDownloads.state {
                case .absent, .failed:
                    Text("\(m.displayName) runs entirely on your \(Platform.deviceNounPhrase). One-time download over Wi-Fi (~\(byteString(m.sizeBytes))). After that, coaching works with no internet.")
                        .strandCaption()
                    if case .failed(let msg) = coach.modelDownloads.state {
                        Text(msg).strandCaption().foregroundStyle(.red)
                    }
                    NoopButton("Download coach model", systemImage: "arrow.down.circle",
                               kind: .primary) { coach.modelDownloads.startDownload() }
                case .downloading(let p):
                    ProgressView(value: p) { Text("Downloading… \(Int(p * 100))%").strandCaption() }
                    NoopButton("Cancel", systemImage: "xmark", kind: .secondary) { coach.modelDownloads.cancel() }
                case .verifying:
                    ProgressView { Text("Verifying…").strandCaption() }
                case .ready:
                    StatePill("Model ready", tone: .accent, showsDot: true)
                    NoopButton("Delete model (free \(byteString(m.sizeBytes)))", systemImage: "trash",
                               kind: .secondary) { coach.modelDownloads.deleteModel() }
                }
            }
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
```

(Use whatever the file's existing caption/pill helpers are — `strandCaption`, `StatePill`, `NoopButton` are already used in this file. Match them.)

- [ ] **Step 3: Route sending through `sendStreaming` and add a Stop button**

Find where the composer calls `coach.send(...)` (the send action). Change it to `await coach.sendStreaming(text)`. Where the send button shows a spinner while `coach.sending`, add a Stop affordance:

```swift
                if coach.sending {
                    NoopButton("Stop", systemImage: "stop.fill", kind: .secondary) { coach.stop() }
                }
```

Streaming render needs no extra work: the assistant `ChatMessage.text` mutates in place and the message list re-renders.

- [ ] **Step 4: On-device privacy copy**

Find the bottom privacy line (around lines 570-575, the `coach.provider == .custom ? … : …` ternary). Add an on-device case so it reads:

```swift
            Text(coach.provider == .onDevice
                 ? "On-device coaching never leaves your \(Platform.deviceNounPhrase) — your metrics are read and answered locally."
                 : (coach.provider == .custom
                    ? /* existing custom text */
                    : /* existing cloud text */))
```

- [ ] **Step 5: Verify both builds compile**

Run:
```bash
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```
Expected: both compile.

- [ ] **Step 6: Commit**

```bash
git add Strand/Screens/CoachView.swift
git commit -m "coach: on-device setup card, streaming send, Stop button, privacy copy"
```

---

### Task 11: Entitlement, memory-pressure unload, background unload

**Files:**
- Modify: `project.yml` (`NOOPiOS` entitlements)
- Modify: `Strand/AI/AICoach.swift` (memory-pressure + background-unload wiring in `AICoachEngine`)

**Interfaces:**
- Consumes: `LlamaEngine.shared` (iOS), `NotificationCenter` app lifecycle, `DispatchSource` memory pressure.
- Produces: `AICoachEngine` unloads the model on memory pressure (critical) while idle and on backgrounding (default ON).

- [ ] **Step 1: Add the increased-memory entitlement**

In `project.yml`, `NOOPiOS` → `entitlements` → `properties`, add:

```yaml
        com.apple.developer.kernel.increased-memory-limit: true
```

- [ ] **Step 2: Add memory-pressure + background unload to the engine**

In `Strand/AI/AICoach.swift`, add to `AICoachEngine` (iOS-guarded so macOS is untouched):

```swift
    #if os(iOS)
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    /// Free the model under critical memory pressure (only when idle) and on backgrounding, so the
    /// coach is never the top jetsam target. Reloads lazily on the next generation. Call once from init.
    func installMemoryGuards() {
        let src = DispatchSource.makeMemoryPressureSource(eventMask: .critical, queue: .main)
        src.setEventHandler { [weak self] in
            guard let self, !self.sending else { return }
            Task { await LlamaEngine.shared.unload() }
        }
        src.resume()
        memoryPressureSource = src

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, !self.sending else { return }
            Task { await LlamaEngine.shared.unload() }
        }
    }
    #endif
```

Call `installMemoryGuards()` at the end of `init` under `#if os(iOS)`. Add `import UIKit` guarded by `#if canImport(UIKit)` at the top of the file if not present.

- [ ] **Step 3: Verify builds**

Run:
```bash
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```
Expected: both compile.

- [ ] **Step 4: Run the full macOS test suite (no regressions)**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test`
Expected: all tests pass, including the new on-device suites.

- [ ] **Step 5: Commit**

```bash
git add project.yml Strand/AI/AICoach.swift
git commit -m "coach: increased-memory entitlement + memory-pressure/background model unload"
```

---

### Task 12: Device verification + docs

**Files:**
- Modify: `noop/CLAUDE.md` (document the on-device coach + how to change the model)
- Create: `docs/superpowers/plans/2026-07-09-on-device-coach-device-checklist.md` (verification record)

**This task has NO CI test** — it is the physical-device verification the pure tests can't cover. It must be run on a real iPhone (BLE/Metal/memory), not the simulator.

- [ ] **Step 1: Fill the real model checksum**

Download the pinned GGUF, compute its SHA-256, and replace the placeholder in `ModelCatalog.coach.sha256`:

```bash
curl -L "<ModelCatalog.coach.url>" -o coach.gguf
shasum -a 256 coach.gguf
```
Commit the real checksum. **This is required before the download can ever succeed** (a placeholder guarantees a verify failure).

- [ ] **Step 2: On-device smoke test**

On a physical iPhone (≥6 GB RAM) with a source build:
1. Open Coach → provider defaults to On-device → tap "Download coach model" → progress → verifying → **Model ready**.
2. Ask a question with data consent ON → reply **streams** token-by-token.
3. Tap **Stop** mid-reply → generation halts, partial text retained.
4. "Today's brief" runs on first open.
5. Background the app during idle → reopen → next question still works (lazy reload).
6. Instruments (Allocations/Memory): note peak memory; confirm no jetsam. If it jetsams, raise `ModelCatalog.minPhysicalMemory` and/or revisit the entitlement.
7. Delete model → returns to the download prompt; ~2 GB reclaimed.
8. Toggle to a cloud provider → still works (cloud path unchanged, now via the streaming default = one chunk).

Record measured tokens/sec and peak memory in the checklist doc.

- [ ] **Step 3: Confirm / adjust the RAM gate**

Based on Step 2 measurements, confirm `minPhysicalMemory = 6 GB` (or adjust). Commit any change.

- [ ] **Step 4: Update CLAUDE.md**

Add a short subsection under the coach/AI area of `noop/CLAUDE.md` documenting: the on-device provider is iOS-only, in-process llama.cpp, first-run download (pinned URL + SHA-256 in `ModelCatalog`), how to change the model (update every `BundledModel` field + the `LlamaCpp` package pin), and that inference is 100% offline (only the one-time weight download uses the network).

- [ ] **Step 5: Commit**

```bash
git add Strand/AI/OnDevice/ModelCatalog.swift noop/CLAUDE.md docs/superpowers/plans/2026-07-09-on-device-coach-device-checklist.md
git commit -m "coach: pin real model checksum + document on-device coach; device verification"
```

---

## Self-Review

**Spec coverage:**
- Fifth `.onDevice` provider via `AIProviderClient` → Tasks 6, 9. ✓
- llama.cpp in-process, Metal → Tasks 7, 8. ✓
- ~3B Q4 GGUF, Llama-3.2-3B-Instruct pinned → Task 2 (`ModelCatalog`). ✓
- First-run download, SHA-256 verify, resume, excluded-from-backup, delete → Tasks 2, 3. ✓
- Streaming token-by-token + uniform path for cloud → Tasks 4, 5. ✓
- Default provider + front-and-center positioning + setup card + Stop + privacy copy → Tasks 6, 10. ✓
- Memory: increased-memory entitlement, RAM gate, lazy load, memory-pressure unload, background unload → Tasks 2, 11. ✓
- Error handling via extended `AICoachError` → Task 1. ✓
- Testing: pure units in CI (catalog/gate, download state machine, verifier, streaming adapter, sendStreaming, isConfigured truth table); native device-verified → Tasks 1-6, 12. ✓
- Reuse of context/consent/chat/UI unchanged → guaranteed by conforming to `AIProviderClient` and only branching the setup card. ✓
- macOS + `StrandTests` stay green (native excluded, platform-guarded) → Tasks 6, 7. ✓

**Placeholder scan:** the only intentional placeholder is `ModelCatalog.coach.sha256` (64 zeros) and the `b<NNNN>` release tag — both are explicitly resolved in Tasks 7 (checksum/URL) and 12 Step 1 (model sha256) with exact commands. No "TODO/handle edge cases" hand-waving remains.

**Type consistency:** `ModelDownloadState`, `ModelFileFetcher`, `ModelDownloadManager` (`state`, `startDownload`, `startDownloadAndWait`, `cancel`, `deleteModel`, `setStateForTesting`, `sha256Hex`), `BundledModel` fields, `ModelStorage.fileURL(for:)`, `LlamaEngine.shared`/`load`/`unload`/`generate`, `OnDeviceClient.shared`, `AIProvider.onDevice`/`available`/`defaultProvider`/`client`, `AICoachEngine.modelDownloads`/`sendStreaming`/`stop`/`streamOverride`, `AIProviderClient.stream(...)` — names are used identically across the tasks that define and consume them.

**Known verification-dependent items (not gaps):** exact llama.cpp C symbol names track the pinned `b<NNNN>` release (Task 8 Step 2 compiles against real headers); the RAM-gate number and peak-memory behavior are confirmed on device (Task 12). Both are called out where they occur.
