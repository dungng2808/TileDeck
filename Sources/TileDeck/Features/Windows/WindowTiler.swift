import AppKit
import Carbon.HIToolbox

/// Rectangle-style window snapping on ⌃⌥ + arrows, and ⌃⌥⌘ + ←/→ to move a
/// window to another display. Instant: no animation, no delay.
@MainActor
final class WindowTiler: ObservableObject {
    enum Action: CaseIterable {
        case leftHalf, rightHalf, maximize, center, nextDisplay, previousDisplay
    }

    static let shared = WindowTiler()
    private static let defaultsKey = "windowTiling"

    @Published private(set) var isEnabled: Bool
    private var hotKeys: [UInt32] = []

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
    }

    func activateIfNeeded() {
        if isEnabled { registerHotKeys() }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.defaultsKey)
        if enabled {
            if !AXWindow.isTrusted { AXWindow.requestTrust() }
            registerHotKeys()
        } else {
            HotKeys.shared.unregister(hotKeys)
            hotKeys.removeAll()
        }
    }

    private func registerHotKeys() {
        guard hotKeys.isEmpty else { return }
        let controlOption = controlKey | optionKey
        let bindings: [(Int, Int, Action)] = [
            (kVK_LeftArrow, controlOption, .leftHalf),
            (kVK_RightArrow, controlOption, .rightHalf),
            (kVK_UpArrow, controlOption, .maximize),
            (kVK_DownArrow, controlOption, .center),
            (kVK_RightArrow, controlOption | cmdKey, .nextDisplay),
            (kVK_LeftArrow, controlOption | cmdKey, .previousDisplay),
        ]
        hotKeys = bindings.compactMap { key, modifiers, action in
            HotKeys.shared.register(keyCode: key, modifiers: modifiers) { [weak self] in self?.perform(action) }
        }
    }

    func perform(_ action: Action) {
        guard AXWindow.isTrusted else {
            AXWindow.requestTrust()
            return
        }
        guard let window = AXWindow.focused(), let axFrame = window.frame else { return }
        let frame = AXWindow.flip(axFrame)
        guard let target = Self.target(for: action, windowFrame: frame) else { return }
        window.setFrame(AXWindow.flip(target.integral))
    }

    /// The new frame in AppKit coordinates, or nil when there's nowhere to go.
    static func target(for action: Action, windowFrame frame: CGRect) -> CGRect? {
        let screens = NSScreen.screens
        guard let current = screens.max(by: { $0.frame.intersection(frame).area < $1.frame.intersection(frame).area }) else { return nil }
        let area = current.visibleFrame

        switch action {
        case .leftHalf:
            return CGRect(x: area.minX, y: area.minY, width: (area.width / 2).rounded(), height: area.height)
        case .rightHalf:
            let half = (area.width / 2).rounded()
            return CGRect(x: area.maxX - half, y: area.minY, width: half, height: area.height)
        case .maximize:
            return area
        case .center:
            let size = CGSize(width: min(frame.width, area.width), height: min(frame.height, area.height))
            return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
        case .nextDisplay, .previousDisplay:
            guard screens.count > 1 else { return nil }
            let ordered = screens.sorted { $0.frame.minX < $1.frame.minX }
            let index = ordered.firstIndex(of: current) ?? 0
            let step = action == .nextDisplay ? 1 : -1
            let destination = ordered[(index + step + ordered.count) % ordered.count].visibleFrame
            // Keep the window's relative position and size on the new display.
            let scaleX = destination.width / area.width
            let scaleY = destination.height / area.height
            let width = min(frame.width * scaleX, destination.width)
            let height = min(frame.height * scaleY, destination.height)
            let x = destination.minX + (frame.minX - area.minX) * scaleX
            let y = destination.minY + (frame.minY - area.minY) * scaleY
            return CGRect(x: min(max(x, destination.minX), destination.maxX - width),
                          y: min(max(y, destination.minY), destination.maxY - height),
                          width: width, height: height)
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
