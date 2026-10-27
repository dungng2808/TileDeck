import Foundation
import IOKit
import IOKit.ps

/// Battery and charger state. macOS pushes a notification whenever the power
/// source changes; TileDeck listens only while something needs it (the panel
/// is open, or a battery alert is on) and never polls.
@MainActor
final class BatteryMonitor: ObservableObject {
    struct Snapshot: Equatable {
        var onAC = true
        var hasBattery = false
        var percent = 0
        var isCharging = false
        var isFull = false
        /// Positive while charging, negative while discharging.
        var batteryWatts = 0.0
        var systemWatts: Double?
        var cycleCount = 0
        var designCycles = 1000
        var fullCapacity = 0
        var designCapacity = 0
        var temperature = 0.0
        var adapterWatts: Int?
        var adapterName: String?

        var health: Double {
            designCapacity > 0 ? Double(fullCapacity) / Double(designCapacity) : 0
        }
    }

    static let shared = BatteryMonitor()

    @Published private(set) var snapshot = BatteryMonitor.read()

    private var source: CFRunLoopSource?
    private var reasons: Set<String> = []

    /// Starts listening for `reason`; stops once every reason has been removed.
    func observe(_ reason: String) {
        reasons.insert(reason)
        snapshot = Self.read()
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.snapshot = BatteryMonitor.read() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = source
    }

    func stopObserving(_ reason: String) {
        reasons.remove(reason)
        guard reasons.isEmpty, let source else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = nil
    }

    // MARK: Reading

    private static func read() -> Snapshot {
        var snapshot = Snapshot()
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
            snapshot.onAC = type == kIOPMACPowerKey
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return snapshot }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let battery = properties?.takeRetainedValue() as? [String: Any] else { return snapshot }

        func int(_ key: String) -> Int? { battery[key] as? Int }

        snapshot.hasBattery = true
        snapshot.percent = int("CurrentCapacity") ?? 0
        snapshot.isCharging = battery["IsCharging"] as? Bool ?? false
        snapshot.isFull = battery["FullyCharged"] as? Bool ?? false
        snapshot.batteryWatts = Double(int("Voltage") ?? 0) * Double(int("InstantAmperage") ?? 0) / 1_000_000
        snapshot.cycleCount = int("CycleCount") ?? 0
        snapshot.designCycles = int("DesignCycleCount9C") ?? 1000
        snapshot.fullCapacity = int("NominalChargeCapacity") ?? int("AppleRawMaxCapacity") ?? 0
        snapshot.designCapacity = int("DesignCapacity") ?? 0
        snapshot.temperature = Double(int("Temperature") ?? 0) / 100

        if let telemetry = battery["PowerTelemetryData"] as? [String: Any], let load = telemetry["SystemLoad"] as? Int {
            snapshot.systemWatts = Double(load) / 1000
        }
        if snapshot.onAC, let adapter = battery["AdapterDetails"] as? [String: Any] {
            snapshot.adapterWatts = adapter["Watts"] as? Int
            let description = (adapter["Description"] as? String)?.lowercased() ?? ""
            snapshot.adapterName = description.contains("pd") ? "USB-C PD" : (adapter["Name"] as? String)
        }
        return snapshot
    }
}
