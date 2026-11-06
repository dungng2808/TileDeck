import FanHelperShared
import Foundation

/// One XPC connection to TileDeck's privileged helper. The helper hands fans
/// and charging back to macOS once no connection is left, so each feature
/// keeps its own connection open exactly as long as it holds something.
@MainActor
final class HelperConnection {
    private var connection: NSXPCConnection?
    /// Every reply's error (nil on success), and failures to reach the helper.
    private let report: (String?) -> Void

    init(report: @escaping (String?) -> Void) {
        self.report = report
    }

    func invalidate() {
        connection?.invalidate()
    }

    private func makeConnection() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(machServiceName: FanHelper.machService, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
        // Talk only to our own helper, never to something squatting on the service name.
        connection.setCodeSigningRequirement(FanHelper.helperRequirement)
        connection.invalidationHandler = { [weak self, weak connection] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let self, self.connection === connection { self.connection = nil }
                }
            }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    /// Sends one request. If the helper was just exiting (it quits once nothing
    /// is held), the message is lost with the connection, so it is sent once
    /// more on a fresh connection.
    func send(retry: Bool = true, _ request: @escaping (FanHelperProtocol, @escaping (String?) -> Void) -> Void) {
        let connection = makeConnection()
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.connection === connection { self.connection = nil }
                    if retry {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.send(retry: false, request) }
                    } else {
                        self.report("Không kết nối được trình trợ giúp: \(error.localizedDescription)")
                    }
                }
            }
        } as? FanHelperProtocol
        guard let proxy else { return }
        request(proxy) { [weak self] error in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.report(error) } }
        }
    }
}
