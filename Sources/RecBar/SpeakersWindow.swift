import AppKit
import AVFoundation
import RecCore
import SwiftUI
import UniformTypeIdentifiers

/// "Name Speakers": each voice found in a transcript, with a couple of lines
/// they said and a ▶ button that plays them from the recording, so you can
/// tell who is who. Saving rewrites the .srt with the names.
struct SpeakersView: View {
    let transcriptURL: URL
    let onClose: () -> Void

    @State private var transcript: Transcript?
    @State private var names: [String: String] = [:]
    @State private var error: String?
    @State private var saved = false
    @State private var player: AVPlayer?
    @State private var playing: String?
    @State private var stopWork: DispatchWorkItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Name the speakers").font(.title2.weight(.semibold))
                Text(transcriptURL.deletingPathExtension().deletingPathExtension().lastPathComponent)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .padding(20)

            if let transcript {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(transcript.summaries(), id: \.speaker.id) { summary in
                            row(summary)
                            Divider()
                        }
                        Text("Give two speakers the same name to merge them. Leave a name empty to go back to the default.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                }
            } else if let error {
                Text(error).foregroundStyle(.red).padding(20)
            }

            Divider()
            HStack {
                if saved {
                    Label("Saved — subtitles updated", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                Spacer()
                Button("Close") { stopPlayback(); onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Names") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(transcript == nil)
            }
            .padding(16)
        }
        .frame(width: 560, height: 520)
        .onAppear(perform: load)
        .onDisappear(perform: stopPlayback)
    }

    private func row(_ summary: Transcript.SpeakerSummary) -> some View {
        let speaker = summary.speaker
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: speaker.isLocal ? "mic.fill" : "person.wave.2.fill")
                    .foregroundStyle(speaker.isLocal ? Color.accentColor : .secondary)
                    .frame(width: 18)
                TextField(speaker.defaultName, text: Binding(
                    get: { names[speaker.id] ?? speaker.name },
                    set: { names[speaker.id] = $0; saved = false }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Text("\(summary.lineCount) line\(summary.lineCount == 1 ? "" : "s") · \(Marker.clock(summary.talkTime)) talking")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let first = summary.firstLines.first {
                    Button {
                        togglePlay(speaker.id, at: first.start, until: min(first.end, first.start + 8))
                    } label: {
                        Image(systemName: playing == speaker.id ? "stop.fill" : "play.fill")
                    }
                    .help("Play what they said at \(Marker.clock(first.start))")
                }
            }
            ForEach(Array(summary.firstLines.enumerated()), id: \.offset) { _, line in
                Text("\(Marker.clock(line.start))  “\(line.text)”")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 28)
            }
        }
    }

    // MARK: Actions

    private func load() {
        do {
            transcript = try Transcript.load(from: transcriptURL)
        } catch {
            self.error = "Couldn't read the transcript: \(error.localizedDescription)"
        }
    }

    private func save() {
        guard var updated = transcript else { return }
        for speaker in updated.speakers {
            if let name = names[speaker.id] { updated.rename(speaker.id, to: name) }
        }
        do {
            try updated.save(to: transcriptURL)
            transcript = updated
            names = [:]
            saved = true
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func togglePlay(_ id: String, at start: Double, until end: Double) {
        if playing == id { stopPlayback(); return }
        stopPlayback()
        guard let path = transcript?.recording, FileManager.default.fileExists(atPath: path) else {
            error = "The recording isn't where it was when it was transcribed."
            return
        }
        let player = AVPlayer(url: URL(fileURLWithPath: path))
        player.seek(to: CMTime(seconds: max(0, start - 0.3), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        self.player = player
        playing = id
        let work = DispatchWorkItem { stopPlayback() }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(2, end - start + 0.6), execute: work)
    }

    private func stopPlayback() {
        stopWork?.cancel()
        player?.pause()
        player = nil
        playing = nil
    }
}

@MainActor
final class SpeakersWindow {
    static let shared = SpeakersWindow()
    private var window: NSWindow?

    func show(transcriptURL: URL) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Name Speakers"
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.contentView = NSHostingView(rootView: SpeakersView(
            transcriptURL: transcriptURL, onClose: { [weak self] in self?.window?.orderOut(nil) }))
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Pick any earlier recording or subtitle file and name its speakers.
    func pickAndShow() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio, UTType(filenameExtension: "srt") ?? .plainText]
        panel.directoryURL = RecPaths.recordingsDirectory
        panel.message = "Choose a transcribed recording (or its .srt) to name its speakers"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let json = Transcript.locate(for: url) else {
            let alert = NSAlert()
            alert.messageText = "No transcript found for \(url.lastPathComponent)."
            alert.informativeText = "Transcribe it first (Transcribe…), then name its speakers."
            alert.runModal()
            return
        }
        show(transcriptURL: json)
    }
}
