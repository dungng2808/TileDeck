import AVFoundation
import AudioToolbox
import CoreAudio
import ScreenCaptureKit
import os

struct ScreenRecordingRequest {
    let displayID: CGDirectDisplayID
    /// In points, from the display's top left corner.
    let region: CGRect
    let scale: CGFloat
    /// Records this window alone, wherever it moves, instead of the region.
    let windowID: CGWindowID?
    let framesPerSecond: Int
    let recordsSystemAudio: Bool
    /// Whether the microphone is on when recording starts.
    let recordsMicrophone: Bool
    /// Leaves room for the microphone so it can be switched on mid-recording.
    var canUseMicrophone = false
    /// Apps TileDeck plays at another volume. ScreenCaptureKit would record
    /// them at full volume, so their sound comes from a Core Audio tap instead.
    var replayedProcesses: [AudioObjectID] = []
}

/// Writes one region of a display to an MP4 with the hardware encoder.
/// TileDeck's own windows (the stop button, the frame) stay out of the video.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Failure: LocalizedError {
        case noDisplay
        case nothingRecorded
        case writer(String)

        var errorDescription: String? {
            switch self {
            case .noDisplay: "Không tìm thấy màn hình cần quay."
            case .nothingRecorded: "Chưa ghi được khung hình nào."
            case .writer(let reason): "Không ghi được video: \(reason)"
            }
        }
    }

    /// While muted, system sound is written as silence, so the video stays continuous.
    let systemMuted = OSAllocatedUnfairLock(initialState: false)

    /// Called when capture ends by itself, e.g. the display went away.
    var stoppedOnItsOwn: (@Sendable () -> Void)?

    private let request: ScreenRecordingRequest
    private let output: URL
    private let queue = DispatchQueue(label: "TileDeck.screenRecorder", qos: .userInteractive)

    private var stream: SCStream?
    private var microphone: AVCaptureSession?
    /// Starting and stopping the microphone can block, so it happens off the sample queue.
    private let microphoneControl = DispatchQueue(label: "TileDeck.screenRecorder.microphone", qos: .userInitiated)
    private var microphoneFiller: DispatchSourceTimer?
    private var systemTap: SystemAudioTap?
    private var isStopping = false

    // Only touched on `queue`.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var startTime: CMTime?
    private var lastFrame: CMSampleBuffer?
    private var microphoneOn = false
    /// Where the microphone track has been written up to.
    private var microphoneEnd: CMTime?

    init(request: ScreenRecordingRequest, output: URL) {
        self.request = request
        self.output = output
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let configuration = SCStreamConfiguration()
        let filter: SCContentFilter
        let size: (width: Int, height: Int)
        if let window = content.windows.first(where: { $0.windowID == request.windowID }) {
            filter = SCContentFilter(desktopIndependentWindow: window)
            size = ScreenshotGeometry.recordingSize(of: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale))
        } else {
            guard let display = content.displays.first(where: { $0.displayID == request.displayID }) else { throw Failure.noDisplay }
            let own = content.applications.filter { $0.processID == getpid() }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            size = ScreenshotGeometry.recordingSize(of: request.region.size, scale: request.scale)
            configuration.sourceRect = request.region
        }
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(request.framesPerSecond))
        configuration.queueDepth = 6
        configuration.showsCursor = true
        // With per-app volumes in play, a tap hears what the speakers do; otherwise ScreenCaptureKit is enough.
        if request.recordsSystemAudio, !request.replayedProcesses.isEmpty {
            systemTap = try? SystemAudioTap(excluding: request.replayedProcesses, queue: queue) { [weak self] sample in
                self?.appendSystem(sample)
            }
        }
        configuration.capturesAudio = request.recordsSystemAudio && systemTap == nil
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        try makeWriter(width: size.width, height: size.height, systemSampleRate: systemTap?.sampleRate ?? 48_000)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if configuration.capturesAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        self.stream = stream

        if microphoneInput != nil {
            if request.recordsMicrophone { setMicrophone(true) }
            startMicrophoneFiller()
        }
        try await stream.startCapture()
        if let systemTap, (try? systemTap.start()) == nil {
            systemTap.stop()
            self.systemTap = nil
        }
    }

    private func makeWriter(width: Int, height: Int, systemSampleRate: Double) throws {
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let pixelsPerSecond = width * height * request.framesPerSecond
        let bitRate = min(max(pixelsPerSecond / 12, 4_000_000), 40_000_000)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: request.framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: request.framesPerSecond * 2,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        videoInput = video

        if request.recordsSystemAudio {
            let input = Self.audioInput(channels: 2, bitRate: 160_000, sampleRate: systemSampleRate)
            writer.add(input)
            systemInput = input
        }
        if request.canUseMicrophone {
            let input = Self.audioInput(channels: 1, bitRate: 96_000, sampleRate: 48_000)
            writer.add(input)
            microphoneInput = input
        }
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "") }
        self.writer = writer
    }

    private static func audioInput(channels: Int, bitRate: Int, sampleRate: Double) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate,
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    /// Really turns the microphone on or off (and macOS's orange dot with it).
    func setMicrophone(_ on: Bool) {
        guard microphoneInput != nil else { return }
        queue.async { [self] in microphoneOn = on }
        microphoneControl.async { [self] in
            if on {
                guard microphone == nil else { return }
                microphone = makeMicrophoneSession()
                microphone?.startRunning()
            } else {
                microphone?.stopRunning()
                microphone = nil
            }
        }
    }

    private func makeMicrophoneSession() -> AVCaptureSession? {
        guard let device = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        let session = AVCaptureSession()
        let audio = AVCaptureAudioDataOutput()
        audio.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.microphoneRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        audio.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddInput(input), session.canAddOutput(audio) else { return nil }
        session.addInput(input)
        session.addOutput(audio)
        return session
    }

    // MARK: Keeping the microphone track continuous

    static let microphoneRate: Double = 48_000

    /// AVAssetWriter closes up gaps in an audio track, which would pull
    /// everything said after a pause too early. So while the microphone is
    /// off, silence is written in its place.
    private func startMicrophoneFiller() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            // Before the microphone is first switched on there's nothing to keep in line: its track can simply start late.
            guard let self, !microphoneOn, microphoneEnd != nil else { return }
            // A little behind the clock, so a microphone switched back on doesn't land inside the silence.
            fillMicrophone(until: CMClockGetTime(CMClockGetHostTimeClock()) - CMTime(value: 1, timescale: 10))
        }
        timer.resume()
        microphoneFiller = timer
    }

    private func fillMicrophone(until end: CMTime) {
        guard let startTime, let input = microphoneInput else { return }
        var position = microphoneEnd ?? startTime
        while end - position >= CMTime(value: 10, timescale: 1000), input.isReadyForMoreMediaData {
            let frames = min(4_800, Int(((end - position).seconds * Self.microphoneRate).rounded(.down)))
            guard let silence = Self.silentMicrophoneSample(at: position, frames: frames), input.append(silence) else { break }
            position = position + CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(Self.microphoneRate))
        }
        microphoneEnd = position
    }

    private func appendMicrophone(_ sample: CMSampleBuffer) {
        guard microphoneOn, let startTime, sample.presentationTimeStamp >= startTime else { return }
        if let microphoneEnd, sample.presentationTimeStamp < microphoneEnd { return }  // already covered by silence
        fillMicrophone(until: sample.presentationTimeStamp)
        guard let input = microphoneInput, input.isReadyForMoreMediaData, input.append(sample) else { return }
        microphoneEnd = sample.presentationTimeStamp + CMTime(value: CMTimeValue(sample.numSamples), timescale: CMTimeScale(Self.microphoneRate))
    }

    /// Silence in exactly the format the microphone is asked for.
    static func silentMicrophoneSample(at time: CMTime, frames: Int) -> CMSampleBuffer? {
        var description = AudioStreamBasicDescription(
            mSampleRate: microphoneRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        let length = frames * 4
        var block: CMBlockBuffer?
        guard frames > 0,
              CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr,
              let format,
              CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: length,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block, CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) == noErr
        else { return nil }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                             sampleCount: frames, presentationTimeStamp: time, packetDescriptions: nil,
                                                             sampleBufferOut: &sample)
        return sample
    }

    // MARK: Samples (on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sample.isValid else { return }
        switch type {
        case .screen: appendFrame(sample)
        case .audio: appendSystem(sample)
        default: break
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        appendMicrophone(sample)
    }

    private func appendSystem(_ sample: CMSampleBuffer) {
        let muted = systemMuted.withLock { $0 }
        append(muted ? Self.silenced(sample) : sample, to: systemInput)
    }

    /// The same stretch of time, with every sample at zero.
    static func silenced(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard let format = sample.formatDescription, let source = sample.dataBuffer else { return nil }
        let length = CMBlockBufferGetDataLength(source)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: length,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block, CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) == noErr
        else { return nil }
        var silent: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                             sampleCount: sample.numSamples, presentationTimeStamp: sample.presentationTimeStamp,
                                                             packetDescriptions: nil, sampleBufferOut: &silent)
        return silent
    }

    private func appendFrame(_ sample: CMSampleBuffer) {
        // Idle and blank callbacks carry no picture.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let writer, let videoInput else { return }
        if startTime == nil {
            let time = sample.presentationTimeStamp
            writer.startSession(atSourceTime: time)
            startTime = time
        }
        guard videoInput.isReadyForMoreMediaData, videoInput.append(sample) else { return }
        lastFrame = sample
    }

    private func append(_ sample: CMSampleBuffer?, to input: AVAssetWriterInput?) {
        guard let sample, let input, let startTime, sample.isValid, sample.presentationTimeStamp >= startTime, input.isReadyForMoreMediaData else { return }
        input.append(sample)
    }

    // MARK: Stopping

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !isStopping else { return }
        stoppedOnItsOwn?()
    }

    func stop() async throws -> URL {
        isStopping = true
        try? await stream?.stopCapture()
        stream = nil
        systemTap?.stop()
        systemTap = nil
        microphoneControl.sync {
            microphone?.stopRunning()
            microphone = nil
        }
        queue.sync {
            microphoneFiller?.cancel()
            microphoneFiller = nil
        }
        try await finishWriting()
        return await ScreenRecordingMixer.mergingAudioTracks(of: output)
    }

    private func finishWriting() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let writer, startTime != nil else {
                    self.writer?.cancelWriting()
                    self.writer = nil
                    continuation.resume(throwing: Failure.nothingRecorded)
                    return
                }
                repeatLastFrameUntilNow()
                [videoInput, systemInput, microphoneInput].forEach { $0?.markAsFinished() }
                self.writer = nil
                let finished = UncheckedBox(writer)
                writer.finishWriting {
                    if finished.value.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: Failure.writer(finished.value.error?.localizedDescription ?? ""))
                    }
                }
            }
        }
    }

    /// A still screen sends no frames, so without this the picture would end before the sound.
    private func repeatLastFrameUntilNow() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        guard let lastFrame, now > lastFrame.presentationTimeStamp, let videoInput, videoInput.isReadyForMoreMediaData,
              let copy = try? CMSampleBuffer(copying: lastFrame, withNewTiming: [
                  CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: now, decodeTimeStamp: .invalid),
              ]) else { return }
        videoInput.append(copy)
        self.lastFrame = nil
    }
}

/// Everything the speakers play, as sample buffers: every process except the
/// ones listed, which still includes TileDeck re-playing them at their levels.
/// Needs the "System Audio Recording" permission, which per-app volume already uses.
final class SystemAudioTap: @unchecked Sendable {
    enum Failure: Error { case tap(OSStatus), aggregate(OSStatus), format, ioProc(OSStatus) }

    let sampleRate: Double
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var format: CMAudioFormatDescription?
    private var bytesPerFrame: UInt32 = 0

    init(excluding processes: [AudioObjectID], queue: DispatchQueue, deliver: @escaping (CMSampleBuffer) -> Void) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: processes)
        description.name = "TileDeck recording"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw Failure.tap(status) }

        var streamFormat: AudioStreamBasicDescription = CA.get(tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        sampleRate = streamFormat.mSampleRate
        guard streamFormat.mFormatID == kAudioFormatLinearPCM, streamFormat.mBytesPerFrame > 0, sampleRate > 0,
              CMAudioFormatDescriptionCreate(allocator: nil, asbd: &streamFormat, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr else {
            stop()
            throw Failure.format
        }
        bytesPerFrame = streamFormat.mBytesPerFrame

        do {
            let outputID: AudioObjectID = CA.get(CA.system, kAudioHardwarePropertyDefaultOutputDevice, default: 0)
            guard let outputUID = CA.string(outputID, kAudioDevicePropertyDeviceUID) else { throw Failure.format }
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "TileDeck recording",
                kAudioAggregateDeviceUIDKey: AppVolume.aggregatePrefix + "recording." + UUID().uuidString,
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

            status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self] _, input, inputTime, output, _ in
                // This device only listens: what it would play is silence.
                for buffer in UnsafeMutableAudioBufferListPointer(output) {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                guard let sample = self?.sample(from: input, at: inputTime.pointee) else { return }
                deliver(sample)
            }
            guard status == noErr, ioProcID != nil else { throw Failure.ioProc(status) }
        } catch {
            stop()
            throw error
        }
    }

    func start() throws {
        let status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { throw Failure.ioProc(status) }
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
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Wraps one callback's audio, stamped on the host clock that video frames use too.
    private func sample(from input: UnsafePointer<AudioBufferList>, at time: AudioTimeStamp) -> CMSampleBuffer? {
        guard let format, time.mFlags.contains(.hostTimeValid),
              let first = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)).first,
              first.mDataByteSize > 0 else { return nil }
        let frames = CMItemCount(first.mDataByteSize / bytesPerFrame)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                                        presentationTimeStamp: CMClockMakeHostTimeFromSystemUnits(time.mHostTime),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: format, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr,
              let sample,
              CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                             flags: 0, bufferList: input) == noErr else { return nil }
        return sample
    }

    deinit { stop() }
}

private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Many players only play a file's first audio track, so system sound and the
/// microphone are combined into one once recording ends. The video is copied
/// as it is, so this takes moments and costs no quality.
enum ScreenRecordingMixer {
    /// The file with one audio track: a new one if tracks were merged, otherwise (or on any failure) `url`.
    static func mergingAudioTracks(of url: URL) async -> URL {
        let merged = url.deletingPathExtension().appendingPathExtension("merged.mp4")
        do {
            let asset = AVURLAsset(url: url)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            guard audio.count > 1, let video = try await asset.loadTracks(withMediaType: .video).first else { return url }
            try await merge(asset: asset, video: video, audio: audio, to: merged)
            try? FileManager.default.removeItem(at: url)
            return merged
        } catch {
            try? FileManager.default.removeItem(at: merged)
            return url
        }
    }

    private static func merge(asset: AVURLAsset, video: AVAssetTrack, audio: [AVAssetTrack], to output: URL) async throws {
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        reader.add(videoOutput)
        let format = try await video.load(.formatDescriptions).first
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        writer.add(videoInput)

        let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audio, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(audioOutput)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ])
        writer.add(audioInput)

        guard reader.startReading(), writer.startWriting() else { throw reader.error ?? writer.error ?? ScreenRecorder.Failure.nothingRecorded }
        writer.startSession(atSourceTime: .zero)

        async let videoDone: Void = copy(from: videoOutput, to: videoInput, label: "video")
        async let audioDone: Void = copy(from: audioOutput, to: audioInput, label: "audio")
        _ = await (videoDone, audioDone)

        guard reader.status == .completed else {
            writer.cancelWriting()
            throw reader.error ?? ScreenRecorder.Failure.nothingRecorded
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ScreenRecorder.Failure.nothingRecorded }
    }

    private static func copy(from output: AVAssetReaderOutput, to input: AVAssetWriterInput, label: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let pump = UncheckedBox((output, input))
            var finished = false
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "TileDeck.recordingMixer.\(label)")) {
                let (output, input) = pump.value
                while input.isReadyForMoreMediaData, !finished {
                    if let sample = output.copyNextSampleBuffer(), input.append(sample) { continue }
                    finished = true
                    input.markAsFinished()
                    continuation.resume()
                }
            }
        }
    }
}
