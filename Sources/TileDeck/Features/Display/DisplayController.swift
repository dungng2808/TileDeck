import AppKit
import CoreGraphics

struct DisplayItem: Identifiable, Equatable {
    enum Control: Equatable {
        case native     // built-in panel via DisplayServices
        case ddc        // external monitor's own backlight
        case software   // gamma dimming when the monitor ignores DDC
    }

    let id: CGDirectDisplayID
    var name: String
    var size: String
    var isBuiltin: Bool
    var isMain: Bool
    var brightness: Double
    var control: Control
    var isDisabled = false
}

/// Brightness and soft-disconnect for every connected display. Work happens only
/// when the panel is open, a brightness key is pressed, or the screen setup changes.
@MainActor
final class DisplayController: ObservableObject {
    static let shared = DisplayController()

    @Published private(set) var displays: [DisplayItem] = []

    private var ddc: [CGDirectDisplayID: DDCService]?
    private var ddcMax: [CGDirectDisplayID: Int] = [:]
    private var ddcUnsupported: Set<CGDirectDisplayID> = []
    private var knownBrightness: [CGDirectDisplayID: Double] = [:]
    private var disabled: [CGDirectDisplayID: DisplayItem] = [:]
    private var usedGamma = false

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    var canSoftDisconnect: Bool { PrivateAPI.configureDisplayEnabled != nil }
    var activeCount: Int { displays.filter { !$0.isDisabled }.count }

    // MARK: Listing

    func refresh() {
        var items: [DisplayItem] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let builtin = CGDisplayIsBuiltin(id) != 0
            let control = controlKind(for: id, builtin: builtin)
            let size = screen.frame.size
            items.append(DisplayItem(
                id: id,
                name: screen.localizedName,
                size: "\(Int(size.width)) × \(Int(size.height))",
                isBuiltin: builtin,
                isMain: CGDisplayIsMain(id) != 0,
                brightness: storedBrightness(id, control),
                control: control
            ))
        }
        items.sort { $0.isBuiltin && !$1.isBuiltin }
        items += disabled.values.filter { off in !items.contains { $0.id == off.id } }
        displays = items
        loadDDCValues()
    }

    private func screensChanged() {
        ddc = nil
        if !displays.isEmpty { refresh() }
        if !observedBuiltins.isEmpty {
            stopObservingBrightness()
            startObservingBrightness()
        }
    }

    // MARK: Live updates

    private var observedBuiltins: [CGDirectDisplayID] = []

    /// While the panel is open, follow brightness changes made elsewhere (F1/F2,
    /// Control Center, auto-brightness). macOS pushes them; nothing is polled.
    /// External monitors have no such notification, so their sliders show the last value TileDeck knows.
    func startObservingBrightness() {
        guard observedBuiltins.isEmpty, let register = PrivateAPI.registerBrightnessNotifications else { return }
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        for item in displays where item.isBuiltin && !item.isDisabled {
            let status = register(item.id, observer) { _, observer, _, _, userInfo in
                guard let observer, let value = (userInfo as NSDictionary?)?["value"] as? Double else { return }
                let controller = Unmanaged<DisplayController>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { controller.builtinBrightnessChanged(value) }
                }
            }
            if status == 0 { observedBuiltins.append(item.id) }
        }
    }

    func stopObservingBrightness() {
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        for id in observedBuiltins { _ = PrivateAPI.unregisterBrightnessNotifications?(id, observer) }
        observedBuiltins.removeAll()
    }

    private func builtinBrightnessChanged(_ value: Double) {
        // The callback doesn't say which display; there is only ever one built-in panel.
        for id in observedBuiltins {
            update(id) { $0.brightness = value }
        }
    }

    private func controlKind(for id: CGDirectDisplayID, builtin: Bool) -> DisplayItem.Control {
        if builtin { return .native }
        if ddcUnsupported.contains(id) { return .software }
        return ddcService(for: id) == nil ? .software : .ddc
    }

    private func ddcService(for id: CGDirectDisplayID) -> DDCService? {
        if ddc == nil { ddc = DDCService.matchExternalDisplays() }
        return ddc?[id]
    }

    private func storedBrightness(_ id: CGDirectDisplayID, _ control: DisplayItem.Control) -> Double {
        if control == .native, let get = PrivateAPI.getBrightness {
            var value: Float = 0
            if get(id, &value) == 0 { return Double(value) }
        }
        return knownBrightness[id] ?? 1
    }

    /// DDC reads take ~60 ms, so they run once per monitor in the background and are cached.
    private func loadDDCValues() {
        for item in displays where item.control == .ddc && knownBrightness[item.id] == nil {
            readDDC(item.id)
        }
    }

    private func readDDC(_ id: CGDirectDisplayID, then action: ((CGDirectDisplayID) -> Void)? = nil) {
        ddcService(for: id)?.read { [weak self] value in
            guard let self else { return }
            if let value, value.max > 0 {
                self.ddcMax[id] = value.max
                self.knownBrightness[id] = Double(value.current) / Double(value.max)
            } else {
                self.ddcUnsupported.insert(id)
            }
            self.update(id) {
                $0.control = self.controlKind(for: id, builtin: false)
                $0.brightness = self.knownBrightness[id] ?? 1
            }
            action?(id)
        }
    }

    // MARK: Brightness

    func setBrightness(_ value: Double, for id: CGDirectDisplayID) {
        guard let item = displays.first(where: { $0.id == id }), !item.isDisabled else { return }
        let value = min(max(value, 0), 1)
        knownBrightness[id] = value
        update(id) { $0.brightness = value }

        switch item.control {
        case .native:
            _ = PrivateAPI.setBrightness?(id, Float(value))
        case .ddc:
            let max = Double(ddcMax[id] ?? 100)
            ddcService(for: id)?.write(UInt16((value * max).rounded()))
        case .software:
            // Keep a floor so the screen can't be dimmed to unreadable black.
            let level = CGGammaValue(0.1 + 0.9 * value)
            CGSetDisplayTransferByFormula(id, 0, level, 1, 0, level, 1, 0, level, 1)
            usedGamma = true
        }
    }

    /// Brightness key path: one step is 1/16, like the system's own keys, with an on-screen HUD.
    func step(_ id: CGDirectDisplayID, up: Bool) {
        let delta = up ? 1.0 / 16 : -1.0 / 16
        if !displays.contains(where: { $0.id == id }) { refresh() }
        guard let item = displays.first(where: { $0.id == id }) else { return }
        if item.control == .ddc && knownBrightness[id] == nil {
            readDDC(id) { [weak self] id in
                guard let self, let current = self.displays.first(where: { $0.id == id }) else { return }
                self.stepAndShow(current, by: delta)
            }
        } else {
            stepAndShow(item, by: delta)
        }
    }

    private func stepAndShow(_ item: DisplayItem, by delta: Double) {
        // Snap to the 1/16 grid so repeated presses land on the same levels as macOS.
        let level = ((item.brightness + delta) * 16).rounded() / 16
        setBrightness(level, for: item.id)
        let shown = displays.first(where: { $0.id == item.id })?.brightness ?? level
        BrightnessOSD.shared.show(level: shown, displayName: item.name, on: item.id)
    }

    // MARK: Soft disconnect

    func setEnabled(_ enabled: Bool, for id: CGDirectDisplayID) {
        if enabled {
            guard disabled[id] != nil, configure([id], enabled: true) else { return }
            disabled[id] = nil
        } else {
            // Never switch off the last screen that's still showing something.
            guard activeCount > 1, var item = displays.first(where: { $0.id == id && !$0.isDisabled }),
                  configure([id], enabled: false) else { return }
            item.isDisabled = true
            disabled[id] = item
        }
        refresh()
    }

    func disableExternals() {
        let targets = displays.filter { !$0.isBuiltin && !$0.isDisabled }
        guard displays.contains(where: { $0.isBuiltin && !$0.isDisabled }), !targets.isEmpty,
              configure(targets.map(\.id), enabled: false) else { return }
        for var item in targets {
            item.isDisabled = true
            disabled[item.id] = item
        }
        refresh()
    }

    func enableAll() {
        guard !disabled.isEmpty, configure(Array(disabled.keys), enabled: true) else { return }
        disabled.removeAll()
        refresh()
    }

    func restoreAll() {
        if !disabled.isEmpty { _ = configure(Array(disabled.keys), enabled: true) }
        if usedGamma { CGDisplayRestoreColorSyncSettings() }
    }

    private func configure(_ ids: [CGDirectDisplayID], enabled: Bool) -> Bool {
        guard let setEnabled = PrivateAPI.configureDisplayEnabled else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        for id in ids where setEnabled(config, id, enabled) != 0 {
            CGCancelDisplayConfiguration(config)
            return false
        }
        // .forAppOnly: if TileDeck quits or crashes, macOS turns the screens back on by itself.
        return CGCompleteDisplayConfiguration(config, .forAppOnly) == .success
    }

    // MARK: Helpers

    private func update(_ id: CGDirectDisplayID, _ change: (inout DisplayItem) -> Void) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        change(&displays[index])
    }

    static func displayUnderCursor() -> CGDirectDisplayID? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }?.displayID
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
