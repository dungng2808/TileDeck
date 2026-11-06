import AppKit

/// Checks GitHub Releases for a newer TileDeck. On demand, plus at most once a
/// day when the panel opens; one small HTTPS request, nothing in the background.
/// A newer release is installed in place by AppInstaller when the user asks.
@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL)
        case noReleases
        case failed
        case installing(version: String, step: String)
        case installFailed(url: URL, reason: String)
    }

    static let shared = UpdateChecker()
    nonisolated static let repository = "dungng2808/TileDeck"
    private static let lastCheckKey = "updateLastCheck"

    @Published private(set) var state: State = .idle
    /// The newer release's zip, when it has one that can be installed in place.
    private var package: URL?

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
        package = nil
        if status == 404 {
            state = .noReleases
        } else if let release, let url = URL(string: release.htmlURL) {
            let version = Self.clean(release.tagName)
            guard Self.isNewer(release.tagName, than: currentVersion) else { return state = .upToDate }
            package = release.assets
                .first { $0.name == "TileDeck-\(version).zip" }
                .flatMap { URL(string: $0.downloadURL) }
                .flatMap { AppInstaller.isTrustedPackage($0) ? $0 : nil }
            state = .available(version: version, url: url)
        } else {
            state = .failed
        }
    }

    func openDownload() {
        switch state {
        case .available(_, let url), .installFailed(let url, _): NSWorkspace.shared.open(url)
        default: break
        }
    }

    /// Downloads, checks and installs the newer release, then relaunches.
    /// Falls back to the release page when it can't be done in place.
    func installUpdate() {
        guard case .available(let version, let page) = state else { return }
        guard let package, AppInstaller.canInstall else { return openDownload() }
        let target = Bundle.main.bundleURL
        state = .installing(version: version, step: "Đang tải…")
        Task {
            do {
                try await AppInstaller.install(from: package, version: version, replacing: target) { [weak self] step in
                    self?.state = .installing(version: version, step: step)
                }
                AppInstaller.relaunch(target)
            } catch {
                state = .installFailed(url: page, reason: error.localizedDescription)
            }
        }
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let downloadURL: String

            enum CodingKeys: String, CodingKey {
                case name
                case downloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
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
