import AVFoundation
import CoreGraphics
import Foundation

// MARK: - Helpers

let pidFilePath = "/tmp/rec-cli.pid"

func usage() -> Never {
    print("""
    rec — headless screen + meeting-audio recorder (no on-screen UI)

    Usage:
      rec start [output.mov]   Record the main display, system audio, and mic
                               into one .mov with 3 separate tracks.
                               Default output: ~/Movies/recordings/rec-<timestamp>.mov
                               Stop with Ctrl+C, or `rec stop` from another terminal.
      rec stop                 Cleanly stop a recording started elsewhere.
      rec status               Show whether a recording is running.
    """)
    exit(64)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("rec: " + message + "\n").utf8))
    exit(1)
}

func runningPID() -> pid_t? {
    guard let text = try? String(contentsOfFile: pidFilePath, encoding: .utf8),
          let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return nil }
    // kill 0 = existence check only. ESRCH means the pidfile is stale.
    if kill(pid, 0) == 0 { return pid }
    try? FileManager.default.removeItem(atPath: pidFilePath)
    return nil
}

func defaultOutputURL() -> URL {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies/recordings")
    return dir.appendingPathComponent("rec-\(formatter.string(from: Date())).mov")
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
}

func fileSizeString(_ url: URL) -> String {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let bytes = (attributes?[.size] as? Int64) ?? 0
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// Resumes a continuation exactly once no matter how many stop triggers fire
/// (Ctrl+C, `rec stop`, stream death).
final class StopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?

    func wait() async -> String {
        await withCheckedContinuation { c in
            lock.lock(); continuation = c; lock.unlock()
        }
    }

    func fire(_ reason: String) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(returning: reason)
    }
}

// MARK: - Permissions

func ensurePermissions() async {
    let permissionHelp = """
    Grant permission in System Settings → Privacy & Security:
      • Screen & System Audio Recording  → enable your terminal app (Terminal/iTerm/etc.)
      • Microphone                       → enable your terminal app
    Then quit and reopen the terminal app, and run `rec start` again.
    (For CLI tools, macOS attributes the permission to the terminal that launches them.)
    """

    if !CGPreflightScreenCaptureAccess() {
        CGRequestScreenCaptureAccess()  // pops the system prompt on first run
        fail("Screen & System Audio Recording permission is not granted yet.\n" + permissionHelp)
    }

    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        break
    case .notDetermined:
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        if !granted {
            fail("Microphone permission was denied.\n" + permissionHelp)
        }
    default:
        fail("Microphone permission is not granted.\n" + permissionHelp)
    }
}

// MARK: - Subcommands

func commandStart(outputPath: String?) async {
    if let pid = runningPID() {
        fail("A recording is already running (pid \(pid)). Stop it with `rec stop`.")
    }

    let outputURL: URL
    if let path = outputPath {
        outputURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    } else {
        outputURL = defaultOutputURL()
    }
    do {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    } catch {
        fail("Could not create output directory: \(error.localizedDescription)")
    }
    if FileManager.default.fileExists(atPath: outputURL.path) {
        fail("Output file already exists: \(outputURL.path)")
    }

    await ensurePermissions()

    let recorder: Recorder
    do {
        recorder = try await Recorder(outputURL: outputURL)
        try await recorder.start()
    } catch {
        fail("Could not start capture: \(error)")
    }

    try? "\(ProcessInfo.processInfo.processIdentifier)"
        .write(toFile: pidFilePath, atomically: true, encoding: .utf8)

    print("● Recording  →  \(outputURL.path)")
    print("  video (HEVC) + system audio (track 1) + mic (track 2), no on-screen UI")
    print("  Stop with Ctrl+C here, or `rec stop` from another terminal.")

    let stopSignal = StopSignal()
    recorder.onStreamStopped = { error in
        stopSignal.fire("the capture stream stopped (\(error?.localizedDescription ?? "unknown reason"))")
    }

    // Ignore default handling and route SIGINT/SIGTERM through dispatch
    // sources so we always finalize the writer before exiting.
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let signalQueue = DispatchQueue(label: "rec.signals")
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
    let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
    sigint.setEventHandler { stopSignal.fire("Ctrl+C") }
    sigterm.setEventHandler { stopSignal.fire("stop request") }
    sigint.resume()
    sigterm.resume()

    // Once a minute, one status line — enough to see it's alive from the
    // terminal without any on-screen UI.
    let heartbeat = DispatchSource.makeTimerSource(queue: signalQueue)
    heartbeat.schedule(deadline: .now() + 60, repeating: 60)
    heartbeat.setEventHandler {
        print("  … recording \(formatDuration(recorder.elapsed)), \(fileSizeString(outputURL)) so far")
    }
    heartbeat.resume()

    let reason = await stopSignal.wait()
    heartbeat.cancel()
    print("\nStopping (\(reason)) — finalizing file…")

    defer { try? FileManager.default.removeItem(atPath: pidFilePath) }
    do {
        try await recorder.stopAndFinish()
    } catch {
        fail("\(error)")
    }

    print("✔ Saved \(outputURL.path)  (\(formatDuration(recorder.elapsed)), \(fileSizeString(outputURL)))")
    exit(0)
}

func commandStop() {
    guard let pid = runningPID() else {
        fail("No recording is running.")
    }
    kill(pid, SIGINT)
    print("Sent stop to recording (pid \(pid)); waiting for it to finalize…")
    // Wait up to 15s for the recorder to finalize and exit.
    for _ in 0..<150 {
        usleep(100_000)
        if kill(pid, 0) != 0 {
            print("✔ Recording stopped and saved.")
            exit(0)
        }
    }
    fail("Recorder (pid \(pid)) is still running — check its terminal for errors.")
}

func commandStatus() {
    if let pid = runningPID() {
        print("● Recording in progress (pid \(pid)).")
    } else {
        print("Not recording.")
    }
}

// MARK: - Entry

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "start":
    if arguments.count > 2 { usage() }
    await commandStart(outputPath: arguments.count == 2 ? arguments[1] : nil)
case "stop":
    commandStop()
case "status":
    commandStatus()
default:
    usage()
}
