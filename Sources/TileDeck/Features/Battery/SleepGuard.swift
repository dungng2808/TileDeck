import AppKit
import IOKit
import IOKit.pwr_mgt

/// Keeps a closed MacBook truly asleep in a bag.
/// - Dark Wake guard: turns off Power Nap and TCP keep-alive on battery
///   (the two settings that wake a sleeping Mac in the background). This is a
///   system setting, so macOS asks for the admin password once per change.
/// - Bluetooth: switched off when the lid closes and back on at wake, so
///   AirPods or a mouse can't keep waking the Mac overnight.
@MainActor
final class SleepGuard: ObservableObject {
    static let shared = SleepGuard()

    private static let bluetoothKey = "sleepGuardBluetooth"
    private static let turnedOffKey = "sleepGuardTurnedOffBluetooth"

    @Published private(set) var darkWakeBlocked = false
    @Published private(set) var bluetoothOffOnLid: Bool
    @Published private(set) var isApplying = false
    @Published private(set) var lastError: String?

    private var observers: [NSObjectProtocol] = []

    private init() {
        bluetoothOffOnLid = UserDefaults.standard.bool(forKey: Self.bluetoothKey)
    }

    var bluetoothAvailable: Bool {
        PrivateAPI.getBluetoothPower != nil && PrivateAPI.setBluetoothPower != nil
    }

    func activateIfNeeded() {
        updateSleepObservers()
        // Recover if TileDeck quit while the Mac slept with Bluetooth switched off.
        restoreBluetooth()
    }

    // MARK: Dark Wake

    func refresh() {
        guard let preferences = PrivateAPI.copyPMPreferences?()?.takeRetainedValue() as? [String: Any],
              let battery = preferences[kIOPMBatteryPowerKey] as? [String: Any] else { return }
        let powerNap = battery["DarkWakeBackgroundTasks"] as? Int ?? 1
        let keepAlive = battery["TCPKeepAlivePref"] as? Int ?? 1
        darkWakeBlocked = powerNap == 0 && keepAlive == 0
    }

    func setDarkWakeBlocked(_ blocked: Bool) {
        guard !isApplying else { return }
        isApplying = true
        lastError = nil
        let value = blocked ? 0 : 1
        Self.runAsAdmin("/usr/bin/pmset -b powernap \(value) tcpkeepalive \(value)") { [weak self] error in
            guard let self else { return }
            self.isApplying = false
            self.lastError = error
            self.refresh()
        }
    }

    /// Runs a shell command through macOS's own administrator prompt and reports
    /// an error message (nil on success or cancel). Waits on the exit event
    /// rather than blocking a thread, since the password prompt can stay up for minutes.
    private static func runAsAdmin(_ command: String, completion: @escaping @MainActor (String?) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(command)\" with administrator privileges"]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.terminationHandler = { process in
            var error: String?
            if process.terminationStatus != 0 {
                let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                error = message.contains("-128") ? nil : "Không đổi được cài đặt nguồn"  // -128: user cancelled
            }
            DispatchQueue.main.async { completion(error) }
        }
        do {
            try process.run()
        } catch {
            completion(error.localizedDescription)
        }
    }

    // MARK: Bluetooth

    func setBluetoothOffOnLid(_ on: Bool) {
        bluetoothOffOnLid = on
        UserDefaults.standard.set(on, forKey: Self.bluetoothKey)
        updateSleepObservers()
    }

    private func updateSleepObservers() {
        let center = NSWorkspace.shared.notificationCenter
        if bluetoothOffOnLid && observers.isEmpty && bluetoothAvailable {
            observers = [
                center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.willSleep() }
                },
                center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.restoreBluetooth() }
                },
            ]
        } else if !bluetoothOffOnLid {
            observers.forEach(center.removeObserver)
            observers.removeAll()
        }
    }

    private func willSleep() {
        // Only for a closed lid: a Mac sleeping on a desk with an external
        // display must stay wakeable from its Bluetooth keyboard and mouse.
        guard Self.isLidClosed, let get = PrivateAPI.getBluetoothPower, let set = PrivateAPI.setBluetoothPower,
              get() == 1 else { return }
        set(0)
        UserDefaults.standard.set(true, forKey: Self.turnedOffKey)
    }

    private func restoreBluetooth() {
        guard UserDefaults.standard.bool(forKey: Self.turnedOffKey) else { return }
        PrivateAPI.setBluetoothPower?(1)
        UserDefaults.standard.set(false, forKey: Self.turnedOffKey)
    }

    private static var isLidClosed: Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return false }
        defer { IOObjectRelease(rootDomain) }
        let state = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return state as? Bool ?? false
    }
}
