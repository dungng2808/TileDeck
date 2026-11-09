import AppKit
import CoreAudio
import os

private let log = Logger(subsystem: "com.dungng.tiledeck", category: "AppVolume")

/// Per-app volume. Apps left at 100 % cost nothing; any other level gets a
/// ProcessTapPlayer that re-plays the app's audio scaled. Levels are kept per
/// bundle ID and reapplied whenever the app (or the output device) changes.
/// Core Audio calls and tap setup run on `queue`, never on the main thread.
@MainActor
final class AppVolume: ObservableObject {
    struct App: Identifiable, Equatable {
        let id: String  // the app's bundle ID
        let name: String
        let pid: pid_t
        let processes: Set<AudioObjectID>
        let isPlaying: Bool
    }

    static let shared = AppVolume()
    nonisolated static let aggregatePrefix = "com.dungng.tiledeck.appvolume."
    private static let levelsKey = "appVolumeLevels"
    private static let mutedKey = "appVolumeMuted"
    private nonisolated static let captureWorkedKey = "appVolumeCaptureWorked"

    @Published private(set) var apps: [App] = []
    @Published private(set) var levels: [String: Float]
    @Published private(set) var muted: Set<String>
    @Published private(set) var lastError: String?
    /// Something else rerouting app audio would fight TileDeck over the same streams.
    @Published private(set) var otherMixer: String?

    private var listeners: [() -> Void] = []
    private var playingTimer: Timer?
    private var watchers = 0
    private var refreshRunning = false
    private var refreshAgain = false
    private var pendingSave: DispatchWorkItem?
    private var icons: [String: NSImage] = [:]

    /// What to play each app at.
    private struct Mix {
        let apps: [App]
        let gains: [String: Float]
    }

    private struct RunningApp {
        let pid: pid_t
        let bundleID: String
        let name: String?
    }

    private nonisolated let queue = DispatchQueue(label: "TileDeck.appVolume.control", qos: .userInitiated)
    /// Only the newest mix is worth applying while a slider is being dragged.
    private nonisolated let pendingMix = OSAllocatedUnfairLock<Mix?>(initialState: nil)
    /// Only touched on `queue`.
    private nonisolated(unsafe) var players: [String: ProcessTapPlayer] = [:]

    private init() {
        let defaults = UserDefaults.standard
        levels = (defaults.dictionary(forKey: Self.levelsKey) as? [String: Double])?.mapValues(Float.init) ?? [:]
        muted = Set(defaults.stringArray(forKey: Self.mutedKey) ?? [])
    }

    func level(for app: String) -> Float { levels[app] ?? 1 }

    private var hasAdjustments: Bool {
        !muted.isEmpty || levels.values.contains { $0 != 1 }
    }

    func icon(for app: App) -> NSImage {
        if let icon = icons[app.id] { return icon }
        let icon = NSRunningApplication(processIdentifier: app.pid)?.icon ?? NSImage()
        icons[app.id] = icon
        return icon
    }

    // MARK: Lifecycle

    func activateIfNeeded() {
        guard hasAdjustments else { return }
        listen()
        refresh()
    }

    /// The Sound tab opened: also keep the "playing" dots fresh.
    func start() {
        watchers += 1
        listen()
        refresh()
        guard playingTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        playingTimer = timer
    }

    func stop() {
        watchers = max(watchers - 1, 0)
        guard watchers == 0 else { return }
        playingTimer?.invalidate()
        playingTimer = nil
        if !hasAdjustments { unlisten() }
    }

    /// The taps must be gone before the process is: they mute the apps they capture.
    func stopAll() {
        saveNow()
        pendingMix.withLock { $0 = nil }
        queue.sync {
            players.values.forEach { $0.stop() }
            players.removeAll()
        }
    }

    private func listen() {
        guard listeners.isEmpty else { return }
        listeners = [
            // Apps opening or closing audio streams, and the speaker changing, both need the taps rebuilt.
            CA.listen(CA.system, kAudioHardwarePropertyProcessObjectList) { [weak self] in MainActor.assumeIsolated { self?.refresh() } },
            CA.listen(CA.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in MainActor.assumeIsolated { self?.refresh() } },
        ]
    }

    private func unlisten() {
        listeners.forEach { $0() }
        listeners = []
    }

    // MARK: Changing levels

    func setLevel(_ value: Float, for app: String) {
        levels[app] = min(max(value, 0), 1)
        if value > 0 && muted.contains(app) { muted.remove(app) }
        saveSoon()
        if hasAdjustments { listen() }
        reconcile()
    }

    func toggleMute(_ app: String) {
        if muted.contains(app) { muted.remove(app) } else { muted.insert(app) }
        saveNow()
        if hasAdjustments { listen() }
        reconcile()
    }

    /// A dragged slider changes many times a second; only where it stops matters.
    private func saveSoon() {
        pendingSave?.cancel()
        let save = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        pendingSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: save)
    }

    private func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        UserDefaults.standard.set(levels.mapValues(Double.init), forKey: Self.levelsKey)
        UserDefaults.standard.set(Array(muted), forKey: Self.mutedKey)
    }

    // MARK: Permission

    enum CapturePermission { case granted, denied, notDetermined }

    /// "System Audio Recording" has no public status API. The TCC preflight
    /// call answers it (0 granted, 1 denied, 2 not asked yet); if that call is
    /// unavailable, a tap that once worked on this Mac is taken as permission.
    static var capturePermission: CapturePermission {
        if let preflight = tccPreflight {
            switch preflight("kTCCServiceAudioCapture" as CFString, nil) {
            case 0: return .granted
            case 1: return .denied
            default: return .notDetermined
            }
        }
        return UserDefaults.standard.bool(forKey: captureWorkedKey) ? .granted : .notDetermined
    }

    /// Asks macOS to show the permission prompt: creating any process tap
    /// triggers it, so tap TileDeck's own (silent) audio and drop it again.
    static func requestCapturePermission() {
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var address = CA.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(CA.system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object) == noErr,
              object != kAudioObjectUnknown else { return }
        let description = CATapDescription(stereoMixdownOfProcesses: [object])
        description.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        if AudioHardwareCreateProcessTap(description, &tap) == noErr {
            AudioHardwareDestroyProcessTap(tap)
            UserDefaults.standard.set(true, forKey: captureWorkedKey)
        }
    }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private static let tccPreflight: Preflight? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_LAZY),
              let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: Preflight.self)
    }()

    // MARK: Apps and taps

    func refresh() {
        guard !refreshRunning else {
            refreshAgain = true
            return
        }
        refreshRunning = true
        let running = NSWorkspace.shared.runningApplications
        let mixers = ["SoundFlow", "SoundSource", "Background Music", "eqMac"]
        let mixer = running.first { mixers.contains($0.localizedName ?? "") }?.localizedName
        if otherMixer != mixer { otherMixer = mixer }
        let regular = running.compactMap { app -> RunningApp? in
            guard app.activationPolicy == .regular, let bundleID = app.bundleIdentifier else { return nil }
            return RunningApp(pid: app.processIdentifier, bundleID: bundleID, name: app.localizedName)
        }
        queue.async { [weak self] in
            let found = Self.audioApps(among: regular)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.refreshed(found) }
            }
        }
    }

    private func refreshed(_ found: [App]) {
        refreshRunning = false
        if apps != found { apps = found }
        reconcile()
        if refreshAgain {
            refreshAgain = false
            refresh()
        }
    }

    private func reconcile() {
        let gains = Dictionary(apps.map { ($0.id, muted.contains($0.id) ? 0 : level(for: $0.id)) }, uniquingKeysWith: { first, _ in first })
        let mix = Mix(apps: apps, gains: gains)
        pendingMix.withLock { $0 = mix }
        queue.async { [weak self] in self?.applyPendingMix() }
    }

    private nonisolated func applyPendingMix() {
        guard let mix = pendingMix.withLock({ pending -> Mix? in
            defer { pending = nil }
            return pending
        }) else { return }
        let outputID: AudioObjectID = CA.get(CA.system, kAudioHardwarePropertyDefaultOutputDevice, default: 0)
        guard let outputUID = CA.string(outputID, kAudioDevicePropertyDeviceUID) else { return }
        var failure: String?

        for app in mix.apps {
            let gain = mix.gains[app.id] ?? 1
            if gain == 1 {
                players.removeValue(forKey: app.id)?.stop()
                continue
            }
            if let player = players[app.id], player.processes == app.processes, player.outputUID == outputUID {
                player.gain = gain
                continue
            }
            players.removeValue(forKey: app.id)?.stop()
            do {
                players[app.id] = try ProcessTapPlayer(processes: app.processes, outputUID: outputUID, gain: gain, name: app.name)
                UserDefaults.standard.set(true, forKey: Self.captureWorkedKey)
                log.info("tap on \(app.id, privacy: .public): \(app.processes.count) processes, gain \(gain)")
            } catch {
                log.error("tap failed for \(app.id, privacy: .public): \(String(describing: error), privacy: .public)")
                failure = "Không chỉnh được âm lượng \(app.name). Hãy cho phép TileDeck trong Cài đặt › Quyền riêng tư & Bảo mật › Ghi âm thanh hệ thống."
            }
        }
        // Apps that stopped using audio altogether.
        for id in players.keys where !mix.apps.contains(where: { $0.id == id }) {
            players.removeValue(forKey: id)?.stop()
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.lastError != failure else { return }
                self.lastError = failure
            }
        }
    }

    /// Audio process objects grouped by the app they belong to: Chrome plays
    /// through "Google Chrome Helper", Safari through a shared WebKit process.
    private nonisolated static func audioApps(among regular: [RunningApp]) -> [App] {
        let me = getpid()
        let byPID = Dictionary(regular.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

        var grouped: [String: (app: RunningApp, processes: Set<AudioObjectID>, playing: Bool)] = [:]
        for object in CA.objects(CA.system, kAudioHardwarePropertyProcessObjectList) {
            let pid: pid_t = CA.get(object, kAudioProcessPropertyPID, default: pid_t(0))
            guard pid > 0, pid != me else { continue }
            let bundleID = CA.string(object, kAudioProcessPropertyBundleID) ?? ""
            let owner = byPID[pid]
                ?? regular.filter { bundleID.hasPrefix($0.bundleID + ".") }.max { $0.bundleID.count < $1.bundleID.count }
                ?? responsiblePID(pid).flatMap { byPID[$0] }
            guard let owner else { continue }
            let id = owner.bundleID
            let playing: UInt32 = CA.get(object, kAudioProcessPropertyIsRunningOutput, default: 0)
            var entry = grouped[id] ?? (owner, [], false)
            entry.processes.insert(object)
            entry.playing = entry.playing || playing != 0
            grouped[id] = entry
        }
        return grouped.map { id, entry in
            App(id: id, name: entry.app.name ?? id, pid: entry.app.pid,
                processes: entry.processes, isPlaying: entry.playing)
        }
        .sorted { lhs, rhs in
            lhs.isPlaying != rhs.isPlaying ? lhs.isPlaying : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private typealias ResponsiblePID = @convention(c) (pid_t) -> pid_t
    private nonisolated static let responsibleFunction: ResponsiblePID? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsiblePID.self)
    }()

    /// The app a helper process works for (e.g. Safari for its WebKit media process).
    private nonisolated static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let responsible = responsibleFunction?(pid), responsible > 0, responsible != pid else { return nil }
        return responsible
    }
}
