import AppKit
import RecCore
import SwiftUI

@main
struct RecBarApp: App {
    @StateObject private var controller = RecController()

    var body: some Scene {
        // Simple title+systemImage form: the most reliable MenuBarExtra label
        // (complex conditional labels can render zero-width and vanish).
        MenuBarExtra(
            "RecBar",
            systemImage: controller.isRecording ? "record.circle.fill" : "record.circle"
        ) {
            if controller.isRecording {
                Text("Recording — \(controller.elapsedText)")
                Button("Stop Recording") {
                    Task { await controller.stop() }
                }
            } else {
                Button(controller.audioOnly ? "Start Recording (audio only)" : "Start Recording") {
                    Task { await controller.start() }
                }
                Toggle("Audio Only (no video)", isOn: $controller.audioOnly)
            }

            Divider()

            if let last = controller.lastRecordingURL {
                Button("Reveal Last Recording") {
                    NSWorkspace.shared.activateFileViewerSelecting([last])
                }
            }
            Button("Open Recordings Folder") {
                try? FileManager.default.createDirectory(
                    at: RecPaths.recordingsDirectory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(RecPaths.recordingsDirectory)
            }

            Divider()

            Button("Quit RecBar") {
                controller.quit()
            }
        }
    }
}
