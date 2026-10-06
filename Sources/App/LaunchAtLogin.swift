import Foundation
import ServiceManagement
import os

/// Wraps `SMAppService` for the login item toggle.
///
/// `SMLoginItemSetEnabled` is deprecated and requires shipping a separate helper
/// bundle; `SMAppService.mainApp` registers the app itself and is the supported
/// path on macOS 13+.
@MainActor
final class LaunchAtLogin: ObservableObject {

    private static let logger = Logger(subsystem: "com.raahil.quitguard", category: "login")

    @Published private(set) var isEnabled = false

    /// macOS 13 can park a registration behind user approval in
    /// System Settings › General › Login Items. Registration succeeded, but the
    /// app will not actually launch until the user approves it.
    @Published private(set) var requiresApproval = false

    init() {
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = (status == .enabled)
        requiresApproval = (status == .requiresApproval)
    }

    func setEnabled(_ enabled: Bool) {
        let action = enabled ? "register" : "unregister"
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Self.logger.notice("Launch at login: \(action, privacy: .public) succeeded")
        } catch {
            Self.logger.error(
                "Launch at login: \(action, privacy: .public) failed — \(error.localizedDescription, privacy: .public)"
            )
        }
        refresh()
    }

    func toggle() {
        setEnabled(!isEnabled)
    }
}
