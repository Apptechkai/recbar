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
    @Published private(set) var isRecording = false
    @Published private(set) var elapsedText = "00:00:00"
    @Published var audioOnly = false
    @Published private(set) var lastRecordingURL: URL?

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

    func start() async {
        guard !isRecording else { return }
        if let pid = PidFile.runningPID(),
           pid != ProcessInfo.processInfo.processIdentifier {
            alert("Another recording is already running (pid \(pid)).",
                  detail: "Stop it first — e.g. `rec stop` in a terminal.")
            return
        }
        guard await ensurePermissions() else { return }

        let outputURL = RecPaths.defaultOutputURL(audioOnly: audioOnly)
        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let newRecorder = try await Recorder(outputURL: outputURL, audioOnly: audioOnly)
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

        PidFile.remove()
        isRecording = false
        if finalizeError == nil {
            lastRecordingURL = recorder.outputURL
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
