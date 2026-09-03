import AppKit
import Foundation
import RecCore
import UniformTypeIdentifiers

/// UI-side wrapper around RecCore's TranscriptionJob: file picker, published
/// progress, cancel, reveal result.
@MainActor
final class Transcriber: ObservableObject {
    static let shared = Transcriber()

    @Published private(set) var isBusy = false
    @Published private(set) var statusText = ""
    @Published private(set) var fraction: Double?  // nil = indeterminate
    @Published private(set) var resultURL: URL?
    @Published private(set) var errorText: String?
    @Published var translateToEnglish = false

    private var job: TranscriptionJob?

    func pickAndTranscribe() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a video or audio file to transcribe into a .srt subtitle file"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await transcribe(url: url) }
    }

    func cancel() {
        job?.cancel()
    }

    func transcribe(url: URL) async {
        guard !isBusy else { return }
        isBusy = true
        errorText = nil
        resultURL = nil
        fraction = nil
        statusText = "Starting…"
        defer {
            isBusy = false
            fraction = nil
            job = nil
        }

        let job = TranscriptionJob(input: url, translateToEnglish: translateToEnglish)
        job.onStatus = { [weak self] text in
            Task { @MainActor in self?.statusText = text }
        }
        job.onProgress = { [weak self] value in
            Task { @MainActor in
                guard let self else { return }
                if let value { self.fraction = max(self.fraction ?? 0, value) } else { self.fraction = nil }
            }
        }
        self.job = job

        do {
            let srt = try await job.run()
            resultURL = srt
            statusText = "Done"
            NSWorkspace.shared.activateFileViewerSelecting([srt])
        } catch is CancellationError {
            statusText = "Cancelled"
        } catch {
            statusText = "Failed"
            errorText = "\(error)"
        }
    }
}
