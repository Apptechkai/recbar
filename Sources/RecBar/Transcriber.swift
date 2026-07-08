import AVFoundation
import AppKit
import Foundation
import RecCore
import UniformTypeIdentifiers

/// Turns any audio/video file into an .srt subtitle file next to it, using
/// ffmpeg (track extraction) + whisperkit-cli (local WhisperKit models, the
/// same ones MacWhisper downloads). Files with exactly two audio tracks are
/// assumed to be rec-cli recordings and get [Them]/[Me] speaker labels.
@MainActor
final class Transcriber: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var statusText = ""
    @Published private(set) var fraction: Double?  // nil = indeterminate
    @Published private(set) var resultURL: URL?
    @Published private(set) var errorText: String?
    @Published var translateToEnglish = false

    private var currentProcess: Process?
    private var cancelled = false

    private static let whisperCLIPaths = ["/opt/homebrew/bin/whisperkit-cli", "/usr/local/bin/whisperkit-cli"]
    private static let ffmpegPaths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]

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
        cancelled = true
        currentProcess?.terminate()
    }

    private func transcribe(url: URL) async {
        isBusy = true
        cancelled = false
        errorText = nil
        resultURL = nil
        fraction = nil
        defer {
            isBusy = false
            fraction = nil
        }
        do {
            let srt = try await runPipeline(url)
            resultURL = srt
            statusText = "Done"
            NSWorkspace.shared.activateFileViewerSelecting([srt])
        } catch {
            statusText = cancelled ? "Cancelled" : "Failed"
            if !cancelled { errorText = "\(error)" }
        }
    }

    // MARK: - Pipeline

    private func runPipeline(_ input: URL) async throws -> URL {
        guard let ffmpeg = Self.firstExisting(Self.ffmpegPaths) else {
            throw RecError("ffmpeg not found — brew install ffmpeg")
        }
        guard let whisper = Self.firstExisting(Self.whisperCLIPaths) else {
            throw RecError("whisperkit-cli not found — brew install whisperkit-cli")
        }
        guard let model = Self.findModel() else {
            throw RecError("No WhisperKit model found. Download one in MacWhisper first.")
        }

        let asset = AVURLAsset(url: input)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw RecError("\(input.lastPathComponent) has no audio track.")
        }
        let duration = try await asset.load(.duration).seconds
        // rec-cli layout: exactly 2 audio tracks = system audio (them) + mic (me)
        let labels: [String?] = audioTracks.count == 2 ? ["Them", "Me"] : [nil]

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("recbar-subs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var cues: [SRT.Cue] = []
        for (index, label) in labels.enumerated() {
            let trackNote = labels.count == 2 ? " (track \(index + 1)/2)" : ""

            statusText = "Extracting audio\(trackNote)…"
            fraction = nil
            let wav = tmp.appendingPathComponent("track\(index).wav")
            try await run(ffmpeg, ["-v", "error", "-y", "-i", input.path,
                                   "-map", "0:a:\(index)", "-ac", "1", "-ar", "16000", wav.path])
            try Task.checkCancellation()

            statusText = "Transcribing\(trackNote)…"
            var args = ["transcribe", "--audio-path", wav.path, "--model-path", model.path,
                        "--report", "--report-path", tmp.path, "--verbose"]
            if translateToEnglish { args += ["--task", "translate"] }
            // Progress: whisperkit-cli --verbose renders a "] 42% |" progress
            // bar on stdout; parse the percentage out of it.
            let trackBase = Double(index)
            let trackCount = Double(labels.count)
            try await run(whisper, args) { [weak self] line in
                guard let percent = Self.progressPercent(in: line) else { return }
                let overall = (trackBase + percent / 100.0) / trackCount
                Task { @MainActor in
                    guard let self, self.isBusy else { return }
                    self.fraction = max(self.fraction ?? 0, overall)
                }
            }

            let srt = tmp.appendingPathComponent("track\(index).srt")
            guard let content = try? String(contentsOf: srt, encoding: .utf8) else {
                throw RecError("whisperkit-cli produced no subtitles for track \(index + 1).")
            }
            cues += SRT.parse(content).map { cue in
                var cue = cue
                if let label { cue.text = "[\(label)] \(cue.text)" }
                return cue
            }
        }

        statusText = "Writing subtitles…"
        cues.sort { $0.startMS < $1.startMS }
        guard !cues.isEmpty else {
            throw RecError("No speech was detected in \(input.lastPathComponent).")
        }
        let output = Self.availableOutputURL(for: input, translated: translateToEnglish)
        try SRT.render(cues).write(to: output, atomically: true, encoding: .utf8)
        return output
    }

    // MARK: - Subprocess plumbing

    private func run(_ tool: String, _ args: [String],
                     onLine: (@Sendable (String) -> Void)? = nil) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let tail = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            // whisperkit-cli redraws its progress bar with \r, not \n
            for line in chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let text = String(line)
                tail.append(text)
                onLine?(text)
            }
        }

        currentProcess = process
        defer { currentProcess = nil }
        try process.run()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in c.resume() }
        }
        pipe.fileHandleForReading.readabilityHandler = nil

        if cancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            let toolName = URL(fileURLWithPath: tool).lastPathComponent
            throw RecError("\(toolName) failed:\n\(tail.lastLines(4))")
        }
    }

    /// Thread-safe rolling buffer of recent subprocess output for error messages.
    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) {
            lock.lock()
            lines.append(line)
            if lines.count > 20 { lines.removeFirst() }
            lock.unlock()
        }
        func lastLines(_ n: Int) -> String {
            lock.lock()
            defer { lock.unlock() }
            return lines.suffix(n).joined(separator: "\n")
        }
    }

    // MARK: - Helpers

    private static func firstExisting(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Locate a WhisperKit CoreML model folder (MacWhisper's download location),
    /// preferring large-v3.
    static func findModel() -> URL? {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/MacWhisper/models/whisperkit/models/argmaxinc/whisperkit-coreml")
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil)) ?? []
        let models = candidates.filter { $0.hasDirectoryPath }
        return models.first { $0.lastPathComponent.contains("large-v3") } ?? models.first
    }

    /// Extract the last "] 42% |"-style percentage from whisperkit-cli's
    /// progress bar output, if the line contains one.
    nonisolated static func progressPercent(in line: String) -> Double? {
        var best: Double?
        var search = line[...]
        while let mark = search.range(of: "% ") {
            var digits = ""
            for char in search[..<mark.lowerBound].reversed() {
                guard char.isNumber else { break }
                digits.insert(char, at: digits.startIndex)
            }
            if let value = Double(digits) {
                best = value
            }
            search = search[mark.upperBound...]
        }
        return best
    }

    private static func availableOutputURL(for input: URL, translated: Bool) -> URL {
        let dir = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent + (translated ? ".en" : "")
        var candidate = dir.appendingPathComponent("\(base).srt")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-\(counter).srt")
            counter += 1
        }
        return candidate
    }
}

/// Minimal SRT reader/writer — enough to merge per-track subtitle files and
/// strip whisper's special tokens.
enum SRT {
    struct Cue {
        var startMS: Int
        var endMS: Int
        var text: String
    }

    static func parse(_ content: String) -> [Cue] {
        var cues: [Cue] = []
        let blocks = content.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n").map(String.init)
            guard let timeLineIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timeLineIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseTimestamp(parts[0]), let end = parseTimestamp(parts[1])
            else { continue }
            let text = lines[(timeLineIndex + 1)...].joined(separator: " ")
                .replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            cues.append(Cue(startMS: start, endMS: end, text: text))
        }
        return cues
    }

    static func render(_ cues: [Cue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.startMS)) --> \(timestamp(cue.endMS))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    private static func parseTimestamp(_ raw: String) -> Int? {
        // "00:01:23,456" (comma or dot before millis)
        let cleaned = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: ",")
        let main = cleaned.components(separatedBy: ",")
        let hms = main[0].components(separatedBy: ":").compactMap { Int($0) }
        guard hms.count == 3 else { return nil }
        let millis = main.count > 1 ? (Int(main[1].prefix(3)) ?? 0) : 0
        return ((hms[0] * 60 + hms[1]) * 60 + hms[2]) * 1000 + millis
    }

    private static func timestamp(_ ms: Int) -> String {
        String(format: "%02d:%02d:%02d,%03d",
               ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }
}
