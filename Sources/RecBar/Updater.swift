import AppKit
import Foundation
import RecCore

/// Settings → Updates. Checks GitHub only when asked. "Update Now" re-runs
/// the one-command installer from its own copy of the source: it pulls the
/// latest code, rebuilds, replaces RecBar and reopens it. The installer is
/// launched detached so it survives RecBar being quit and replaced.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum Phase {
        case idle
        case checking
        case upToDate(checkedAt: Date)
        case available(count: Int, changes: [UpdateCheck.Change])
        case aheadOfGitHub
        case updating
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    let build = BuildInfo.current()
    private var watchTimer: Timer?

    var isBusy: Bool {
        switch phase {
        case .checking, .updating: return true
        default: return false
        }
    }

    /// Why Update Now can't run right now, if anything.
    var blockedReason: String? {
        // Includes recordings and clean-ups started from the `rec` CLI.
        if RecController.shared.isRecording || PidFile.runningPID() != nil {
            return "Stop the recording first."
        }
        if PostProcessor.shared.isBusy || ProcessingLock.currentJob() != nil {
            return "Wait until the audio clean-up finishes."
        }
        return nil
    }

    func check() async {
        guard let commit = build.commit else {
            phase = .failed("This copy of RecBar has no version stamp, so it can't be compared with GitHub. Reinstall it with the one-command installer.")
            return
        }
        phase = .checking
        do {
            switch try await UpdateCheck.check(localCommit: commit) {
            case .upToDate:
                phase = .upToDate(checkedAt: Date())
            case .updateAvailable(let count, let changes):
                phase = .available(count: count, changes: changes)
            case .aheadOfGitHub:
                phase = .aheadOfGitHub
            }
        } catch {
            phase = .failed("Couldn't check for updates: \(error.localizedDescription)")
        }
    }

    func updateNow() {
        guard build.isInstallerManaged, blockedReason == nil else { return }
        let source = UpdateCheck.installerSourceDirectory.path
        let script = UpdateCheck.installerSourceDirectory.appendingPathComponent("install.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            phase = .failed("The installer isn't where RecBar expects it. Run the one-command install line from the README again.")
            return
        }
        // Apps launched from the Dock get a minimal PATH; the installer needs
        // Homebrew's to update ffmpeg / whisperkit-cli and the `rec` tool.
        let path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        // Pull first, then run the *new* install.sh, so fixes to the installer
        // itself apply on this update rather than the next one. (If the pull
        // fails, the installer handles it: it re-downloads the source.)
        let command = "git -C \"$RECBAR_SRC\" pull --ff-only --quiet; exec /bin/bash \"$RECBAR_SRC/install.sh\""
        guard let pid = spawnDetached(executable: "/bin/bash", arguments: ["-c", command],
                                      log: UpdateCheck.installLog,
                                      extraEnvironment: ["PATH": path, "RECBAR_SRC": source]) else {
            phase = .failed("Couldn't start the installer.")
            return
        }
        phase = .updating
        // On success the installer quits this copy of RecBar and opens the new
        // one, so if the installer finishes and we're still running, it failed.
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            // The installer is our child: once it exits it lingers as a zombie
            // (so kill(pid, 0) keeps succeeding) until we reap it with waitpid.
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            guard result == pid || (result == -1 && errno == ECHILD) else { return }
            timer.invalidate()
            Task { @MainActor in
                self?.phase = .failed("The update didn't complete — RecBar is still on the old version. Details are in the install log.")
            }
        }
    }

    func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([UpdateCheck.installLog])
    }

    /// Commands for people who built RecBar from their own checkout.
    var manualUpdateCommand: String {
        let folder = build.sourceDirectory.map { RecPaths.displayPath($0) } ?? "<your RecBar folder>"
        return "cd \(folder) && git pull && make install-app"
    }
}
