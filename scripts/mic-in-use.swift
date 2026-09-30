// Exits 0 if any audio input device is currently in use by some app
// (e.g. a meeting in Chrome, Zoom, Teams), 1 otherwise. Used by smoke.sh to
// avoid playing test speech into a live call.
import CoreAudio

func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ empty: T) -> [T] {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    var values = [T](repeating: empty, count: Int(size) / MemoryLayout<T>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &values) == noErr else { return [] }
    return values
}

let devices = property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, AudioDeviceID(0))
for device in devices {
    let inputStreams = property(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, AudioStreamID(0))
    guard !inputStreams.isEmpty else { continue }
    if property(device, kAudioDevicePropertyDeviceIsRunningSomewhere, UInt32(0)).first == 1 {
        exit(0)
    }
}
exit(1)
