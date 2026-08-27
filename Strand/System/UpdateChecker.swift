import Foundation
import WhoopProtocol

/// User-initiated "Check for updates": one call to the project's PUBLIC releases API (GitHub),
/// made ONLY when the user taps the button. No background polling and no auto-update — it just reads the latest version
/// number and compares it to the installed one; nothing about the user is sent. (Uses the
/// network-client entitlement, which is otherwise only for the opt-in, off-by-default AI Coach.)
@MainActor
final class UpdateChecker: ObservableObject {

    enum State: Equatable {
        case idle
        case checking
        case upToDate(version: String)
        case available(version: String, url: URL, notes: String)
        case failed
    }

    @Published var state: State = .idle

    private static let endpoint = URL(string: "https://api.github.com/repos/ryanbr/noop/releases/latest")!

    /// One release read. Shared by the button and the automatic check (#1659) so there is exactly one
    /// copy of the endpoint, the headers and the parsing — a second copy is how the two would drift into
    /// disagreeing about what "latest" means.
    struct Release: Equatable {
        let version: String
        let url: URL
        let notes: String
    }

    static func fetchLatest() async -> Release? {
        do {
            var req = URLRequest(url: Self.endpoint, timeoutInterval: 12)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let urlString = json["html_url"] as? String,
                  let url = URL(string: urlString) else { return nil }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            return Release(version: latest, url: url, notes: cleanNotes(json["body"] as? String ?? ""))
        } catch {
            return nil
        }
    }

    func check(currentVersion: String) {
        guard state != .checking else { return }
        state = .checking
        Task {
            guard let release = await Self.fetchLatest() else {
                state = .failed
                return
            }
            state = VersionCheck.isNewer(release.version, than: currentVersion)
                ? .available(version: release.version, url: release.url, notes: release.notes)
                : .upToDate(version: release.version)
        }
    }

    /// Turn a GitHub release body into a short, readable "what's new" for an inline preview: drop the
    /// "Downloads"/footer boilerplate, strip the heaviest markdown markers, and cap the length.
    static func cleanNotes(_ body: String) -> String {
        var s = body.components(separatedBy: "Downloads").first ?? body
        for marker in ["**", "## ", "# "] { s = s.replacingOccurrences(of: marker, with: "") }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 700 { s = String(s.prefix(700)).trimmingCharacters(in: .whitespacesAndNewlines) + "…" }
        return s
    }
}
