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
            window.level = .floating
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKey.register()  // ⌃⌥R → show panel
    }

    /// Called when the user "opens" RecBar while it's already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        Task { @MainActor in PanelWindow.shared.show() }
        return false
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
