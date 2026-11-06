import AppKit
import FanHelperShared
import Security

/// Installs a release in place: downloads its zip over HTTPS, checks that the
/// app inside is TileDeck, signed by the same team as this copy and notarized
/// by Apple, swaps it for the running copy and relaunches. Nothing is replaced
/// unless every check passes.
enum AppInstaller {
    enum Failure: LocalizedError {
        case download
        case unzip
        case signature
        case version
        case replace(String)

        var errorDescription: String? {
            switch self {
            case .download: "Không tải được bản cập nhật."
            case .unzip: "Không giải nén được bản cập nhật."
            case .signature: "Bản tải về không có chữ ký TileDeck hợp lệ, đã huỷ."
            case .version: "Bản tải về không đúng phiên bản, đã huỷ."
            case .replace(let reason): "Không thay được app: \(reason)"
            }
        }
    }

    /// Only files GitHub serves for this repository's releases are ever downloaded.
    static func isTrustedPackage(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com"
            && url.path.hasPrefix("/\(UpdateChecker.repository)/releases/download/")
    }

    /// An app bundle TileDeck can replace (not a bare binary started by `swift run`).
    static var canInstall: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static func install(from package: URL, version: String, replacing target: URL,
                        step: @escaping @MainActor (String) -> Void) async throws {
        guard isTrustedPackage(package) else { throw Failure.download }
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appendingPathComponent("TileDeck-update-\(UUID().uuidString)")
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        await step("Đang tải…")
        let zip = work.appendingPathComponent("TileDeck.zip")
        do {
            let (downloaded, response) = try await URLSession.shared.download(from: package)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.download }
            try fileManager.moveItem(at: downloaded, to: zip)
        } catch {
            throw Failure.download
        }

        await step("Đang kiểm tra…")
        guard await run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]) else { throw Failure.unzip }
        let app = work.appendingPathComponent("TileDeck.app")
        try verify(app, version: version)

        await step("Đang cài…")
        do {
            _ = try fileManager.replaceItemAt(target, withItemAt: app)
        } catch {
            throw Failure.replace(error.localizedDescription)
        }
    }

    /// TileDeck's identifier, our own team's certificate and Apple's notarization,
    /// checked over every file in the bundle (including the fan helper).
    static func verify(_ app: URL, version: String) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("\(FanHelper.clientRequirement) and notarized" as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
        else { throw Failure.signature }
        guard Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String == version else {
            throw Failure.version
        }
    }

    /// Quits, then opens the new copy once this process is gone.
    @MainActor
    static func relaunch(_ app: URL) {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The path goes in as $1 so no quoting can break it.
        waiter.arguments = ["-c", "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$1\"",
                            "sh", app.path]
        try? waiter.run()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}
