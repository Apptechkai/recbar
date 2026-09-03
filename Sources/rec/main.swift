import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import RecCore

// MARK: - Helpers

func usage() -> Never {
    print("""
    rec — headless screen + meeting-audio recorder (no on-screen UI)

    Usage:
      rec start [output.mov]   Record the main display, system audio, and mic
                               into one .mov with 3 separate tracks.
                               Default output: ~/Movies/recordings/rec-<timestamp>.mov
                               Stop with Ctrl+C, or `rec stop` from another terminal.
        --window <text>  | -w  Record one window instead of the display: the
                               first on-screen window whose app name or title
                               contains <text> (case-insensitive). System audio
                               is then limited to that app.
        --mic <text>     | -m  Use the microphone whose name contains <text>
                               (e.g. "AirPods") instead of the system default.
        --audio-only     | -a  Skip the screen: record just system audio + mic
                               (still 2 separate tracks, ~115 MB/hour).
        --no-normalize         Skip the speech clean-up + loudness normalization
                               that runs on stop.
        --meter                Print mic / system audio levels every second
                               (the once-a-minute status line always shows them).
      rec windows              List windows you can pass to --window.
      rec mics                 List microphones you can pass to --mic.
      rec normalize <file>     Run the audio clean-up + normalization on an
                               existing recording, in place.
      rec stop                 Cleanly stop a recording started elsewhere.
      rec status               Show whether a recording is running.
    """)
    exit(64)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("rec: " + message + "\n").utf8))
    exit(1)
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

func commandWindows() async {
    await ensurePermissions()
    let windows: [CaptureWindow]
    do {
        windows = try await Recorder.availableWindows()
    } catch {
        fail("Could not list windows: \(error)")
    }
    if windows.isEmpty {
        print("No capturable windows on screen.")
        return
    }
    for window in windows {
        print("  \(window.label)  [\(Int(window.frame.width))×\(Int(window.frame.height))]")
    }
    print("\nUse: rec start --window \"<part of app name or title>\"")
}

func resolveWindow(matching query: String) async -> CaptureWindow {
    let windows: [CaptureWindow]
    do {
        windows = try await Recorder.availableWindows()
    } catch {
        fail("Could not list windows: \(error)")
    }
    let needle = query.lowercased()
    // Prefer a title match (e.g. the meeting tab), then app name; both
    // lists are largest-window-first.
    if let match = windows.first(where: { $0.title.lowercased().contains(needle) })
        ?? windows.first(where: { $0.appName.lowercased().contains(needle) }) {
        return match
    }
    fail("No on-screen window matches \"\(query)\". Run `rec windows` to see the list.")
}

func commandMics() {
    let mics = Recorder.availableMicrophones()
    if mics.isEmpty {
        print("No microphones found.")
        return
    }
    for (index, mic) in mics.enumerated() {
        print("  \(mic.name)\(index == 0 ? "  (system default)" : "")")
    }
    print("\nUse: rec start --mic \"<part of the name>\"")
}

func resolveMicrophone(matching query: String) -> CaptureMicrophone {
    let needle = query.lowercased()
    if let match = Recorder.availableMicrophones().first(where: { $0.name.lowercased().contains(needle) }) {
        return match
    }
    fail("No microphone matches \"\(query)\". Run `rec mics` to see the list.")
}

/// Latest audio levels from the capture queue, read by the status timer.
final class LevelStore: @unchecked Sendable {
    private let lock = NSLock()
    private var levels: [AudioLevelTrack: Float] = [:]
    func set(_ track: AudioLevelTrack, _ level: Float) {
        lock.lock(); levels[track] = level; lock.unlock()
    }
    var summary: String {
        lock.lock(); defer { lock.unlock() }
        func fmt(_ t: AudioLevelTrack) -> String {
            guard let l = levels[t] else { return "—" }
            return l <= -59 ? "silent" : String(format: "%.0f dB", l)
        }
        return "mic \(fmt(.microphone)), audio \(fmt(.system))"
    }
}

func commandStart(outputPath: String?, audioOnly: Bool, windowQuery: String?,
                  micQuery: String?, normalize: Bool, meter: Bool) async {
    if let pid = PidFile.runningPID() {
        fail("A recording is already running (pid \(pid)). Stop it with `rec stop`.")
    }

    let outputURL: URL
    if let path = outputPath {
        outputURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    } else {
        outputURL = RecPaths.defaultOutputURL(audioOnly: audioOnly)
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

    var source: CaptureSource = .display
    if let windowQuery {
        source = .window(await resolveWindow(matching: windowQuery))
    }
    let microphone = micQuery.map(resolveMicrophone(matching:))

    let recorder: Recorder
    do {
        recorder = try await Recorder(outputURL: outputURL, audioOnly: audioOnly,
                                      source: source, microphone: microphone)
        try await recorder.start()
    } catch {
        fail("Could not start capture: \(error)")
    }

    PidFile.write()

    print("● Recording\(audioOnly ? " (audio only)" : "")  →  \(outputURL.path)")
    if case .window(let window) = source {
        print("  source: window \"\(window.label)\" — system audio limited to \(window.appName)")
    }
    print("  mic: \(microphone?.name ?? (Recorder.availableMicrophones().first?.name ?? "system default"))")
    if audioOnly {
        print("  system audio (track 1) + mic (track 2), no video, no on-screen UI")
    } else {
        print("  video (HEVC) + system audio (track 1) + mic (track 2), no on-screen UI")
    }
    print("  Stop with Ctrl+C here, or `rec stop` from another terminal.")

    let levels = LevelStore()
    recorder.onAudioLevel = { track, level in levels.set(track, level) }

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
    let interval: Double = meter ? 1 : 60
    heartbeat.schedule(deadline: .now() + interval, repeating: interval)
    heartbeat.setEventHandler {
        print("  … \(formatDuration(recorder.elapsed))  \(levels.summary)  (\(fileSizeString(outputURL)))")
    }
    heartbeat.resume()

    let reason = await stopSignal.wait()
    heartbeat.cancel()
    print("\nStopping (\(reason)) — finalizing file…")

    defer { PidFile.remove() }
    do {
        try await recorder.stopAndFinish()
    } catch {
        fail("\(error)")
    }
    // File is safe now; release the pidfile so `rec stop` returns promptly
    // even though normalization may run for a minute on long meetings.
    PidFile.remove()

    if normalize {
        print("  cleaning up + normalizing audio…")
        let lastShown = LockedValue(-1)
        do {
            try await AudioNormalizer.normalize(fileURL: outputURL) { fraction in
                let percent = Int(fraction * 100) / 10 * 10
                if lastShown.exchange(percent) != percent { print("  … \(percent)%") }
            }
        } catch {
            print("  ⚠︎ \(error) — original audio kept")
        }
    }

    print("✔ Saved \(outputURL.path)  (\(formatDuration(recorder.elapsed)), \(fileSizeString(outputURL)))")
    exit(0)
}

/// Tiny lock-protected box for state touched from ffmpeg's reader thread.
final class LockedValue: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int
    init(_ value: Int) { self.value = value }
    func exchange(_ new: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let old = value; value = new; return old
    }
}

func commandStop() {
    guard let pid = PidFile.runningPID() else {
        fail("No recording is running.")
    }
    kill(pid, SIGINT)
    print("Sent stop to recording (pid \(pid)); waiting for it to finalize…")
    // Wait up to 15s. The CLI exits when done; RecBar keeps running but
    // removes the pidfile — either signals a clean finalize.
    for _ in 0..<150 {
        usleep(100_000)
        if kill(pid, 0) != 0 || !FileManager.default.fileExists(atPath: PidFile.path) {
            print("✔ Recording stopped and saved.")
            exit(0)
        }
    }
    fail("Recorder (pid \(pid)) is still running — check its terminal for errors.")
}

func commandNormalize(path: String) async {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
        fail("No such file: \(url.path)")
    }
    print("Cleaning up + normalizing audio in \(url.lastPathComponent)…")
    let lastShown = LockedValue(-1)
    do {
        try await AudioNormalizer.normalize(fileURL: url) { fraction in
            let percent = Int(fraction * 100) / 10 * 10
            if lastShown.exchange(percent) != percent { print("  … \(percent)%") }
        }
    } catch {
        fail("\(error)")
    }
    print("✔ Done  (\(fileSizeString(url)))")
}

func commandStatus() {
    if let pid = PidFile.runningPID() {
        print("● Recording in progress (pid \(pid)).")
    } else {
        print("Not recording.")
    }
}

// MARK: - Entry

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "start":
    var rest = Array(arguments.dropFirst())
    let audioOnly = rest.contains("--audio-only") || rest.contains("-a")
    rest.removeAll { $0 == "--audio-only" || $0 == "-a" }
    let normalize = !rest.contains("--no-normalize")
    rest.removeAll { $0 == "--no-normalize" }
    let meter = rest.contains("--meter")
    rest.removeAll { $0 == "--meter" }
    func takeValue(_ long: String, _ short: String) -> String? {
        guard let flagIndex = rest.firstIndex(where: { $0 == long || $0 == short }) else { return nil }
        guard flagIndex + 1 < rest.count else { usage() }
        let value = rest[flagIndex + 1]
        rest.removeSubrange(flagIndex...(flagIndex + 1))
        return value
    }
    let windowQuery = takeValue("--window", "-w")
    let micQuery = takeValue("--mic", "-m")
    if rest.count > 1 { usage() }
    await commandStart(outputPath: rest.first, audioOnly: audioOnly,
                       windowQuery: windowQuery, micQuery: micQuery,
                       normalize: normalize, meter: meter)
case "windows":
    await commandWindows()
case "mics":
    commandMics()
case "normalize":
    guard arguments.count == 2 else { usage() }
    await commandNormalize(path: arguments[1])
case "thumbs":
    // Undocumented: dump picker thumbnails as PNGs into a directory (self-test
    // for the SourceCatalog thumbnail path RecBar's picker relies on).
    guard arguments.count == 2 else { usage() }
    let dir = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    do {
        let catalog = try await SourceCatalog.load()
        print("\(catalog.windows.count) windows, \(catalog.applications.count) apps, \(catalog.displays.count) displays")
        var written = 0
        for window in catalog.windows.prefix(6) {
            if let image = await catalog.thumbnail(for: window, maxWidth: 360) {
                let url = dir.appendingPathComponent("window-\(window.id).png")
                if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, image, nil)
                    if CGImageDestinationFinalize(dest) { written += 1 }
                }
                print("  \(window.label) → \(image.width)×\(image.height)")
            } else {
                print("  \(window.label) → no thumbnail")
            }
        }
        for app in catalog.applications.prefix(2) {
            let image = await catalog.thumbnail(for: app, maxWidth: 360)
            print("  app \(app.name) → \(image.map { "\($0.width)×\($0.height)" } ?? "no thumbnail")")
        }
        print("wrote \(written) PNGs to \(dir.path)")
    } catch {
        fail("\(error)")
    }
case "stop":
    commandStop()
case "status":
    commandStatus()
default:
    usage()
}
