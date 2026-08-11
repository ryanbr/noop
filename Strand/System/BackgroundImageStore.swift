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

    /// The decoded background, cached; nil = none stored. Drawn by ``BackgroundImageBackdrop``.
    @Published private(set) var image: Image?

    /// Master enable toggle (persisted under ``BackgroundImagePrefs/enabledKey``). When true AND an
    /// image is present, the custom image overrides the sky.
    @Published var enabled: Bool {
        didSet { d.set(enabled, forKey: BackgroundImagePrefs.enabledKey) }
    }

    /// How the image is scaled (persisted under ``BackgroundImagePrefs/fillModeKey`` as its rawValue).
    @Published var fillMode: BackgroundFillMode {
        didSet { d.set(fillMode.rawValue, forKey: BackgroundImagePrefs.fillModeKey) }
    }

    private let d = UserDefaults.standard

    /// The custom image is the ACTIVE backdrop (top of the precedence: enabled AND actually decoded).
    var isActive: Bool { enabled && image != nil }

    /// Whether a photo is stored — drives the Remove affordance in Settings.
    var hasImage: Bool { image != nil }

    private init() {
        enabled = d.bool(forKey: BackgroundImagePrefs.enabledKey)                       // default false
        fillMode = BackgroundFillMode.resolve(d.string(forKey: BackgroundImagePrefs.fillModeKey) ?? "")
        // Decode the persisted image (if any) once, up front.
        if d.bool(forKey: BackgroundImagePrefs.presentKey),
           let url = try? Self.fileURL(create: false),
           let data = try? Data(contentsOf: url),
           let platform = PlatformImage(data: data) {
            image = Image(platformImage: platform)
        } else {
            image = nil
        }
    }

    /// Store a picked image: downscale + re-encode to the app-private JPEG, flip the present flag, and
    /// update the cached ``image``. Silently no-ops if the bytes can't be decoded/written (the current
    /// background is left untouched). Reuses the avatar's ImageIO downscale path.
    func setImage(from data: Data) {
        // Downscale the longest edge to at most MAX_DIMEN so a 100MP pick can never sit full-res in memory
        // or on disk; fall back to the raw bytes only if the decode fails (matching setAvatar).
        let jpeg = AvatarImage.downscaledJPEG(from: data, maxDimension: Self.maxDimension, quality: 0.9) ?? data
        guard let platform = PlatformImage(data: jpeg) else { return }
        guard let url = try? Self.fileURL(create: true) else { return }
        do {
            try jpeg.write(to: url, options: .atomic)
        } catch {
            return
        }
        d.set(true, forKey: BackgroundImagePrefs.presentKey)
        image = Image(platformImage: platform)
        // Actively picking an image means the user wants to SEE it — turn the background on so it shows
        // immediately, instead of silently storing a photo that stays hidden behind a separate toggle.
        // They can still toggle it off afterwards (the image is kept) or Remove it entirely.
        if !enabled { enabled = true }
    }

    /// Remove the photo: delete the file, clear the present flag, drop the cached ``image``.
    func clearImage() {
        if let url = try? Self.fileURL(create: false) {
            try? FileManager.default.removeItem(at: url)
        }
        d.set(false, forKey: BackgroundImagePrefs.presentKey)
        image = nil
    }

    /// Longest edge (px) the stored image is downscaled to — big enough to cover a large display crisply,
    /// capped so a huge pick sub-samples rather than fully decoding. Mirrors the Kotlin MAX_DIMEN.
    private static let maxDimension: CGFloat = 2560

    /// `<AppSupport>/OpenWhoop/background.jpg` (the same base folder the capture recorder uses).
    private static func fileURL(create: Bool) throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                             appropriateFor: nil, create: create)
            .appendingPathComponent("OpenWhoop", isDirectory: true)
        if create { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        return dir.appendingPathComponent("background.jpg", isDirectory: false)
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
