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
    private lazy var interceptor = QuitInterceptor(frontmost: frontmost)

    private var statusItem: StatusItemController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(permissions: permissions)

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

        if !permissions.refresh() {
            permissions.requestAccess()
            permissions.startPolling()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        interceptor.stop()
    }
}
