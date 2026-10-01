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
    /// Open speaker-separation models (SpeakerKit, CC-BY-4.0).
    public static var speakerModelDirectory: URL {
        modelDownloadDirectory.appendingPathComponent("speakerkit", isDirectory: true)
    }

    /// Tell the meeting's speakers apart (Speaker 1, 2, …) — on by default.
    public let identifySpeakers: Bool

    public init(input: URL, translateToEnglish: Bool = false, identifySpeakers: Bool = true) {
        self.input = input
        self.translateToEnglish = translateToEnglish
        self.identifySpeakers = identifySpeakers
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

    /// Runs the whole pipeline and returns the written .srt URL. Also writes
    /// `<name>.transcript.json` beside it (who said what, for renaming).
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
        // Recall Bar layout: exactly 2 audio tracks = system audio (the
        // meeting) + mic (you). Anything else: transcribe the first track.
        let recBarLayout = audioTracks.count == 2
        let trackCount = recBarLayout ? 2 : 1

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

        var trackCues: [[SRT.Cue]] = []
        var turns: SpeakerTurns?
        for index in 0..<trackCount {
            let trackNote = trackCount == 2 ? " (track \(index + 1)/2)" : ""

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
            let total = Double(trackCount)
            let progress = onProgress
            try await run(whisper, args) { line in
                guard let percent = Self.progressPercent(in: line) else { return }
                progress?((trackBase + percent / 100.0) / total)
            }

            let srt = tmp.appendingPathComponent("track\(index).srt")
            guard let content = try? String(contentsOf: srt, encoding: .utf8) else {
                throw RecError("whisperkit-cli produced no subtitles for track \(index + 1).")
            }
            trackCues.append(SRT.parse(content))

            // Who is speaking: the meeting track (or the only track).
            if identifySpeakers, index == 0, !trackCues[0].isEmpty {
                onStatus?("Telling speakers apart\(trackNote)…")
                onProgress?(nil)
                do {
                    turns = try await diarize(whisper: whisper, wav: wav, tmp: tmp)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    onStatus?("Couldn't tell speakers apart (\(error)); continuing without.")
                }
            }
        }

        onStatus?("Writing subtitles…")
        var transcript = buildTranscript(trackCues: trackCues, recBarLayout: recBarLayout, turns: turns)
        guard !transcript.cues.isEmpty else {
            throw RecError("No speech was detected in \(input.lastPathComponent).")
        }
        let output = Self.availableOutputURL(for: input, translated: translateToEnglish)
        transcript.subtitleFile = output.lastPathComponent
        try transcript.save(to: Transcript.url(forSubtitles: output))
        return output
    }

    /// Assigns speakers, flags lines near markers, merges tracks in time order.
    private func buildTranscript(trackCues: [[SRT.Cue]], recBarLayout: Bool,
                                 turns: SpeakerTurns?) -> Transcript {
        func seconds(_ ms: Int) -> Double { Double(ms) / 1000 }

        // Meeting track: diarization clusters, numbered by first appearance.
        let meetingCues = trackCues.first ?? []
        let clusters = meetingCues.map { turns?.speaker(from: seconds($0.startMS), to: seconds($0.endMS)) }
        var order: [String] = []
        for case let cluster? in clusters where !order.contains(cluster) { order.append(cluster) }
        let multiple = order.count >= 2

        var speakers: [Transcript.Speaker] = []
        if recBarLayout {
            speakers.append(.init(id: "me", name: "Me", defaultName: "Me", isLocal: true))
        }
        if multiple {
            for n in order.indices {
                let name = "Speaker \(n + 1)"
                speakers.append(.init(id: "s\(n + 1)", name: name, defaultName: name, isLocal: false))
            }
        } else if recBarLayout {
            speakers.append(.init(id: "them", name: "Them", defaultName: "Them", isLocal: false))
        }

        var cues: [Transcript.Cue] = []
        for (i, cue) in meetingCues.enumerated() {
            var id: String?
            if multiple, let cluster = clusters[i], let n = order.firstIndex(of: cluster) {
                id = "s\(n + 1)"
            } else if recBarLayout {
                id = multiple ? nil : "them"
            }
            cues.append(.init(start: seconds(cue.startMS), end: seconds(cue.endMS),
                              text: cue.text, speaker: id, marked: false))
        }
        if recBarLayout, trackCues.count > 1 {
            cues += trackCues[1].map {
                .init(start: seconds($0.startMS), end: seconds($0.endMS), text: $0.text, speaker: "me", marked: false)
            }
        }

        // ★ markers: highlight what was said in the 15 s before each marker
        // (you press it right after hearing something important). A marker
        // with no speech nearby becomes its own line.
        let markers = MarkerFile.load(for: input)
        for marker in markers {
            var hit = false
            for i in cues.indices where cues[i].end > marker.time - 15 && cues[i].start < marker.time + 2 {
                cues[i].marked = true
                hit = true
            }
            if !hit {
                cues.append(.init(start: marker.time, end: marker.time + 3,
                                  text: marker.title, speaker: nil, marked: true))
            }
        }
        cues.sort { $0.start < $1.start }

        return Transcript(recording: input.path, subtitleFile: "", speakers: speakers,
                          cues: cues, markers: markers)
    }

    /// Runs `whisperkit-cli diarize` (open SpeakerKit models, CC-BY-4.0,
    /// ~11 MB, downloaded once) and returns the speaker turns.
    private func diarize(whisper: String, wav: URL, tmp: URL) async throws -> SpeakerTurns {
        let rttm = tmp.appendingPathComponent("speakers.rttm")
        var args = ["diarize", "--audio-path", wav.path, "--rttm-path", rttm.path]
        let models = Self.speakerModelDirectory
            .appendingPathComponent("models/argmaxinc/speakerkit-coreml", isDirectory: true)
        if FileManager.default.fileExists(atPath: models.appendingPathComponent("speaker_segmenter").path) {
            args += ["--model-path", models.path]
        } else {
            try FileManager.default.createDirectory(at: Self.speakerModelDirectory, withIntermediateDirectories: true)
            args += ["--download-model-path", Self.speakerModelDirectory.path]
            onStatus?("Downloading the speaker models (first time only, 11 MB)…")
        }
        try await run(whisper, args)
        let text = try String(contentsOf: rttm, encoding: .utf8)
        return SpeakerTurns(rttm: text)
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
