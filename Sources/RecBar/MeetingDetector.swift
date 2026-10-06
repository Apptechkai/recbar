import AppKit
import Foundation
import RecCore
import UserNotifications

/// Notices when a meeting app starts using the microphone and asks whether to
/// record; while recording, notices when the call ends and offers to stop.
/// It only looks at *which app* holds the microphone (no audio, no content)
/// and never records without a click.
@MainActor
final class MeetingDetector: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = MeetingDetector()

    struct Meeting: Equatable, Identifiable {
        let id: String          // app key, e.g. "com.google.Chrome"
        let appName: String     // "Google Chrome"
        let label: String       // "Google Meet in Google Chrome"
        let appPID: pid_t       // the app's main process (for app-only capture)
    }

    enum CaptureChoice: String, CaseIterable, Identifiable {
        case panel = "panel"            // whatever the panel's Source is set to
        case meetingApp = "meetingApp"  // only the meeting app's windows + sound
        var id: String { rawValue }
        var title: String {
            switch self {
            case .panel: return "Panel's Source"
            case .meetingApp: return "Meeting app only"
            }
        }
    }

    // Settings (Recall Bar's own preferences)
    @Published var askToRecord = UserDefaults.standard.object(forKey: "meetingAskToRecord") as? Bool ?? true {
        didSet { UserDefaults.standard.set(askToRecord, forKey: "meetingAskToRecord"); reconfigure() }
    }
    @Published var offerToStop = UserDefaults.standard.object(forKey: "meetingOfferToStop") as? Bool ?? true {
        didSet { UserDefaults.standard.set(offerToStop, forKey: "meetingOfferToStop"); reconfigure() }
    }
    @Published var captureChoice = CaptureChoice(rawValue: UserDefaults.standard.string(forKey: "meetingCapture") ?? "") ?? .panel {
        didSet { UserDefaults.standard.set(captureChoice.rawValue, forKey: "meetingCapture") }
    }

    /// Shown as a banner in the panel too (in case notifications are off).
    @Published private(set) var startPrompt: Meeting?
    @Published private(set) var endPrompt: Meeting?
    @Published private(set) var notificationsAllowed: Bool?

    /// Apps recognised as meeting apps: bundle id prefix → name, browser?
    static let knownApps: [(prefix: String, name: String, browser: Bool)] = [
        ("us.zoom.xos", "Zoom", false),
        ("com.microsoft.teams2", "Microsoft Teams", false),
        ("com.microsoft.teams", "Microsoft Teams", false),
        ("com.tinyspeck.slackmacgap", "Slack", false),
        ("com.cisco.webexmeetingsapp", "Webex", false),
        ("com.webex.meetingmanager", "Webex", false),
        ("com.apple.FaceTime", "FaceTime", false),
        ("com.hnc.Discord", "Discord", false),
        ("net.whatsapp.WhatsApp", "WhatsApp", false),
        ("com.google.Chrome", "Google Chrome", true),
        ("com.microsoft.edgemac", "Microsoft Edge", true),
        ("com.brave.Browser", "Brave", true),
        ("company.thebrowser.Browser", "Arc", true),
        ("org.mozilla.firefox", "Firefox", true),
        ("com.apple.WebKit.GPU", "Safari", true),
        ("com.apple.Safari", "Safari", true),
    ]

    private var timer: Timer?
    private var activeSince: [String: Date] = [:]        // meetings currently holding the mic
    private var prompted: Set<String> = []               // asked already (until their mic use ends)
    private var heldDuringRecording: Set<String> = []    // meeting apps seen while recording
    private var silentSince: Date?
    private var offeredStop = false
    private let autoAccept = CommandLine.arguments.contains("--auto-accept-meetings")  // tests only
    private static let log = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/RecBar/meetings.log")

    // MARK: Lifecycle

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let record = UNNotificationAction(identifier: "record", title: "Record", options: [.foreground])
        let notNow = UNNotificationAction(identifier: "notNow", title: "Not Now")
        let stop = UNNotificationAction(identifier: "stop", title: "Stop Recording", options: [.foreground])
        let keep = UNNotificationAction(identifier: "keep", title: "Keep Recording")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "meetingStart", actions: [record, notNow], intentIdentifiers: []),
            UNNotificationCategory(identifier: "meetingEnd", actions: [stop, keep], intentIdentifiers: []),
        ])
        reconfigure()
    }

    private func reconfigure() {
        let wanted = askToRecord || offerToStop
        if wanted, timer == nil {
            requestNotificationPermission()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
        } else if !wanted {
            timer?.invalidate()
            timer = nil
            startPrompt = nil
            endPrompt = nil
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            Task { @MainActor in self.notificationsAllowed = granted }
        }
    }

    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            // Only an explicit "Don't Allow" counts as off; "not asked yet"
            // isn't worth a warning.
            let status = settings.authorizationStatus
            let allowed: Bool? = status == .denied ? false
                : (status == .authorized || status == .provisional) ? true : nil
            Task { @MainActor in self.notificationsAllowed = allowed }
        }
    }

    // MARK: Polling

    private var anyRecording: Bool {
        RecController.shared.isRecording || PidFile.runningPID() != nil
    }

    private func poll() {
        let meetings = currentMeetings()
        let now = Date()
        let keys = Set(meetings.map(\.id))

        // Forget meetings that let go of the mic (so a new call asks again).
        for key in activeSince.keys where !keys.contains(key) {
            activeSince[key] = nil
            prompted.remove(key)
            if startPrompt?.id == key { startPrompt = nil; removeDelivered("start-\(key)") }
            note("mic released by \(key)")
        }
        for meeting in meetings where activeSince[meeting.id] == nil {
            activeSince[meeting.id] = now
            note("mic in use by \(meeting.label) (pid \(meeting.appPID))")
        }

        if anyRecording {
            startPrompt = nil
            heldDuringRecording.formUnion(keys)
            checkCallEnded(stillHolding: !keys.isDisjoint(with: heldDuringRecording), now: now)
            return
        }
        heldDuringRecording = []
        silentSince = nil
        offeredStop = false
        endPrompt = nil

        // Ask once per call, after the mic has been in use for 4 s (ignores
        // brief mic checks).
        guard askToRecord else { return }
        for meeting in meetings where !prompted.contains(meeting.id) {
            guard let since = activeSince[meeting.id], now.timeIntervalSince(since) >= 4 else { continue }
            prompted.insert(meeting.id)
            askToRecord(meeting)
            break
        }
    }

    private func checkCallEnded(stillHolding: Bool, now: Date) {
        guard offerToStop, !heldDuringRecording.isEmpty else { return }
        if stillHolding {
            silentSince = nil
            if endPrompt != nil { endPrompt = nil; removeDelivered("end") }   // call resumed
            offeredStop = false
            return
        }
        if silentSince == nil { silentSince = now }
        // 8 s without the meeting app on the mic → the call has ended.
        guard !offeredStop, let since = silentSince, now.timeIntervalSince(since) >= 8 else { return }
        offeredStop = true
        let key = heldDuringRecording.sorted().first ?? ""
        let meeting = Meeting(id: key, appName: Self.appName(for: key), label: Self.appName(for: key), appPID: 0)
        endPrompt = meeting
        note("call ended in \(meeting.appName) → offering to stop")
        notify(id: "end", category: "meetingEnd",
               title: "The \(meeting.appName) call seems to have ended",
               body: "Recall Bar is still recording. Stop the recording?")
        if autoAccept { Task { await stopRecording() } }
    }

    /// Meeting apps holding the microphone right now (one per app).
    private func currentMeetings() -> [Meeting] {
        let own = ProcessInfo.processInfo.processIdentifier
        let testNames = UserDefaults.standard.stringArray(forKey: "meetingDetectionTestProcesses") ?? []
        var result: [String: Meeting] = [:]
        for user in MicActivity.currentUsers() where user.pid != own {
            if let bundle = user.bundleID,
               let app = Self.knownApps.first(where: { bundle.hasPrefix($0.prefix) }) {
                let key = app.prefix == "com.apple.WebKit.GPU" ? "com.apple.Safari" : app.prefix
                let main = NSRunningApplication.runningApplications(withBundleIdentifier: key).first
                let label = app.browser ? Self.browserMeetingLabel(app: app.name, pid: main?.processIdentifier) : app.name
                result[key] = Meeting(id: key, appName: app.name, label: label,
                                      appPID: main?.processIdentifier ?? user.pid)
            } else if testNames.contains(user.executableName) {
                // Test hook: treat e.g. `ffmpeg` holding the mic as a meeting.
                result["test." + user.executableName] = Meeting(
                    id: "test." + user.executableName, appName: user.executableName,
                    label: "Test meeting (\(user.executableName))", appPID: user.pid)
            }
        }
        return Array(result.values)
    }

    /// "Google Meet in Google Chrome" when a window title gives it away.
    private static func browserMeetingLabel(app: String, pid: pid_t?) -> String {
        guard let pid,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return app }
        let services = [("Meet", "Google Meet"), ("meet.google.com", "Google Meet"), ("Zoom", "Zoom"),
                        ("Teams", "Microsoft Teams"), ("Webex", "Webex"), ("Huddle", "Slack huddle")]
        for window in windows where (window[kCGWindowOwnerPID as String] as? pid_t) == pid {
            let title = window[kCGWindowName as String] as? String ?? ""
            if let service = services.first(where: { title.contains($0.0) }) {
                return "\(service.1) in \(app)"
            }
        }
        return app
    }

    private static func appName(for key: String) -> String {
        knownApps.first { $0.prefix == key }?.name ?? key.replacingOccurrences(of: "test.", with: "")
    }

    // MARK: Prompts

    private func askToRecord(_ meeting: Meeting) {
        startPrompt = meeting
        note("asking to record \(meeting.label)")
        notify(id: "start-\(meeting.id)", category: "meetingStart",
               title: "\(meeting.label) is using your microphone",
               body: "Record this call? (Recall Bar records nothing until you say so.)")
        if autoAccept { Task { await record(meeting) } }
    }

    func record(_ meeting: Meeting) async {
        startPrompt = nil
        removeDelivered("start-\(meeting.id)")
        var source: CaptureSource?
        if captureChoice == .meetingApp, meeting.appPID > 0 {
            let name = NSRunningApplication(processIdentifier: meeting.appPID)?.localizedName ?? meeting.appName
            source = .application(CaptureApplication(id: meeting.appPID, name: name,
                                                     bundleID: meeting.id, windowCount: 1))
        }
        note("recording \(meeting.label) (\(source == nil ? "panel source" : "app only"))")
        await RecController.shared.start(sourceOverride: source)
    }

    func dismissStart() {
        if let id = startPrompt?.id { removeDelivered("start-\(id)") }
        startPrompt = nil
    }

    func stopRecording() async {
        endPrompt = nil
        removeDelivered("end")
        note("stopping after the call ended")
        if RecController.shared.isRecording {
            await RecController.shared.stop()
        } else if let pid = PidFile.runningPID() {
            kill(pid, SIGINT)   // a `rec` recording
        }
    }

    func keepRecording() {
        endPrompt = nil
        removeDelivered("end")
    }

    private func notify(id: String, category: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private func removeDelivered(_ id: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .list] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        await MainActor.run {
            Task { @MainActor in
                switch (category, action) {
                case ("meetingStart", "record"):
                    if let meeting = self.startPrompt { await self.record(meeting) }
                case ("meetingStart", "notNow"):
                    self.dismissStart()
                case ("meetingEnd", "stop"):
                    await self.stopRecording()
                case ("meetingEnd", "keep"):
                    self.keepRecording()
                default:
                    PanelWindow.shared.show()   // clicked the notification itself
                }
            }
        }
    }

    // MARK: Log

    private func note(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        try? FileManager.default.createDirectory(at: Self.log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: Self.log) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: Self.log, atomically: true, encoding: .utf8)
        }
    }
}
