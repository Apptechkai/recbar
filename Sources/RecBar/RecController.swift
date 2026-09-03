import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import RecCore

/// Owns the recording lifecycle for the menu bar app. Same engine as the CLI
/// (RecCore.Recorder) and the same pidfile, so `rec stop` in a terminal can
/// stop a RecBar recording and vice versa.
@MainActor
final class RecController: ObservableObject {
    static let shared = RecController()

    @Published private(set) var isRecording = false
    @Published private(set) var elapsedText = "00:00:00"
    @Published var audioOnly = false
    @Published var normalizeAudio = true
    @Published private(set) var lastRecordingURL: URL?

    /// Capture source: 0 (kCGNullWindowID) = entire display, else a window id.
    @Published var selectedWindowID: CGWindowID = 0
    @Published private(set) var windows: [CaptureWindow] = []
    @Published private(set) var sourceLabel = "Entire display"

    /// After Stop: loudness normalization in progress (Start stays disabled).
    @Published private(set) var isFinalizing = false
    @Published private(set) var finalizeFraction: Double?

    private var recorder: Recorder?
    private var timer: Timer?
    private var sigintSource: DispatchSourceSignal?

    init() {
        // `rec stop` sends SIGINT: stop the recording, but keep the app alive.
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in await self?.stop() }
        }
        source.resume()
        sigintSource = source
    }

    /// Why the window list is empty, if it is (shown under the picker).
    @Published private(set) var windowsHint: String?

    /// Refresh the window list for the source picker. Listing windows needs
    /// Screen Recording permission, same as capturing.
    func refreshWindows(requestPermission: Bool = false) async {
        guard !isRecording else { return }
        if !CGPreflightScreenCaptureAccess() {
            if requestPermission { CGRequestScreenCaptureAccess() }
            windows = []
            windowsHint = "Grant Screen & System Audio Recording to RecBar in System Settings → Privacy & Security, then relaunch RecBar."
            return
        }
        do {
            windows = try await Recorder.availableWindows()
            windowsHint = windows.isEmpty ? "No app windows on screen right now." : nil
        } catch {
            windows = []
            windowsHint = "Couldn't list windows: \(error.localizedDescription)"
        }
        if selectedWindowID != 0, !windows.contains(where: { $0.id == selectedWindowID }) {
            selectedWindowID = 0
        }
    }

    func start() async {
        guard !isRecording, !isFinalizing else { return }
        if let pid = PidFile.runningPID(),
           pid != ProcessInfo.processInfo.processIdentifier {
            alert("Another recording is already running (pid \(pid)).",
                  detail: "Stop it first — e.g. `rec stop` in a terminal.")
            return
        }
        guard await ensurePermissions() else { return }

        var source: CaptureSource = .display
        if selectedWindowID != 0 {
            guard let window = windows.first(where: { $0.id == selectedWindowID }) else {
                alert("The selected window is gone.", detail: "Pick a source again.")
                await refreshWindows()
                return
            }
            source = .window(window)
        }
        sourceLabel = { if case .window(let w) = source { return w.label } else { return "Entire display" } }()

        let outputURL = RecPaths.defaultOutputURL(audioOnly: audioOnly)
        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let newRecorder = try await Recorder(outputURL: outputURL, audioOnly: audioOnly,
                                                 source: source)
            newRecorder.onStreamStopped = { [weak self] error in
                Task { @MainActor in
                    await self?.stop(streamError: error?.localizedDescription ?? "unknown reason")
                }
            }
            try await newRecorder.start()
            recorder = newRecorder
        } catch {
            alert("Could not start recording.", detail: "\(error)")
            return
        }

        PidFile.write()
        isRecording = true
        elapsedText = "00:00:00"
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                self.elapsedText = formatDuration(recorder.elapsed)
            }
        }
    }

    func stop(streamError: String? = nil) async {
        guard let recorder else { return }
        self.recorder = nil
        timer?.invalidate()
        timer = nil

        var finalizeError: String?
        do {
            try await recorder.stopAndFinish()
        } catch {
            finalizeError = "\(error)"
        }

        // Pidfile goes first so `rec stop` returns as soon as the file is
        // safe, while normalization keeps running here.
        PidFile.remove()
        isRecording = false
        if finalizeError == nil {
            lastRecordingURL = recorder.outputURL
        }

        if finalizeError == nil, normalizeAudio {
            isFinalizing = true
            finalizeFraction = nil
            do {
                try await AudioNormalizer.normalize(fileURL: recorder.outputURL) { [weak self] fraction in
                    Task { @MainActor in self?.finalizeFraction = fraction }
                }
            } catch {
                alert("Audio normalization skipped.", detail: "\(error)")
            }
            isFinalizing = false
            finalizeFraction = nil
        }

        if let finalizeError {
            alert("Recording could not be finalized.", detail: finalizeError)
        } else if let streamError {
            alert("Recording stopped by the system (\(streamError)).",
                  detail: "The file up to this point was saved:\n\(recorder.outputURL.path)")
        }
    }

    func quit() {
        Task { @MainActor in
            await stop()
            NSApp.terminate(nil)
        }
    }

    // MARK: - Permissions

    private func ensurePermissions() async -> Bool {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()  // pops the system prompt on first run
            alert("Screen & System Audio Recording permission is needed.",
                  detail: """
                  System Settings → Privacy & Security → Screen & System Audio Recording \
                  → enable RecBar, then relaunch RecBar and try again.
                  """)
            return false
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                alert("Microphone permission was denied.",
                      detail: "System Settings → Privacy & Security → Microphone → enable RecBar.")
            }
            return granted
        default:
            alert("Microphone permission is needed.",
                  detail: "System Settings → Privacy & Security → Microphone → enable RecBar.")
            return false
        }
    }

    private func alert(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
