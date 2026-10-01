import Foundation

/// A "this matters" point in a recording, dropped with ⌃⌥M (Recall Bar) or
/// `rec mark` while recording. Stored next to the recording as
/// `<name>.markers.json` (written on every new marker, so a crash keeps
/// them), embedded as video chapters by the post-recording pass, and
/// highlighted in transcripts.
public struct Marker: Codable, Sendable, Identifiable, Equatable {
    public let index: Int          // 1-based
    public let time: Double        // seconds from the start of the recording
    public let label: String?
    public var id: Int { index }

    public init(index: Int, time: Double, label: String?) {
        self.index = index
        self.time = time
        self.label = label
    }

    /// "Marker 3" or "Marker 3 — pricing decision".
    public var title: String {
        guard let label, !label.isEmpty else { return "Marker \(index)" }
        return "Marker \(index) — \(label)"
    }

    /// "12:34" or "1:02:03".
    public var timeText: String { Self.clock(time) }

    public static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

public enum MarkerFile {
    /// `<recording without extension>.markers.json`.
    public static func url(for recording: URL) -> URL {
        recording.deletingPathExtension().appendingPathExtension("markers.json")
    }

    public static func load(for recording: URL) -> [Marker] {
        guard let data = try? Data(contentsOf: url(for: recording)),
              let markers = try? JSONDecoder().decode([Marker].self, from: data)
        else { return [] }
        return markers.sorted { $0.time < $1.time }
    }

    static func save(_ markers: [Marker], for recording: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(markers) {
            try? data.write(to: url(for: recording), options: .atomic)
        }
    }

    // MARK: Cross-process request (`rec mark "label"`)

    /// `rec mark` drops a request here; the recording process (CLI or Recall
    /// Bar) picks it up within ¼ s and deletes it. The request carries its
    /// own timestamp, so the pickup delay doesn't move the marker.
    public static let requestPath = "/tmp/rec-cli-marker-request"

    struct Request: Codable { let label: String?; let requestedAt: Date }

    public static func writeRequest(label: String?) {
        let request = Request(label: label?.isEmpty == true ? nil : label, requestedAt: Date())
        if let data = try? JSONEncoder().encode(request) {
            try? data.write(to: URL(fileURLWithPath: requestPath), options: .atomic)
        }
    }

    /// True once the recording has consumed the request (for `rec mark`'s
    /// confirmation).
    public static var requestPending: Bool { FileManager.default.fileExists(atPath: requestPath) }

    /// Reads and clears a pending request.
    static func takeRequest() -> Request? {
        guard let data = FileManager.default.contents(atPath: requestPath) else { return nil }
        try? FileManager.default.removeItem(atPath: requestPath)
        return try? JSONDecoder().decode(Request.self, from: data)
    }

    /// Polls for `rec mark` requests while recording and adds them to
    /// `recorder` (stamped with when they were requested).
    public final class Watcher: @unchecked Sendable {
        private let timer: DispatchSourceTimer
        public init(recorder: Recorder, onMarker: @escaping @Sendable (Marker?) -> Void) {
            try? FileManager.default.removeItem(atPath: MarkerFile.requestPath)   // stale
            timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "rec.marker-requests", qos: .utility))
            timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
            timer.setEventHandler {
                guard let request = MarkerFile.takeRequest() else { return }
                onMarker(recorder.addMarker(label: request.label, requestedAt: request.requestedAt))
            }
            timer.resume()
        }
        public func stop() { timer.cancel() }
        deinit { timer.cancel() }
    }

    // MARK: Chapters

    /// ffmpeg metadata describing one chapter per marker (plus "Start"), for
    /// `-map_chapters`. Nil when there are no markers.
    static func ffmetadata(markers: [Marker], duration: Double) -> String? {
        let points = markers.filter { $0.time > 0.5 && $0.time < duration - 0.5 }
        guard !points.isEmpty else { return nil }
        func ms(_ t: Double) -> Int { Int((t * 1000).rounded()) }
        func escape(_ s: String) -> String {
            var out = ""
            for c in s {
                if "=;#\\\n".contains(c) { out.append("\\") }
                out.append(c)
            }
            return out
        }
        var chapters: [(start: Double, title: String)] = [(0, "Start")]
        chapters += points.map { ($0.time, "★ " + $0.title) }
        var text = ";FFMETADATA1\n"
        for (i, chapter) in chapters.enumerated() {
            let end = i + 1 < chapters.count ? chapters[i + 1].start : duration
            text += "[CHAPTER]\nTIMEBASE=1/1000\nSTART=\(ms(chapter.start))\nEND=\(ms(end))\ntitle=\(escape(chapter.title))\n"
        }
        return text
    }
}
