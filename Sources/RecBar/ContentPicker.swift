import Foundation
import ScreenCaptureKit

/// Wraps the system content-sharing picker (the thumbnail grid FaceTime and
/// Zoom use) so the user can choose a window, a whole app, or a display
/// visually. Delivers an SCContentFilter ready for the Recorder.
@MainActor
final class ContentPicker: NSObject, SCContentSharingPickerObserver {
    static let shared = ContentPicker()

    private var completion: ((SCContentFilter?) -> Void)?

    func pick(_ completion: @escaping (SCContentFilter?) -> Void) {
        self.completion = completion
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow, .singleApplication, .singleDisplay]
        config.allowsChangingSelectedContent = true
        picker.defaultConfiguration = config
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    private func finish(_ filter: SCContentFilter?) {
        let picker = SCContentSharingPicker.shared
        picker.isActive = false   // also removes the system "sharing" indicator
        picker.remove(self)
        let done = completion
        completion = nil
        done?(filter)
    }

    // MARK: SCContentSharingPickerObserver (called on an arbitrary queue)

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                          didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in self.finish(filter) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
}
