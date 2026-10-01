import CoreAudio
import Darwin
import Foundation

/// Which processes are using an audio input right now (macOS 14+ Core Audio
/// process objects). Needs no permission — it's the same information the
/// orange microphone indicator in the menu bar is based on.
public enum MicActivity {
    public struct User: Hashable, Sendable {
        public let pid: pid_t
        public let bundleID: String?      // e.g. "com.google.Chrome.helper"
        public let executableName: String // e.g. "Google Chrome Helper"
    }

    public static func currentUsers() -> [User] {
        let processes: [AudioObjectID] = property(AudioObjectID(kAudioObjectSystemObject),
                                                  kAudioHardwarePropertyProcessObjectList, AudioObjectID(0))
        return processes.compactMap { process in
            guard (property(process, kAudioProcessPropertyIsRunningInput, UInt32(0)).first ?? 0) != 0,
                  let pid = property(process, kAudioProcessPropertyPID, pid_t(0)).first, pid > 0
            else { return nil }
            return User(pid: pid, bundleID: bundleID(of: process), executableName: executableName(pid))
        }
    }

    // MARK: Core Audio helpers

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                    _ empty: T) -> [T] {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var values = [T](repeating: empty, count: Int(size) / MemoryLayout<T>.stride)
        let status = values.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!)
        }
        return status == noErr ? values : []
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr,
              let id = value?.takeRetainedValue() as String?, !id.isEmpty
        else { return nil }
        return id
    }

    private static func executableName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    }
}
