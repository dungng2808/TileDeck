import AVFoundation
import ScreenCaptureKit

struct ScreenRecordingRequest {
    let displayID: CGDirectDisplayID
    /// In points, from the display's top left corner.
    let region: CGRect
    let scale: CGFloat
    /// Records this window alone, wherever it moves, instead of the region.
    let windowID: CGWindowID?
    let framesPerSecond: Int
    let recordsSystemAudio: Bool
    let recordsMicrophone: Bool
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

    /// Called when capture ends by itself, e.g. the display went away.
    var stoppedOnItsOwn: (@Sendable () -> Void)?

    private let request: ScreenRecordingRequest
    private let output: URL
    private let queue = DispatchQueue(label: "TileDeck.screenRecorder", qos: .userInteractive)

    private var stream: SCStream?
    private var microphone: AVCaptureSession?
    private var isStopping = false

    // Only touched on `queue`.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var startTime: CMTime?
    private var lastFrame: CMSampleBuffer?

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
        configuration.capturesAudio = request.recordsSystemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        try makeWriter(width: size.width, height: size.height)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if request.recordsSystemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        self.stream = stream

        if request.recordsMicrophone { startMicrophone() }
        try await stream.startCapture()
    }

    private func makeWriter(width: Int, height: Int) throws {
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
            let input = Self.audioInput(channels: 2, bitRate: 160_000)
            writer.add(input)
            systemInput = input
        }
        if request.recordsMicrophone {
            let input = Self.audioInput(channels: 1, bitRate: 96_000)
            writer.add(input)
            microphoneInput = input
        }
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "") }
        self.writer = writer
    }

    private static func audioInput(channels: Int, bitRate: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate,
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    private func startMicrophone() {
        guard let device = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: device) else { return }
        let session = AVCaptureSession()
        let audio = AVCaptureAudioDataOutput()
        audio.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        audio.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddInput(input), session.canAddOutput(audio) else { return }
        session.addInput(input)
        session.addOutput(audio)
        session.startRunning()
        microphone = session
    }

    // MARK: Samples (on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sample.isValid else { return }
        switch type {
        case .screen: appendFrame(sample)
        case .audio: append(sample, to: systemInput)
        default: break
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        append(sample, to: microphoneInput)
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

    private func append(_ sample: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard let input, let startTime, sample.isValid, sample.presentationTimeStamp >= startTime, input.isReadyForMoreMediaData else { return }
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
        microphone?.stopRunning()
        microphone = nil
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
