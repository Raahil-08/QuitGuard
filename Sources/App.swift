import AppKit
import Combine
import SwiftUI

/// QuitGuard is a menu bar only agent (LSUIElement).
///
/// The `Settings` scene is deliberate: SwiftUI's `App` protocol requires at
/// least one `Scene`, and `Settings` is the only one that creates no window at
/// launch. The real settings window is an NSWindow built by
/// `SettingsWindowController` — see the note there for why.
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

    /// How often to confirm the tap is still armed. The system disables taps
    /// silently, and the callback-based re-arm only fires if the tap is still
    /// delivering events at all.
    private static let healthCheckInterval: TimeInterval = 30

    private let permissions = PermissionGate()
    private let frontmost = FrontmostAppTracker()
    private let protectedApps = ProtectedAppsStore()
    private let launchAtLogin = LaunchAtLogin()
    private lazy var interceptor = QuitInterceptor(
        frontmost: frontmost,
        protectedApps: protectedApps
    )

    private let confirmationPanel = ConfirmationPanelController()
    private lazy var settingsWindow = SettingsWindowController(store: protectedApps)
    private lazy var permissionResetWindow = PermissionResetWindowController(
        permissions: permissions,
        protectedApps: protectedApps
    )

    private var statusItem: StatusItemController?
    private var healthTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(
            permissions: permissions,
            protectedApps: protectedApps,
            launchAtLogin: launchAtLogin,
            openSettings: { [weak self] in
                self?.settingsWindow.show()
            }
        )

        interceptor.onProtectedQuitAttempt = { [weak self] target in
            MainActor.assumeIsolated {
                self?.confirmationPanel.present(for: target)
            }
        }

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
                    self.updateHealth()
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

        presentLaunchStateIfNeeded()
        startHealthMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        healthTimer?.invalidate()
        interceptor.stop()
    }

    // MARK: - Launch state

    private func presentLaunchStateIfNeeded() {
        guard !permissions.refresh() else { return }

        permissions.startPolling()

        if protectedApps.all.isEmpty {
            // First run: nothing is configured yet, so the system prompt says
            // everything that needs saying.
            permissions.requestAccess()
        } else {
            // Configuration exists and is silently not being enforced. A bare
            // system prompt would not explain why a working setup stopped.
            permissionResetWindow.show()
        }
    }

    // MARK: - Health

    private func startHealthMonitoring() {
        updateHealth()
        let timer = Timer(timeInterval: Self.healthCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkTapHealth()
            }
        }
        // .common rather than the default mode: a scheduled timer stops firing
        // while a menu is being tracked, which is exactly when the user is
        // looking at the status item to find out whether we are working.
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    private func checkTapHealth() {
        guard permissions.refresh() else {
            updateHealth()
            return
        }

        if !interceptor.isInstalled {
            interceptor.start()
        } else {
            // CGEvent.tapIsEnabled is the authoritative check; a tap disabled
            // while no events were flowing never reaches the callback's re-arm.
            interceptor.reEnableIfNeeded()
        }

        updateHealth()
    }

    private func updateHealth() {
        let healthy = permissions.isTrusted && interceptor.isTapEnabled
        statusItem?.setHealth(healthy ? .normal : .degraded)
    }
}
