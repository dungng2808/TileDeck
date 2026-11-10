import AVFoundation
import XCTest
@testable import TileDeck

/// The part of screen recording that needs no screen: sizes and audio merging.
final class ScreenRecordingTests: XCTestCase {
    func testVideoSizesSuitTheEncoder() {
        let odd = ScreenshotGeometry.recordingSize(of: CGSize(width: 333.5, height: 201), scale: 2)
        XCTAssertEqual(odd.width % 2, 0)
        XCTAssertEqual(odd.height % 2, 0)
        XCTAssertEqual(odd.width, 666)

        let huge = ScreenshotGeometry.recordingSize(of: CGSize(width: 2560, height: 1440), scale: 2)
        XCTAssertLessThanOrEqual(max(huge.width, huge.height), 4096)
    }

    func testRegionIsMeasuredFromTheTop() {
        XCTAssertEqual(ScreenshotGeometry.topLeftRegion(of: CGRect(x: 10, y: 100, width: 50, height: 40), screenHeight: 600),
                       CGRect(x: 10, y: 460, width: 50, height: 40))
    }

    func testWindowBoundsBecomeOverlayFrames() {
        let onPrimary = ScreenshotGeometry.overlayFrame(ofWindowBounds: CGRect(x: 100, y: 50, width: 400, height: 300),
                                                        screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), primaryScreenHeight: 800)
        XCTAssertEqual(onPrimary, CGRect(x: 100, y: 450, width: 400, height: 300))

        let onRightDisplay = ScreenshotGeometry.overlayFrame(ofWindowBounds: CGRect(x: 1100, y: 50, width: 400, height: 300),
                                                             screenFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800), primaryScreenHeight: 800)
        XCTAssertEqual(onRightDisplay, CGRect(x: 100, y: 450, width: 400, height: 300))
    }

    func testClock() {
        XCTAssertEqual(ScreenshotGeometry.clock(5), "00:05")
        XCTAssertEqual(ScreenshotGeometry.clock(3725), "1:02:05")
    }

    func testTwoAudioTracksBecomeOneContainingBoth() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TileDeckTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mp4")
        try await writeFile(source, tones: [440, 1760])

        let merged = await ScreenRecordingMixer.mergingAudioTracks(of: source)
        XCTAssertNotEqual(merged, source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "the unmerged file is removed")

        let asset = AVURLAsset(url: merged)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1)
        let video = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(video.count, 1)

        let samples = try readSamples(asset, track: audio[0])
        XCTAssertGreaterThan(strength(of: 440, in: samples), 0.02, "first source is audible")
        XCTAssertGreaterThan(strength(of: 1760, in: samples), 0.02, "second source is audible")
    }

    func testOneAudioTrackIsLeftAlone() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TileDeckTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mp4")
        try await writeFile(source, tones: [440])
        let result = await ScreenRecordingMixer.mergingAudioTracks(of: source)
        XCTAssertEqual(result, source)
    }

    // MARK: Helpers

    private func writeFile(_ url: URL, tones: [Double]) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        let audio = tones.map { _ -> AVAssetWriterInput in
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000,
            ])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            return input
        }
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for step in 0..<20 {
            let time = CMTime(value: CMTimeValue(step) * 4800, timescale: 48_000)
            while !video.isReadyForMoreMediaData { usleep(1000) }
            XCTAssertTrue(video.append(try videoSample(at: time)))
            for (input, tone) in zip(audio, tones) {
                while !input.isReadyForMoreMediaData { usleep(1000) }
                XCTAssertTrue(input.append(try audioSample(tone: tone, startFrame: step * 4800, frames: 4800, at: time)))
            }
        }
        video.markAsFinished()
        audio.forEach { $0.markAsFinished() }
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }

    private func videoSample(at time: CMTime) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixels)
        let buffer = try XCTUnwrap(pixels)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 10), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: try XCTUnwrap(format),
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }

    private func audioSample(tone: Double, startFrame: Int, frames: Int, at time: CMTime) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let values = (0..<frames).map { Float(0.25 * sin(2 * .pi * tone * Double(startFrame + $0) / 48_000)) }
        let bytes = frames * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                           offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        let data = try XCTUnwrap(block)
        _ = values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: bytes) }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: data, formatDescription: try XCTUnwrap(format),
                                                             sampleCount: frames, presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }

    private func readSamples(_ asset: AVAsset, track: AVAssetTrack) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var chunk = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            samples += chunk
        }
        return samples
    }

    /// Amplitude of one frequency (a single DFT bin).
    private func strength(of frequency: Double, in samples: [Float]) -> Double {
        var real = 0.0, imaginary = 0.0
        for (index, sample) in samples.enumerated() {
            let phase = 2 * Double.pi * frequency * Double(index) / 48_000
            real += Double(sample) * cos(phase)
            imaginary += Double(sample) * sin(phase)
        }
        return 2 * hypot(real, imaginary) / Double(max(samples.count, 1))
    }
}
