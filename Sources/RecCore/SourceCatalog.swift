import CoreGraphics
import Foundation
import ScreenCaptureKit

/// A snapshot of everything capturable right now — windows, apps, displays —
/// with on-demand thumbnails for a visual picker.
public final class SourceCatalog: @unchecked Sendable {
    public let windows: [CaptureWindow]
    public let applications: [CaptureApplication]
    public let displays: [CaptureDisplay]
    private let content: SCShareableContent

    public static func load() async throws -> SourceCatalog {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true)
        return SourceCatalog(content: content)
    }

    private init(content: SCShareableContent) {
        self.content = content
        let ownBundle = Bundle.main.bundleIdentifier

        windows = content.windows.compactMap { window in
            guard let app = window.owningApplication,
                  window.windowLayer == 0,
                  window.frame.width >= 200, window.frame.height >= 150,
                  app.bundleIdentifier != ownBundle
            else { return nil }
            return CaptureWindow(id: window.windowID, title: window.title ?? "",
                                 appName: app.applicationName, processID: app.processID,
                                 frame: window.frame)
        }
        .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }

        // Apps = owners of the listed windows, most windows first.
        var counts: [pid_t: Int] = [:]
        for window in windows { counts[window.processID, default: 0] += 1 }
        applications = content.applications.compactMap { app in
            guard let count = counts[app.processID] else { return nil }
            return CaptureApplication(id: app.processID, name: app.applicationName,
                                      bundleID: app.bundleIdentifier, windowCount: count)
        }
        .sorted { ($0.windowCount, $0.name) > ($1.windowCount, $1.name) }

        let mainID = CGMainDisplayID()
        displays = content.displays.enumerated().map { index, display in
            let isMain = display.displayID == mainID
            return CaptureDisplay(id: display.displayID,
                                  name: "Display \(index + 1)\(isMain ? " (main)" : "") — \(display.width)×\(display.height)",
                                  width: display.width, height: display.height)
        }
    }

    // MARK: Thumbnails

    public func thumbnail(for window: CaptureWindow, maxWidth: Int) async -> CGImage? {
        guard let scWindow = content.windows.first(where: { $0.windowID == window.id }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        return await capture(filter, size: window.frame.size, maxWidth: maxWidth)
    }

    public func thumbnail(for app: CaptureApplication, maxWidth: Int) async -> CGImage? {
        guard let scApp = content.applications.first(where: { $0.processID == app.id }),
              let display = mainSCDisplay else { return nil }
        let filter = SCContentFilter(display: display, including: [scApp], exceptingWindows: [])
        return await capture(filter, size: CGSize(width: display.width, height: display.height), maxWidth: maxWidth)
    }

    public func thumbnail(for display: CaptureDisplay, maxWidth: Int) async -> CGImage? {
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else { return nil }
        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        return await capture(filter, size: CGSize(width: display.width, height: display.height), maxWidth: maxWidth)
    }

    private var mainSCDisplay: SCDisplay? {
        let mainID = CGMainDisplayID()
        return content.displays.first { $0.displayID == mainID } ?? content.displays.first
    }

    private func capture(_ filter: SCContentFilter, size: CGSize, maxWidth: Int) async -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, CGFloat(maxWidth) / size.width)
        let config = SCStreamConfiguration()
        config.width = max(2, Int(size.width * scale))
        config.height = max(2, Int(size.height * scale))
        config.showsCursor = false
        config.captureResolution = .nominal
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
