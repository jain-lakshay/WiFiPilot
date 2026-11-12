import Foundation
import ServiceManagement
import UserNotifications

/// Launch-at-login via ServiceManagement.
///
/// `SMAppService.mainApp` requires a real app bundle (see `Scripts/build-app.sh`).
/// macOS may require the user to approve the login item in System Settings.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: "Enabled"
        case .notRegistered: "Not registered"
        case .requiresApproval: "Waiting for approval in System Settings → General → Login Items"
        case .notFound: "Login item not found — run a bundled build"
        @unknown default: "Unknown status"
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard SMAppService.mainApp.status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Minimal local notifications for switches and recoveries. Nothing is sent remotely.
enum LocalNotifications {
    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    static func post(title: String, body: String) {
        Task {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}
