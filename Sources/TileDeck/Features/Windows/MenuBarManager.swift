import AppKit

/// Hides and reorders menu bar icons, Hidden Bar–style. Two status items of
/// our own: a toggle chevron and, to its left, a separator. Icons left of the
/// separator form the hidden section; collapsing stretches the separator to
/// push them off screen. Moving an icon replays the ⌘-drag you'd do by hand.
@MainActor
final class MenuBarManager: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: CGWindowID
        let pid: pid_t
        let name: String
        let frame: CGRect  // Quartz coordinates, origin top-left of the main display
        let isHidden: Bool
        let isMovable: Bool
        /// SF Symbol for system icons, which share one owner app.
        var symbol: String?
    }

    static let shared = MenuBarManager()

    private enum Key {
        static let enabled = "menuBarManager"
        static let collapsed = "menuBarCollapsed"
        static let autoCollapse = "menuBarAutoCollapse"
    }
    private static let collapsedLength: CGFloat = 10_000
    // Fixed widths identify our own items on every display: each display has
    // its own copy of a status item window, with a different window number.
    // The window is the item's length plus 16 pt of padding on recent macOS.
    private static let separatorLength: CGFloat = 10
    private static let toggleLength: CGFloat = 30

    private static func matches(_ width: CGFloat, length: CGFloat) -> Bool {
        abs(width - length) <= 1 || abs(width - length - 16) <= 1
    }
    private static let autoCollapseDelay: TimeInterval = 15

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isCollapsed: Bool
    @Published private(set) var autoCollapse: Bool
    @Published private(set) var items: [Item] = []
    @Published private(set) var isMoving = false

    /// Where our separator sits on the display being read, for drop targets.
    private var separatorFrame: CGRect?

    private var toggle: NSStatusItem?
    private var separator: NSStatusItem?
    private var collapseWork: DispatchWorkItem?
    private var holdExpanded = false

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Key.enabled)
        isCollapsed = defaults.bool(forKey: Key.collapsed)
        autoCollapse = defaults.object(forKey: Key.autoCollapse) as? Bool ?? true
    }

    func activateIfNeeded() {
        if isEnabled { install() }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Key.enabled)
        enabled ? install() : uninstall()
    }

    func setAutoCollapse(_ on: Bool) {
        autoCollapse = on
        UserDefaults.standard.set(on, forKey: Key.autoCollapse)
        scheduleAutoCollapse()
    }

    // MARK: Status items

    private func install() {
        guard toggle == nil else { return }
        // A new status item appears left of existing ones, so the toggle comes first and the separator lands left of it.
        let toggle = NSStatusBar.system.statusItem(withLength: Self.toggleLength)
        toggle.autosaveName = "TileDeckMenuBarToggle"
        toggle.button?.target = self
        toggle.button?.action = #selector(toggleClicked)
        let separator = NSStatusBar.system.statusItem(withLength: Self.separatorLength)
        separator.autosaveName = "TileDeckMenuBarSeparator"
        separator.button?.image = Self.symbol("poweron", size: 11)
        separator.button?.appearsDisabled = true
        self.toggle = toggle
        self.separator = separator
        apply()
    }

    private func uninstall() {
        collapseWork?.cancel()
        [toggle, separator].compactMap { $0 }.forEach(NSStatusBar.system.removeStatusItem)
        toggle = nil
        separator = nil
        items = []
    }

    @objc private func toggleClicked() {
        setCollapsed(!isCollapsed)
    }

    func setCollapsed(_ collapsed: Bool) {
        isCollapsed = collapsed
        UserDefaults.standard.set(collapsed, forKey: Key.collapsed)
        apply()
        scheduleAutoCollapse()
    }

    private func apply() {
        let collapsed = isCollapsed && !holdExpanded
        separator?.length = collapsed ? Self.collapsedLength : Self.separatorLength
        separator?.button?.image = collapsed ? nil : Self.symbol("poweron", size: 11)
        toggle?.button?.image = Self.symbol(collapsed ? "chevron.left" : "chevron.right", size: 12)
        toggle?.button?.toolTip = collapsed ? "Hiện các icon đang ẩn" : "Ẩn các icon bên trái vạch"
    }

    /// Re-hide 15 s after the hidden icons were revealed.
    private func scheduleAutoCollapse() {
        collapseWork?.cancel()
        guard autoCollapse, isEnabled, !isCollapsed, !holdExpanded else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.setCollapsed(true) }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoCollapseDelay, execute: work)
    }

    /// While the settings tab is open every icon stays visible so it can be arranged.
    func beginEditing() {
        holdExpanded = true
        collapseWork?.cancel()
        apply()
        // The separator needs a moment to shrink before the icons are back in place.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func endEditing() {
        holdExpanded = false
        apply()
        scheduleAutoCollapse()
    }

    private static func symbol(_ name: String, size: CGFloat) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold))
        image?.isTemplate = true
        return image
    }

    // MARK: Reading the menu bar

    func refresh() {
        let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let me = getpid()
        func isSeparator(_ icon: (id: CGWindowID, pid: pid_t, name: String, frame: CGRect)) -> Bool {
            separator != nil && icon.pid == me && Self.matches(icon.frame.width, length: Self.separatorLength)
        }
        func isToggle(_ icon: (id: CGWindowID, pid: pid_t, name: String, frame: CGRect)) -> Bool {
            toggle != nil && icon.pid == me && Self.matches(icon.frame.width, length: Self.toggleLength)
        }

        var icons: [(id: CGWindowID, pid: pid_t, name: String, frame: CGRect)] = []
        for entry in entries {
            guard entry[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.statusWindow)),
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            let owner = entry[kCGWindowOwnerName as String] as? String ?? "?"
            icons.append((id, pid, NSRunningApplication(processIdentifier: pid)?.localizedName ?? owner, frame))
        }

        // Every display shows its own copy of the same icons, and a display
        // running a full-screen app shows none. Read one display whose menu bar
        // is up: the one with our separator if possible, else the fullest.
        let screens = NSScreen.screens.map { AXWindow.flip($0.frame) }
        let perScreen = screens.map { screen in
            icons.filter { $0.frame.minY == screen.minY && $0.frame.minX >= screen.minX && $0.frame.maxX <= screen.maxX + 1 }
        }
        // Prefer the fullest display: a notch hides icons that a wider screen still shows.
        let withSeparator = perScreen.filter { $0.contains { isSeparator($0) } }
        let chosen = (withSeparator.isEmpty ? perScreen : withSeparator).max { $0.count < $1.count } ?? []
        let found = chosen.sorted { $0.frame.minX < $1.frame.minX }

        separatorFrame = found.first(where: isSeparator)?.frame
        let separatorX = separatorFrame?.minX ?? -1
        let clock = found.last  // Control Center's clock is pinned to the far right
        let visible = found.filter { !isSeparator($0) && !isToggle($0) }
        let labels = Self.labels(for: visible.map { ($0.pid, $0.frame) })
        items = zip(visible, labels).map { item, label in
            Item(id: item.id, pid: item.pid, name: label.name ?? item.name, frame: item.frame,
                 isHidden: separatorX >= 0 && item.frame.minX < separatorX,
                 // macOS ignores a synthetic drag of an app's own icon, so TileDeck's icons are moved by hand.
                 isMovable: item.pid != me && item.id != clock?.id,
                 symbol: label.symbol)
        }
    }

    // MARK: Names

    /// Control Center, the input menu and friends each own several icons; their
    /// Accessibility descriptions ("Wi‑Fi, connected", "Battery"…) tell them apart.
    /// AX lists an app's icons in its own order, so both sides are matched left to right.
    private static func labels(for icons: [(pid: pid_t, frame: CGRect)]) -> [(name: String?, symbol: String?)] {
        var perApp: [pid_t: [(x: CGFloat, name: String?, identifier: String?)]] = [:]
        for pid in Set(icons.map(\.pid)) {
            let app = AXWindow.application(pid)
            guard let bar: AXUIElement = app.value("AXExtrasMenuBar") else { continue }
            let children: [AXUIElement] = bar.value(kAXChildrenAttribute) ?? []
            perApp[pid] = children.map { child in
                var position = CGPoint.zero
                if let value: AXValue = child.value(kAXPositionAttribute) { AXValueGetValue(value, .cgPoint, &position) }
                let description: String? = child.value(kAXDescriptionAttribute)
                let identifier: String? = child.value(kAXIdentifierAttribute)
                // "Wi‑Fi, connected, 3 bars" → "Wi‑Fi"
                let name = description?.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) }
                return (position.x, name, identifier)
            }.sorted { $0.x < $1.x }
        }

        var used: [pid_t: Int] = [:]
        let ownerName = Dictionary(icons.map { ($0.pid, NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier ?? "") },
                                   uniquingKeysWith: { first, _ in first })
        return icons.map { icon in
            let index = used[icon.pid, default: 0]
            used[icon.pid] = index + 1
            let symbol = systemSymbol(identifier: nil, bundleID: ownerName[icon.pid])
            let fallback = ownerName[icon.pid] == "com.apple.TextInputMenuAgent" ? "Nguồn nhập bàn phím" : nil
            guard let entries = perApp[icon.pid], entries.indices.contains(index) else { return (fallback, symbol) }
            let entry = entries[index]
            let isSystem = ownerName[icon.pid].map { $0.hasPrefix("com.apple.") } ?? false
            // Third-party apps keep their app name unless they own several icons.
            let multiple = icons.filter { $0.pid == icon.pid }.count > 1
            let name = (isSystem || multiple) ? entry.name : nil
            return (name ?? fallback, systemSymbol(identifier: entry.identifier, bundleID: ownerName[icon.pid]) ?? symbol)
        }
    }

    private static func systemSymbol(identifier: String?, bundleID: String?) -> String? {
        if bundleID == "com.apple.TextInputMenuAgent" { return "keyboard" }
        guard let identifier = identifier?.lowercased(), identifier.hasPrefix("com.apple.menuextra.") else { return nil }
        let table: [(String, String)] = [
            ("clock", "clock"), ("controlcenter", "switch.2"), ("wifi", "wifi"), ("battery", "battery.100"),
            ("bluetooth", "dot.radiowaves.left.and.right"), ("focus", "moon.fill"), ("audiovideo", "mic.fill"),
            ("now-playing", "play.circle"), ("sound", "speaker.wave.2.fill"), ("display", "display"),
            ("screenmirroring", "rectangle.on.rectangle"), ("airdrop", "airplayaudio"), ("spotlight", "magnifyingglass"),
            ("siri", "waveform"), ("user", "person.crop.circle"), ("keyboardbrightness", "light.max"),
            ("timemachine", "clock.arrow.circlepath"), ("vpn", "network.badge.shield.half.filled"),
            ("accessibility", "accessibility"), ("hearing", "ear"), ("stagemanager", "rectangle.3.group"),
        ]
        return table.first { identifier.contains($0.0) }?.1
    }

    // MARK: Moving icons

    /// Drops the icon right next to `target`: on its left when coming from the
    /// right, on its right when coming from the left — i.e. it takes target's place.
    func place(_ item: Item, at target: Item) {
        guard let from = items.firstIndex(of: item), let to = items.firstIndex(of: target), from != to else { return }
        let frame = target.frame
        drag(item, to: CGPoint(x: from > to ? frame.minX + 1 : frame.maxX - 2, y: frame.midY))
    }

    func hide(_ item: Item) {
        guard let separatorFrame else { return }
        drag(item, to: CGPoint(x: separatorFrame.minX + 1, y: separatorFrame.midY))
    }

    func show(_ item: Item) {
        guard let separatorFrame else { return }
        drag(item, to: CGPoint(x: separatorFrame.maxX - 2, y: separatorFrame.midY))
    }

    /// Moves the icon past its neighbour on the left (-1) or right (+1).
    func move(_ item: Item, by offset: Int) {
        guard let index = items.firstIndex(of: item), items.indices.contains(index + offset) else { return }
        let neighbour = items[index + offset].frame
        drag(item, to: CGPoint(x: offset < 0 ? neighbour.minX + 1 : neighbour.maxX - 2, y: neighbour.midY))
    }

    /// The ⌘-drag you'd do by hand: press on the icon, slide, release where it
    /// should land. The events carry the icon's window and owner so the menu bar
    /// accepts them. macOS only takes this drag through the shared event stream
    /// (posting straight to the app is ignored), so it has to move the pointer:
    /// the pointer is hidden for the ~0.1 s it takes and put back afterwards.
    private func drag(_ item: Item, to target: CGPoint) {
        guard item.isMovable, !isMoving else { return }
        guard AXWindow.isTrusted else {
            AXWindow.requestTrust()
            return
        }
        isMoving = true
        let source = CGEventSource(stateID: .combinedSessionState)
        let allow: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        source?.setLocalEventsFilterDuringSuppressionState(allow, state: .eventSuppressionStateRemoteMouseDrag)
        source?.setLocalEventsFilterDuringSuppressionState(allow, state: .eventSuppressionStateSuppressionInterval)
        source?.localEventsSuppressionInterval = 0

        func event(_ type: CGEventType, _ point: CGPoint) -> CGEvent? {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.flags = .maskCommand
            event?.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(item.pid))
            event?.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(item.id))
            event?.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(item.id))
            if type != .leftMouseDragged { event?.setIntegerValueField(.mouseEventClickState, value: 1) }
            return event
        }

        let start = CGPoint(x: item.frame.midX, y: item.frame.midY)
        let steps = 3
        let sequence = [event(.leftMouseDown, start)]
            + (1...steps).map { step in
                let progress = CGFloat(step) / CGFloat(steps)
                return event(.leftMouseDragged, CGPoint(x: start.x + (target.x - start.x) * progress, y: start.y))
            }
            + [event(.leftMouseUp, target)]
        let original = CGEvent(source: nil)?.location ?? start
        nonisolated(unsafe) let events = sequence.compactMap { $0 }

        Self.hideCursor()
        // Paced off the main thread: the menu bar needs real time between press, drag and release.
        DispatchQueue.global(qos: .userInitiated).async {
            for (index, event) in events.enumerated() {
                event.post(tap: .cgSessionEventTap)
                usleep(index == 0 ? 30_000 : (index == events.count - 1 ? 20_000 : 8_000))
            }
            CGWarpMouseCursorPosition(original)
            CGDisplayShowCursor(CGMainDisplayID())
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    self.isMoving = false
                    self.refresh()
                }
            }
        }
    }

    /// A background app may only hide the pointer after asking the window server for it.
    private static func hideCursor() {
        typealias MainConnectionID = @convention(c) () -> Int32
        typealias SetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        if let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
           let main = dlsym(handle, "SLSMainConnectionID"), let set = dlsym(handle, "SLSSetConnectionProperty") {
            let connection = unsafeBitCast(main, to: MainConnectionID.self)()
            _ = unsafeBitCast(set, to: SetConnectionProperty.self)(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        }
        CGDisplayHideCursor(CGMainDisplayID())
    }
}
