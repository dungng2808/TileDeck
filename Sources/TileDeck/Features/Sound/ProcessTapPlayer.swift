import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

/// Plays one app's audio at a chosen gain: a Core Audio process tap captures
/// (and silences) the app's own output, and a private aggregate device made of
/// the tap plus the real speaker plays it back scaled. macOS 14.2+, needs the
/// "System Audio Recording" permission.
final class ProcessTapPlayer: @unchecked Sendable {
    enum Failure: Error {
        case tap(OSStatus), aggregate(OSStatus), ioProc(OSStatus), start(OSStatus), format
    }

    /// Written from the main thread, read on the audio thread; a single aligned Float store is atomic on Apple Silicon.
    nonisolated(unsafe) var gain: Float

    let processes: Set<AudioObjectID>
    let outputUID: String

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "TileDeck.appVolume", qos: .userInteractive)

    private var inputChannels = 2
    private var inputInterleaved = true
    private var outputChannels = 2
    private var outputInterleaved = true

    init(processes: Set<AudioObjectID>, outputUID: String, gain: Float, name: String) throws {
        self.processes = processes
        self.outputUID = outputUID
        self.gain = gain

        let description = CATapDescription(stereoMixdownOfProcesses: processes.sorted())
        description.name = "TileDeck \(name)"
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.mutedWhenTapped
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw Failure.tap(status) }

        do {
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "TileDeck \(name)",
                kAudioAggregateDeviceUIDKey: AppVolume.aggregatePrefix + UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
            status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
            guard status == noErr else { throw Failure.aggregate(status) }

            try readFormats()

            status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [unowned self] _, input, _, output, _ in
                self.render(input, output)
            }
            guard status == noErr, ioProcID != nil else { throw Failure.ioProc(status) }
            status = AudioDeviceStart(aggregateID, ioProcID)
            guard status == noErr else { throw Failure.start(status) }
        } catch {
            stop()
            throw error
        }
    }

    deinit {
        stop()
    }

    func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        // Destroying the tap un-mutes the app's own output.
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Channel count and layout of the tap (input side) and the speaker (output side).
    private func readFormats() throws {
        let tapFormat: AudioStreamBasicDescription = CA.get(tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        guard tapFormat.mFormatID == kAudioFormatLinearPCM, tapFormat.mBitsPerChannel == 32 else { throw Failure.format }
        inputChannels = Int(max(tapFormat.mChannelsPerFrame, 1))
        inputInterleaved = tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        guard let stream = CA.objects(aggregateID, kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput).first else { throw Failure.format }
        let outputFormat: AudioStreamBasicDescription = CA.get(stream, kAudioStreamPropertyVirtualFormat, default: AudioStreamBasicDescription())
        guard outputFormat.mFormatID == kAudioFormatLinearPCM, outputFormat.mBitsPerChannel == 32 else { throw Failure.format }
        outputChannels = Int(max(outputFormat.mChannelsPerFrame, 1))
        outputInterleaved = outputFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
    }

    /// Copies the tapped audio to the speaker, scaled by `gain`. Runs on the real-time audio thread: no allocation, no locks.
    private func render(_ inputList: UnsafePointer<AudioBufferList>, _ outputList: UnsafeMutablePointer<AudioBufferList>) {
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputList))
        let output = UnsafeMutableAudioBufferListPointer(outputList)
        var level = gain

        // Fast path: identical layouts, so each buffer is one vector multiply.
        if input.count == output.count, inputChannels == outputChannels, inputInterleaved == outputInterleaved {
            for index in 0..<output.count {
                guard let destination = output[index].mData else { continue }
                guard let source = input[index].mData else {
                    memset(destination, 0, Int(output[index].mDataByteSize))
                    continue
                }
                let samples = Int(min(input[index].mDataByteSize, output[index].mDataByteSize)) / MemoryLayout<Float>.size
                vDSP_vsmul(source.assumingMemoryBound(to: Float.self), 1, &level,
                           destination.assumingMemoryBound(to: Float.self), 1, vDSP_Length(samples))
            }
            return
        }

        // General path: map channel by channel, repeating the last tap channel if the speaker has more.
        let frames: Int = {
            guard let first = output.first else { return 0 }
            let perFrame = outputInterleaved ? outputChannels : 1
            return Int(first.mDataByteSize) / MemoryLayout<Float>.size / perFrame
        }()
        for channel in 0..<outputChannels {
            let sourceChannel = min(channel, inputChannels - 1)
            let (sourceBuffer, sourceOffset, sourceStride) = inputInterleaved
                ? (0, sourceChannel, inputChannels) : (sourceChannel, 0, 1)
            let (destinationBuffer, destinationOffset, destinationStride) = outputInterleaved
                ? (0, channel, outputChannels) : (channel, 0, 1)
            guard destinationBuffer < output.count, let destination = output[destinationBuffer].mData?.assumingMemoryBound(to: Float.self) else { continue }
            guard sourceBuffer < input.count, let source = input[sourceBuffer].mData?.assumingMemoryBound(to: Float.self) else {
                for frame in 0..<frames { destination[destinationOffset + frame * destinationStride] = 0 }
                continue
            }
            let available = Int(input[sourceBuffer].mDataByteSize) / MemoryLayout<Float>.size
            for frame in 0..<frames {
                let at = sourceOffset + frame * sourceStride
                destination[destinationOffset + frame * destinationStride] = at < available ? source[at] * level : 0
            }
        }
    }
}
