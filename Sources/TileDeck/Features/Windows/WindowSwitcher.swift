import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import SwiftUI

struct SwitcherWindow: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let appName: String
    let icon: NSImage?
    let ax: AXWindow?
    let isMinimized: Bool
}

/// ⌘Tab window switcher (AltTab-style): every window rather than every app,
/// in most-recently-used order. A quick ⌘Tab tap switches straight away;
/// holding ⌘ shows the panel with live previews.
///   Tab / ⇧Tab / ` / arrows: move   W: close window   Q: quit app
///   Esc: cancel   Return or releasing ⌘: switch
@MainActor
final class WindowSwitcher: ObservableObject {
    static let shared = WindowSwitcher()
    private static let defaultsKey = "windowSwitcher"
    private static let showDelay: TimeInterval = 0.12

    @Published private(set) var isEnabled: Bool

    private lazy var tap = EventTap(types: [.keyDown, .keyUp, .flagsChanged]) { [weak self] type, event in
        self?.handle(type, event) ?? Unmanaged.passUnretained(event)
    }
    private var model: SwitcherModel?
    private var panel: NSPanel?
    private var showWork: DispatchWorkItem?
    private var previewTask: Task<Void, Never>?

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
    }

    var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    func activateIfNeeded() {
        // Also run when the feature is off: puts macOS's own ⌘Tab back if TileDeck crashed while it was replaced.
        setNativeSwitcher(enabled: !(isEnabled && tap.start()))
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.defaultsKey)
        if enabled {
            if tap.start() {
                setNativeSwitcher(enabled: false)
            } else {
                AXWindow.requestTrust()
            }
        } else {
            tap.stop()
            cancel()
            setNativeSwitcher(enabled: true)
        }
    }

    /// Called at quit so macOS's ⌘Tab works again without TileDeck.
    func restoreNativeSwitcher() {
        setNativeSwitcher(enabled: true)
        _ = SkyLight.setSymbolicHotKey?(SymbolicHotKey.commandKeyAboveTab, true)
    }

    /// macOS handles its own ⌘Tab before any event tap sees the key, so both
    /// switchers would open; the system one has to be switched off while ours runs.
    private func setNativeSwitcher(enabled: Bool) {
        guard let set = SkyLight.setSymbolicHotKey else { return }
        _ = set(SymbolicHotKey.commandTab, enabled)
        _ = set(SymbolicHotKey.commandShiftTab, enabled)
    }

    // MARK: Keyboard

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let flags = event.flags
        let key = Int(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .flagsChanged {
            if model != nil && !flags.contains(.maskCommand) { commit() }
            return pass
        }

        guard let model else {
            let plainCommand = flags.contains(.maskCommand) && !flags.contains(.maskControl) && !flags.contains(.maskAlternate)
            if type == .keyDown && key == kVK_Tab && plainCommand {
                begin(reverse: flags.contains(.maskShift))
                return nil
            }
            return pass
        }

        // While the switcher is up it owns the keyboard.
        guard type == .keyDown else { return nil }
        switch key {
        case kVK_Tab: model.move(flags.contains(.maskShift) ? -1 : 1)
        case kVK_ANSI_Grave, kVK_LeftArrow: model.move(-1)
        case kVK_RightArrow: model.move(1)
        case kVK_ANSI_W: closeSelected()
        case kVK_ANSI_Q: quitSelected()
        case kVK_Escape: cancel()
        case kVK_Return: commit()
        default: break
        }
        return nil
    }

    // MARK: Session

    private func begin(reverse: Bool) {
        let windows = Self.collectWindows()
        guard !windows.isEmpty else { return }
        let model = SwitcherModel(windows: windows)
        model.selection = reverse ? windows.count - 1 : min(1, windows.count - 1)
        self.model = model
        // ⌘` steps back inside our switcher, so macOS's "next window of this app" must not fire meanwhile.
        _ = SkyLight.setSymbolicHotKey?(SymbolicHotKey.commandKeyAboveTab, false)

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.showPanel() }
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay, execute: work)
    }

    func commit() {
        guard let window = model?.selectedWindow else { return cancel() }
        cancel()
        Self.focus(window)
    }

    func cancel() {
        if model != nil { _ = SkyLight.setSymbolicHotKey?(SymbolicHotKey.commandKeyAboveTab, true) }
        showWork?.cancel()
        showWork = nil
        previewTask?.cancel()
        previewTask = nil
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }

    func select(_ index: Int) {
        model?.selection = index
        commit()
    }

    private func closeSelected() {
        guard let model, let window = model.selectedWindow else { return }
        window.ax?.close()
        model.remove { $0.id == window.id }
        if model.windows.isEmpty { cancel() } else { resizePanel() }
    }

    private func quitSelected() {
        guard let model, let window = model.selectedWindow else { return }
        NSRunningApplication(processIdentifier: window.pid)?.terminate()
        model.remove { $0.pid == window.pid }
        if model.windows.isEmpty { cancel() } else { resizePanel() }
    }

    // MARK: Panel

    private func showPanel() {
        guard let model, panel == nil else { return }
        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.acceptsMouseMovedEvents = true
        panel.contentView = FirstClickHostingView(rootView: SwitcherView(model: model) { [weak self] index in self?.select(index) })
        self.panel = panel
        resizePanel()
        panel.orderFrontRegardless()
        loadPreviews(for: model)
    }

    private func resizePanel() {
        guard let panel, let content = panel.contentView else { return }
        let size = content.fittingSize
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let area = screen?.frame ?? .zero
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height), display: true)
    }

    /// One small capture per window, only while the panel is visible. Needs Screen Recording; without it the cards show app icons.
    private func loadPreviews(for model: SwitcherModel) {
        guard hasScreenRecording else { return }
        let ids = Set(model.windows.map(\.id))
        previewTask = Task { [weak model] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return }
            await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                for window in content.windows where ids.contains(window.windowID) {
                    group.addTask {
                        let configuration = SCStreamConfiguration()
                        let scale = min(1, 360 / max(window.frame.width, 1)) * 2
                        configuration.width = max(Int(window.frame.width * scale), 1)
                        configuration.height = max(Int(window.frame.height * scale), 1)
                        configuration.showsCursor = false
                        configuration.ignoreShadowsSingleWindow = true
                        let filter = SCContentFilter(desktopIndependentWindow: window)
                        let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                        return (window.windowID, image)
                    }
                }
                for await (id, image) in group {
                    guard !Task.isCancelled, let image else { continue }
                    await MainActor.run { model?.previews[id] = image }
                }
            }
        }
    }

    // MARK: Windows

    /// Visible windows front-to-back (which is most-recently-used order), then
    /// windows on other desktops and full-screen apps, then minimized and hidden ones.
    static func collectWindows() -> [SwitcherWindow] {
        let me = getpid()
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
        let appsByPID = Dictionary(apps.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })

        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var onScreen: [(id: CGWindowID, pid: pid_t)] = []
        for entry in info {
            guard entry[kCGWindowLayer as String] as? Int == 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, appsByPID[pid] != nil,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) > 60, (bounds["Height"] ?? 0) > 60 else { continue }
            onScreen.append((id, pid))
        }

        // Each AX attribute is a round trip to another process (~20–35 ms per
        // app), so all apps are asked in parallel: the wait is the slowest app, not the sum.
        let pids = apps.map(\.processIdentifier)
        var answers = [AppWindows](repeating: AppWindows(), count: pids.count)
        answers.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let buffer = buffer  // each iteration writes only its own index
            DispatchQueue.concurrentPerform(iterations: pids.count) { index in
                buffer[index] = Self.standardWindows(of: pids[index])
            }
        }

        var axByID: [CGWindowID: AXInfo] = [:]
        var answeredPIDs: Set<pid_t> = []
        var offScreen: [SwitcherWindow] = []
        let onScreenIDs = Set(onScreen.map(\.id))
        for (app, answer) in zip(apps, answers) {
            if answer.answered { answeredPIDs.insert(app.processIdentifier) }
            for info in answer.windows {
                axByID[info.id] = info
                if !onScreenIDs.contains(info.id) && (info.isMinimized || app.isHidden) {
                    offScreen.append(make(id: info.id, app: app, info: info, minimized: true))
                }
            }
        }

        var result: [SwitcherWindow] = []
        for (id, pid) in onScreen {
            guard let app = appsByPID[pid] else { continue }
            let info = axByID[id]
            // Skip panels, popovers and other non-standard windows; keep everything from apps that don't answer AX.
            if info == nil && answeredPIDs.contains(pid) { continue }
            result.append(make(id: id, app: app, info: info, minimized: false))
        }

        // Other desktops and full-screen apps: neither the on-screen window list
        // nor most apps' Accessibility tree includes them, but the window server does.
        let listed = onScreenIDs.union(offScreen.map(\.id))
        var candidates: [(id: CGWindowID, app: NSRunningApplication, name: String?)] = []
        for entry in Spaces.windowsOnOtherSpaces() {
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID, !listed.contains(id),
                  entry[kCGWindowLayer as String] as? Int == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, let app = appsByPID[pid],
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  // Full-screen apps add toolbar strips as separate windows; real windows are bigger.
                  (bounds["Width"] ?? 0) >= 200, (bounds["Height"] ?? 0) >= 200 else { continue }
            candidates.append((id, app, entry[kCGWindowName as String] as? String))
        }

        // Their AX elements (needed for the title and to switch Space on focus) are looked up per app, in parallel.
        let missing = Dictionary(grouping: candidates.filter { axByID[$0.id] == nil }, by: { $0.app.processIdentifier })
            .mapValues { Set($0.map(\.id)) }
        let lookups = Array(missing)
        var remote = [[CGWindowID: AXInfo]](repeating: [:], count: lookups.count)
        remote.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let buffer = buffer  // each iteration writes only its own index
            DispatchQueue.concurrentPerform(iterations: lookups.count) { index in
                let (pid, ids) = lookups[index]
                buffer[index] = AXWindow.remoteWindows(of: pid, matching: ids).compactMapValues { Self.info(for: $0) }
            }
        }
        for found in remote { axByID.merge(found) { current, _ in current } }

        var otherSpaces: [SwitcherWindow] = []
        for candidate in candidates {
            otherSpaces.append(make(id: candidate.id, app: candidate.app, info: axByID[candidate.id], minimized: false,
                                    fallbackTitle: candidate.name))
        }
        return result + otherSpaces + offScreen
    }

    private struct AXInfo {
        let window: AXWindow
        let id: CGWindowID
        let title: String
        let isMinimized: Bool
    }

    private struct AppWindows {
        var answered = false
        var windows: [AXInfo] = []
    }

    nonisolated private static func standardWindows(of pid: pid_t) -> AppWindows {
        let windows = AXWindow.windows(of: pid)
        return AppWindows(answered: !windows.isEmpty, windows: windows.compactMap(info(for:)))
    }

    /// Title and minimized state in one round trip; nil for anything that isn't a standard window.
    nonisolated private static func info(for window: AXWindow) -> AXInfo? {
        let values = window.values([kAXSubroleAttribute, kAXTitleAttribute, kAXMinimizedAttribute])
        guard values[0] as? String == kAXStandardWindowSubrole, let id = window.windowID else { return nil }
        return AXInfo(window: window, id: id, title: values[1] as? String ?? "", isMinimized: values[2] as? Bool ?? false)
    }

    private static func make(id: CGWindowID, app: NSRunningApplication, info: AXInfo?, minimized: Bool,
                             fallbackTitle: String? = nil) -> SwitcherWindow {
        let name = app.localizedName ?? "App"
        let title = info?.title ?? fallbackTitle ?? ""
        return SwitcherWindow(id: id, pid: app.processIdentifier, title: title.isEmpty ? name : title,
                              appName: name, icon: app.icon, ax: info?.window, isMinimized: minimized)
    }

    /// Brings exactly this window to the front, even across apps (plain
    /// NSRunningApplication.activate only picks an app, not a window).
    static func focus(_ window: SwitcherWindow) {
        let app = NSRunningApplication(processIdentifier: window.pid)
        if app?.isHidden == true { app?.unhide() }

        if let getPSN = SkyLight.getProcessForPID, let setFront = SkyLight.setFrontProcess, let post = SkyLight.postEventRecord {
            var psn = ProcessSerialNumber()
            if getPSN(window.pid, &psn) == noErr {
                _ = setFront(&psn, window.id, 0x200)  // kCPSUserGenerated
                // Make it the key window: the same event record the Dock sends.
                var bytes = [UInt8](repeating: 0, count: 0xF8)
                bytes[0x04] = 0xF8
                bytes[0x3A] = 0x10
                withUnsafeBytes(of: window.id) { bytes.replaceSubrange(0x3C..<0x40, with: $0) }
                for index in 0x20..<0x30 { bytes[index] = 0xFF }
                bytes[0x08] = 0x01
                _ = post(&psn, &bytes)
                bytes[0x08] = 0x02
                _ = post(&psn, &bytes)
            }
            window.ax?.raise()
        } else {
            window.ax?.raise()
            app?.activate()
        }
    }
}

/// The panel never becomes key (the app you're switching from keeps focus),
/// so the first click must act right away instead of only focusing the panel.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Private window-server calls, resolved lazily so a missing symbol only degrades focusing.
private enum SkyLight {
    typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    typealias SetFrontProcess = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> Int32
    typealias PostEventRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    typealias SetSymbolicHotKey = @convention(c) (UInt32, Bool) -> Int32

    private static func symbol<T>(_ path: String, _ name: String, as type: T.Type) -> T? {
        guard let handle = dlopen(path, RTLD_LAZY), let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private static let skyLight = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    static let getProcessForPID = symbol("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", "GetProcessForPID", as: GetProcessForPID.self)
    static let setFrontProcess = symbol(skyLight, "_SLPSSetFrontProcessWithOptions", as: SetFrontProcess.self)
    static let postEventRecord = symbol(skyLight, "SLPSPostEventRecordTo", as: PostEventRecord.self)
    static let setSymbolicHotKey = symbol(skyLight, "SLSSetSymbolicHotKeyEnabled", as: SetSymbolicHotKey.self)
}

/// Windows that live on Spaces other than the visible ones (other desktops,
/// full-screen apps), read from the window server.
private enum Spaces {
    typealias MainConnectionID = @convention(c) () -> Int32
    typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias CopyWindowsWithOptionsAndTags = @convention(c) (Int32, Int32, CFArray, Int32, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>) -> Unmanaged<CFArray>?

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        dlsym(handle, name).map { unsafeBitCast($0, to: type) }
    }
    private static let mainConnectionID = symbol("SLSMainConnectionID", as: MainConnectionID.self)
    private static let copyManagedDisplaySpaces = symbol("SLSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpaces.self)
    private static let copyWindows = symbol("SLSCopyWindowsWithOptionsAndTags", as: CopyWindowsWithOptionsAndTags.self)

    static func windowsOnOtherSpaces() -> [[String: Any]] {
        guard let mainConnectionID, let copyManagedDisplaySpaces, let copyWindows else { return [] }
        let connection = mainConnectionID()
        let displays = copyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] ?? []
        var hidden: [UInt64] = []
        for display in displays {
            let current = (display["Current Space"] as? [String: Any])?["id64"] as? UInt64
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                if let id = space["id64"] as? UInt64, id != current { hidden.append(id) }
            }
        }
        guard !hidden.isEmpty else { return [] }

        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        let ids = copyWindows(connection, 0, hidden as CFArray, 2, &setTags, &clearTags)?.takeRetainedValue() as? [CGWindowID] ?? []
        guard !ids.isEmpty else { return [] }
        var pointers = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        let array = CFArrayCreate(nil, &pointers, pointers.count, nil)
        return CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] ?? []
    }
}

/// System shortcut IDs used by SLSSetSymbolicHotKeyEnabled.
private enum SymbolicHotKey {
    static let commandTab: UInt32 = 1
    static let commandShiftTab: UInt32 = 2
    static let commandKeyAboveTab: UInt32 = 6
}

@MainActor
final class SwitcherModel: ObservableObject {
    @Published private(set) var windows: [SwitcherWindow]
    @Published var selection = 0
    @Published var previews: [CGWindowID: CGImage] = [:]

    init(windows: [SwitcherWindow]) {
        self.windows = windows
    }

    var selectedWindow: SwitcherWindow? {
        windows.indices.contains(selection) ? windows[selection] : nil
    }

    func move(_ delta: Int) {
        guard !windows.isEmpty else { return }
        selection = (selection + delta + windows.count) % windows.count
    }

    func remove(where shouldRemove: (SwitcherWindow) -> Bool) {
        windows.removeAll(where: shouldRemove)
        selection = min(selection, max(windows.count - 1, 0))
    }
}
