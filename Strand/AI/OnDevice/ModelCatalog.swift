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
        // Pinned to an IMMUTABLE Hugging Face commit revision (not `main`) so the URL can't drift; the
        // sha256 below is an independent fail-closed check. The file's LFS sha256 at this revision
        // (HF `x-linked-etag`) equals the sha256 below. sha256 verified against the downloaded file:
        //   curl -L <url> -o m.gguf && shasum -a 256 m.gguf  (→ the value below)
        url: URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/5ab33fa94d1d04e903623ae72c95d1696f09f9e8/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!,
        sha256: "6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff",
        sizeBytes: 2_019_377_696,
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
