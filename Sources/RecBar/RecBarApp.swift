import AppKit
import RecCore
import SwiftUI

@main
struct RecBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var controller = RecController.shared
    @ObservedObject private var transcriber = Transcriber.shared

    private var icon: String {
        if controller.isRecording { return "record.circle.fill" }
        if transcriber.isBusy { return "waveform.circle" }
        return "record.circle"
    }

    var body: some Scene {
        // .window style: a real SwiftUI popover panel, so live progress bars
        // work (plain .menu items can't re-render while open).
        MenuBarExtra("Recall Bar", systemImage: icon) {
            PanelView(controller: controller, transcriber: transcriber)
        }
        .menuBarExtraStyle(.window)
        .commands {
            // RecBar → Settings… (⌘,) in the app menu.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsWindow.shared.show() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Name Speakers in a Transcript…") { SpeakersWindow.shared.pickAndShow() }
            }
        }
    }
}

// MARK: - Panel

struct PanelView: View {
    @ObservedObject var controller: RecController
    @ObservedObject var transcriber: Transcriber
    @ObservedObject var exporter = Exporter.shared
    @ObservedObject var processor = PostProcessor.shared
    @ObservedObject var detector = MeetingDetector.shared
    @ViewState private var optionsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let meeting = detector.startPrompt, !controller.isRecording {
                meetingBanner(meeting)
            }
            Section(title: "Record", icon: "record.circle") {
                if controller.isRecording {
                    recordingLive
                } else {
                    recordSetup
                }
            }
            if processor.isBusy || !processor.failures.isEmpty || processor.lastFinished != nil {
                processingStrip
            }
            Section(title: "After recording", icon: "wand.and.stars") {
                transcribeRow
                Divider().padding(.vertical, 2)
                exportRow
            }
            footer
        }
        .padding(16)
        .frame(width: 360)
    }

    // MARK: Meeting detection banners

    private func meetingBanner(_ meeting: MeetingDetector.Meeting) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "phone.fill").foregroundStyle(.green).font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(meeting.label) is using your microphone")
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Record") { Task { await detector.record(meeting) } }
                        .buttonStyle(.borderedProminent).tint(.red)
                    Button("Not Now") { detector.dismissStart() }
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.12)))
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Recall Bar").font(.title3.weight(.semibold))
            Spacer()
            statusPill
        }
    }

    @ViewBuilder private var statusPill: some View {
        if controller.isRecording {
            Label("REC \(controller.elapsedText)", systemImage: "circle.fill")
                .font(.caption.weight(.medium)).monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(.red))
        } else {
            Text("Ready").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Record — setup

    private var recordSetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Source
            LabeledRow("Source") {
                if let picked = controller.pickedLabel {
                    HStack(spacing: 6) {
                        Label(picked, systemImage: "checkmark.rectangle")
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        IconButton("xmark.circle.fill", help: "Back to the dropdown") {
                            controller.clearPickedSource()
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        Picker("", selection: $controller.selectedWindowID) {
                            Text("Entire display").tag(CGWindowID(0))
                            ForEach(controller.windows) { window in
                                Text(window.label).lineLimit(1).tag(window.id)
                            }
                        }
                        .labelsHidden()
                        IconButton("rectangle.grid.2x2", help: "Choose from thumbnails") {
                            controller.pickSourceVisually()
                        }
                        IconButton("arrow.clockwise", help: "Refresh window list") {
                            Task { await controller.refreshWindows(requestPermission: true) }
                        }
                    }
                }
            }
            if let hint = controller.windowsHint {
                Caption(hint)
            } else if controller.selectedWindowID != 0 || controller.pickedLabel != nil {
                Caption("System audio will be limited to this app.")
            }

            // Mic
            LabeledRow("Mic") {
                Picker("", selection: $controller.selectedMicID) {
                    Text("System default\(controller.microphones.first.map { " (\($0.name))" } ?? "")")
                        .tag("")
                    ForEach(controller.microphones) { mic in
                        Text(mic.name).tag(mic.id)
                    }
                }
                .labelsHidden()
            }

            // Options (collapsed by default; defaults are the right choice)
            DisclosureGroup(isExpanded: $optionsExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Audio only (no video)", isOn: $controller.audioOnly)
                    Toggle("Echo cancellation", isOn: $controller.echoCancellation)
                    Toggle("Clean up audio after stop (in background)", isOn: $controller.normalizeAudio)
                }
                .toggleStyle(.checkbox)
                .font(.callout)
                .padding(.top, 4)
            } label: {
                HStack(spacing: 6) {
                    Text("Options").font(.callout)
                    Text(optionsSummary).font(.caption).foregroundStyle(.secondary)
                    InfoButton("""
                    Echo cancellation keeps the meeting audio coming out of your speakers \
                    off your mic track (the same processing FaceTime uses).

                    Clean-up runs in the background after you stop: denoise, gentle \
                    compression, and loudness normalization of each audio track. Video is \
                    never re-encoded, and you can start the next recording right away.
                    """)
                }
            }

            Button {
                Task { await controller.start() }
            } label: {
                Group {
                    if controller.isStarting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Starting…")
                        }
                    } else {
                        Label("Start Recording", systemImage: "record.circle.fill")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)   // record = red, stop = neutral (recorder convention)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(controller.isStarting)

            // Where it will be saved — click to change.
            let destination = RecPaths.resolveRecordingsDirectory()
            Button {
                SettingsWindow.shared.show()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: destination.warning == nil ? "folder" : "exclamationmark.triangle.fill")
                    Text("Saves to \(RecPaths.displayPath(destination.url))")
                        .lineLimit(1).truncationMode(.middle)
                    Text("· Change").foregroundStyle(.tint)
                }
                .font(.caption2)
                .foregroundStyle(destination.warning == nil ? Color.secondary : Color.orange)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .help(destination.warning ?? "Change the recordings folder in Settings")
        }
        .task { await controller.refreshWindows() }
        .onAppear { Task { await controller.refreshWindows() } }
    }

    private var optionsSummary: String {
        var parts: [String] = []
        if controller.audioOnly { parts.append("audio only") }
        if !controller.echoCancellation { parts.append("no echo cancel") }
        if !controller.normalizeAudio { parts.append("no clean-up") }
        return parts.isEmpty ? "defaults" : parts.joined(separator: " · ")
    }

    // MARK: Record — live

    private var recordingLive: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(controller.sourceLabel)
                .font(.callout).lineLimit(1).truncationMode(.middle)
            if let warning = controller.folderWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let meeting = detector.endPrompt {
                HStack(spacing: 8) {
                    Image(systemName: "phone.down.fill").foregroundStyle(.orange)
                    Text("The \(meeting.appName) call seems to have ended.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Stop") { Task { await detector.stopRecording() } }
                    Button("Keep") { detector.keepRecording() }
                }
                .controlSize(.small)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }

            LevelMeter(label: "Mic", detail: controller.activeMicName, level: controller.micLevel)
            if controller.micSilentSeconds >= 3 {
                Label("No mic signal for \(controller.micSilentSeconds)s — muted or wrong microphone?",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            }
            LevelMeter(label: "Meeting", detail: "system audio", level: controller.systemLevel)

            // ★ markers
            HStack(spacing: 8) {
                Button {
                    controller.addMarker()
                } label: {
                    Label("Add Marker", systemImage: "star.fill")
                }
                .controlSize(.small)
                Text("⌃⌥M from anywhere").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                InfoButton("""
                Press ⌃⌥M (or this button) right after something important is said. \
                Markers become chapters in the video, and the transcript highlights \
                with ★ what was said in the 15 seconds before each marker. From a \
                terminal: rec mark "label".
                """)
            }
            if !controller.markers.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(controller.markers.suffix(3).reversed()) { marker in
                        Text("★ \(marker.timeText)  \(marker.title)")
                            .font(.caption).monospacedDigit()
                            .lineLimit(1).truncationMode(.tail)
                    }
                    if controller.markers.count > 3 {
                        Caption("\(controller.markers.count) markers so far")
                    }
                }
            }

            if let preview = controller.previewImage {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            } else if !controller.audioOnly {
                Caption("Waiting for first frame…")
            }

            Button {
                Task { await controller.stop() }
            } label: {
                Label("Stop Recording", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(nsColor: .darkGray))
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Background clean-up

    /// Shown only while clean-ups are queued/running, or to report the last
    /// result. Never blocks the Record card.
    private var processingStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let job = processor.current {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Cleaning up audio").font(.callout.weight(.medium))
                    Text(job.url.lastPathComponent)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    InfoButton("""
                    Runs in the background after each recording: denoise, gentle \
                    compression and loudness normalization of both audio tracks. \
                    The recording is already saved and playable — this only improves \
                    its audio, and you can start the next recording right away.
                    """)
                }
                if let fraction = processor.fraction {
                    HStack(spacing: 8) {
                        ProgressView(value: fraction)
                        Text("\(Int(fraction * 100))%")
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                if !processor.waiting.isEmpty {
                    Caption("\(processor.waiting.count) more queued")
                }
            } else if let done = processor.lastFinished {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Audio cleaned up").font(.callout)
                    Text(done.lastPathComponent)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([done]) }
                        .controlSize(.small)
                    IconButton("xmark", help: "Dismiss") { processor.dismissFinished() }
                }
            }
            ForEach(processor.failures) { failure in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clean-up skipped: \(failure.url.lastPathComponent)")
                            .font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        Text("Recording is fine, original audio kept. \(failure.message)")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                    IconButton("xmark", help: "Dismiss") { processor.dismiss(failure) }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    // MARK: After recording

    private var transcribeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Transcribe to subtitles").font(.callout.weight(.medium))
                        InfoButton("""
                        Writes a .srt file next to the recording using a local Whisper model — \
                        nothing is uploaded. Recall Bar recordings are transcribed per track, so lines \
                        are labelled [Me] and [Them].
                        """)
                    }
                    Toggle("Translate to English", isOn: $transcriber.translateToEnglish)
                        .toggleStyle(.checkbox).font(.caption)
                        .disabled(transcriber.isBusy)
                }
                Spacer()
                Button("Transcribe…") { transcriber.pickAndTranscribe() }
                    .disabled(transcriber.isBusy)
            }
            if transcriber.isBusy {
                ProgressRow(status: transcriber.statusText, fraction: transcriber.fraction) {
                    transcriber.cancel()
                }
            } else if let result = transcriber.resultURL {
                ResultRow(url: result)
                if transcriber.hasSpeakers {
                    Button {
                        if let json = Transcript.locate(for: result) { SpeakersWindow.shared.show(transcriptURL: json) }
                    } label: {
                        Label("Name Speakers…", systemImage: "person.2")
                    }
                    .controlSize(.small)
                }
            } else if let error = transcriber.errorText {
                ErrorText(error)
            }
        }
    }

    private var exportRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Export for sharing").font(.callout.weight(.medium))
                        InfoButton("""
                        Recordings keep the meeting audio and your mic as two separate tracks. \
                        QuickTime plays both, but most other players and upload sites use only the \
                        first track.

                        Export mixes both tracks into one normal stereo track in an .mp4 (video \
                        copied, not re-encoded) and attaches the .srt as subtitles if one exists. \
                        The original 3-track recording is kept.
                        """)
                    }
                    Toggle("Burn subtitles into the video", isOn: $exporter.burnSubtitles)
                        .toggleStyle(.checkbox).font(.caption)
                        .disabled(exporter.isBusy)
                }
                Spacer()
                Button("Export…") { exporter.pickAndExport(defaultFile: controller.lastRecordingURL) }
                    .disabled(exporter.isBusy)
            }
            if exporter.isBusy {
                ProgressRow(status: "Exporting…", fraction: exporter.fraction, onCancel: nil)
            } else if let result = exporter.resultURL {
                ResultRow(url: result)
            } else if let error = exporter.errorText {
                ErrorText(error)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            IconButton("folder", help: "Open recordings folder") {
                try? FileManager.default.createDirectory(
                    at: RecPaths.recordingsDirectory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(RecPaths.recordingsDirectory)
            }
            if let last = controller.lastRecordingURL {
                IconButton("doc.viewfinder", help: "Reveal last recording") {
                    NSWorkspace.shared.activateFileViewerSelecting([last])
                }
            }
            Toggle("Keep on top", isOn: $controller.keepOnTop)
                .toggleStyle(.checkbox).font(.caption)
            Spacer()
            IconButton("gearshape", help: "Settings (⌘,)") {
                SettingsWindow.shared.show()
            }
            Button("Quit") {
                controller.quit()   // confirms if recording / cleaning up
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Building blocks

/// A titled card with an icon — the panel's grouping unit.
private struct Section<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title.uppercased(), systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.35)))
    }
}

/// "Label    control" row with a fixed label column.
private struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label).font(.callout).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            content
        }
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    init(_ symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(help)
    }
}

/// ⓘ that opens an explanation popover.
struct InfoButton: View {
    let text: String
    @ViewState private var shown = false

    init(_ text: String) { self.text = text }

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("What does this do?")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(14)
        }
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ErrorText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.red).lineLimit(4).textSelection(.enabled)
    }
}

private struct ProgressRow: View {
    let status: String
    let fraction: Double?
    let onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let onCancel {
                    Button("Cancel", action: onCancel).controlSize(.small)
                }
            }
            if let fraction {
                HStack(spacing: 8) {
                    ProgressView(value: fraction)
                    Text("\(Int(fraction * 100))%")
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
    }
}

private struct ResultRow: View {
    let url: URL
    var body: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(url.lastPathComponent)
                .font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .controlSize(.small)
        }
    }
}

/// A compact dBFS meter: label, live bar, numeric readout.
struct LevelMeter: View {
    let label: String
    let detail: String
    let level: Float   // dBFS

    /// −80 dB (empty) … 0 dB (full): quiet room tone (~−60 dB with noise
    /// suppression) still shows as a sliver, so "on but quiet" ≠ "dead".
    private var fraction: Double { Double(min(max(level + 80, 0), 80) / 80) }
    private var color: Color {
        if level > -6 { return .red }        // near clipping
        if level > -40 { return .green }     // healthy signal
        return .secondary                    // quiet / silence
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.caption).monospacedDigit()
                Text(detail).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(width: 96, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 8)
            Text(level <= -85 ? "—" : String(format: "%.0f dB", level))
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}
