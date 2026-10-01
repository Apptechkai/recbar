import AppKit
import RecCore
import Carbon.HIToolbox
import SwiftUI

/// The menu bar icon can be hidden by a crowded menu bar, so the same panel
/// is also reachable as a small floating window: re-launching RecBar
/// (Spotlight/Dock) or pressing ⌃⌥R opens it.
@MainActor
final class PanelWindow {
    static let shared = PanelWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingView(rootView: PanelView(
                controller: RecController.shared, transcriber: Transcriber.shared))
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Recall Bar"
            window.contentView = hosting
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
            applyPinning(RecController.shared.keepOnTop)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Pinned: floats above other apps. Unpinned: hides as soon as another
    /// app is clicked (comes back via Dock icon or ⌃⌥R).
    func applyPinning(_ pinned: Bool) {
        window?.level = pinned ? .floating : .normal
        window?.hidesOnDeactivate = !pinned
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKey.register()  // ⌃⌥R → show panel, ⌃⌥M → ★ marker
        Task { @MainActor in MeetingDetector.shared.start() }
        Task { @MainActor in
            PanelWindow.shared.show()  // Dock launch → panel
            // `open -a RecBar --args --show-settings` opens Settings directly;
            // --check-updates / --update-now drive the Updates section (used
            // to test updating end to end without clicking).
            let args = CommandLine.arguments
            if args.contains("--show-settings") || args.contains("--check-updates") {
                SettingsWindow.shared.show()
            }
            // `--name-speakers <recording|.srt>` opens Name Speakers for it.
            if let i = args.firstIndex(of: "--name-speakers"), i + 1 < args.count,
               let json = Transcript.locate(for: URL(fileURLWithPath: args[i + 1])) {
                SpeakersWindow.shared.show(transcriptURL: json)
            }
            if args.contains("--check-updates") || args.contains("--update-now") {
                await Updater.shared.check()
                if args.contains("--update-now"), case .available = Updater.shared.phase {
                    Updater.shared.updateNow()
                }
            }
        }
    }

    /// Called when the user clicks the Dock icon while RecBar is running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        Task { @MainActor in PanelWindow.shared.show() }
        return false
    }

    /// Closing the panel must not quit — recording continues in the background.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Every quit path (panel button, Dock menu, ⌘Q, logout) lands here:
    /// confirm if a recording or clean-up is running, then finalize the file
    /// and stop background work before exiting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let proceed = MainActor.assumeIsolated { RecController.shared.confirmQuit() }
        guard proceed else { return .terminateCancel }
        Task { @MainActor in
            await RecController.shared.shutdownForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Global hotkeys via Carbon — work without Accessibility permission, unlike
/// NSEvent global monitors.
///   ⌃⌥R  show the panel
///   ⌃⌥M  drop a ★ marker in the current recording
enum HotKey {
    private static var refs: [EventHotKeyRef?] = []
    private static let signature: OSType = 0x5242_4152 // 'RBAR'

    static func register() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            Task { @MainActor in
                switch id {
                case 2: RecController.shared.addMarker()
                default: PanelWindow.shared.show()
                }
            }
            return noErr
        }, 1, &eventType, nil, nil)

        for (id, key) in [(UInt32(1), kVK_ANSI_R), (UInt32(2), kVK_ANSI_M)] {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey),
                                EventHotKeyID(signature: signature, id: id),
                                GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }
}
