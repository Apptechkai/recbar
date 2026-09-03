import AVFoundation
import Foundation

/// Turns any audio/video file into an .srt subtitle file next to it, fully
/// on-device: ffmpeg extracts each audio track, whisperkit-cli transcribes it
/// with a local WhisperKit model. Files with exactly two audio tracks are
/// assumed to be RecBar recordings and get [Them]/[Me] speaker labels.
public final class TranscriptionJob: @unchecked Sendable {
    public let input: URL
    public let translateToEnglish: Bool

    /// Human-readable stage ("Transcribing (track 2/2)…"). Called on arbitrary threads.
    public var onStatus: (@Sendable (String) -> Void)?
    /// 0…1, or nil while indeterminate. Called on arbitrary threads.
    public var onProgress: (@Sendable (Double?) -> Void)?

    private let lock = NSLock()
    private var currentProcess: Process?
    private var cancelled = false

    public static let whisperCLIPaths = ["/opt/homebrew/bin/whisperkit-cli", "/usr/local/bin/whisperkit-cli"]
    /// Where RecBar downloads a model if none is found on the machine.
    public static let modelDownloadDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/RecBar/models")
    public static let defaultModel = "large-v3"

    public init(input: URL, translateToEnglish: Bool = false) {
        self.input = input
        self.translateToEnglish = translateToEnglish
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let process = currentProcess
        lock.unlock()
        process?.terminate()
    }

    // Lock access lives in synchronous helpers: NSLock must not be taken
    // directly inside async functions.
    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private func setCurrentProcess(_ process: Process?) {
        lock.lock(); currentProcess = process; lock.unlock()
    }

    /// Runs the whole pipeline and returns the written .srt URL.
    public func run() async throws -> URL {
        guard let ffmpeg = AudioNormalizer.ffmpegPath else {
            throw RecError("ffmpeg not found — brew install ffmpeg")
        }
        guard let whisper = Self.whisperCLIPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw RecError("whisperkit-cli not found — brew install whisperkit-cli")
        }

        let asset = AVURLAsset(url: input)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw RecError("\(input.lastPathComponent) has no audio track.")
        }
        // RecBar layout: exactly 2 audio tracks = system audio (them) + mic (me).
        let labels: [String?] = audioTracks.count == 2 ? ["Them", "Me"] : [nil]

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("recbar-subs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Model: an existing WhisperKit model on disk, else download once.
        let modelArgs: [String]
        if let model = Self.findModel() {
            modelArgs = ["--model-path", model.path]
        } else {
            try FileManager.default.createDirectory(at: Self.modelDownloadDirectory, withIntermediateDirectories: true)
            modelArgs = ["--model", Self.defaultModel, "--download-model-path", Self.modelDownloadDirectory.path]
            onStatus?("Downloading the \(Self.defaultModel) model (first time only, ~1.5 GB)…")
        }

        var cues: [SRT.Cue] = []
        for (index, label) in labels.enumerated() {
            let trackNote = labels.count == 2 ? " (track \(index + 1)/2)" : ""

            onStatus?("Extracting audio\(trackNote)…")
            onProgress?(nil)
            let wav = tmp.appendingPathComponent("track\(index).wav")
            try await run(ffmpeg, ["-v", "error", "-y", "-i", input.path,
                                   "-map", "0:a:\(index)", "-ac", "1", "-ar", "16000", wav.path])

            onStatus?("Transcribing\(trackNote)…")
            var args = ["transcribe", "--audio-path", wav.path] + modelArgs
                + ["--report", "--report-path", tmp.path, "--verbose"]
            if translateToEnglish { args += ["--task", "translate"] }
            // whisperkit-cli --verbose renders a "] 42% |" bar; parse the percentage.
            let trackBase = Double(index)
            let trackCount = Double(labels.count)
            let progress = onProgress
            try await run(whisper, args) { line in
                guard let percent = Self.progressPercent(in: line) else { return }
                progress?((trackBase + percent / 100.0) / trackCount)
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

        onStatus?("Writing subtitles…")
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
        if isCancelled { throw CancellationError() }

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

        setCurrentProcess(process)
        defer { setCurrentProcess(nil) }
        try process.run()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in c.resume() }
        }
        pipe.fileHandleForReading.readabilityHandler = nil

        if isCancelled { throw CancellationError() }
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

    /// Locate a WhisperKit CoreML model folder: RecBar's own download
    /// directory first, then MacWhisper's. Prefers large-v3.
    public static func findModel() -> URL? {
        let roots = [
            modelDownloadDirectory,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support/MacWhisper/models/whisperkit/models/argmaxinc/whisperkit-coreml"),
        ]
        var found: [URL] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                guard enumerator.level <= 6, url.hasDirectoryPath else { continue }
                // A model folder contains the CoreML encoder package.
                let marker = url.appendingPathComponent("AudioEncoder.mlmodelc")
                if FileManager.default.fileExists(atPath: marker.path) {
                    found.append(url)
                    enumerator.skipDescendants()
                }
            }
        }
        return found.first { $0.lastPathComponent.contains("large-v3") } ?? found.first
    }

    /// Extract the last "] 42% |"-style percentage from whisperkit-cli's
    /// progress bar output, if the line contains one.
    static func progressPercent(in line: String) -> Double? {
        var best: Double?
        var search = line[...]
        while let mark = search.range(of: "% ") {
            var digits = ""
            for char in search[..<mark.lowerBound].reversed() {
                guard char.isNumber else { break }
                digits.insert(char, at: digits.startIndex)
            }
            if let value = Double(digits) { best = value }
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
public enum SRT {
    public struct Cue {
        public var startMS: Int
        public var endMS: Int
        public var text: String
        public init(startMS: Int, endMS: Int, text: String) {
            self.startMS = startMS; self.endMS = endMS; self.text = text
        }
    }

    public static func parse(_ content: String) -> [Cue] {
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

    public static func render(_ cues: [Cue]) -> String {
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
