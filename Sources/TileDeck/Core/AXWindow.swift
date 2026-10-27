import AppKit
import ApplicationServices

/// Thin wrapper over the Accessibility API for moving, focusing and closing
/// other apps' windows. Every call goes to another process, so each element
/// gets a short timeout: a hung app must never freeze TileDeck.
struct AXWindow {
    let element: AXUIElement
    let pid: pid_t

    private static let timeout: Float = 0.25

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func focused() -> AXWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = application(app.processIdentifier)
        guard let window: AXUIElement = appElement.value(kAXFocusedWindowAttribute) else { return nil }
        return AXWindow(element: window, pid: app.processIdentifier)
    }

    static func windows(of pid: pid_t) -> [AXWindow] {
        let appElement = application(pid)
        let elements: [AXUIElement] = appElement.value(kAXWindowsAttribute) ?? []
        return elements.map { AXWindow(element: $0, pid: pid) }
    }

    /// Windows on other Spaces are missing from an app's AX window list. Their
    /// elements can still be built from a remote token (pid + "coco" + element
    /// number) by trying element numbers until the window IDs match, as AltTab does.
    static func remoteWindows(of pid: pid_t, matching ids: Set<CGWindowID>) -> [CGWindowID: AXWindow] {
        guard let createWithToken = Self.createWithRemoteToken, let getWindow = Self.getWindowID, !ids.isEmpty else { return [:] }
        var token = Data(count: 20)
        withUnsafeBytes(of: pid) { token.replaceSubrange(0..<4, with: $0) }
        withUnsafeBytes(of: Int32(0x636F_636F)) { token.replaceSubrange(8..<12, with: $0) }

        var found: [CGWindowID: AXWindow] = [:]
        for elementID: UInt64 in 0..<1000 where found.count < ids.count {
            withUnsafeBytes(of: elementID) { token.replaceSubrange(12..<20, with: $0) }
            guard let element = createWithToken(token as CFData)?.takeRetainedValue() else { continue }
            var id: CGWindowID = 0
            // A window's own element comes first; the next one maps to the same window but is its content view.
            guard getWindow(element, &id) == .success, ids.contains(id), found[id] == nil else { continue }
            AXUIElementSetMessagingTimeout(element, timeout)
            found[id] = AXWindow(element: element, pid: pid)
        }
        return found
    }

    static func application(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    // MARK: Properties

    var windowID: CGWindowID? {
        guard let getWindow = Self.getWindowID else { return nil }
        var id: CGWindowID = 0
        return getWindow(element, &id) == .success ? id : nil
    }

    /// Several attributes in a single round trip; a missing one comes back as nil.
    func values(_ attributes: [String]) -> [Any?] {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &values) == .success,
              let array = values as? [Any], array.count == attributes.count else {
            return attributes.map { _ in nil }
        }
        // Missing attributes arrive as AXValue-wrapped errors, which no cast below accepts.
        return array.map { CFGetTypeID($0 as CFTypeRef) == AXValueGetTypeID() ? nil : $0 }
    }

    var title: String { element.value(kAXTitleAttribute) ?? "" }
    var isMinimized: Bool { element.value(kAXMinimizedAttribute) ?? false }
    var isStandard: Bool { (element.value(kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole }

    /// In Accessibility coordinates: origin at the top-left of the primary screen.
    var frame: CGRect? {
        guard let positionValue: AXValue = element.value(kAXPositionAttribute),
              let sizeValue: AXValue = element.value(kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue, .cgPoint, &position)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    // MARK: Actions

    func setFrame(_ frame: CGRect) {
        // Apps with "enhanced user interface" animate every resize; switch it off meanwhile.
        let app = Self.application(pid)
        let enhanced: Bool = app.value("AXEnhancedUserInterface") ?? false
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer { if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }

        var size = frame.size
        var origin = frame.origin
        // Size → position → size: a window moving to a smaller screen is resized
        // first, and apps that clamp the size during the move get corrected after.
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) }
        if let value = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) }
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) }
    }

    func raise() {
        if isMinimized { AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    @discardableResult
    func close() -> Bool {
        guard let button: AXUIElement = element.value(kAXCloseButtonAttribute) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    // MARK: Coordinates

    /// Converts between AppKit (bottom-left origin) and Accessibility (top-left origin) rects; the mapping is its own inverse.
    static func flip(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private typealias GetWindowID = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias CreateWithRemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }
    private static let getWindowID = symbol("_AXUIElementGetWindow", as: GetWindowID.self)
    private static let createWithRemoteToken = symbol("_AXUIElementCreateWithRemoteToken", as: CreateWithRemoteToken.self)
}

extension AXUIElement {
    /// Typed attribute read; AXUIElement and AXValue results are checked by CF type ID.
    func value<T>(_ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            return CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! T) : nil
        }
        if T.self == AXValue.self {
            return CFGetTypeID(value) == AXValueGetTypeID() ? (value as! T) : nil
        }
        return value as? T
    }
}
