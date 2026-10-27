import AudioToolbox
import CoreAudio
import Foundation

/// System output and input: which device is used and how loud. Listens for
/// changes only while the Sound tab is open.
@MainActor
final class AudioDevices: ObservableObject {
    struct Device: Identifiable, Equatable, Hashable {
        let id: AudioObjectID
        let uid: String
        let name: String
    }

    struct Side: Equatable {
        var devices: [Device] = []
        var current: AudioObjectID = 0
        /// nil when the device has no software volume (e.g. most HDMI displays).
        var volume: Float?
        var muted = false
    }

    static let shared = AudioDevices()

    @Published private(set) var output = Side()
    @Published private(set) var input = Side()

    private var stopListening: [() -> Void] = []
    private var deviceListeners: [() -> Void] = []
    private var watchers = 0

    func start() {
        watchers += 1
        guard watchers == 1 else { return }
        refresh()
        stopListening = [
            CA.listen(CA.system, kAudioHardwarePropertyDevices) { [weak self] in MainActor.assumeIsolated { self?.refresh() } },
            CA.listen(CA.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in MainActor.assumeIsolated { self?.refresh() } },
            CA.listen(CA.system, kAudioHardwarePropertyDefaultInputDevice) { [weak self] in MainActor.assumeIsolated { self?.refresh() } },
        ]
    }

    func stop() {
        watchers = max(watchers - 1, 0)
        guard watchers == 0 else { return }
        (stopListening + deviceListeners).forEach { $0() }
        stopListening = []
        deviceListeners = []
    }

    func refresh() {
        let all = CA.objects(CA.system, kAudioHardwarePropertyDevices)
        output = side(of: all, scope: kAudioDevicePropertyScopeOutput, default: kAudioHardwarePropertyDefaultOutputDevice)
        input = side(of: all, scope: kAudioDevicePropertyScopeInput, default: kAudioHardwarePropertyDefaultInputDevice)

        // Follow volume keys and other apps changing the current devices' levels.
        deviceListeners.forEach { $0() }
        deviceListeners = []
        for (device, scope) in [(output.current, kAudioDevicePropertyScopeOutput), (input.current, kAudioDevicePropertyScopeInput)] where device != 0 {
            for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] where CA.has(device, selector, scope) {
                deviceListeners.append(CA.listen(device, selector, scope: scope) { [weak self] in
                    MainActor.assumeIsolated { self?.refreshLevels() }
                })
            }
        }
    }

    private func refreshLevels() {
        output.volume = Self.volume(of: output.current, scope: kAudioDevicePropertyScopeOutput)
        output.muted = Self.muted(output.current, scope: kAudioDevicePropertyScopeOutput)
        input.volume = Self.volume(of: input.current, scope: kAudioDevicePropertyScopeInput)
        input.muted = Self.muted(input.current, scope: kAudioDevicePropertyScopeInput)
    }

    private func side(of all: [AudioObjectID], scope: AudioObjectPropertyScope, default selector: AudioObjectPropertySelector) -> Side {
        let devices = all.compactMap { id -> Device? in
            guard !CA.objects(id, kAudioDevicePropertyStreams, scope).isEmpty,
                  let uid = CA.string(id, kAudioDevicePropertyDeviceUID),
                  // TileDeck's own per-app aggregate devices aren't real outputs.
                  !uid.hasPrefix(AppVolume.aggregatePrefix) else { return nil }
            return Device(id: id, uid: uid, name: CA.string(id, kAudioObjectPropertyName) ?? "Thiết bị \(id)")
        }
        let current: AudioObjectID = CA.get(CA.system, selector, default: 0)
        return Side(devices: devices, current: current,
                    volume: Self.volume(of: current, scope: scope), muted: Self.muted(current, scope: scope))
    }

    // MARK: Changing things

    func select(_ device: Device, output isOutput: Bool) {
        CA.set(CA.system, isOutput ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice, device.id)
        if isOutput {
            // Keep system sounds on the same device, as the Sound settings pane does.
            CA.set(CA.system, kAudioHardwarePropertyDefaultSystemOutputDevice, device.id)
        }
        refresh()
    }

    func setVolume(_ value: Float, output isOutput: Bool) {
        let side = isOutput ? output : input
        let scope = isOutput ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput
        CA.set(side.current, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope, Float32(min(max(value, 0), 1)))
        if side.muted && value > 0 { CA.set(side.current, kAudioDevicePropertyMute, scope: scope, UInt32(0)) }
        refreshLevels()
    }

    func toggleMute(output isOutput: Bool) {
        let side = isOutput ? output : input
        let scope = isOutput ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput
        CA.set(side.current, kAudioDevicePropertyMute, scope: scope, UInt32(side.muted ? 0 : 1))
        refreshLevels()
    }

    func canMute(output isOutput: Bool) -> Bool {
        let side = isOutput ? output : input
        return CA.isSettable(side.current, kAudioDevicePropertyMute, isOutput ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput)
    }

    private static func volume(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> Float? {
        guard device != 0, CA.isSettable(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope) else { return nil }
        return Float(CA.get(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope, default: Float32(0)))
    }

    private static func muted(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        device != 0 && CA.get(device, kAudioDevicePropertyMute, scope, default: UInt32(0)) != 0
    }
}
