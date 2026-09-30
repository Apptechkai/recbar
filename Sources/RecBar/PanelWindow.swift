import AppKit
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
            window.title = "RecBar"
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
        HotKey.register()  // ⌃⌥R → show panel
        Task { @MainActor in PanelWindow.shared.show() }  // Dock launch → panel
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

/// Global hotkey via Carbon — works without Accessibility permission, unlike
/// NSEvent global monitors.
enum HotKey {
    private static var hotKeyRef: EventHotKeyRef?

    static func register() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in PanelWindow.shared.show() }
            return noErr
        }, 1, &eventType, nil, nil)

        let hotKeyID = EventHotKeyID(signature: 0x5242_4152 /* 'RBAR' */, id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey),
                            hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
