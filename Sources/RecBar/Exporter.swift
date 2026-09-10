import AppKit
import Foundation
import RecCore
import UniformTypeIdentifiers

/// UI wrapper for ShareExport: pick a recording, export a single-audio-track
/// .mp4 next to it with progress, reveal the result.
@MainActor
final class Exporter: ObservableObject {
    static let shared = Exporter()

    @Published private(set) var isBusy = false
    @Published private(set) var fraction: Double?
    @Published private(set) var resultURL: URL?
    @Published private(set) var errorText: String?
    @Published var burnSubtitles = false

    func pickAndExport(defaultFile: URL? = nil) {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a recording to export as a shareable .mp4 (both sides mixed into one audio track)"
        if let defaultFile { panel.directoryURL = defaultFile.deletingLastPathComponent() }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await export(url: url) }
    }

    func export(url: URL) async {
        guard !isBusy else { return }
        isBusy = true
        errorText = nil
        resultURL = nil
        fraction = 0
        defer { isBusy = false; fraction = nil }
        do {
            let out = try await ShareExport.export(fileURL: url, burnSubtitles: burnSubtitles) { [weak self] value in
                Task { @MainActor in self?.fraction = value }
            }
            resultURL = out
            NSWorkspace.shared.activateFileViewerSelecting([out])
        } catch {
            errorText = "\(error)"
        }
    }
}
