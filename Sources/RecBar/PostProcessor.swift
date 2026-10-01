import Foundation
import RecCore

/// Background queue for post-recording audio clean-up. Stop hands the file
/// over and returns immediately, so the next recording can start while
/// earlier ones are processed one at a time, at low priority. Failures are
/// shown in the panel instead of modal alerts, so they never interrupt a
/// live recording.
@MainActor
final class PostProcessor: ObservableObject {
    static let shared = PostProcessor()

    struct Job: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        var cleanUpAudio = true    // false: only embed marker chapters
    }

    struct Failure: Identifiable {
        let id = UUID()
        let url: URL
        let message: String
    }

    @Published private(set) var current: Job?
    @Published private(set) var waiting: [Job] = []
    /// nil = not started yet (waiting for the file lock / loading), else 0…1.
    @Published private(set) var fraction: Double?
    @Published private(set) var lastFinished: URL?
    @Published private(set) var failures: [Failure] = []

    private var worker: Task<Void, Never>?

    var isBusy: Bool { current != nil || !waiting.isEmpty }
    var pendingCount: Int { waiting.count + (current == nil ? 0 : 1) }

    func enqueue(_ url: URL, cleanUpAudio: Bool = true) {
        waiting.append(Job(url: url, cleanUpAudio: cleanUpAudio))
        lastFinished = nil
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        while !Task.isCancelled, !waiting.isEmpty {
            let job = waiting.removeFirst()
            current = job
            fraction = nil
            do {
                try await AudioNormalizer.normalize(fileURL: job.url, cleanUpAudio: job.cleanUpAudio) { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.current?.id == job.id else { return }
                        self.fraction = value
                    }
                }
                lastFinished = job.url
            } catch is CancellationError {
                break
            } catch {
                failures.append(Failure(url: job.url, message: "\(error)"))
            }
            current = nil
            fraction = nil
        }
        current = nil
        fraction = nil
        worker = nil
    }

    /// Stops everything (used on quit). The running job's original file is
    /// kept intact; queued files simply stay unprocessed.
    func cancelAll() async {
        waiting.removeAll()
        let running = worker
        running?.cancel()
        await running?.value
    }

    func dismiss(_ failure: Failure) {
        failures.removeAll { $0.id == failure.id }
    }

    func dismissFinished() {
        lastFinished = nil
    }
}
