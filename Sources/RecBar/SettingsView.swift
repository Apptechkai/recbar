import AppKit
import RecCore
import SwiftUI

/// RecBar → Settings (⌘, or the gear in the panel). The recordings folder is
/// shared with the `rec` CLI via RecSettings.
struct SettingsView: View {
    @ObservedObject var controller = RecController.shared
    @State private var folder = RecPaths.resolveRecordingsDirectory()
    @State private var isCustom = RecSettings.customRecordingsFolder != nil
    @State private var error: String?

    var body: some View {
        Form {
            SwiftUI.Section {
                LabeledContent("Save recordings to") {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill").foregroundStyle(.blue)
                        Text(RecPaths.displayPath(folder.url))
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(folder.url.path)
                    }
                }
                HStack {
                    Button("Change…", action: chooseFolder)
                    Button("Show in Finder") { NSWorkspace.shared.open(folder.url) }
                    if isCustom {
                        Button("Use Default") { apply(nil) }
                            .help("Back to \(RecPaths.displayPath(RecPaths.defaultRecordingsDirectory))")
                    }
                    Spacer()
                }
                if let warning = folder.warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let free = RecPaths.freeSpaceDescription(for: folder.url) {
                    Text("\(free) — an hour of recording takes about 1.8 GB (115 MB audio-only).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if needsPrivacyNote(folder.url) {
                    Text("macOS may ask RecBar for permission to use this folder the first time it records.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Recordings")
            } footer: {
                Text("Applies to new recordings, in RecBar and in the `rec` command-line tool. Existing recordings stay where they are.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            SwiftUI.Section("Panel") {
                Toggle("Keep the RecBar window on top of other apps", isOn: $controller.keepOnTop)
                Text("Off: the window hides when you click another app. Bring it back from the Dock or with ⌃⌥R.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: reload)
    }

    private func reload() {
        folder = RecPaths.resolveRecordingsDirectory()
        isCustom = RecSettings.customRecordingsFolder != nil
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder.url
        panel.prompt = "Use This Folder"
        panel.message = "Choose where RecBar saves new recordings"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        apply(url)
    }

    private func apply(_ url: URL?) {
        error = nil
        if let url, let problem = RecPaths.problem(with: url) {
            error = "\(RecPaths.displayPath(url)) \(problem). Choose another folder."
            return
        }
        RecSettings.customRecordingsFolder = url
        reload()
    }

    /// Folders macOS guards with its own per-app permission prompt.
    private func needsPrivacyNote(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.standardizedFileURL.path
        let guarded = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"]
            .map { "\(home)/\($0)" }
        return guarded.contains { path == $0 || path.hasPrefix($0 + "/") }
            || path.hasPrefix("/Volumes/")
    }
}

/// Hosts SettingsView in its own window, like the panel.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "RecBar Settings"
            window.isReleasedWhenClosed = false
            self.window = window
        }
        // Fresh view each time so it re-reads the (possibly CLI-changed) setting.
        let hosting = NSHostingView(rootView: SettingsView())
        window?.contentView = hosting
        window?.setContentSize(hosting.fittingSize)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
