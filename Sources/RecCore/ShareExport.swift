import AVFoundation
import Foundation

/// Makes a shareable copy of a recording: one normal stereo audio track (both
/// sides mixed) in an .mp4, because most players and upload targets only use
/// the first audio track. Video is stream-copied unless subtitles are burned
/// in. The multi-track original is left untouched.
public enum ShareExport {
    /// Writes `<name>-share.mp4` next to `fileURL` and returns it.
    /// - burnSubtitles: render the sidecar `.srt` into the picture (re-encodes
    ///   video). Otherwise a matching `.srt` is attached as a toggleable track.
    public static func export(fileURL: URL, burnSubtitles: Bool = false,
                              progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        guard let ffmpeg = AudioNormalizer.ffmpegPath else {
            throw RecError("ffmpeg not found — brew install ffmpeg")
        }

        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration).seconds
        let audioCount = try await asset.loadTracks(withMediaType: .audio).count
        let hasVideo = try await !asset.loadTracks(withMediaType: .video).isEmpty
        guard audioCount > 0 else { throw RecError("\(fileURL.lastPathComponent) has no audio.") }

        let output = availableOutputURL(for: fileURL)
        let sidecarSRT = fileURL.deletingPathExtension().appendingPathExtension("srt")
        let hasSRT = FileManager.default.fileExists(atPath: sidecarSRT.path)

        var args = ["-v", "error", "-nostats", "-progress", "pipe:1", "-y", "-i", fileURL.path]
        if hasSRT, !burnSubtitles { args += ["-i", sidecarSRT.path] }

        // Audio: mix every track into one stereo track, limiter so overlapping
        // speech (both at −16 LUFS) can't clip.
        let inputs = (0..<audioCount).map { "[0:a:\($0)]" }.joined()
        let mix = audioCount > 1
            ? "\(inputs)amix=inputs=\(audioCount):normalize=0,alimiter=limit=0.95[a]"
            : "[0:a:0]anull[a]"
        var filters = [mix]

        if hasVideo {
            if burnSubtitles, hasSRT {
                // libass needs the path escaped for the filter parser.
                let escaped = sidecarSRT.path
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: ":", with: "\\:")
                    .replacingOccurrences(of: "'", with: "\\'")
                filters.append("[0:v]subtitles='\(escaped)'[v]")
            }
        }
        args += ["-filter_complex", filters.joined(separator: ";")]

        if hasVideo {
            if burnSubtitles, hasSRT {
                args += ["-map", "[v]", "-c:v", "hevc_videotoolbox", "-b:v", "4M", "-tag:v", "hvc1"]
            } else {
                args += ["-map", "0:v:0", "-c:v", "copy", "-tag:v", "hvc1"]
            }
        }
        args += ["-map", "[a]", "-c:a", "aac", "-b:a", "160k", "-ac", "2"]
        if hasSRT, !burnSubtitles {
            args += ["-map", "1:0", "-c:s", "mov_text", "-metadata:s:s:0", "language=eng"]
        }
        args += ["-movflags", "+faststart", output.path]

        let result = try await AudioNormalizer.runFFmpeg(ffmpeg, args) { line in
            guard duration > 0, line.hasPrefix("out_time_us="),
                  let us = Double(line.dropFirst("out_time_us=".count)) else { return }
            progress?(min(us / 1_000_000 / duration, 1.0))
        }
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: output)
            throw RecError("ffmpeg export failed: \(result.stderr.suffix(300))")
        }
        progress?(1.0)
        return output
    }

    private static func availableOutputURL(for input: URL) -> URL {
        let dir = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent + "-share"
        var candidate = dir.appendingPathComponent("\(base).mp4")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-\(counter).mp4")
            counter += 1
        }
        return candidate
    }
}
