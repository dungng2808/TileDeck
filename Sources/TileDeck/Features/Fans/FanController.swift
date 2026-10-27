import AppKit
import FanHelperShared
import ServiceManagement

/// Fan control through TileDeck's privileged helper (SMC writes need root).
/// The helper is installed once with SMAppService and approved in System
/// Settings; it hands fans back to macOS whenever TileDeck disconnects.
@MainActor
final class FanController: ObservableObject {
    enum Mode: Codable, Equatable {
        case automatic
        case fixed(rpm: Double)
        /// Minimum speed at or below `low` °C, maximum at or above `high` °C,
        /// linear between, following the hottest reading of `sensor` (a FanMonitor
        /// sensor choice; nil means the hottest CPU core).
        case temperature(low: Double, high: Double, sensor: String?)
    }

    enum HelperState: Equatable {
        case notInstalled, needsApproval, ready
    }

    static let shared = FanController()
    private static let modesKey = "fanModes"
    private static let curveInterval: TimeInterval = 3
    /// Weight of the newest reading in the smoothed temperature. Single core
    /// temperatures on Apple Silicon jump 10–20° within seconds; without
    /// smoothing the fans would surge and drop with every burst of work.
    private static let smoothing = 0.3
    /// Speed changes per tick: up quickly so heat is answered at once, down
    /// slowly so the fans never fall off abruptly.
    private static let maxRise = 500.0
    private static let maxFall = 150.0
    private static let deadband = 100.0
    private static let helperRequirement =
        "anchor apple generic and identifier \"com.dungng.tiledeck.helper\" and certificate leaf[subject.OU] = \"83K669D2N5\""

    @Published private(set) var helperState: HelperState = .notInstalled
    @Published private(set) var modes: [Int: Mode]
    @Published private(set) var lastError: String?
    /// Latest reading of each followed sensor, for the UI.
    @Published private(set) var sensorReadings: [String: Double] = [:]

    private let service = SMAppService.daemon(plistName: FanHelper.plistName)
    private var connection: NSXPCConnection?
    private var curveTimer: Timer?
    private var lastCurveTarget: [Int: Double] = [:]
    private var smoothedTemperature: [String: Double] = [:]
    nonisolated(unsafe) private var smc: SMC.Connection?
    nonisolated(unsafe) private var allKeys: [String]?
    private let queue = DispatchQueue(label: "TileDeck.fanControl", qos: .utility)

    private init() {
        let data = UserDefaults.standard.data(forKey: Self.modesKey)
        modes = data.flatMap { try? JSONDecoder().decode([Int: Mode].self, from: $0) } ?? [:]
    }

    func mode(for fan: Int) -> Mode { modes[fan] ?? .automatic }

    var isControlling: Bool { modes.values.contains { $0 != .automatic } }

    // MARK: Helper

    func refreshHelperState() {
        switch service.status {
        case .enabled: helperState = .ready
        case .requiresApproval: helperState = .needsApproval
        default: helperState = .notInstalled
        }
    }

    func installHelper() {
        lastError = nil
        do {
            try service.register()
        } catch {
            // Registration that still awaits the user's approval also lands here.
            if service.status != .requiresApproval { lastError = error.localizedDescription }
        }
        refreshHelperState()
        if helperState == .needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func makeConnection() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(machServiceName: FanHelper.machService, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
        // Talk only to our own helper, never to something squatting on the service name.
        connection.setCodeSigningRequirement(Self.helperRequirement)
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

    /// Sends one request. If the helper was just exiting (it quits after handing
    /// the fans back), the message is lost with the connection, so it is sent
    /// once more on a fresh connection.
    private func send(retry: Bool = true, _ request: @escaping (FanHelperProtocol, @escaping (String?) -> Void) -> Void) {
        let connection = makeConnection()
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.connection === connection { self.connection = nil }
                    if retry {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.send(retry: false, request) }
                    } else {
                        self.lastError = "Không kết nối được trình trợ giúp: \(error.localizedDescription)"
                    }
                }
            }
        } as? FanHelperProtocol
        guard let proxy else { return }
        request(proxy) { [weak self] error in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.lastError = error } }
        }
    }

    // MARK: Modes

    func activateIfNeeded() {
        refreshHelperState()
        guard helperState == .ready, isControlling else { return }
        for fan in modes.keys { apply(fan) }
        updateCurveTimer()
    }

    func setMode(_ mode: Mode, for fan: Int) {
        modes[fan] = mode
        if let data = try? JSONEncoder().encode(modes) { UserDefaults.standard.set(data, forKey: Self.modesKey) }
        lastCurveTarget[fan] = nil
        lastError = nil
        apply(fan)
        updateCurveTimer()
    }

    /// Called at quit. Dropping the connection is enough: the helper hands every
    /// fan back to macOS when its client leaves. Waiting for it here could hold
    /// up quitting for seconds while the SMC settles.
    func restoreAll() {
        connection?.invalidate()
    }

    private func apply(_ fan: Int) {
        guard helperState == .ready else { return }
        switch mode(for: fan) {
        case .automatic:
            send { helper, done in
                helper.setFanAutomatic(fan) { error in
                    done(error)
                    // Nothing left to hold: let the helper go once it has answered.
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            let controller = FanController.shared
                            if !controller.isControlling { controller.connection?.invalidate() }
                        }
                    }
                }
            }
        case .fixed(let rpm):
            send { helper, done in helper.setFanSpeed(fan, rpm: rpm, reply: done) }
        case .temperature:
            evaluateCurves()
        }
    }

    // MARK: Temperature curves

    private func updateCurveTimer() {
        let needed = modes.values.contains { if case .temperature = $0 { return true } else { return false } }
        if needed && curveTimer == nil {
            let timer = Timer(timeInterval: Self.curveInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluateCurves() }
            }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            curveTimer = timer
        } else if !needed {
            curveTimer?.invalidate()
            curveTimer = nil
            sensorReadings = [:]
            smoothedTemperature = [:]
            queue.async { [self] in smc = nil }
        }
    }

    private func evaluateCurves() {
        let curves = modes.compactMap { fan, mode -> (fan: Int, low: Double, high: Double, sensor: String)? in
            if case .temperature(let low, let high, let sensor) = mode { return (fan, low, high, sensor ?? "cpu") }
            return nil
        }
        guard !curves.isEmpty else { return }
        let sensors = Set(curves.map(\.sensor))
        queue.async { [self] in
            guard let reading = read(sensors: sensors) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for (sensor, value) in reading.temperatures {
                        let previous = self.smoothedTemperature[sensor] ?? value
                        self.smoothedTemperature[sensor] = previous + (value - previous) * Self.smoothing
                    }
                    self.sensorReadings = self.smoothedTemperature
                    for curve in curves {
                        guard let range = reading.ranges[curve.fan], let temperature = self.smoothedTemperature[curve.sensor] else { continue }
                        let progress = min(max((temperature - curve.low) / max(curve.high - curve.low, 1), 0), 1)
                        let wanted = range.lowerBound + (range.upperBound - range.lowerBound) * progress
                        var target = wanted
                        if let last = self.lastCurveTarget[curve.fan] {
                            target = min(max(wanted, last - Self.maxFall), last + Self.maxRise)
                            // Small wobbles shouldn't keep re-targeting the fan.
                            if abs(target - last) < Self.deadband { continue }
                        }
                        target = target.rounded()
                        self.lastCurveTarget[curve.fan] = target
                        self.send { helper, done in helper.setFanSpeed(curve.fan, rpm: target, reply: done) }
                    }
                }
            }
        }
    }

    /// Hottest reading per sensor choice and each fan's speed range, read on `queue`.
    nonisolated private func read(sensors: Set<String>) -> (temperatures: [String: Double], ranges: [Int: ClosedRange<Double>])? {
        if smc == nil { smc = SMC.Connection() }
        guard let smc else { return nil }
        if allKeys == nil { allKeys = smc.allKeys().filter { $0.hasPrefix("T") } }
        var temperatures: [String: Double] = [:]
        for sensor in sensors {
            let values = FanMonitor.keys(for: sensor, in: allKeys ?? []).compactMap { smc.float($0) }.filter { $0 > 10 && $0 < 130 }
            if let hottest = values.max() { temperatures[sensor] = hottest }
        }
        var ranges: [Int: ClosedRange<Double>] = [:]
        for fan in 0..<Int(smc.uint8("FNum") ?? 0) {
            if let low = smc.float("F\(fan)Mn"), let high = smc.float("F\(fan)Mx"), high > low { ranges[fan] = low...high }
        }
        return (temperatures, ranges)
    }
}
