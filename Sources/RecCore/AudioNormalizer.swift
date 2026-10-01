import AVFoundation
import Foundation

/// Post-recording speech processing + loudness normalization via ffmpeg.
///
/// Meeting audio arrives quiet, uneven and noisy. Each audio track gets a
/// podcast-style chain — high-pass, spectral denoise, (mic: small presence
/// lift), gentle compression — then a two-pass *linear* EBU R128
/// normalization to −16 LUFS: pass 1 measures integrated loudness with the
/// `ebur128` meter (all tracks in parallel), pass 2 applies one fixed gain
/// plus a peak limiter. Linear matters: single-pass dynamic normalization
/// pumps the noise floor up between words. (ffmpeg's `loudnorm` does the same
/// job but upsamples to 192 kHz internally, which made clean-up ~4× slower.)
/// Video is stream-copied, so this never touches picture quality.
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
    /// Target integrated loudness (LUFS) — the usual level for spoken content.
    static let targetLUFS = -16.0
    /// Peak ceiling after gain: 0.84 ≈ −1.5 dBFS.
    static let limiter = "alimiter=limit=0.84:level=disabled:attack=5:release=50"
    /// Never boost more than this: a nearly silent track (muted mic) would
    /// otherwise have its noise floor pushed up to speech level.
    static let maxGainDB = 24.0

    /// Post-recording pass, in place: cleans up and normalizes every audio
    /// track (unless `cleanUpAudio` is false) and embeds the recording's
    /// markers as chapters. `progress` receives 0…1 (the first call, 0, means
    /// "started" — before it the job is waiting for another clean-up to
    /// finish). Runs at low priority so it can overlap a new recording.
    /// Cancellable: cancelling the task stops ffmpeg. On any failure or
    /// cancellation the original file is left untouched.
    public static func normalize(fileURL: URL, cleanUpAudio: Bool = true,
                                 progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard let ffmpeg = ffmpegPath else {
            throw RecError("ffmpeg not found — brew install ffmpeg (recording kept unprocessed)")
        }

        let lock = try await ProcessingLock.acquire(label: fileURL.path)
        defer { ProcessingLock.release(lock) }
        progress?(0)

        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let chapters = MarkerFile.ffmetadata(markers: MarkerFile.load(for: fileURL), duration: duration)
        if !cleanUpAudio && chapters == nil { progress?(1); return }   // nothing to do
        guard !audioTracks.isEmpty || chapters != nil else { return }

        // -- Pass 1: measure loudness of every track (after its chain), in parallel
        var filters: [String] = []
        if cleanUpAudio {
            let chains = audioTracks.indices.map { $0 == 1 ? micChain : systemChain }
            let loudness = try await withThrowingTaskGroup(of: (Int, Double?).self) { group in
                for (index, chain) in chains.enumerated() {
                    group.addTask {
                        (index, try await measure(ffmpeg: ffmpeg, file: fileURL, track: index, chain: chain))
                    }
                }
                var results = [Double?](repeating: nil, count: chains.count)
                for try await (index, value) in group { results[index] = value }
                return results
            }
            filters = chains.enumerated().map { index, chain in
                guard let measured = loudness[index] else {
                    // Silent track (e.g. window capture of an app that played no
                    // sound): nothing to normalize, just run the clean-up chain.
                    return chain
                }
                let gain = min(targetLUFS - measured, maxGainDB)
                return "\(chain),volume=\(String(format: "%.2f", gain))dB,\(limiter)"
            }
        }
        let applyStart = cleanUpAudio ? 0.3 : 0.0
        progress?(applyStart)

        // -- Pass 2: apply, video copied, atomic swap --------------------------
        let tmpURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).normalizing.mov")
        let chaptersURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).chapters.txt")
        try? FileManager.default.removeItem(at: tmpURL)
        defer { try? FileManager.default.removeItem(at: chaptersURL) }

        var args = ["-v", "error", "-nostats", "-progress", "pipe:1", "-y", "-i", fileURL.path]
        if let chapters {
            try chapters.write(to: chaptersURL, atomically: true, encoding: .utf8)
            args += ["-i", chaptersURL.path, "-map_chapters", "1"]
        }
        // Explicit maps: an existing chapter track is a data stream; copying it
        // as well as writing chapters would duplicate them.
        args += ["-map", "0:v?", "-map", "0:a", "-map", "0:s?",
                 "-c:v", "copy", "-tag:v", "hvc1", "-c:s", "copy"]
        if cleanUpAudio {
            args += ["-c:a", "aac"]
            for (index, track) in audioTracks.enumerated() {
                var channels: UInt32 = 2
                if let description = try? await track.load(.formatDescriptions).first,
                   let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                    channels = asbd.pointee.mChannelsPerFrame
                }
                args += ["-filter:a:\(index)", filters[index],
                         "-b:a:\(index)", channels > 1 ? "160k" : "96k"]
            }
        } else {
            args += ["-c:a", "copy"]   // chapters only: audio untouched
        }
        args.append(tmpURL.path)

        let result: (status: Int32, stderr: String)
        do {
            result = try await runFFmpeg(ffmpeg, args, qos: .utility) { line in
                guard duration > 0, line.hasPrefix("out_time_us="),
                      let us = Double(line.dropFirst("out_time_us=".count)) else { return }
                progress?(applyStart + (1 - applyStart) * min(us / 1_000_000 / duration, 1.0))
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)   // cancelled mid-write
            throw error
        }
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: tmpURL)
            throw RecError("ffmpeg processing failed: \(result.stderr.suffix(300))")
        }

        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
        progress?(1.0)
    }

    /// Pass 1: integrated loudness (LUFS) of one track after its clean-up
    /// chain, or nil if the track is (near-)silent and shouldn't be
    /// normalized at all (ebur128's gate reports −70 for silence).
    private static func measure(ffmpeg: String, file: URL, track: Int, chain: String) async throws -> Double? {
        let result = try await runFFmpeg(ffmpeg, [
            "-v", "info", "-nostats", "-i", file.path, "-map", "0:a:\(track)",
            "-af", "\(chain),ebur128=framelog=quiet", "-f", "null", "-",
        ], qos: .utility)
        // Summary block at the end:  "Integrated loudness:\n    I:   -23.4 LUFS"
        guard result.status == 0,
              let summary = result.stderr.range(of: "Integrated loudness:", options: .backwards),
              let line = result.stderr[summary.upperBound...]
                .split(separator: "\n").first(where: { $0.contains("I:") }),
              let value = line.split(separator: " ").compactMap({ Double($0) }).first
        else {
            throw RecError("loudness measurement failed on track \(track + 1): \(result.stderr.suffix(200))")
        }
        return value.isFinite && value > -69.5 ? value : nil
    }

    /// Runs ffmpeg, streaming stdout lines (for `-progress pipe:1`) and
    /// collecting stderr. Shared by the normalizer and the share exporter.
    /// Cancelling the calling task terminates ffmpeg and throws
    /// CancellationError. `qos: .utility` keeps background work on the
    /// efficiency cores, out of the way of a live recording.
    static func runFFmpeg(_ ffmpeg: String, _ args: [String],
                          qos: QualityOfService = .userInitiated,
                          onStdoutLine: (@Sendable (String) -> Void)? = nil)
        async throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = args
        process.qualityOfService = qos
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

        // Handler installed before launch so a very short run can't finish
        // before we're listening.
        var stderrTask: Task<Data, Never>?
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in c.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    c.resume(throwing: error)
                    return
                }
                // Drain stderr concurrently so a chatty ffmpeg can't block on a full pipe.
                stderrTask = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }
            }
        } onCancel: {
            process.terminate()
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        let text = String(data: await stderrTask?.value ?? Data(), encoding: .utf8) ?? ""
        if Task.isCancelled { throw CancellationError() }
        return (process.terminationStatus, text)
    }
}
