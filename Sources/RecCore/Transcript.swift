import Foundation

/// The structured result of a transcription, saved next to the subtitles as
/// `<name>.transcript.json`. It remembers who said each line (speaker ids,
/// not names), so speakers can be renamed later and the `.srt` re-rendered
/// without transcribing again.
public struct Transcript: Codable, Sendable {
    public struct Cue: Codable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String
        public var speaker: String?     // Speaker.id, or nil (unlabelled)
        public var marked: Bool         // near a ★ marker
    }

    public struct Speaker: Codable, Sendable, Identifiable, Equatable {
        public let id: String           // "me", "them", "s1", "s2", …
        public var name: String         // what the subtitles show
        public let defaultName: String  // "Me", "Speaker 2", …
        public let isLocal: Bool        // your microphone track
    }

    public var recording: String        // absolute path of the source file
    public var subtitleFile: String     // .srt file name in the same folder
    public var speakers: [Speaker]
    public var cues: [Cue]
    public var markers: [Marker]

    // MARK: Files

    public static func url(forSubtitles srt: URL) -> URL {
        srt.deletingPathExtension().appendingPathExtension("transcript.json")
    }

    /// Finds the transcript for a recording, subtitle or transcript path —
    /// the most recently written one if there are several.
    public static func locate(for path: URL) -> URL? {
        let fm = FileManager.default
        if path.lastPathComponent.hasSuffix(".transcript.json") {
            return fm.fileExists(atPath: path.path) ? path : nil
        }
        if path.pathExtension.lowercased() == "srt" {
            let candidate = url(forSubtitles: path)
            return fm.fileExists(atPath: candidate.path) ? candidate : nil
        }
        let base = path.deletingPathExtension().lastPathComponent
        let folder = path.deletingLastPathComponent()
        let matches = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(base) && $0.lastPathComponent.hasSuffix(".transcript.json") }
        return matches.max {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
    }

    public static func load(from url: URL) throws -> Transcript {
        try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: url))
    }

    /// Saves the JSON at `url` and (re)writes the `.srt` beside it.
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        let srt = url.deletingLastPathComponent().appendingPathComponent(subtitleFile)
        try renderSRT().write(to: srt, atomically: true, encoding: .utf8)
    }

    // MARK: Rendering

    public func renderSRT() -> String {
        let names = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.name) })
        let rendered = cues.map { cue -> SRT.Cue in
            var text = cue.text
            if let id = cue.speaker, let name = names[id], !name.isEmpty { text = "[\(name)] \(text)" }
            if cue.marked { text = "★ " + text }
            return SRT.Cue(startMS: Int((cue.start * 1000).rounded()), endMS: Int((cue.end * 1000).rounded()), text: text)
        }
        return SRT.render(rendered)
    }

    // MARK: Speakers

    public mutating func rename(_ id: String, to name: String) {
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        speakers[index].name = trimmed.isEmpty ? speakers[index].defaultName : trimmed
    }

    public struct SpeakerSummary: Sendable {
        public let speaker: Speaker
        public let talkTime: Double
        public let lineCount: Int
        public let firstLines: [Cue]     // a couple of things they said, to recognise them
    }

    public func summaries(sampleLines: Int = 2) -> [SpeakerSummary] {
        speakers.map { speaker in
            let lines = cues.filter { $0.speaker == speaker.id }
            let samples = lines.filter { $0.text.split(separator: " ").count >= 4 }.prefix(sampleLines)
            return SpeakerSummary(speaker: speaker,
                                  talkTime: lines.reduce(0) { $0 + ($1.end - $1.start) },
                                  lineCount: lines.count,
                                  firstLines: Array(samples.isEmpty ? lines.prefix(sampleLines) : samples))
        }
    }
}

/// Speaker turns from `whisperkit-cli diarize` (RTTM format).
struct SpeakerTurns {
    struct Turn { let start: Double; let end: Double; let speaker: String }
    let turns: [Turn]

    init(rttm: String) {
        // "SPEAKER <file> 1 <start> <duration> <NA> <NA> <speaker> <NA> <NA>"
        turns = rttm.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ")
            guard f.count >= 8, f[0] == "SPEAKER",
                  let start = Double(f[3]), let duration = Double(f[4]) else { return nil }
            return Turn(start: start, end: start + duration, speaker: String(f[7]))
        }
    }

    /// The speaker who talks most during [start, end], or the nearest turn
    /// within 1 s if nobody overlaps it.
    func speaker(from start: Double, to end: Double) -> String? {
        var overlap: [String: Double] = [:]
        for turn in turns where turn.end > start && turn.start < end {
            overlap[turn.speaker, default: 0] += min(turn.end, end) - max(turn.start, start)
        }
        if let best = overlap.max(by: { $0.value < $1.value }) { return best.key }
        let nearest = turns.min { distance($0, start, end) < distance($1, start, end) }
        return nearest.flatMap { distance($0, start, end) <= 1 ? $0.speaker : nil }
    }

    private func distance(_ turn: Turn, _ start: Double, _ end: Double) -> Double {
        max(0, max(turn.start - end, start - turn.end))
    }
}
