// Renders Recall Bar's windows offscreen with clean demo state, for the user
// guide. Built by scripts/doc-screenshots/render.sh (compiles the app's
// sources plus this file into one throwaway binary); not part of the app.
import AppKit
import SwiftUI

/// Draws controls in their active (key-window) style — accent colours on —
/// without actually taking focus from whatever you're doing.
final class ActiveApplication: NSApplication {
    override var isActive: Bool { true }
}

final class ActiveWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

@MainActor
func snapshot<V: View>(_ view: V, width: CGFloat, to path: String, settle: TimeInterval = 2.5) {
    let hosting = NSHostingView(rootView: view.frame(width: width))
    let window = ActiveWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = hosting
    window.appearance = NSAppearance(named: .aqua)
    // Offscreen, but key: AppKit only draws accent colours (the red Start
    // button, blue switches) in the focused window.
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(settle))
    let size = hosting.fittingSize
    window.setContentSize(size)
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    window.orderOut(nil)
    print("wrote \(path) (\(Int(size.width))×\(Int(size.height)) pt)")
}

@main
struct DocScreenshots {
    @MainActor
    static func main() {
        let app = ActiveApplication.shared   // first access: creates the subclass
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .aqua)
        let args = CommandLine.arguments
        let out = args.count > 1 ? args[1] : "."
        let transcript = args.count > 2 ? args[2] : nil

        snapshot(PanelView(controller: RecController.shared, transcriber: Transcriber.shared)
                    .padding(.top, 4),
                 width: 360, to: "\(out)/panel.png")
        snapshot(SettingsView(), width: 500, to: "\(out)/settings.png")
        if let transcript {
            snapshot(SpeakersView(transcriptURL: URL(fileURLWithPath: transcript), onClose: {}),
                     width: 560, to: "\(out)/name-speakers.png")
        }
    }
}
