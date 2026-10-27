import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "com.dungng.tiledeck", category: "BrightnessKeys")

/// F1/F2 adjust whichever display the cursor is on. On the built-in screen the
/// keys pass straight through to macOS (native OSD included); on an external
/// screen TileDeck takes them over.
@MainActor
final class BrightnessKeys: ObservableObject {
    static let shared = BrightnessKeys()
    private static let defaultsKey = "brightnessFollowsCursor"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var needsPermission = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        // macOS broadcasts this whenever any app's Accessibility trust changes,
        // so the tap starts as soon as the user grants it — no polling.
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self?.activateIfNeeded() }
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.defaultsKey)
        if enabled {
            start(prompt: true)
        } else {
            stop()
        }
    }

    func activateIfNeeded() {
        if isEnabled { start(prompt: false) }
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    private func start(prompt: Bool) {
        guard tap == nil else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            needsPermission = true
            return
        }

        // Media keys arrive as NX_SYSDEFINED (14); some external keyboards send
        // plain key codes instead, hence keyDown/keyUp.
        let mask = CGEventMask(1 << 14)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        log.info("starting event tap")
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: brightnessTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            needsPermission = true
            return
        }
        needsPermission = false
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        self.source = source
    }

    private func stop() {
        needsPermission = false
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        self.source = nil
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Returns true when the event was handled and must not reach macOS.
    fileprivate func handle(up: Bool, isDown: Bool) -> Bool {
        let cursorDisplay = DisplayController.displayUnderCursor()
        log.info("brightness \(up ? "up" : "down", privacy: .public) down=\(isDown) cursorDisplay=\(cursorDisplay ?? 0)")
        guard let id = cursorDisplay, CGDisplayIsBuiltin(id) == 0 else { return false }
        if isDown { DisplayController.shared.step(id, up: up) }
        return true
    }
}

private let brightnessUpKeyCode: Int64 = 144
private let brightnessDownKeyCode: Int64 = 145
private let nxKeyTypeBrightnessUp = 2
private let nxKeyTypeBrightnessDown = 3

/// (isUp, isKeyDown) for brightness keys, nil for everything else.
private func brightnessKey(_ type: CGEventType, _ event: CGEvent) -> (up: Bool, isDown: Bool)? {
    if type.rawValue == 14 {
        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else { return nil }
        let code = (nsEvent.data1 & 0xFFFF_0000) >> 16
        let isDown = ((nsEvent.data1 & 0xFF00) >> 8) == 0xA
        log.debug("media key code=\(code)")
        switch code {
        case nxKeyTypeBrightnessUp: return (true, isDown)
        case nxKeyTypeBrightnessDown: return (false, isDown)
        default: return nil
        }
    }
    guard type == .keyDown || type == .keyUp else { return nil }
    switch event.getIntegerValueField(.keyboardEventKeycode) {
    case brightnessUpKeyCode: return (true, type == .keyDown)
    case brightnessDownKeyCode: return (false, type == .keyDown)
    default: return nil
    }
}

private func brightnessTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let passThrough = Unmanaged.passUnretained(event)
    guard let refcon else { return passThrough }
    let keys = Unmanaged<BrightnessKeys>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { keys.reenable() }
        return passThrough
    }
    guard let key = brightnessKey(type, event) else { return passThrough }
    let handled = MainActor.assumeIsolated { keys.handle(up: key.up, isDown: key.isDown) }
    return handled ? nil : passThrough
}
