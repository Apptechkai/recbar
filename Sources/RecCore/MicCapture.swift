import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

/// Microphone capture through Apple's voice-processing audio unit — the path
/// FaceTime uses. It echo-cancels whatever the Mac is playing (the meeting
/// coming out of the speakers) and suppresses noise, so the mic track holds
/// only the local speaker. ScreenCaptureKit's raw mic capture has no echo
/// cancellation and picks the meeting up through the speakers.
final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    /// Format the tap delivers (voice processing typically gives mono Float32).
    let format: AVAudioFormat

    init(deviceUID: String?) throws {
        let input = engine.inputNode
        if let uid = deviceUID, let deviceID = Self.deviceID(forUID: uid) {
            try input.auAudioUnit.setDeviceID(deviceID)
        }
        try input.setVoiceProcessingEnabled(true)
        // Keep natural dynamics; the post-recording chain handles levels.
        input.isVoiceProcessingAGCEnabled = false
        // Don't turn the meeting down while we capture (default VPIO behavior).
        input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false,
                                                                 duckingLevel: .min)
        format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecError("Microphone reports no usable format.")
        }
    }

    /// Starts delivering CMSampleBuffers (host-clock timestamps, so they line
    /// up with ScreenCaptureKit's) on the tap's own thread.
    func start(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) throws {
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, when in
            if let sample = MicCapture.makeSampleBuffer(buffer, at: when) { handler(sample) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: - Helpers

    private static func makeSampleBuffer(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) -> CMSampleBuffer? {
        let pts = when.isHostTimeValid
            ? CMClockMakeHostTimeFromSystemUnits(when.hostTime)
            : CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: buffer.format.formatDescription,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample) == noErr, let sample
        else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sample, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
            bufferList: buffer.audioBufferList) == noErr
        else { return nil }
        return sample
    }

    /// CoreAudio device id for an AVCaptureDevice.uniqueID (the CoreAudio UID).
    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), uidPointer,
                                       &size, &deviceID)
        }
        return status == noErr && deviceID != 0 ? deviceID : nil
    }
}
