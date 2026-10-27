import AppKit

/// Fan speeds and temperatures from the SMC. Read every 1.5 s on a background
/// queue, and only while the Fans tab is on screen.
@MainActor
final class FanMonitor: ObservableObject {
    struct Fan: Identifiable, Equatable {
        let id: Int
        let name: String
        let current: Double
        let minimum: Double
        let maximum: Double
        let target: Double
        let isManual: Bool

        /// Where the current speed sits between minimum and maximum, 0…1.
        var load: Double {
            maximum > minimum ? min(max((current - minimum) / (maximum - minimum), 0), 1) : 0
        }
    }

    struct SensorGroup: Identifiable, Equatable {
        let id: String
        let name: String
        let icon: String
        let average: Double
        let hottest: Double
        let count: Int
    }

    /// Groups by SMC key naming on Apple Silicon. Prefix groups take every
    /// matching key; the rest name single, well-known sensors.
    struct GroupDefinition {
        let id: String
        let name: String
        let icon: String
        let matches: @Sendable (String) -> Bool
    }

    nonisolated static let definitions: [GroupDefinition] = [
        .init(id: "pcore", name: "CPU hiệu năng", icon: "cpu") { $0.hasPrefix("Tp") },
        .init(id: "ecore", name: "CPU tiết kiệm", icon: "cpu.fill") { $0.hasPrefix("Te") },
        .init(id: "gpu", name: "GPU", icon: "square.stack.3d.up.fill") { $0.hasPrefix("Tg") },
        .init(id: "memory", name: "Bộ nhớ", icon: "memorychip") { $0.hasPrefix("Tm") },
        .init(id: "pmu", name: "Quản lý nguồn", icon: "bolt.circle") { $0.hasPrefix("TPD") },
        .init(id: "ssd", name: "SSD", icon: "internaldrive") { ["TH0x", "TH0a", "TH0b"].contains($0) },
        .init(id: "battery", name: "Pin", icon: "battery.75percent") { ["TB0T", "TB1T", "TB2T"].contains($0) },
        .init(id: "charger", name: "Bộ sạc", icon: "powerplug") { $0 == "TPSP" },
        .init(id: "wifi", name: "Wi‑Fi", icon: "wifi") { $0 == "TW0P" },
        .init(id: "tbLeft", name: "Thunderbolt trái", icon: "bolt.horizontal") { $0 == "TaLT" },
        .init(id: "tbRight", name: "Thunderbolt phải", icon: "bolt.horizontal") { $0 == "TaRT" },
        .init(id: "trackpad", name: "Trackpad", icon: "rectangle.and.hand.point.up.left") { $0 == "Ts0P" },
    ]

    /// Sensors a temperature-driven fan can follow: the hottest CPU core, or any group above.
    nonisolated static let sensorChoices: [(id: String, name: String)] =
        [("cpu", "CPU nóng nhất")] + definitions.map { ($0.id, $0.name) }

    /// The SMC keys behind a sensor choice.
    nonisolated static func keys(for sensor: String, in allKeys: [String]) -> [String] {
        if sensor == "cpu" { return allKeys.filter { $0.hasPrefix("Tp") || $0.hasPrefix("Te") } }
        guard let definition = definitions.first(where: { $0.id == sensor }) else { return [] }
        return allKeys.filter(definition.matches)
    }

    struct Sensor: Identifiable, Equatable {
        var id: String { key }
        let key: String
        let name: String
        /// nil while the sensor is idle (e.g. a parked CPU core reads ~0°).
        let value: Double?
    }

    struct SensorSection: Identifiable, Equatable {
        let id: String
        let name: String
        let sensors: [Sensor]
    }

    /// Readable names for individual SMC keys. CPU, GPU, memory, airflow and
    /// storage keys follow the open-source Stats app's M4 table (MIT licence);
    /// the power-supply, Thunderbolt and trackpad keys were matched against
    /// Macs Fan Control's readings on an M4 Pro.
    nonisolated private static let knownNames: [String: String] = [
        "Tp01": "Lõi hiệu năng 1", "Tp05": "Lõi hiệu năng 2", "Tp09": "Lõi hiệu năng 3", "Tp0D": "Lõi hiệu năng 4",
        "Tp0V": "Lõi hiệu năng 5", "Tp0Y": "Lõi hiệu năng 6", "Tp0b": "Lõi hiệu năng 7", "Tp0e": "Lõi hiệu năng 8",
        "Te05": "Lõi tiết kiệm 1", "Te0S": "Lõi tiết kiệm 2", "Te09": "Lõi tiết kiệm 3", "Te0H": "Lõi tiết kiệm 4",
        "Tg1U": "GPU 1", "Tg1k": "GPU 2", "Tg0K": "GPU 3", "Tg0L": "GPU 4",
        "Tg0d": "GPU 5", "Tg0e": "GPU 6", "Tg0j": "GPU 7", "Tg0k": "GPU 8",
        "Tm0p": "Gần bộ nhớ", "TaLP": "Luồng khí trái", "TaRF": "Luồng khí phải",
        "TH0x": "SSD (NAND)", "TB0T": "Pin", "TB1T": "Pin 1", "TB2T": "Pin 2", "TW0P": "Wi‑Fi",
        "TPSP": "Gần bộ nguồn", "TaLT": "Thunderbolt trái", "TaRT": "Thunderbolt phải",
        "Ts0P": "Trackpad", "Ts1P": "Bộ rung trackpad", "TPDX": "Quản lý nguồn (nóng nhất)",
    ]

    nonisolated private static func name(for key: String) -> String? {
        if let known = knownNames[key] { return known }
        // TPD0…TPDf: one reading per power-manager die.
        if key.hasPrefix("TPD"), let index = Int(String(key.last!), radix: 16) { return "Die quản lý nguồn \(index + 1)" }
        return nil
    }

    /// Sections for the full list: the summary groups with several keys, a
    /// "Thân máy & kết nối" catch-all for the single named sensors, then the rest.
    nonisolated private static func section(for key: String) -> (id: String, name: String) {
        for id in ["pcore", "ecore", "gpu", "memory", "pmu"] {
            if let definition = definitions.first(where: { $0.id == id }), definition.matches(key) {
                return (id, definition.name)
            }
        }
        if knownNames[key] != nil || key.hasPrefix("TH") || key.hasPrefix("TB") { return ("body", "Thân máy, pin & kết nối") }
        // Unnamed keys stay grouped by their two-letter prefix, which is how the SMC families them.
        let prefix = String(key.prefix(2))
        return ("other-\(prefix)", "Chưa rõ tên · nhóm \(prefix)")
    }

    static let shared = FanMonitor()

    @Published private(set) var fans: [Fan] = []
    @Published private(set) var groups: [SensorGroup] = []
    /// Every sensor, only read while the full list is open.
    @Published private(set) var sections: [SensorSection] = []
    @Published var showsAllSensors = false {
        didSet { if showsAllSensors { refresh() } else { sections = [] } }
    }

    private let queue = DispatchQueue(label: "TileDeck.fans", qos: .utility)
    nonisolated(unsafe) private var connection: SMC.Connection?
    nonisolated(unsafe) private var sensorKeys: [String: [String]]?
    nonisolated(unsafe) private var temperatureKeyList: [String] = []
    /// Keys that have given a plausible reading this session. Core sensors drop
    /// to ~0° whenever their core parks; keeping them listed stops rows from
    /// appearing and vanishing on every refresh.
    nonisolated(unsafe) private var seenKeys: Set<String> = []
    private var timer: Timer?
    private var watchers = 0

    func start() {
        watchers += 1
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        watchers = max(watchers - 1, 0)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
        queue.async { [self] in connection = nil }
    }

    func refresh() {
        let detailed = showsAllSensors
        queue.async { [self] in
            let (fans, groups) = read()
            let sections = detailed ? readAllSensors() : []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.fans = fans
                    self.groups = groups
                    if self.showsAllSensors { self.sections = sections }
                }
            }
        }
    }

    // MARK: Reading (on `queue`)

    nonisolated private func read() -> ([Fan], [SensorGroup]) {
        if connection == nil { connection = SMC.Connection() }
        guard let smc = connection else { return ([], []) }

        let count = Int(smc.uint8("FNum") ?? 0)
        let fans = (0..<count).compactMap { index -> Fan? in
            guard let current = smc.float("F\(index)Ac") else { return nil }
            return Fan(
                id: index,
                name: Self.fanName(index, of: count),
                current: current,
                minimum: smc.float("F\(index)Mn") ?? 0,
                maximum: smc.float("F\(index)Mx") ?? 0,
                target: smc.float("F\(index)Tg") ?? current,
                // 1 is forced/manual; 0 and 3 are the system's own automatic modes.
                isManual: smc.uint8("F\(index)Md") == 1
            )
        }

        // The temperature key list is built once per session from the SMC's own key table.
        if sensorKeys == nil {
            let temperatureKeys = smc.allKeys().filter { $0.hasPrefix("T") }
            temperatureKeyList = temperatureKeys
            var grouped: [String: [String]] = [:]
            for definition in Self.definitions {
                grouped[definition.id] = temperatureKeys.filter(definition.matches)
            }
            sensorKeys = grouped
        }

        let groups = Self.definitions.compactMap { definition -> SensorGroup? in
            // Plausible readings only: unused sensors report 0 or junk.
            let values = (sensorKeys?[definition.id] ?? []).compactMap { smc.float($0) }.filter { $0 > 10 && $0 < 130 }
            guard !values.isEmpty else { return nil }
            return SensorGroup(id: definition.id, name: definition.name, icon: definition.icon,
                               average: values.reduce(0, +) / Double(values.count),
                               hottest: values.max() ?? 0, count: values.count)
        }
        return (fans, groups)
    }

    nonisolated private func readAllSensors() -> [SensorSection] {
        guard let smc = connection else { return [] }
        // Some sensors read exactly 0 until they're next sampled; a few quick
        // passes the first time settle the list before it's shown.
        if seenKeys.isEmpty {
            for pass in 0..<3 {
                if pass > 0 { usleep(120_000) }
                for key in temperatureKeyList {
                    if let reading = smc.float(key), reading > 1, reading < 130 { seenKeys.insert(key) }
                }
            }
        }
        var bySection: [String: (name: String, sensors: [Sensor])] = [:]
        for key in temperatureKeyList {
            let reading = smc.float(key)
            let value = reading.flatMap { $0 > 10 && $0 < 130 ? $0 : nil }
            // A parked core still reads a few degrees; an unused sensor reads 0.
            if let reading, reading > 1, reading < 130 { seenKeys.insert(key) }
            guard seenKeys.contains(key) else { continue }
            let section = Self.section(for: key)
            let sensor = Sensor(key: key, name: Self.name(for: key) ?? "Cảm biến \(key)", value: value)
            bySection[section.id, default: (section.name, [])].sensors.append(sensor)
        }
        let order = ["pcore", "ecore", "gpu", "memory", "pmu", "body"] + bySection.keys.filter { $0.hasPrefix("other-") }.sorted()
        return order.compactMap { id in
            guard let section = bySection[id] else { return nil }
            // Named sensors first, in natural order ("Lõi 2" before "Lõi 10"), then the rest by key.
            let sorted = section.sensors.sorted { lhs, rhs in
                let lhsNamed = Self.name(for: lhs.key) != nil, rhsNamed = Self.name(for: rhs.key) != nil
                if lhsNamed != rhsNamed { return lhsNamed }
                return lhsNamed ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending : lhs.key < rhs.key
            }
            return SensorSection(id: id, name: section.name, sensors: sorted)
        }
    }

    nonisolated private static func fanName(_ index: Int, of count: Int) -> String {
        guard count == 2 else { return count == 1 ? "Quạt" : "Quạt \(index + 1)" }
        return index == 0 ? "Quạt trái" : "Quạt phải"
    }

    /// Another fan controller writing the same keys would fight TileDeck for the fans.
    var otherController: String? {
        let names = ["Macs Fan Control", "TG Pro", "smcFanControl"]
        return NSWorkspace.shared.runningApplications.first { names.contains($0.localizedName ?? "") }?.localizedName
    }
}
