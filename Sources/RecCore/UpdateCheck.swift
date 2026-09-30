import Foundation

/// Which commit an app build came from — stamped into the bundle's Info.plist
/// by `make app` (keys RecBarCommit / RecBarBuildDate / RecBarSourceDir /
/// RecBarDirty).
public struct BuildInfo: Sendable {
    public let commit: String?
    public let buildDate: Date?
    public let sourceDirectory: URL?
    public let hasLocalChanges: Bool

    public static func current(bundle: Bundle = .main) -> BuildInfo {
        let info = bundle.infoDictionary ?? [:]
        let commit = (info["RecBarCommit"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let date = (info["RecBarBuildDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let source = (info["RecBarSourceDir"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
        return BuildInfo(commit: commit, buildDate: date, sourceDirectory: source,
                         hasLocalChanges: (info["RecBarDirty"] as? String) == "yes")
    }

    public var shortCommit: String { commit.map { String($0.prefix(7)) } ?? "unknown" }

    /// True when this build came from the one-command installer's own copy
    /// of the source — the only case where RecBar updates itself.
    public var isInstallerManaged: Bool {
        guard let sourceDirectory else { return false }
        return sourceDirectory.standardizedFileURL.path == UpdateCheck.installerSourceDirectory.standardizedFileURL.path
    }
}

public enum UpdateCheck {
    public static let repository = "Apptechkai/recbar"
    public static let branch = "main"
    public static let installerSourceDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/RecBar/src", isDirectory: true)
    public static let installLog = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/RecBar/install.log")

    public struct Change: Sendable, Identifiable {
        public let id: String          // commit sha
        public let summary: String     // first line of the commit message
    }

    public enum Result: Sendable {
        case upToDate
        /// `changes` newest first; `count` may exceed changes.count.
        case updateAvailable(count: Int, changes: [Change])
        /// Local build has commits GitHub doesn't (a development build).
        case aheadOfGitHub
    }

    /// Asks GitHub how `main` compares with the commit this build came from.
    /// One unauthenticated request; only ever called when the user asks.
    public static func check(localCommit: String) async throws -> Result {
        let url = URL(string: "https://api.github.com/repos/\(repository)/compare/\(localCommit)...\(branch)")!
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("RecBar-update-check", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 404: throw RecError("This build (\(localCommit.prefix(7))) isn't on GitHub — probably a local development build.")
        case 403, 429: throw RecError("GitHub's rate limit was reached. Try again in an hour.")
        default: throw RecError("GitHub answered with status \(status).")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = json["status"] as? String
        else { throw RecError("Unexpected answer from GitHub.") }

        switch state {
        case "identical":
            return .upToDate
        case "behind":
            return .aheadOfGitHub
        case "ahead", "diverged":
            let commits = (json["commits"] as? [[String: Any]]) ?? []
            let changes: [Change] = commits.reversed().compactMap { entry in
                guard let sha = entry["sha"] as? String,
                      let message = (entry["commit"] as? [String: Any])?["message"] as? String
                else { return nil }
                return Change(id: sha, summary: String(message.split(separator: "\n").first ?? ""))
            }
            let count = (json["ahead_by"] as? Int) ?? changes.count
            return count == 0 ? .upToDate : .updateAvailable(count: count, changes: changes)
        default:
            throw RecError("Unexpected comparison result from GitHub: \(state).")
        }
    }
}
