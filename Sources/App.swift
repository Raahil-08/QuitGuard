import SwiftUI

/// QuitGuard is a menu bar only agent (LSUIElement).
///
/// The `Settings` scene is deliberate: SwiftUI's `App` protocol requires at
/// least one `Scene`, and `Settings` is the only one that creates no window at
/// launch. Stage 6 fills it with the app picker.
@main
struct QuitGuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let permissions = PermissionGate()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(permissions: permissions)

        // Prompt on launch when the grant is missing. Stage 7 replaces this with
        // a distinction between first-run onboarding and "permission was reset".
        if !permissions.refresh() {
            permissions.requestAccess()
            permissions.startPolling()
        }
    }
}
