import AVFoundation
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Screen recording on ⌘⇧2: pick an area or the whole display, record it with
/// system sound and optionally the microphone, press ⌘⇧2 again to stop.
@MainActor
final class ScreenRecordTool: ObservableObject {
    enum Phase: Equatable {
        case idle
        case selecting
        case starting
        case recording(since: Date)
        case saving
    }

    static let shared = ScreenRecordTool()
    private static let enabledKey = "screenRecord"
    private static let systemAudioKey = "screenRecordSystemAudio"
    private static let microphoneKey = "screenRecordMicrophone"
    private static let framesKey = "screenRecordFPS"
    private static let folderKey = "screenRecordFolder"
    private static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var phase = Phase.idle
    @Published private(set) var recordsSystemAudio: Bool
    @Published private(set) var recordsMicrophone: Bool
    @Published private(set) var framesPerSecond: Int
    @Published private(set) var folder: URL
    @Published private(set) var hasSelection = false

    private var hotKey: UInt32?
    private var overlays: [ScreenshotOverlay] = []
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var recorder: ScreenRecorder?
    private let hud = ScreenRecordHUD()
    private let options = ScreenCaptureOptions.shared

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        recordsSystemAudio = defaults.object(forKey: Self.systemAudioKey) as? Bool ?? true
        let wantsMicrophone = defaults.bool(forKey: Self.microphoneKey)
        recordsMicrophone = wantsMicrophone && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        framesPerSecond = defaults.object(forKey: Self.framesKey) as? Int ?? 30
        folder = defaults.url(forKey: Self.folderKey)
            ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
    }

    var isBusy: Bool { phase != .idle }
    var microphoneDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }

    func activateIfNeeded() {
        if isEnabled { registerHotKey() }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            registerHotKey()
            if !WindowSwitcher.shared.hasScreenRecording { WindowSwitcher.shared.requestScreenRecording() }
        } else {
            if let hotKey { HotKeys.shared.unregister([hotKey]) }
            hotKey = nil
            if phase == .selecting { cancelSelection() }
        }
    }

    private func registerHotKey() {
        guard hotKey == nil else { return }
        hotKey = HotKeys.shared.register(keyCode: kVK_ANSI_2, modifiers: cmdKey | shiftKey) { [weak self] in
            self?.shortcutPressed()
        }
    }

    private func shortcutPressed() {
        switch phase {
        case .idle: beginSelection()
        case .recording: stop()
        case .selecting, .starting, .saving: break
        }
    }

    // MARK: Options

    func setSystemAudio(_ enabled: Bool) {
        recordsSystemAudio = enabled
        UserDefaults.standard.set(enabled, forKey: Self.systemAudioKey)
    }

    func setFramesPerSecond(_ value: Int) {
        framesPerSecond = value
        UserDefaults.standard.set(value, forKey: Self.framesKey)
    }

    func setMicrophone(_ enabled: Bool) {
        guard enabled else {
            storeMicrophone(false)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            storeMicrophone(true)
        case .notDetermined:
            // macOS's question must not end up underneath the selection overlay.
            overlays.forEach { $0.level = .normal }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.overlays.forEach { $0.level = ScreenshotOverlay.level }
                        self.storeMicrophone(granted)
                    }
                }
            }
        default:
            if phase == .selecting { cancelSelection() }
            NSWorkspace.shared.open(URL(string: Self.settingsURL + "Privacy_Microphone")!)
        }
    }

    private func storeMicrophone(_ enabled: Bool) {
        recordsMicrophone = enabled
        UserDefaults.standard.set(enabled, forKey: Self.microphoneKey)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Chọn"
        NSApp.activate()
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else { return }
                self.folder = url
                UserDefaults.standard.set(url, forKey: Self.folderKey)
            }
        }
    }

    // MARK: Choosing the area

    func beginSelection(returningTo app: NSRunningApplication? = nil) {
        guard phase == .idle, !ScreenshotTool.shared.isOpen else { return }
        guard WindowSwitcher.shared.hasScreenRecording else {
            WindowSwitcher.shared.requestScreenRecording()
            return
        }
        phase = .selecting
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = app ?? (front?.processIdentifier == getpid() ? nil : front)
        NSApp.activate()

        let bar = AnyView(ScreenCaptureModeBar(options: options, isRecording: true,
                                               chooseAction: { [weak self] recording in if !recording { self?.switchToScreenshot() } },
                                               chooseMode: { [weak self] mode in self?.setMode(mode) }))
        overlays = NSScreen.screens.map { screen in
            ScreenshotOverlay(
                screen: screen, image: nil, palette: ScreenshotPalette(), verb: "quay", placement: .bottomCenter,
                options: options, modeBar: bar,
                mayStartSelection: { _ in true },
                selectionStarted: { [weak self] overlay in self?.clearSelections(except: overlay) },
                toolbar: ScreenRecordToolbar(
                    tool: self,
                    start: { [weak self] in self?.startRecording() },
                    close: { [weak self] in self?.cancelSelection() }
                )
            )
        }
        overlays.forEach { $0.selectionChanged = { [weak self] in self?.updateHasSelection() } }
        updateHasSelection()
        overlays.forEach { $0.orderFrontRegardless() }
        (overlays.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? overlays.first)?.makeKey()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
        selectScreenIfNeeded()
    }

    private func setMode(_ mode: ScreenCaptureMode) {
        guard options.mode != mode else { return }
        options.mode = mode
        overlays.forEach { $0.modeChanged() }
        selectScreenIfNeeded()
    }

    private func selectScreenIfNeeded() {
        guard options.mode == .fullScreen else { return }
        (overlays.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? overlays.first)?.selectAll()
    }

    private func updateHasSelection() {
        let selected = overlays.contains(where: \.hasSelection)
        if hasSelection != selected { hasSelection = selected }
    }

    private func switchToScreenshot() {
        let app = previousApp
        previousApp = nil
        ScreenshotTool.shared.begin(returningTo: app, replacing: { [weak self] in
            self?.closeOverlays()
            self?.phase = .idle
        })
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape: cancelSelection()
        case kVK_Return, kVK_ANSI_KeypadEnter: startRecording()
        default: break
        }
        return true
    }

    private func clearSelections(except overlay: ScreenshotOverlay) {
        overlays.filter { $0 !== overlay }.forEach { $0.clearSelection() }
    }

    private func closeOverlays() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        hasSelection = false
        previousApp?.activate()
        previousApp = nil
    }

    private func cancelSelection() {
        closeOverlays()
        phase = .idle
    }

    // MARK: Recording

    private func startRecording() {
        guard phase == .selecting, let selected = overlays.first(where: \.hasSelection), let local = selected.selectionRect,
              let displayID = selected.targetScreen.displayID else { return }
        let screen = selected.targetScreen
        let windowID = selected.selectedWindowID
        // A window can move during the recording, so a fixed outline would mislead.
        let showsOutline = windowID == nil && local.size != screen.frame.size

        let request = ScreenRecordingRequest(
            displayID: displayID,
            region: ScreenshotGeometry.topLeftRegion(of: local, screenHeight: screen.frame.height),
            scale: screen.backingScaleFactor,
            windowID: windowID,
            framesPerSecond: framesPerSecond,
            recordsSystemAudio: recordsSystemAudio,
            recordsMicrophone: recordsMicrophone
        )
        closeOverlays()
        phase = .starting

        let output = FileManager.default.temporaryDirectory.appendingPathComponent("TileDeck-\(UUID().uuidString).mp4")
        let recorder = ScreenRecorder(request: request, output: output)
        recorder.stoppedOnItsOwn = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.stop() }
            }
        }
        self.recorder = recorder
        Task {
            do {
                try await recorder.start()
                let since = Date()
                phase = .recording(since: since)
                hud.show(on: screen, region: showsOutline ? local.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY) : nil, tool: self)
            } catch {
                self.recorder = nil
                phase = .idle
                ScreenRecordToast.shared.showFailure(error.localizedDescription)
            }
        }
    }

    func stop() {
        guard case .recording(let since) = phase, let recorder else { return }
        phase = .saving
        let duration = Date().timeIntervalSince(since)
        Task {
            do {
                let recorded = try await recorder.stop()
                finish(recorded, duration: duration)
            } catch {
                ScreenRecordToast.shared.showFailure(error.localizedDescription)
            }
            self.recorder = nil
            hud.close()
            phase = .idle
        }
    }

    /// Lets a quit wait for the video instead of losing it.
    func stopForQuit(then done: @escaping () -> Void) {
        guard case .recording = phase else {
            done()
            return
        }
        stop()
        Task {
            while isBusy { try? await Task.sleep(for: .milliseconds(50)) }
            done()
        }
    }

    private func finish(_ recorded: URL, duration: TimeInterval) {
        let name = ScreenshotGeometry.fileName(for: Date(), prefix: "Video", extension: "mp4")
        let destination = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: recorded, to: destination)
            ScreenRecordToast.shared.showSaved(destination, duration: duration, note: nil)
        } catch {
            ScreenRecordToast.shared.showSaved(recorded, duration: duration, note: "Không lưu được vào \(folder.lastPathComponent), video đang ở thư mục tạm.")
        }
    }
}
