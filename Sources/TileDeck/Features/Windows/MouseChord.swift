import AppKit

/// Pressing the left and right mouse buttons together opens Mission Control.
/// The tap only sees mouse button presses, never mouse movement.
@MainActor
final class MouseChord: ObservableObject {
    static let shared = MouseChord()
    private static let defaultsKey = "mouseChordMissionControl"

    @Published private(set) var isEnabled: Bool

    private lazy var tap = EventTap(types: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]) { [weak self] type, event in
        self?.handle(type, event) ?? Unmanaged.passUnretained(event)
    }
    private var leftDown = false
    private var rightDown = false
    private var fired = false
    private var swallowRightUp = false

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
    }

    func activateIfNeeded() {
        if isEnabled { tap.start() }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.defaultsKey)
        if enabled {
            if !tap.start() { AXWindow.requestTrust() }
        } else {
            tap.stop()
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .leftMouseDown:
            leftDown = true
            if rightDown { fire() }
            return pass
        case .rightMouseDown:
            rightDown = true
            guard leftDown else { return pass }
            fire()
            // Swallow this right click so no context menu opens.
            swallowRightUp = true
            return nil
        case .leftMouseUp:
            leftDown = false
            if !rightDown { fired = false }
            return pass
        case .rightMouseUp:
            rightDown = false
            if !leftDown { fired = false }
            if swallowRightUp {
                swallowRightUp = false
                return nil
            }
            return pass
        default:
            return pass
        }
    }

    private func fire() {
        guard !fired else { return }
        fired = true
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
    }
}
