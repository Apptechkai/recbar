import AVFoundation
import Foundation

/// Post-recording loudness normalization (EBU R128 via ffmpeg's loudnorm).
/// Meeting audio arrives quiet and uneven; normalizing each track to a
/// standard level is what makes a recording sound "clear" on playback.
/// Video is stream-copied, so this is audio-only work and never touches
/// picture quality.
public enum AudioNormalizer {
    public static let ffmpegPaths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]

    public static var ffmpegPath: String? {
        ffmpegPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Normalizes every audio track of `fileURL` in place. `progress` receives
    /// 0…1 as ffmpeg works through the file. On any failure the original file
    /// is left untouched and the error is thrown.
    public static func normalize(fileURL: URL,
                                 progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard let ffmpeg = ffmpegPath else {
            throw RecError("ffmpeg not found — brew install ffmpeg (recording kept un-normalized)")
        }

        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { return }

        let tmpURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).normalizing.mov")
        try? FileManager.default.removeItem(at: tmpURL)

        var args = ["-v", "error", "-nostats", "-progress", "pipe:1", "-y",
                    "-i", fileURL.path, "-map", "0",
                    "-c:v", "copy", "-tag:v", "hvc1",
                    "-c:a", "aac",
                    "-af", "loudnorm=I=-16:TP=-1.5:LRA=11"]
        for (index, track) in audioTracks.enumerated() {
            var channels: UInt32 = 2
            if let description = try? await track.load(.formatDescriptions).first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                channels = asbd.pointee.mChannelsPerFrame
            }
            args += ["-b:a:\(index)", channels > 1 ? "160k" : "96k"]
        }
        args.append(tmpURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, duration > 0, let text = String(data: data, encoding: .utf8) else { return }
            // -progress emits "out_time_us=123456" lines as it goes.
            for line in text.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                if let us = Double(line.dropFirst("out_time_us=".count)) {
                    progress?(min(us / 1_000_000 / duration, 1.0))
                }
            }
        }

        try process.run()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in c.resume() }
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: tmpURL)
            throw RecError("ffmpeg loudnorm failed: \(errorText.suffix(300))")
        }

        // Swap in atomically: original is replaced only once the new file is complete.
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
        progress?(1.0)
    }
}
