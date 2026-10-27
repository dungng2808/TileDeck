import AppKit
import Combine

/// Battery heat and deep-discharge warnings. Runs off BatteryMonitor's pushed
/// updates while at least one alert is on; each alert fires once per crossing.
@MainActor
final class BatteryAlerts: ObservableObject {
    static let shared = BatteryAlerts()

    static let hotTemperature = 38.0
    static let lowPercent = 20

    private static let heatKey = "alertBatteryHeat"
    private static let lowKey = "alertLowBatteryExternal"

    @Published private(set) var heatAlert: Bool
    @Published private(set) var lowBatteryAlert: Bool

    private var subscription: AnyCancellable?
    private var heatNotified = false
    private var lowNotified = false

    private init() {
        heatAlert = UserDefaults.standard.bool(forKey: Self.heatKey)
        lowBatteryAlert = UserDefaults.standard.bool(forKey: Self.lowKey)
    }

    func activateIfNeeded() {
        updateObservation()
    }

    func setHeatAlert(_ on: Bool) {
        heatAlert = on
        UserDefaults.standard.set(on, forKey: Self.heatKey)
        if on { requestPermission() }
        updateObservation()
    }

    func setLowBatteryAlert(_ on: Bool) {
        lowBatteryAlert = on
        UserDefaults.standard.set(on, forKey: Self.lowKey)
        if on { requestPermission() }
        updateObservation()
    }

    private func updateObservation() {
        let monitor = BatteryMonitor.shared
        if heatAlert || lowBatteryAlert {
            monitor.observe("alerts")
            subscription = subscription ?? monitor.$snapshot.sink { [weak self] snapshot in
                MainActor.assumeIsolated { self?.evaluate(snapshot) }
            }
        } else {
            subscription = nil
            monitor.stopObserving("alerts")
        }
    }

    private func evaluate(_ battery: BatteryMonitor.Snapshot) {
        guard battery.hasBattery else { return }

        if heatAlert && battery.temperature > Self.hotTemperature && !heatNotified {
            heatNotified = true
            post("Pin đang nóng (\(String(format: "%.1f", battery.temperature))°C)",
                 "Nên rút bớt tác vụ nặng hoặc để máy ở nơi thoáng mát.")
        } else if battery.temperature < Self.hotTemperature - 2 {
            heatNotified = false
        }

        let usingExternal = NSScreen.screens.contains { $0.displayID.map { CGDisplayIsBuiltin($0) == 0 } ?? false }
        if lowBatteryAlert && usingExternal && !battery.onAC && battery.percent < Self.lowPercent && !lowNotified {
            lowNotified = true
            post("Pin còn \(battery.percent)% khi đang dùng màn ngoài",
                 "Cắm sạc để tránh xả pin quá sâu, giúp pin bền hơn.")
        } else if battery.onAC || battery.percent >= Self.lowPercent + 5 {
            lowNotified = false
        }
    }

    private func requestPermission() {
        Notifier.shared.requestPermission()
    }

    private func post(_ title: String, _ body: String) {
        Notifier.shared.post(title, body)
    }
}
