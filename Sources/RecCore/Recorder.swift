import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

public struct RecError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
}

/// SCStream requires its delegate at init time, before our Recorder exists,
/// so a tiny proxy forwards the stopped callback.
private final class StreamDelegateProxy: NSObject, SCStreamDelegate {
    var onStop: ((Error) -> Void)?
    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop?(error) }
}

/// Captures the main display + system audio + microphone via a single SCStream
/// and writes them into one .mov with three separate tracks (video, system
/// audio, mic). Audio is never mixed, so each track can be transcribed alone.
public final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {
    public let outputURL: URL
    public let audioOnly: Bool

    private let stream: SCStream
    private let streamDelegate = StreamDelegateProxy()
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput?
    private let systemAudioInput: AVAssetWriterInput
    private let micInput: AVAssetWriterInput

    // All sample handling runs on this one serial queue, which also
    // serializes writer state (sessionStarted / finished).
    private let queue = DispatchQueue(label: "rec.capture")
    private var sessionStarted = false
    private var finished = false
    private var startDate: Date?

    /// Called (once) if the stream dies on its own, e.g. the display sleeps
    /// or permission is revoked mid-recording.
    public var onStreamStopped: ((Error?) -> Void)?

    public init(outputURL: URL, audioOnly: Bool = false) async throws {
        self.outputURL = outputURL
        self.audioOnly = audioOnly

        // -- Pick the main display ------------------------------------------
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID })
            ?? content.displays.first
        else {
            throw RecError("No display available to capture.")
        }

        // SCDisplay reports points; ask CoreGraphics for real pixel size so
        // Retina text stays sharp.
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let pixelWidth = mode?.pixelWidth ?? display.width
        let pixelHeight = mode?.pixelHeight ?? display.height

        // -- Stream configuration -------------------------------------------
        let config = SCStreamConfiguration()
        if audioOnly {
            // SCK insists on a display filter even for audio capture; shrink
            // the (discarded) video pipeline to almost nothing.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        } else {
            config.width = pixelWidth
            config.height = pixelHeight
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        }
        config.queueDepth = 8
        config.showsCursor = true

        config.capturesAudio = true            // system audio (Chrome, etc.)
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true

        config.captureMicrophone = true        // macOS 15+: mic straight from SCK
        config.microphoneCaptureDeviceID = nil // default input device

        let filter = SCContentFilter(display: display, excludingWindows: [])
        stream = SCStream(filter: filter, configuration: config, delegate: streamDelegate)

        // -- Asset writer: 1 video + 2 audio inputs -------------------------
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        // Flush a movie fragment every 5s so a crash or force-kill still
        // leaves a recoverable file instead of an unreadable one.
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)

        // HEVC ~4 Mbps: screen content is mostly static, this lands around
        // 1.8 GB/hour at full Retina resolution and stays crisp.
        videoInput = audioOnly ? nil : AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 4_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60,
            ],
        ])

        systemAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000,
        ])

        micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ])

        for input in [videoInput, systemAudioInput, micInput].compactMap({ $0 }) {
            input.expectsMediaDataInRealTime = true
            writer.add(input)
        }

        super.init()

        streamDelegate.onStop = { [weak self] error in self?.onStreamStopped?(error) }

        if !audioOnly {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        }
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
    }

    public func start() async throws {
        guard writer.startWriting() else {
            throw RecError("Could not start writing: \(writer.error?.localizedDescription ?? "unknown")")
        }
        try await stream.startCapture()
        startDate = Date()
    }

    /// Stops capture and finalizes the file. Safe to call exactly once;
    /// callers guard against double-invocation.
    public func stopAndFinish() async throws {
        try? await stream.stopCapture()
        queue.sync { finished = true }  // drain in-flight samples, then close the gate

        guard sessionStarted else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw RecError("No frames were captured; nothing was written.")
        }

        videoInput?.markAsFinished()
        systemAudioInput.markAsFinished()
        micInput.markAsFinished()
        await writer.finishWriting()

        if writer.status == .failed {
            throw RecError("Finalizing failed: \(writer.error?.localizedDescription ?? "unknown")")
        }
    }

    public var elapsed: TimeInterval { startDate.map { Date().timeIntervalSince($0) } ?? 0 }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard !finished, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        switch type {
        case .screen:
            guard let videoInput else { return }  // audio-only mode
            // SCK sends placeholder frames (idle/blank); only keep complete ones.
            guard let info = (CMSampleBufferGetSampleAttachmentsArray(
                    sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
                let raw = info[.status] as? Int,
                SCFrameStatus(rawValue: raw) == .complete
            else { return }

            // Anchor the writer session to the first real video frame so all
            // three tracks share one timeline with no black lead-in.
            startSessionIfNeeded(at: sampleBuffer)
            append(sampleBuffer, to: videoInput)

        case .audio:
            if audioOnly { startSessionIfNeeded(at: sampleBuffer) }
            guard sessionStarted else { return }
            append(sampleBuffer, to: systemAudioInput)

        case .microphone:
            if audioOnly { startSessionIfNeeded(at: sampleBuffer) }
            guard sessionStarted else { return }
            append(sampleBuffer, to: micInput)

        @unknown default:
            break
        }
    }

    private func startSessionIfNeeded(at sampleBuffer: CMSampleBuffer) {
        guard !sessionStarted else { return }
        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        sessionStarted = true
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput) {
        // Real-time capture: if the encoder is momentarily behind, dropping a
        // sample beats blocking the capture queue.
        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }
}
