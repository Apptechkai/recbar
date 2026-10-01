import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import RecCore
import ScreenCaptureKit

/// Owns the recording lifecycle for the menu bar app. Same engine as the CLI
/// (RecCore.Recorder) and the same pidfile, so `rec stop` in a terminal can
/// stop a RecBar recording and vice versa.
@MainActor
final class RecController: ObservableObject {
    static let shared = RecController()

    @Published private(set) var isRecording = false
    /// Between Start and the first written frame (the echo-cancelled mic
    /// needs ~2–3 s to warm up).
    @Published private(set) var isStarting = false
    @Published private(set) var elapsedText = "00:00:00"
    @Published var audioOnly = false
    @Published var normalizeAudio = true
    /// Set when the chosen recordings folder wasn't usable at Start and the
    /// default folder was used instead (e.g. external drive unplugged).
    @Published private(set) var folderWarning: String?
    /// Mic through macOS voice processing (echo cancellation): keeps the
    /// meeting audio playing from the speakers off the mic track.
    @Published var echoCancellation = true
    @Published private(set) var lastRecordingURL: URL?

    /// Capture source: 0 (kCGNullWindowID) = entire display, else a window id.
    @Published var selectedWindowID: CGWindowID = 0
    /// A source chosen in the thumbnail picker; overrides the dropdown.
    @Published private(set) var pickedSource: CaptureSource?
    var pickedLabel: String? { pickedSource?.label }

    func pickSourceVisually() {
        SourcePickerWindow.shared.show { [weak self] source in
            self?.pickedSource = source
        }
    }

    func clearPickedSource() {
        pickedSource = nil
    }
    @Published private(set) var windows: [CaptureWindow] = []
    @Published private(set) var sourceLabel = "Entire display"

    /// Mic: "" = system default input, else an AVCaptureDevice uniqueID.
    @Published var selectedMicID: String = ""
    @Published private(set) var microphones: [CaptureMicrophone] = []
    /// Live thumbnail of what's being written to disk (nil in audio-only mode).
    @Published private(set) var previewImage: CGImage?

    /// Live audio levels in dBFS while recording, plus how long the mic has
    /// been silent (to flag a muted / wrong microphone).
    @Published private(set) var micLevel: Float = -120
    @Published private(set) var systemLevel: Float = -120
    @Published private(set) var micSilentSeconds: Int = 0
    private var micLastSignal = Date()
    @Published private(set) var activeMicName = ""
    /// ★ markers dropped in the current recording.
    @Published private(set) var markers: [Marker] = []
    private var badgeResetWork: DispatchWorkItem?

    /// Panel window stays above other apps (else it hides when you click away).
    @Published var keepOnTop: Bool = UserDefaults.standard.bool(forKey: "keepOnTop") {
        didSet {
            UserDefaults.standard.set(keepOnTop, forKey: "keepOnTop")
            PanelWindow.shared.applyPinning(keepOnTop)
        }
    }


    private var recorder: Recorder?
    private var timer: Timer?
    private var sigintSource: DispatchSourceSignal?
    private var markerWatcher: MarkerFile.Watcher?

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

    /// Drops a ★ marker (⌃⌥M, the panel button, or `rec mark`). Feedback is
    /// the Dock badge and the panel — nothing on screen, nothing audible.
    func addMarker(label: String? = nil) {
        guard isRecording, let marker = recorder?.addMarker(label: label) else {
            NSSound.beep()   // not recording (only reachable via hotkey)
            return
        }
        noteMarker(marker)
    }

    private func noteMarker(_ marker: Marker) {
        markers.append(marker)
        NSApp.dockTile.badgeLabel = "★ \(marker.index)"
        badgeResetWork?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.updateRecordingBadge() }
        badgeResetWork = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: reset)
    }

    private func updateRecordingBadge() {
        guard isRecording, let recorder else { return }
        let minutes = Int(recorder.elapsed) / 60
        NSApp.dockTile.badgeLabel = minutes > 0 ? "REC \(minutes)m" : "REC"
    }

    /// Why the window list is empty, if it is (shown under the picker).
    @Published private(set) var windowsHint: String?

    /// Refresh the window list for the source picker. Listing windows needs
    /// Screen Recording permission, same as capturing.
    func refreshWindows(requestPermission: Bool = false) async {
        guard !isRecording else { return }
        microphones = Recorder.availableMicrophones()
        if selectedMicID != "", !microphones.contains(where: { $0.id == selectedMicID }) {
            selectedMicID = ""  // e.g. AirPods went away
        }
        if !CGPreflightScreenCaptureAccess() {
            if requestPermission { CGRequestScreenCaptureAccess() }
            windows = []
            windowsHint = "Grant Screen & System Audio Recording to Recall Bar in System Settings → Privacy & Security, then relaunch Recall Bar."
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

    /// `sourceOverride`: capture this instead of the panel's Source (used by
    /// meeting detection's "only the meeting app" option).
    func start(sourceOverride: CaptureSource? = nil) async {
        // Clean-up of earlier recordings may still be running — that's fine,
        // it's a separate background queue.
        guard !isRecording, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        if let pid = PidFile.runningPID(),
           pid != ProcessInfo.processInfo.processIdentifier {
            alert("Another recording is already running (pid \(pid)).",
                  detail: "Stop it first — e.g. `rec stop` in a terminal.")
            return
        }
        guard await ensurePermissions() else { return }

        var source: CaptureSource = .display
        if let sourceOverride {
            source = sourceOverride
        } else if let pickedSource {
            source = pickedSource
        } else if selectedWindowID != 0 {
            guard let window = windows.first(where: { $0.id == selectedWindowID }) else {
                alert("The selected window is gone.", detail: "Pick a source again.")
                await refreshWindows()
                return
            }
            source = .window(window)
        }
        sourceLabel = source.label

        let (folder, warning) = RecPaths.resolveRecordingsDirectory()
        folderWarning = warning
        let outputURL = RecPaths.outputURL(in: folder, audioOnly: audioOnly)
        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let microphone = microphones.first { $0.id == selectedMicID }
            let newRecorder = try await Recorder(outputURL: outputURL, audioOnly: audioOnly,
                                                 source: source, microphone: microphone,
                                                 echoCancellation: echoCancellation)
            newRecorder.onPreviewFrame = { [weak self] image in
                Task { @MainActor in self?.previewImage = image }
            }
            newRecorder.onAudioLevel = { [weak self] track, level in
                Task { @MainActor in
                    guard let self else { return }
                    switch track {
                    case .system:
                        self.systemLevel = level
                    case .microphone:
                        self.micLevel = level
                        // Room tone is −45…−55 dB raw and ~−60 dB after the
                        // echo canceller's noise suppression; a muted or
                        // missing mic is digital silence (−90 dB and below).
                        if level > -85 { self.micLastSignal = Date() }
                        self.micSilentSeconds = Int(Date().timeIntervalSince(self.micLastSignal))
                    }
                }
            }
            activeMicName = microphone?.name ?? (microphones.first?.name ?? "system default")
            micLastSignal = Date()
            micLevel = -120
            systemLevel = -120
            micSilentSeconds = 0
            newRecorder.onStreamStopped = { [weak self] error in
                Task { @MainActor in
                    await self?.stop(streamError: error?.localizedDescription ?? "unknown reason")
                }
            }
            try await newRecorder.start()
            recorder = newRecorder
            // `rec mark` from a terminal while Recall Bar records.
            markerWatcher = MarkerFile.Watcher(recorder: newRecorder) { [weak self] marker in
                guard let marker else { return }
                Task { @MainActor in self?.noteMarker(marker) }
            }
        } catch {
            alert("Could not start recording.", detail: "\(error)")
            return
        }

        PidFile.write()
        isRecording = true
        elapsedText = "00:00:00"
        NSApp.dockTile.badgeLabel = "REC"  // visible in the Dock even with the panel closed
        markers = []
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                self.elapsedText = formatDuration(recorder.elapsed)
                // Keep "REC n m" current, except during the brief "★ n" flash
                // after a marker (that resets itself).
                if !(NSApp.dockTile.badgeLabel ?? "").hasPrefix("★") { self.updateRecordingBadge() }
            }
        }
    }

    /// Stops and finalizes the file (about a second), then hands the audio
    /// clean-up to the background queue so a new recording can start at once.
    func stop(streamError: String? = nil, enqueueProcessing: Bool = true) async {
        guard let recorder else { return }
        self.recorder = nil
        markerWatcher?.stop()
        markerWatcher = nil
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
        previewImage = nil
        NSApp.dockTile.badgeLabel = nil
        if finalizeError == nil {
            lastRecordingURL = recorder.outputURL
            // Clean-up and/or turning ★ markers into chapters, in the background.
            if enqueueProcessing, normalizeAudio || !markers.isEmpty {
                PostProcessor.shared.enqueue(recorder.outputURL, cleanUpAudio: normalizeAudio)
            }
        }

        if let finalizeError {
            alert("Recording could not be finalized.", detail: finalizeError)
        } else if let streamError {
            alert("Recording stopped by the system (\(streamError)).",
                  detail: "The file up to this point was saved:\n\(recorder.outputURL.path)")
        }
    }

    /// Every quit path (panel button, Dock menu, ⌘Q) goes through
    /// AppDelegate.applicationShouldTerminate → confirmQuit / shutdownForQuit.
    func quit() {
        NSApp.terminate(nil)
    }

    /// Asks before quitting if a recording or clean-up is in progress.
    /// Returns false if the user chose to keep RecBar running.
    func confirmQuit() -> Bool {
        let processor = PostProcessor.shared
        guard isRecording || processor.isBusy else { return true }

        let alert = NSAlert()
        if isRecording {
            alert.messageText = "A recording is in progress."
            alert.informativeText = "Quitting stops it and saves the file"
                + (processor.isBusy || normalizeAudio
                   ? ", without the audio clean-up. You can run it later with `rec normalize`."
                   : ".")
            alert.addButton(withTitle: "Keep Recording")
            alert.addButton(withTitle: "Stop and Quit")
        } else {
            let count = processor.pendingCount
            alert.messageText = "\(count) recording\(count == 1 ? " is" : "s are") still being cleaned up."
            alert.informativeText = """
            Your recordings are already saved. If you quit now they keep their \
            unprocessed audio; you can clean them up later with `rec normalize <file>`.
            """
            alert.addButton(withTitle: "Wait")
            alert.addButton(withTitle: "Quit Anyway")
        }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Finalizes a running recording and stops background work before exit.
    func shutdownForQuit() async {
        if isRecording { await stop(enqueueProcessing: false) }
        Transcriber.shared.cancel()
        await PostProcessor.shared.cancelAll()
    }

    // MARK: - Permissions

    private func ensurePermissions() async -> Bool {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()  // pops the system prompt on first run
            alert("Screen & System Audio Recording permission is needed.",
                  detail: """
                  System Settings → Privacy & Security → Screen & System Audio Recording \
                  → enable Recall Bar, then relaunch Recall Bar and try again.
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
                      detail: "System Settings → Privacy & Security → Microphone → enable Recall Bar.")
            }
            return granted
        default:
            alert("Microphone permission is needed.",
                  detail: "System Settings → Privacy & Security → Microphone → enable Recall Bar.")
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
