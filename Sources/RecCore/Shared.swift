import Foundation

/// Settings shared by RecBar and the `rec` CLI (one preferences file, so a
/// folder chosen in RecBar's Settings also applies to `rec start`).
public enum RecSettings {
    // Deliberately not RecBar's own bundle id: UserDefaults refuses a suite
    // named after the running app, and the CLI has a different bundle id.
    private static let defaults = UserDefaults(suiteName: "sg.com.apptechsystem.recbar.shared")!
    private static let folderKey = "recordingsFolder"

    /// The folder the user chose, or nil for the default.
    public static var customRecordingsFolder: URL? {
        get {
            defaults.synchronize()   // pick up changes made by the other process
            return defaults.string(forKey: folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        set {
            if let newValue {
                defaults.set(newValue.standardizedFileURL.path, forKey: folderKey)
            } else {
                defaults.removeObject(forKey: folderKey)
            }
            defaults.synchronize()
        }
    }
}

public enum RecPaths {
    public static var defaultRecordingsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/recordings", isDirectory: true)
    }

    /// Where new recordings go right now, plus a warning when the chosen
    /// folder can't be used (e.g. an external drive isn't plugged in) and the
    /// default was used instead. Creates the folder if needed.
    public static func resolveRecordingsDirectory() -> (url: URL, warning: String?) {
        let fallback = defaultRecordingsDirectory
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        guard let custom = RecSettings.customRecordingsFolder else { return (fallback, nil) }
        if let problem = problem(with: custom) {
            return (fallback, "Your recordings folder \(displayPath(custom)) \(problem) — saving to \(displayPath(fallback)) instead.")
        }
        return (custom, nil)
    }

    /// The folder new recordings go to (see resolveRecordingsDirectory).
    public static var recordingsDirectory: URL { resolveRecordingsDirectory().url }

    /// Nil if `folder` can hold recordings, else a short reason it can't.
    /// Creates the folder if it's missing but its parent exists.
    public static func problem(with folder: URL) -> String? {
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                return "isn't available"
            }
        } else if !isDirectory.boolValue {
            return "is a file, not a folder"
        }
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            return "isn't writable"
        }
        return nil
    }

    /// "~/Movies/recordings" style path for messages.
    public static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Free space on the volume holding `folder`, e.g. "412 GB free on Macintosh HD".
    public static func freeSpaceDescription(for folder: URL) -> String? {
        guard let values = try? folder.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeNameKey,
        ]), let bytes = values.volumeAvailableCapacityForImportantUsage else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return values.volumeName.map { "\(size) free on \($0)" } ?? "\(size) free"
    }

    public static func defaultOutputURL(audioOnly: Bool) -> URL {
        outputURL(in: recordingsDirectory, audioOnly: audioOnly)
    }

    public static func outputURL(in folder: URL, audioOnly: Bool) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let suffix = audioOnly ? "-audio" : ""
        return folder.appendingPathComponent("rec-\(formatter.string(from: Date()))\(suffix).mov")
    }
}

/// One pidfile shared by the CLI and RecBar, so only one recording can run at
/// a time and `rec stop` can stop either of them.
public enum PidFile {
    public static let path = "/tmp/rec-cli.pid"

    public static func runningPID() -> pid_t? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        // kill 0 = existence check only. ESRCH means the pidfile is stale.
        if kill(pid, 0) == 0 { return pid }
        try? FileManager.default.removeItem(atPath: path)
        return nil
    }

    public static func write() {
        try? "\(ProcessInfo.processInfo.processIdentifier)"
            .write(toFile: path, atomically: true, encoding: .utf8)
    }

    public static func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

public func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
}
