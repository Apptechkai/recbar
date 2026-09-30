import Foundation

/// Launches a process fully detached from the caller: its own session (so
/// Ctrl+C in a terminal, or the parent quitting, can't take it down), default
/// signal handling, stdin from /dev/null, output appended to `log`.
/// Used for background clean-up jobs (CLI) and for RecBar's self-update,
/// which must outlive the app it replaces.
public func spawnDetached(executable: String, arguments: [String], log: URL,
                          extraEnvironment: [String: String] = [:]) -> pid_t? {
    try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)

    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&fileActions, 1, log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    posix_spawn_file_actions_adddup2(&fileActions, 1, 2)

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // The CLI ignores SIGINT/SIGTERM while recording; children must not inherit that.
    var defaultSignals = sigset_t()
    sigemptyset(&defaultSignals)
    sigaddset(&defaultSignals, SIGINT)
    sigaddset(&defaultSignals, SIGTERM)
    posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
    var emptyMask = sigset_t()
    sigemptyset(&emptyMask)
    posix_spawnattr_setsigmask(&attributes, &emptyMask)
    posix_spawnattr_setflags(&attributes,
                             Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

    var environment = ProcessInfo.processInfo.environment
    environment.merge(extraEnvironment) { _, new in new }
    let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { envp.forEach { free($0) } }

    let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let status = posix_spawn(&pid, executable, &fileActions, &attributes, argv, envp)
    return status == 0 ? pid : nil
}
