import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import SwiftUI

/// Region screenshots on ⌘⇧1: freezes every display, lets the user drag out an
/// area, draw on it, then ⌘C copies it and ⌘S saves it. Everything but the
/// chosen colour is built when the shortcut fires and released on close.
@MainActor
final class ScreenshotTool: ObservableObject {
    static let shared = ScreenshotTool()
    private static let defaultsKey = "screenshotTool"
    private static let folderKey = "screenshotFolder"

    @Published private(set) var isEnabled: Bool

    private var hotKey: UInt32?
    private var isCapturing = false
    private var isSaving = false
    private var overlays: [ScreenshotOverlay] = []
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var returnApp: NSRunningApplication?
    private let options = ScreenCaptureOptions.shared
    private let palette = ScreenshotPalette()

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
    }

    func activateIfNeeded() {
        if isEnabled { registerHotKey() }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.defaultsKey)
        if enabled {
            registerHotKey()
            if !WindowSwitcher.shared.hasScreenRecording { WindowSwitcher.shared.requestScreenRecording() }
        } else {
            if let hotKey { HotKeys.shared.unregister([hotKey]) }
            hotKey = nil
            close()
        }
    }

    private func registerHotKey() {
        guard hotKey == nil else { return }
        hotKey = HotKeys.shared.register(keyCode: kVK_ANSI_1, modifiers: cmdKey | shiftKey) { [weak self] in
            self?.begin()
        }
    }

    // MARK: Session

    var isOpen: Bool { !overlays.isEmpty || isCapturing }

    /// `replacing` runs once the overlay is up, so switching from recording shows no gap.
    func begin(returningTo app: NSRunningApplication? = nil, replacing: (() -> Void)? = nil) {
        guard !isOpen, replacing != nil || ScreenRecordTool.shared.phase != .selecting else { return }
        returnApp = app
        guard WindowSwitcher.shared.hasScreenRecording else {
            WindowSwitcher.shared.requestScreenRecording()
            return
        }
        isCapturing = true
        Task {
            let shots = await captureScreens()
            isCapturing = false
            show(shots)
            replacing?()
        }
    }

    private func captureScreens() async -> [(screen: NSScreen, image: CGImage)] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return [] }
        let own = content.applications.filter { $0.processID == getpid() }
        var shots: [(screen: NSScreen, image: CGImage)] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
            configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
            configuration.showsCursor = false
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) {
                shots.append((screen, image))
            }
        }
        return shots
    }

    private func show(_ shots: [(screen: NSScreen, image: CGImage)]) {
        guard !shots.isEmpty else {
            NSSound.beep()
            return
        }
        // Activating lets the overlay set the cursor; the app in front comes back on close.
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = returnApp ?? (front?.processIdentifier == getpid() ? nil : front)
        returnApp = nil
        NSApp.activate()

        let actions = ScreenshotOverlay.Actions(
            mayStartSelection: { [weak self] overlay in
                !(self?.overlays.contains { $0 !== overlay && $0.hasMarks } ?? false)
            },
            selectionStarted: { [weak self] overlay in self?.clearSelections(except: overlay) },
            copy: { [weak self] in self?.copySelection() },
            save: { [weak self] in self?.saveSelection() },
            undo: { [weak self] in self?.activeOverlay?.undo() },
            redo: { [weak self] in self?.activeOverlay?.redo() },
            close: { [weak self] in self?.close() }
        )
        let bar = AnyView(ScreenCaptureModeBar(options: options, isRecording: false,
                                               chooseAction: { [weak self] recording in if recording { self?.switchToRecording() } },
                                               chooseMode: { [weak self] mode in self?.setMode(mode) }))
        overlays = shots.map { ScreenshotOverlay(screen: $0.screen, image: $0.image, palette: palette, actions: actions, options: options, modeBar: bar) }
        overlays.forEach { $0.orderFrontRegardless() }
        let underCursor = overlays.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? overlays[0]
        underCursor.makeKey()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
        selectScreenIfNeeded()
    }

    private func setMode(_ mode: ScreenCaptureMode) {
        guard options.mode != mode else { return }
        options.mode = mode
        palette.tool = nil
        overlays.forEach { $0.modeChanged() }
        selectScreenIfNeeded()
    }

    private func selectScreenIfNeeded() {
        guard options.mode == .fullScreen else { return }
        (overlays.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? overlays.first)?.selectAll()
    }

    private func switchToRecording() {
        let app = previousApp
        previousApp = nil
        close()
        ScreenRecordTool.shared.beginSelection(returningTo: app)
    }

    private func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        palette.tool = nil
        palette.canUndo = false
        palette.canRedo = false
        previousApp?.activate()
        previousApp = nil
    }

    private var activeOverlay: ScreenshotOverlay? { overlays.first(where: \.hasSelection) }

    private func clearSelections(except overlay: ScreenshotOverlay) {
        overlays.filter { $0 !== overlay }.forEach { $0.clearSelection() }
    }

    /// The overlay owns the keyboard until it closes, except while the save dialog is up.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard !isSaving else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = Int(event.keyCode)
        if let editing = overlays.first(where: \.isEditingText) {
            return handleKey(key, flags: flags, whileEditing: editing)
        }
        switch key {
        case kVK_Escape: close()
        case kVK_ANSI_C where flags == .command: copySelection()
        case kVK_ANSI_S where flags == .command: saveSelection()
        case kVK_ANSI_Z where flags == .command: activeOverlay?.undo()
        case kVK_ANSI_Z where flags == [.command, .shift]: activeOverlay?.redo()
        case kVK_ANSI_V where flags.isEmpty: palette.tool = nil
        default:
            if flags.isEmpty, activeOverlay != nil, let tool = ScreenshotDrawTool.allCases.first(where: { $0.keyCode == key }) {
                palette.tool = palette.tool == tool ? nil : tool
            }
        }
        return true
    }

    /// Typing goes to the text box. There's no Edit menu in a menu bar app, so
    /// its standard shortcuts are forwarded by hand.
    private func handleKey(_ key: Int, flags: NSEvent.ModifierFlags, whileEditing editing: ScreenshotOverlay) -> Bool {
        switch key {
        case kVK_Escape where !editing.isComposingText: editing.cancelText()
        case kVK_Return where !editing.isComposingText, kVK_ANSI_KeypadEnter where !editing.isComposingText: editing.commitText()
        case kVK_ANSI_C where flags == .command:
            if editing.hasSelectedText { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) } else { copySelection() }
        case kVK_ANSI_S where flags == .command: saveSelection()
        case kVK_ANSI_X where flags == .command: NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
        case kVK_ANSI_V where flags == .command: NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        case kVK_ANSI_A where flags == .command: NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        default: return false
        }
        return true
    }

    // MARK: Output

    private func selectedImage() -> (rep: NSBitmapImageRep, png: Data)? {
        overlays.forEach { $0.commitText() }
        guard let (image, scale) = overlays.lazy.compactMap({ $0.selectedImage() }).first else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        // Pasted and saved images keep their on-screen size on Retina displays.
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return (rep, png)
    }

    private func copySelection() {
        guard let (rep, png) = selectedImage() else { return }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = rep.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        close()
    }

    private func saveSelection() {
        guard !isSaving, let (_, png) = selectedImage() else { return }
        let defaults = UserDefaults.standard
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = ScreenshotGeometry.fileName(for: Date())
        panel.directoryURL = defaults.url(forKey: Self.folderKey)
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.level = NSWindow.Level(rawValue: ScreenshotOverlay.level.rawValue + 1)

        isSaving = true
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isSaving = false
                guard response == .OK, let url = panel.url else { return }
                do {
                    try png.write(to: url, options: .atomic)
                    defaults.set(url.deletingLastPathComponent(), forKey: Self.folderKey)
                    self.close()
                } catch {
                    NSSound.beep()
                }
            }
        }
    }
}
