import AppKit
import UserNotifications

/// Device-only preferences keep the shared CLI/state-file contract unchanged.
@MainActor
final class Notifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notifications()
    @Published var enabled = UserDefaults.standard.bool(forKey: "notificationsEnabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "notificationsEnabled")
            if enabled { Task { await refresh(request: true) } }
        }
    }
    @Published var sound = UserDefaults.standard.bool(forKey: "notificationSound") {
        didSet { UserDefaults.standard.set(sound, forKey: "notificationSound") }
    }
    @Published private(set) var state = "Not checked"
    @Published private(set) var hint: String?
    @Published private(set) var testResult: String?
    var onOpen: ((String) -> Void)?
    private var submitted = UserDefaults.standard.stringArray(forKey: "notificationEvents") ?? []

    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    func refresh(request: Bool = false) async {
        guard let center else {
            state = "Unavailable"
            hint = "Open the Sift app bundle to use macOS notifications."
            return
        }
        center.delegate = self
        var settings = await center.notificationSettings()
        if request, enabled, settings.authorizationStatus == .notDetermined {
            do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
            catch { state = "Unavailable"; hint = error.localizedDescription; return }
            settings = await center.notificationSettings()
        }
        hint = nil
        switch settings.authorizationStatus {
        case .notDetermined: state = "Permission not requested"
        case .denied:
            state = "Blocked by macOS"
            hint = "Allow Sift in System Settings → Notifications. The edge dot still works."
        case .authorized, .provisional, .ephemeral:
            state = settings.alertSetting == .enabled ? "Allowed by macOS" : "Banners off in macOS"
            if settings.alertSetting != .enabled {
                hint = "Enable Sift alerts in System Settings → Notifications. The edge dot still works."
            } else if sound, settings.soundSetting != .enabled {
                hint = "Sound is off for Sift in System Settings → Notifications."
            }
        @unknown default:
            state = "Unavailable"
            hint = "macOS notification permission could not be determined."
        }
    }

    static func shouldPost(enabled: Bool, focused: Bool, duplicate: Bool) -> Bool {
        enabled && !focused && !duplicate
    }

    func post(title: String, body: String, id: String, destination: String) async {
        guard Self.shouldPost(enabled: enabled, focused: PanelBridge.shared.isFocused,
                              duplicate: submitted.contains(id)) else { return }
        await refresh()
        guard let center, state == "Allowed by macOS" else { return }
        // Permission checks suspend; focus/preferences may have changed meanwhile.
        guard Self.shouldPost(enabled: enabled, focused: PanelBridge.shared.isFocused,
                              duplicate: submitted.contains(id)) else { return }
        submitted.append(id)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound ? .default : nil
        content.userInfo = ["destination": destination]
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            submitted = Array(submitted.suffix(200))
            UserDefaults.standard.set(submitted, forKey: "notificationEvents")
        } catch {
            submitted.removeAll { $0 == id }
            hint = "Notification failed: \(error.localizedDescription)"
        }
    }

    func test() async {
        let id = "test-\(UUID().uuidString)"
        await post(title: "Sift", body: "A quiet nudge. Click to open Sift.", id: id, destination: "")
        try? await Task.sleep(nanoseconds: 700_000_000)
        let delivered = await center?.deliveredNotifications() ?? []
        if let notification = delivered.first(where: { $0.request.identifier == id }) {
            testResult = "Test delivered to Notification Center. " + (notification.request.content.sound == nil ? "Silent." : "Sound requested.")
        } else {
            testResult = "macOS has not confirmed test delivery. Check Focus and notification settings."
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            completionHandler(enabled && !PanelBridge.shared.isFocused
                              ? (sound ? [.banner, .sound] : [.banner]) : [])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let destination = response.notification.request.content.userInfo["destination"] as? String ?? ""
        Task { @MainActor in onOpen?(destination); completionHandler() }
    }
}
