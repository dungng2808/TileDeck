import AudioToolbox
import CoreAudio
import Foundation
import os

/// System output and input: which device is used and how loud. Listens for
/// changes only while the Sound tab is open.
///
/// Every Core Audio call is a round trip to coreaudiod, which is at its slowest
/// exactly while the volume is changing, so they all run on `queue`. The main
/// thread only publishes results: it also serves the keyboard event taps and
/// the sliders, and neither may wait for the audio server.
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
        var canMute = false
    }

    private struct Levels {
        var volume: Float?
        var muted = false
        var canMute = false
    }

    private struct VolumeWrite {
        let device: AudioObjectID
        let level: Float
    }

    static let shared = AudioDevices()

    /// How long a level the user just set outranks what Core Audio reports:
    /// a read from before the latest write would make the slider jump back.
    private static let settleTime: TimeInterval = 0.25
    /// Volume changes notify in bursts; one read covers the whole burst.
    private nonisolated static let burstWindow: TimeInterval = 0.015

    @Published private(set) var output = Side()
    @Published private(set) var input = Side()

    private var watchers = 0
    private var lastLocalChange = Date.distantPast
    private var settleRead: DispatchWorkItem?

    private nonisolated let queue = DispatchQueue(label: "TileDeck.audioDevices", qos: .userInitiated)
    /// Only the newest position of a dragged slider is worth writing.
    private nonisolated let pendingVolume = OSAllocatedUnfairLock<[Bool: VolumeWrite]>(initialState: [:])

    // Only touched on `queue`.
    private nonisolated(unsafe) var stopListening: [() -> Void] = []
    private nonisolated(unsafe) var deviceListeners: [() -> Void] = []
    private nonisolated(unsafe) var outputID: AudioObjectID = 0
    private nonisolated(unsafe) var inputID: AudioObjectID = 0
    private nonisolated(unsafe) var levelsReadQueued = false

    func start() {
        watchers += 1
        guard watchers == 1 else { return }
        queue.async { [self] in
            readAll()
            let changed: () -> Void = { [weak self] in self?.readAll() }
            stopListening = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice]
                .map { CA.listen(CA.system, $0, queue: queue, handler: changed) }
        }
    }

    func stop() {
        watchers = max(watchers - 1, 0)
        guard watchers == 0 else { return }
        queue.async { [self] in
            (stopListening + deviceListeners).forEach { $0() }
            stopListening = []
            deviceListeners = []
            outputID = 0
            inputID = 0
        }
    }

    func refresh() {
        queue.async { [self] in readAll() }
    }

    // MARK: Reading (on `queue`)

    private nonisolated func readAll() {
        let all = CA.objects(CA.system, kAudioHardwarePropertyDevices)
        let newOutput = Self.side(of: all, scope: kAudioDevicePropertyScopeOutput, default: kAudioHardwarePropertyDefaultOutputDevice)
        let newInput = Self.side(of: all, scope: kAudioDevicePropertyScopeInput, default: kAudioHardwarePropertyDefaultInputDevice)
        followLevels(output: newOutput.current, input: newInput.current)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.publish(output: newOutput, input: newInput) }
        }
    }

    /// Follow volume keys and other apps changing the current devices' levels.
    private nonisolated func followLevels(output newOutput: AudioObjectID, input newInput: AudioObjectID) {
        guard newOutput != outputID || newInput != inputID else { return }
        outputID = newOutput
        inputID = newInput
        deviceListeners.forEach { $0() }
        deviceListeners = []
        let changed: () -> Void = { [weak self] in self?.scheduleLevelsRead() }
        for (device, scope) in [(newOutput, kAudioDevicePropertyScopeOutput), (newInput, kAudioDevicePropertyScopeInput)] where device != 0 {
            for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] where CA.has(device, selector, scope) {
                deviceListeners.append(CA.listen(device, selector, scope: scope, queue: queue, handler: changed))
            }
        }
    }

    private nonisolated func scheduleLevelsRead() {
        guard !levelsReadQueued else { return }
        levelsReadQueued = true
        queue.asyncAfter(deadline: .now() + Self.burstWindow) { [weak self] in
            guard let self else { return }
            levelsReadQueued = false
            readLevels()
        }
    }

    private nonisolated func readLevels() {
        let outputDevice = outputID, inputDevice = inputID
        let outputLevels = Self.levels(of: outputDevice, scope: kAudioDevicePropertyScopeOutput)
        let inputLevels = Self.levels(of: inputDevice, scope: kAudioDevicePropertyScopeInput)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                var newOutput = self.output, newInput = self.input
                if newOutput.current == outputDevice { Self.apply(outputLevels, to: &newOutput) }
                if newInput.current == inputDevice { Self.apply(inputLevels, to: &newInput) }
                self.publish(output: newOutput, input: newInput)
            }
        }
    }

    private nonisolated static func side(of all: [AudioObjectID], scope: AudioObjectPropertyScope, default selector: AudioObjectPropertySelector) -> Side {
        let devices = all.compactMap { id -> Device? in
            guard !CA.objects(id, kAudioDevicePropertyStreams, scope).isEmpty,
                  let uid = CA.string(id, kAudioDevicePropertyDeviceUID),
                  // TileDeck's own per-app aggregate devices aren't real outputs.
                  !uid.hasPrefix(AppVolume.aggregatePrefix) else { return nil }
            return Device(id: id, uid: uid, name: CA.string(id, kAudioObjectPropertyName) ?? "Thiết bị \(id)")
        }
        let current: AudioObjectID = CA.get(CA.system, selector, default: 0)
        var side = Side(devices: devices, current: current)
        apply(levels(of: current, scope: scope), to: &side)
        return side
    }

    private nonisolated static func levels(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> Levels {
        guard device != 0 else { return Levels() }
        var levels = Levels()
        if CA.isSettable(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope) {
            levels.volume = Float(CA.get(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope, default: Float32(0)))
        }
        levels.muted = CA.get(device, kAudioDevicePropertyMute, scope, default: UInt32(0)) != 0
        levels.canMute = CA.isSettable(device, kAudioDevicePropertyMute, scope)
        return levels
    }

    private nonisolated static func apply(_ levels: Levels, to side: inout Side) {
        side.volume = levels.volume
        side.muted = levels.muted
        side.canMute = levels.canMute
    }

    // MARK: Publishing

    private func publish(output newOutput: Side, input newInput: Side) {
        var newOutput = newOutput, newInput = newInput
        if Date().timeIntervalSince(lastLocalChange) < Self.settleTime {
            keepLevels(of: output, in: &newOutput)
            keepLevels(of: input, in: &newInput)
        }
        store(newOutput, output: true)
        store(newInput, output: false)
    }

    private func keepLevels(of current: Side, in side: inout Side) {
        guard side.current == current.current else { return }
        side.volume = current.volume
        side.muted = current.muted
    }

    private func store(_ side: Side, output isOutput: Bool) {
        if isOutput {
            if output != side { output = side }
        } else {
            if input != side { input = side }
        }
    }

    /// Shows what the user set right away; one read after they stop confirms it.
    private func noteLocalChange() {
        lastLocalChange = Date()
        settleRead?.cancel()
        let read = DispatchWorkItem { [weak self] in self?.readLevels() }
        settleRead = read
        queue.asyncAfter(deadline: .now() + Self.settleTime + 0.05, execute: read)
    }

    // MARK: Changing things

    func select(_ device: Device, output isOutput: Bool) {
        var side = isOutput ? output : input
        side.current = device.id
        store(side, output: isOutput)
        queue.async { [self] in
            CA.set(CA.system, isOutput ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice, device.id)
            if isOutput {
                // Keep system sounds on the same device, as the Sound settings pane does.
                CA.set(CA.system, kAudioHardwarePropertyDefaultSystemOutputDevice, device.id)
            }
            readAll()
        }
    }

    func setVolume(_ value: Float, output isOutput: Bool) {
        let level = min(max(value, 0), 1)
        var side = isOutput ? output : input
        let unmute = side.muted && level > 0
        let device = side.current
        let scope = isOutput ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput
        side.volume = level
        if unmute { side.muted = false }
        store(side, output: isOutput)
        noteLocalChange()

        pendingVolume.withLock { $0[isOutput] = VolumeWrite(device: device, level: level) }
        queue.async { [self] in
            if unmute { CA.set(device, kAudioDevicePropertyMute, scope: scope, UInt32(0)) }
            guard let write = pendingVolume.withLock({ $0.removeValue(forKey: isOutput) }) else { return }
            CA.set(write.device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope, Float32(write.level))
        }
    }

    func toggleMute(output isOutput: Bool) {
        var side = isOutput ? output : input
        let device = side.current
        let muted = !side.muted
        let scope = isOutput ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput
        side.muted = muted
        store(side, output: isOutput)
        noteLocalChange()
        queue.async {
            CA.set(device, kAudioDevicePropertyMute, scope: scope, UInt32(muted ? 1 : 0))
        }
    }
}
