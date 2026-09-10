import AVFoundation
import Foundation

/// Post-recording speech processing + loudness normalization via ffmpeg.
///
/// Meeting audio arrives quiet, uneven and noisy. Each audio track gets a
/// podcast-style chain — high-pass, spectral denoise, (mic: small presence
/// lift), gentle compression — then a two-pass *linear* EBU R128 normalization
/// to −16 LUFS. Two passes matter: single-pass loudnorm is dynamic and pumps
/// the noise floor up between words. Video is stream-copied, so this never
/// touches picture quality.
public enum AudioNormalizer {
    public static let ffmpegPaths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]

    public static var ffmpegPath: String? {
        ffmpegPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Track 0 (system audio / participants): clean up, keep tonal balance.
    static let systemChain =
        "highpass=f=80,afftdn=nf=-35,acompressor=threshold=-24dB:ratio=2.5:attack=5:release=120:makeup=3"
    /// Track 1 (mic): same plus a presence lift around 3.5 kHz for consonants.
    static let micChain =
        "highpass=f=80,afftdn=nf=-30,equalizer=f=3500:t=q:w=1.2:g=3,acompressor=threshold=-24dB:ratio=3:attack=5:release=120:makeup=3"
    static let loudnormTarget = "I=-16:TP=-1.5:LRA=7"

    /// Processes every audio track of `fileURL` in place. `progress` receives
    /// 0…1 across both passes. On any failure the original file is left
    /// untouched and the error is thrown.
    public static func normalize(fileURL: URL,
                                 progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard let ffmpeg = ffmpegPath else {
            throw RecError("ffmpeg not found — brew install ffmpeg (recording kept unprocessed)")
        }

        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { return }

        // -- Pass 1: measure loudness per track (after its chain) --------------
        var filters: [String] = []
        for (index, _) in audioTracks.enumerated() {
            let chain = index == 1 ? micChain : systemChain
            if let measured = try await measure(ffmpeg: ffmpeg, file: fileURL, track: index, chain: chain) {
                filters.append("\(chain),loudnorm=\(loudnormTarget):\(measured):linear=true")
            } else {
                // Silent track (e.g. window capture of an app that played no
                // sound): nothing to normalize, just run the clean-up chain.
                filters.append(chain)
            }
            progress?(0.3 * Double(index + 1) / Double(audioTracks.count))
        }

        // -- Pass 2: apply, video copied, atomic swap --------------------------
        let tmpURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).normalizing.mov")
        try? FileManager.default.removeItem(at: tmpURL)

        var args = ["-v", "error", "-nostats", "-progress", "pipe:1", "-y",
                    "-i", fileURL.path, "-map", "0",
                    "-c:v", "copy", "-tag:v", "hvc1", "-c:s", "copy", "-c:a", "aac"]
        for (index, track) in audioTracks.enumerated() {
            var channels: UInt32 = 2
            if let description = try? await track.load(.formatDescriptions).first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                channels = asbd.pointee.mChannelsPerFrame
            }
            args += ["-filter:a:\(index)", filters[index],
                     "-b:a:\(index)", channels > 1 ? "160k" : "96k"]
        }
        args.append(tmpURL.path)

        let result = try await runFFmpeg(ffmpeg, args) { line in
            guard duration > 0, line.hasPrefix("out_time_us="),
                  let us = Double(line.dropFirst("out_time_us=".count)) else { return }
            progress?(0.3 + 0.7 * min(us / 1_000_000 / duration, 1.0))
        }
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: tmpURL)
            throw RecError("ffmpeg processing failed: \(result.stderr.suffix(300))")
        }

        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
        progress?(1.0)
    }

    /// First loudnorm pass: returns the `measured_*` parameters for a linear
    /// second pass, or nil if the track is (near-)silent and shouldn't be
    /// normalized at all (loudnorm reports -inf, which pass 2 rejects).
    private static func measure(ffmpeg: String, file: URL, track: Int, chain: String) async throws -> String? {
        let result = try await runFFmpeg(ffmpeg, [
            "-v", "info", "-nostats", "-i", file.path, "-map", "0:a:\(track)",
            "-af", "\(chain),loudnorm=\(loudnormTarget):print_format=json", "-f", "null", "-",
        ])
        guard result.status == 0,
              let open = result.stderr.range(of: "{", options: .backwards),
              let close = result.stderr.range(of: "}", range: open.upperBound..<result.stderr.endIndex),
              let json = try? JSONSerialization.jsonObject(
                with: Data(result.stderr[open.lowerBound...close.upperBound].utf8)) as? [String: Any]
        else {
            throw RecError("loudness measurement failed on track \(track + 1): \(result.stderr.suffix(200))")
        }
        // ffmpeg prints numbers as strings, and "-inf" for silence.
        func number(_ key: String) -> Double? {
            let value = json[key]
            if let d = value as? Double { return d.isFinite ? d : nil }
            if let s = value as? String, let d = Double(s), d.isFinite { return d }
            return nil
        }
        guard let i = number("input_i"), i > -70,
              let tp = number("input_tp"), let lra = number("input_lra"),
              let thresh = number("input_thresh"), let offset = number("target_offset")
        else { return nil }
        return "measured_I=\(i):measured_TP=\(tp):measured_LRA=\(lra):measured_thresh=\(thresh):offset=\(offset)"
    }

    /// Runs ffmpeg, streaming stdout lines (for `-progress pipe:1`) and
    /// collecting stderr. Shared by the normalizer and the share exporter.
    static func runFFmpeg(_ ffmpeg: String, _ args: [String],
                          onStdoutLine: (@Sendable (String) -> Void)? = nil)
        async throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        if let onStdoutLine {
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                for line in text.split(separator: "\n") { onStdoutLine(String(line)) }
            }
        }

        try process.run()
        // Drain stderr concurrently so a chatty ffmpeg can't block on a full pipe.
        let stderrData = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in c.resume() }
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        let text = String(data: await stderrData.value, encoding: .utf8) ?? ""
        return (process.terminationStatus, text)
    }
}
