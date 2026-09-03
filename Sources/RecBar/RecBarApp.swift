import AppKit
import RecCore
import SwiftUI

@main
struct RecBarApp: App {
    @StateObject private var controller = RecController()
    @StateObject private var transcriber = Transcriber()

    private var icon: String {
        if controller.isRecording { return "record.circle.fill" }
        if transcriber.isBusy { return "waveform.circle" }
        return "record.circle"
    }

    var body: some Scene {
        // .window style: a real SwiftUI popover panel, so live progress bars
        // work (plain .menu items can't re-render while open).
        MenuBarExtra("RecBar", systemImage: icon) {
            PanelView(controller: controller, transcriber: transcriber)
        }
        .menuBarExtraStyle(.window)
    }
}

struct PanelView: View {
    @ObservedObject var controller: RecController
    @ObservedObject var transcriber: Transcriber

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            recordingSection
            Divider()
            transcribeSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 330)
    }

    private var recordingSection: some View {
        Group {
            if controller.isRecording {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "record.circle.fill").foregroundStyle(.red)
                        Text("Recording — \(controller.elapsedText)").monospacedDigit()
                        Spacer()
                        Button("Stop") { Task { await controller.stop() } }
                            .keyboardShortcut(.defaultAction)
                    }
                    Text(controller.sourceLabel)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            } else if controller.isFinalizing {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Normalizing audio loudness…")
                        .font(.caption).foregroundStyle(.secondary)
                    if let fraction = controller.finalizeFraction {
                        HStack(spacing: 8) {
                            ProgressView(value: fraction)
                            Text("\(Int(fraction * 100))%")
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        Task { await controller.start() }
                    } label: {
                        Label("Start Recording", systemImage: "record.circle")
                    }
                    HStack(spacing: 6) {
                        Picker("Record:", selection: $controller.selectedWindowID) {
                            Text("Entire display").tag(CGWindowID(0))
                            ForEach(controller.windows) { window in
                                Text(window.label).lineLimit(1).tag(window.id)
                            }
                        }
                        Button {
                            Task { await controller.refreshWindows(requestPermission: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .controlSize(.small)
                        .help("Refresh window list")
                    }
                    if let hint = controller.windowsHint {
                        Text(hint)
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if controller.selectedWindowID != 0 {
                        Text("Window capture also limits system audio to that app.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("\(controller.windows.count) windows available — pick one to record just that app.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Toggle("Audio only (no video)", isOn: $controller.audioOnly)
                        .toggleStyle(.checkbox)
                    Toggle("Normalize audio loudness on stop", isOn: $controller.normalizeAudio)
                        .toggleStyle(.checkbox)
                }
                .task { await controller.refreshWindows() }
                .onAppear { Task { await controller.refreshWindows() } }
            }
        }
    }

    private var transcribeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                transcriber.pickAndTranscribe()
            } label: {
                Label("Transcribe File to Subtitles…", systemImage: "captions.bubble")
            }
            .disabled(transcriber.isBusy)

            Toggle("Translate to English", isOn: $transcriber.translateToEnglish)
                .toggleStyle(.checkbox)
                .disabled(transcriber.isBusy)

            if transcriber.isBusy {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(transcriber.statusText)
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { transcriber.cancel() }
                            .controlSize(.small)
                    }
                    if let fraction = transcriber.fraction {
                        HStack(spacing: 8) {
                            ProgressView(value: fraction)
                            Text("\(Int(fraction * 100))%")
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                }
            } else if let result = transcriber.resultURL {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(result.lastPathComponent)
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([result])
                    }
                    .controlSize(.small)
                }
            } else if let error = transcriber.errorText {
                Text(error)
                    .font(.caption).foregroundStyle(.red)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let last = controller.lastRecordingURL {
                Button("Reveal Recording") {
                    NSWorkspace.shared.activateFileViewerSelecting([last])
                }
                .controlSize(.small)
            }
            Button("Recordings Folder") {
                try? FileManager.default.createDirectory(
                    at: RecPaths.recordingsDirectory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(RecPaths.recordingsDirectory)
            }
            .controlSize(.small)
            Spacer()
            Button("Quit") {
                transcriber.cancel()
                controller.quit()
            }
            .controlSize(.small)
        }
    }
}
