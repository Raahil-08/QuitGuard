import AppKit
import Combine
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
    private let frontmost = FrontmostAppTracker()
    private let protectedApps = ProtectedAppsStore()
    private lazy var interceptor = QuitInterceptor(
        frontmost: frontmost,
        protectedApps: protectedApps
    )

    private var statusItem: StatusItemController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(permissions: permissions, protectedApps: protectedApps)

        // The tap can only be created once we hold the Accessibility grant, so
        // install it now if we do and otherwise wait for the grant to land.
        permissions.$isTrusted
            .removeDuplicates()
            .sink { [weak self] trusted in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if trusted {
                        self.interceptor.start()
                    } else {
                        self.interceptor.stop()
                    }
                }
            }
            .store(in: &cancellables)

        // A `defaults write` from a terminal does not notify this process, so
        // re-read whenever the frontmost app changes. Any Cmd+Q is necessarily
        // preceded by activating the app it targets, which makes this the hook
        // that matters — and it costs one cached defaults read per app switch.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.protectedApps.reload()
        }

        if !permissions.refresh() {
            permissions.requestAccess()
            permissions.startPolling()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        interceptor.stop()
    }
}
