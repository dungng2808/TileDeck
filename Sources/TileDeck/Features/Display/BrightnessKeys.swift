import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "com.dungng.tiledeck", category: "BrightnessKeys")

/// F1/F2 adjust whichever display the cursor is on. On the built-in screen the
/// keys pass straight through to macOS (native OSD included); on an external
/// screen TileDeck takes them over.
///
/// The tap sees every media key, volume included, and macOS holds each event
/// until the tap answers, so it runs on its own thread: a busy main thread must
/// never delay F11/F12.
@MainActor
final class BrightnessKeys: ObservableObject {
    static let shared = BrightnessKeys()
    private static let defaultsKey = "brightnessFollowsCursor"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var needsPermission = false

    private var tap: CFMachPort?

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
        let state = BrightnessTapState()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: brightnessTapCallback,
            userInfo: Unmanaged.passUnretained(state).toOpaque()
        ) else {
            needsPermission = true
            return
        }
        needsPermission = false
        state.port = tap
        state.source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        // The run loop ends, and the thread with it, once `stop()` invalidates the port.
        let thread = Thread {
            withExtendedLifetime(state) {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), state.source, .commonModes)
                CFRunLoopRun()
            }
        }
        thread.name = "TileDeck.brightnessKeys"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.tap = tap
    }

    private func stop() {
        needsPermission = false
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        self.tap = nil
    }
}

/// Set up before the tap's thread starts, then only read from that thread.
private final class BrightnessTapState: @unchecked Sendable {
    var port: CFMachPort?
    var source: CFRunLoopSource?
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

/// Uses CoreGraphics only, which is safe away from the main thread.
private func displayUnderCursor() -> CGDirectDisplayID? {
    guard let point = CGEvent(source: nil)?.location else { return nil }
    var display: CGDirectDisplayID = 0
    var count: UInt32 = 0
    guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0 else { return nil }
    return display
}

/// Runs on the tap's own thread.
private func brightnessTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let passThrough = Unmanaged.passUnretained(event)
    guard let refcon else { return passThrough }

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let state = Unmanaged<BrightnessTapState>.fromOpaque(refcon).takeUnretainedValue()
        if let port = state.port { CGEvent.tapEnable(tap: port, enable: true) }
        return passThrough
    }
    guard let key = brightnessKey(type, event) else { return passThrough }
    let cursorDisplay = displayUnderCursor()
    log.info("brightness \(key.up ? "up" : "down", privacy: .public) down=\(key.isDown) cursorDisplay=\(cursorDisplay ?? 0)")
    guard let id = cursorDisplay, CGDisplayIsBuiltin(id) == 0 else { return passThrough }
    if key.isDown {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { DisplayController.shared.step(id, up: key.up) }
        }
    }
    return nil
}
