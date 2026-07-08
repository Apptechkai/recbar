import Foundation

public enum RecPaths {
    public static var recordingsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/recordings")
    }

    public static func defaultOutputURL(audioOnly: Bool) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let suffix = audioOnly ? "-audio" : ""
        return recordingsDirectory
            .appendingPathComponent("rec-\(formatter.string(from: Date()))\(suffix).mov")
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
