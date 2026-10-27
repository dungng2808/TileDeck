import AppKit

/// Checks GitHub Releases for a newer TileDeck. On demand, plus at most once a
/// day when the panel opens; one small HTTPS request, nothing in the background.
@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL)
        case noReleases
        case failed
    }

    static let shared = UpdateChecker()
    static let repository = "dungng2808/TileDeck"
    private static let lastCheckKey = "updateLastCheck"

    @Published private(set) var state: State = .idle

    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    func checkIfDue() {
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        if Date().timeIntervalSince(last) > 24 * 3600 { check() }
    }

    func check() {
        guard state != .checking else { return }
        state = .checking
        let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let release = data.flatMap { try? JSONDecoder().decode(Release.self, from: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(status: status, release: release) }
            }
        }.resume()
    }

    private func finish(status: Int, release: Release?) {
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        if status == 404 {
            state = .noReleases
        } else if let release, let url = URL(string: release.htmlURL) {
            state = Self.isNewer(release.tagName, than: currentVersion) ? .available(version: Self.clean(release.tagName), url: url) : .upToDate
        } else {
            state = .failed
        }
    }

    func openDownload() {
        if case .available(_, let url) = state { NSWorkspace.shared.open(url) }
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    // MARK: Versions

    /// "v1.2.0" → "1.2.0"
    nonisolated static func clean(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    /// Numeric, part-by-part comparison: "0.10.0" is newer than "0.9.3"; missing parts count as 0.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = clean(candidate).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let rhs = clean(current).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}
