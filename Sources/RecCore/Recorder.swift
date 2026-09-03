import AVFoundation
import CoreGraphics
import CoreImage
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

/// A capturable on-screen window, as listed by `Recorder.availableWindows()`.
public struct CaptureWindow: Identifiable, Hashable, Sendable {
    public let id: CGWindowID
    public let title: String
    public let appName: String
    public let frame: CGRect

    public var label: String { title.isEmpty ? appName : "\(appName) — \(title)" }
}

public enum AudioLevelTrack: Sendable, Hashable {
    case system, microphone
}

/// An audio input device selectable for the mic track.
public struct CaptureMicrophone: Identifiable, Hashable, Sendable {
    public let id: String      // AVCaptureDevice.uniqueID, as SCK expects
    public let name: String
}

/// What to capture: the whole main display, or one window. Window capture
/// also narrows system audio to just the app that owns the window, so other
/// apps' sounds stay out of the recording.
public enum CaptureSource {
    case display
    case window(CaptureWindow)
    /// A filter chosen in the system content picker (window, app, or display).
    case filter(SCContentFilter, label: String)

    public var label: String {
        switch self {
        case .display: return "Entire display"
        case .window(let window): return window.label
        case .filter(_, let label): return label
        }
    }
}

extension SCContentFilter {
    /// Human-readable description of what a picker-chosen filter captures.
    public var recDescription: String {
        switch style {
        case .display:
            return "Entire display"
        case .window:
            if let window = includedWindows.first {
                let app = window.owningApplication?.applicationName ?? "Window"
                let title = window.title ?? ""
                return title.isEmpty ? app : "\(app) — \(title)"
            }
            return "Window"
        case .application:
            let names = includedApplications.map(\.applicationName)
            return names.isEmpty ? "Application" : names.joined(separator: ", ") + " (all windows)"
        default:
            return "Selected content"
        }
    }
}

/// Captures the main display (or one window) + system audio + microphone via
/// a single SCStream and writes them into one .mov with three separate tracks
/// (video, system audio, mic). Audio is never mixed, so each track can be
/// transcribed alone.
public final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {
    public let outputURL: URL
    public let audioOnly: Bool
    public let source: CaptureSource
    public let microphone: CaptureMicrophone?

    /// Microphones available right now (built-in, USB, AirPods…), with the
    /// system default input first.
    public static func availableMicrophones() -> [CaptureMicrophone] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        return session.devices
            .map { CaptureMicrophone(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { ($0.id == defaultID ? 0 : 1) < ($1.id == defaultID ? 0 : 1) }
    }

    /// On-screen windows worth offering as capture targets (real app windows
    /// with a size, skipping menu bar items, overlays and tiny helpers).
    public static func availableWindows() async throws -> [CaptureWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true)
        return content.windows.compactMap { window in
            guard let app = window.owningApplication,
                  window.windowLayer == 0,
                  window.frame.width >= 200, window.frame.height >= 150,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier
            else { return nil }
            return CaptureWindow(id: window.windowID, title: window.title ?? "",
                                 appName: app.applicationName, frame: window.frame)
        }
        .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
    }

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

    /// Receives a small snapshot (≈320 px wide) of the frames being written,
    /// about once per second — a "you're recording the right thing" preview.
    /// Called on the capture queue.
    public var onPreviewFrame: ((CGImage) -> Void)?

    /// Live audio levels (dBFS, roughly −60…0) for each audio track, emitted
    /// at ~10 Hz from the same samples being written. Called on the capture queue.
    public var onAudioLevel: ((AudioLevelTrack, Float) -> Void)?
    private var lastLevelEmit: [AudioLevelTrack: CFAbsoluteTime] = [:]
    private var levelPeak: [AudioLevelTrack: Float] = [:]
    private var lastPreviewTime = CMTime.zero
    private let previewContext = CIContext(options: [.cacheIntermediates: false])

    public init(outputURL: URL, audioOnly: Bool = false,
                source: CaptureSource = .display,
                microphone: CaptureMicrophone? = nil) async throws {
        self.outputURL = outputURL
        self.audioOnly = audioOnly
        self.source = source
        self.microphone = microphone

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
        let scale = Double(mode?.pixelWidth ?? display.width) / Double(display.width)

        // -- Content filter + output size -----------------------------------
        let filter: SCContentFilter
        let pixelWidth: Int
        let pixelHeight: Int
        switch source {
        case .display:
            filter = SCContentFilter(display: display, excludingWindows: [])
            pixelWidth = mode?.pixelWidth ?? display.width
            pixelHeight = mode?.pixelHeight ?? display.height
        case .window(let target):
            guard let window = content.windows.first(where: { $0.windowID == target.id }) else {
                throw RecError("Window \"\(target.label)\" is no longer available.")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            // HEVC needs even dimensions.
            pixelWidth = max(2, Int(window.frame.width * scale) & ~1)
            pixelHeight = max(2, Int(window.frame.height * scale) & ~1)
        case .filter(let picked, _):
            filter = picked
            let pickedScale = Double(picked.pointPixelScale)
            pixelWidth = max(2, Int(picked.contentRect.width * pickedScale) & ~1)
            pixelHeight = max(2, Int(picked.contentRect.height * pickedScale) & ~1)
        }

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
        config.microphoneCaptureDeviceID = microphone?.id  // nil = system default input

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
            emitPreviewIfDue(sampleBuffer)

        case .audio:
            emitLevelIfDue(sampleBuffer, track: .system)
            if audioOnly { startSessionIfNeeded(at: sampleBuffer) }
            guard sessionStarted else { return }
            append(sampleBuffer, to: systemAudioInput)

        case .microphone:
            emitLevelIfDue(sampleBuffer, track: .microphone)
            if audioOnly { startSessionIfNeeded(at: sampleBuffer) }
            guard sessionStarted else { return }
            append(sampleBuffer, to: micInput)

        @unknown default:
            break
        }
    }

    /// RMS level of one audio sample buffer in dBFS, or nil if the format is
    /// unexpected. Handles the PCM layouts SCK produces (Float32 / Int16,
    /// interleaved or planar).
    private func rmsLevel(of sampleBuffer: CMSampleBuffer) -> Float? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        else { return nil }

        var listSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: nil)
        guard listSize > 0 else { return nil }
        let listMemory = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: 16)
        defer { listMemory.deallocate() }
        let list = listMemory.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list,
            bufferListSize: listSize, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer) == noErr
        else { return nil }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        var sum = 0.0
        var count = 0
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            guard let data = buffer.mData else { continue }
            if isFloat, asbd.mBitsPerChannel == 32 {
                let samples = data.assumingMemoryBound(to: Float.self)
                let n = Int(buffer.mDataByteSize) / 4
                for i in 0..<n { sum += Double(samples[i] * samples[i]) }
                count += n
            } else if !isFloat, asbd.mBitsPerChannel == 16 {
                let samples = data.assumingMemoryBound(to: Int16.self)
                let n = Int(buffer.mDataByteSize) / 2
                for i in 0..<n { let v = Double(samples[i]) / 32768; sum += v * v }
                count += n
            } else if !isFloat, asbd.mBitsPerChannel == 24 {
                // Packed 24-bit little-endian signed — what SCK uses for the mic.
                let bytes = data.assumingMemoryBound(to: UInt8.self)
                let n = Int(buffer.mDataByteSize) / 3
                for i in 0..<n {
                    let raw = Int32(bytes[i * 3]) | Int32(bytes[i * 3 + 1]) << 8 | Int32(bytes[i * 3 + 2]) << 16
                    let signed = raw >= 0x80_0000 ? raw - 0x100_0000 : raw   // sign-extend
                    let v = Double(signed) / 8_388_608
                    sum += v * v
                }
                count += n
            } else if !isFloat, asbd.mBitsPerChannel == 32 {
                let samples = data.assumingMemoryBound(to: Int32.self)
                let n = Int(buffer.mDataByteSize) / 4
                for i in 0..<n { let v = Double(samples[i]) / 2_147_483_648; sum += v * v }
                count += n
            }
        }
        guard count > 0 else { return nil }
        return Float(20 * log10(max(sqrt(sum / Double(count)), 1e-6)))
    }

    private func emitLevelIfDue(_ sampleBuffer: CMSampleBuffer, track: AudioLevelTrack) {
        guard let onAudioLevel else { return }
        if ProcessInfo.processInfo.environment["REC_DEBUG_AUDIO"] != nil, lastLevelEmit[track] == nil {
            let asbd = CMSampleBufferGetFormatDescription(sampleBuffer)
                .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            let data = CMSampleBufferGetDataBuffer(sampleBuffer)
            print("[debug] \(track): samples=\(CMSampleBufferGetNumSamples(sampleBuffer)) ready=\(CMSampleBufferDataIsReady(sampleBuffer)) hasBlock=\(data != nil) asbd=\(asbd.map { "flags=0x\(String($0.mFormatFlags, radix: 16)) bits=\($0.mBitsPerChannel) ch=\($0.mChannelsPerFrame) rate=\($0.mSampleRate)" } ?? "nil") level=\(rmsLevel(of: sampleBuffer).map { String($0) } ?? "nil")")
        }
        guard let level = rmsLevel(of: sampleBuffer) else { return }
        levelPeak[track] = max(levelPeak[track] ?? -120, level)
        let now = CFAbsoluteTimeGetCurrent()
        guard now - (lastLevelEmit[track] ?? 0) >= 0.1 else { return }
        lastLevelEmit[track] = now
        onAudioLevel(track, levelPeak[track] ?? level)
        levelPeak[track] = nil
    }

    private func emitPreviewIfDue(_ sampleBuffer: CMSampleBuffer) {
        guard let onPreviewFrame,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard lastPreviewTime == .zero || CMTimeSubtract(now, lastPreviewTime).seconds >= 1 else { return }
        lastPreviewTime = now

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = min(1, 320 / image.extent.width)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if let cgImage = previewContext.createCGImage(small, from: small.extent) {
            onPreviewFrame(cgImage)
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
