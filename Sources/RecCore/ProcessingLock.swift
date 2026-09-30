import Foundation

/// Cross-process lock around post-recording audio processing, so the CLI's
/// background jobs and RecBar's queue never run two clean-ups at once (they'd
/// only compete for CPU). The holder writes what it's working on into the
/// lock file, which `rec status` reads.
public enum ProcessingLock {
    public static let path = "/tmp/rec-cli-processing.lock"

    /// Waits — cancellably, without blocking a thread — for exclusive access,
    /// then records `label` as the current job. Returns a token for `release`.
    static func acquire(label: String) async throws -> Int32 {
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw RecError("Could not open \(path): \(String(cString: strerror(errno)))") }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if Task.isCancelled {
                close(fd)
                throw CancellationError()
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        ftruncate(fd, 0)
        _ = label.withCString { pwrite(fd, $0, strlen($0), 0) }
        return fd
    }

    static func release(_ fd: Int32) {
        ftruncate(fd, 0)
        flock(fd, LOCK_UN)
        close(fd)
    }

    /// The file currently being processed by any process, or nil if idle.
    public static func currentJob() -> String? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        // Getting a shared lock means nobody holds the exclusive one → idle.
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = pread(fd, &buffer, buffer.count, 0)
        guard count > 0 else { return "(unknown file)" }
        return String(decoding: buffer[0..<count], as: UTF8.self)
    }
}
