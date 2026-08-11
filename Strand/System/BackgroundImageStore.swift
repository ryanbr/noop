import Foundation
import Combine
import SwiftUI
import StrandDesign

// MARK: - Custom background image (#custom-background)
//
// A user-picked photo drawn full-bleed behind EVERY screen, REPLACING the day-cycle sky when enabled
// (precedence: image > sky > flat canvas). The Kotlin twin is BackgroundImageStore.kt; the pref KEYS +
// the BackgroundFillMode rawValues are byte-identical (both read StrandDesign's BackgroundImagePrefs /
// BackgroundFillMode). Cloned from the avatar pipeline (ProfileAvatarView.AvatarImage.downscaledJPEG),
// but the bytes live in a FILE under Application Support rather than a UserDefaults blob — a full-screen
// photo is far larger than a 256px avatar. Like the avatar, the file + its toggles are device-local and
// deliberately NOT in the `.noopbak` whitelist.
//
// A single shared, @MainActor ObservableObject: the decoded `Image` is cached once and every scaffold's
// backdrop (LiquidScaffoldSky) + Today's inline sky observe THE SAME instance, so the identical picture
// is drawn on every tab (seamless at the crossfade) with zero per-tab re-decode.

@MainActor
final class BackgroundImageStore: ObservableObject {
    static let shared = BackgroundImageStore()

    /// One recent background: its app-private filename + the fill mode it was last shown with.
    struct Recent: Equatable {
        let id: String
        let fillMode: BackgroundFillMode
    }

    /// The recent images, most-recent (== ACTIVE) first, up to ``maxRecents``.
    @Published private(set) var recents: [Recent] = []

    /// The active (recents[0]) decoded for the backdrop; nil = none stored. Drawn by ``BackgroundImageBackdrop``.
    @Published private(set) var image: Image?

    /// Small preview images, index-aligned to ``recents`` (nil for a decode miss).
    @Published private(set) var thumbnails: [Image?] = []

    /// Master enable toggle (persisted under ``BackgroundImagePrefs/enabledKey``). When true AND an
    /// image is present, the custom image overrides the sky.
    @Published var enabled: Bool {
        didSet { d.set(enabled, forKey: BackgroundImagePrefs.enabledKey) }
    }

    private let d = UserDefaults.standard

    /// How the ACTIVE image is scaled — the fill mode of the most-recent entry. Backed by `recents`
    /// (`@Published`), so the backdrop re-reads it whenever the list changes.
    var fillMode: BackgroundFillMode { recents.first?.fillMode ?? .fill }

    /// The custom image is the ACTIVE backdrop (top of the precedence: enabled AND actually decoded).
    var isActive: Bool { enabled && image != nil }

    /// Whether a photo is stored — drives the Remove affordance in Settings.
    var hasImage: Bool { image != nil }

    private init() {
        enabled = d.bool(forKey: BackgroundImagePrefs.enabledKey)                       // default false
        var list = Self.parse(d.string(forKey: BackgroundImagePrefs.recentsKey) ?? "")
            .filter { Self.fileExists($0.id) }
        // Migration: pre-recents installs stored ONE `background.jpg`; adopt it as the sole recent so an
        // upgrading user keeps their background.
        if list.isEmpty, d.bool(forKey: BackgroundImagePrefs.presentKey), Self.fileExists("background.jpg") {
            list = [Recent(id: "background.jpg",
                           fillMode: BackgroundFillMode.resolve(d.string(forKey: BackgroundImagePrefs.fillModeKey) ?? ""))]
        }
        let capped = Array(list.prefix(Self.maxRecents))
        recents = capped
        // GC orphan background files not referenced by the list — e.g. one left by a crash between writing
        // a pick and persisting the list. (iOS writes atomically, so a partial file never appears; this
        // catches only the crash-before-persist case.)
        Self.gcOrphans(keeping: Set(capped.map(\.id)))
        image = capped.first.flatMap { Self.fullImage(id: $0.id) }
        thumbnails = capped.map { Self.thumbnail(id: $0.id) }
        persist()
    }

    /// Store a picked image: downscale + re-encode to a new app-private JPEG, push it to the FRONT of the
    /// recent list (deleting any dropped beyond ``maxRecents``), and refresh the decoded image/thumbnails.
    /// Silently no-ops if the bytes can't be decoded/written. Reuses the avatar's ImageIO downscale path.
    func setImage(from data: Data) {
        let jpeg = AvatarImage.downscaledJPEG(from: data, maxDimension: Self.maxDimension, quality: 0.9) ?? data
        guard PlatformImage(data: jpeg) != nil else { return }
        let id = "bg-\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
        guard let url = try? Self.fileURL(id: id, create: true) else { return }
        do { try jpeg.write(to: url, options: .atomic) } catch { return }
        // A fresh pick inherits the current fill mode. Prepend, cap, delete any dropped file.
        let next = Array(([Recent(id: id, fillMode: fillMode)] + recents).prefix(Self.maxRecents))
        for r in recents where !next.contains(r) {
            if let u = try? Self.fileURL(id: r.id, create: false) { try? FileManager.default.removeItem(at: u) }
        }
        recents = next
        refresh()
        // Actively picking an image means the user wants to SEE it — turn the background on now.
        if !enabled { enabled = true }
        persist()
    }

    /// Re-apply a recent preset: move it to the front (so it becomes the ACTIVE image + its fill mode).
    func applyRecent(_ index: Int) {
        guard recents.indices.contains(index), index != 0 else { return }
        let chosen = recents[index]
        recents = [chosen] + recents.enumerated().filter { $0.offset != index }.map { $0.element }
        refresh()
        if !enabled { enabled = true }
        persist()
    }

    /// Change the ACTIVE image's fill mode (recents[0]).
    func setFillMode(_ mode: BackgroundFillMode) {
        guard !recents.isEmpty else {
            d.set(mode.rawValue, forKey: BackgroundImagePrefs.fillModeKey)
            return
        }
        recents = recents.enumerated().map { $0.offset == 0 ? Recent(id: $0.element.id, fillMode: mode) : $0.element }
        persist()
    }

    /// Remove the ACTIVE image (recents[0]); the next recent becomes active, or the background clears.
    func clearImage() {
        guard let removed = recents.first else { return }
        if let u = try? Self.fileURL(id: removed.id, create: false) { try? FileManager.default.removeItem(at: u) }
        recents = Array(recents.dropFirst())
        refresh()
        persist()
    }

    /// Decode the active image + every recent's thumbnail.
    private func refresh() {
        image = recents.first.flatMap { Self.fullImage(id: $0.id) }
        thumbnails = recents.map { Self.thumbnail(id: $0.id) }
    }

    private func persist() {
        d.set(Self.serialize(recents), forKey: BackgroundImagePrefs.recentsKey)
        d.set(fillMode.rawValue, forKey: BackgroundImagePrefs.fillModeKey)
        d.set(!recents.isEmpty, forKey: BackgroundImagePrefs.presentKey)
    }

    /// How many recent images the "presets" strip keeps (MRU). Mirrors the Kotlin MAX_RECENTS.
    static let maxRecents = 3

    /// Longest edge (px) the stored image is downscaled to. Mirrors the Kotlin MAX_DIMEN.
    private static let maxDimension: CGFloat = 2560

    /// `"<file>,<mode>;<file>,<mode>"`. Filenames never contain `,`/`;`.
    static func serialize(_ list: [Recent]) -> String {
        list.map { "\($0.id),\($0.fillMode.rawValue)" }.joined(separator: ";")
    }

    static func parse(_ s: String) -> [Recent] {
        s.split(separator: ";").compactMap { entry -> Recent? in
            let parts = entry.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            return Recent(id: String(parts[0]), fillMode: BackgroundFillMode.resolve(String(parts[1])))
        }
    }

    private static func fullImage(id: String) -> Image? {
        guard let url = try? fileURL(id: id, create: false),
              let data = try? Data(contentsOf: url),
              let platform = PlatformImage(data: data) else { return nil }
        return Image(platformImage: platform)
    }

    private static func thumbnail(id: String) -> Image? {
        guard let url = try? fileURL(id: id, create: false),
              let data = try? Data(contentsOf: url),
              let jpeg = AvatarImage.downscaledJPEG(from: data, maxDimension: 256, quality: 0.85),
              let platform = PlatformImage(data: jpeg) else { return nil }
        return Image(platformImage: platform)
    }

    private static func fileExists(_ id: String) -> Bool {
        guard let url = try? fileURL(id: id, create: false) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// `<AppSupport>/OpenWhoop/<id>` (the same base folder the capture recorder uses).
    private static func fileURL(id: String, create: Bool) throws -> URL {
        let dir = try dirURL(create: create)
        return dir.appendingPathComponent(id, isDirectory: false)
    }

    private static func dirURL(create: Bool = false) throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                             appropriateFor: nil, create: create)
            .appendingPathComponent("OpenWhoop", isDirectory: true)
        if create { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        return dir
    }

    /// Delete background files (`bg-*.jpg` / legacy `background.jpg`) NOT referenced by `keeping` — only
    /// OUR files are matched, so the avatar and capture files are untouched.
    private static func gcOrphans(keeping kept: Set<String>) {
        guard let dir = try? dirURL(create: false),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where (name.hasPrefix("bg-") || name == "background.jpg") && !kept.contains(name) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}

// MARK: - BackgroundImageBackdrop
//
// Draws the cached custom image full-bleed under the whole screen, scaled per the store's fill mode. Drop
// it into a scaffold's `topBackground` slot (or a Today/MetricExplorer inline `.background` ZStack) above
// `surfaceBase`. Non-interactive + accessibility-hidden (pure decoration). Mirrors the Compose twin.

struct BackgroundImageBackdrop: View {
    @ObservedObject private var store = BackgroundImageStore.shared

    var body: some View {
        if let image = store.image {
            scaled(image)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func scaled(_ image: Image) -> some View {
        switch store.fillMode {
        case .fill:
            image.resizable().scaledToFill()
        case .fit:
            // Aspect-fit letterboxes onto the surfaceBase canvas beneath (the scaffold ZStack draws it).
            image.resizable().scaledToFit()
        case .stretch:
            // No aspect ratio — the image stretches to exactly fill the frame.
            image.resizable()
        case .tile:
            // One GPU-tiled draw: the source repeats across the viewport.
            image.resizable(resizingMode: .tile)
        }
    }
}
