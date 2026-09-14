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
    private let stayAwake = StayAwake()
    private let keyboardLockSettings = KeyboardLockSettings()
    private let keyboardLock = KeyboardLock()
    private lazy var keyboardLockPanel = KeyboardLockPanelController(lock: keyboardLock)
    private let dockBounds = DockBoundsTracker()
    private let dockQuit = DockQuitSettings()
    private let dockTiles = DockTileResolver()
    private lazy var interceptor = QuitInterceptor(
        frontmost: frontmost,
        protectedApps: protectedApps,
        dockBounds: dockBounds,
        dockQuit: dockQuit,
        dockTiles: dockTiles
    )

    private let confirmationPanel = ConfirmationPanelController()
    private lazy var settingsWindow = SettingsWindowController(
        store: protectedApps,
        dockQuit: dockQuit,
        launchAtLogin: launchAtLogin,
        stayAwake: stayAwake,
        keyboardLockSettings: keyboardLockSettings
    )
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
            dockQuit: dockQuit,
            launchAtLogin: launchAtLogin,
            stayAwake: stayAwake,
            keyboardLock: keyboardLock,
            keyboardLockSettings: keyboardLockSettings,
            openSettings: { [weak self] in
                self?.settingsWindow.show()
            }
        )

        interceptor.onProtectedQuitAttempt = { [weak self] target in
            MainActor.assumeIsolated {
                self?.confirmationPanel.present(for: target, prompt: .protectedApp)
            }
        }

        // The Dock chord has no callback: it does not confirm, so the
        // interceptor terminates the resolved app itself. Only the Cmd+Q path
        // needs UI.

        // The tap can only be created once we hold the Accessibility grant, so
        // install it now if we do and otherwise wait for the grant to land.
        permissions.$isTrusted
            .removeDuplicates()
            .sink { [weak self] trusted in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if trusted {
                        self.interceptor.start()
                        // The tracker is built before the grant exists, so its
                        // first measurement fails and leaves the bounds nil.
                        // Measure again now that AX calls will actually work.
                        self.dockBounds.refresh()
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
            // Delivered on .main by the queue argument above, but the closure
            // is Sendable, so the isolation has to be stated to reach the
            // main-actor properties.
            MainActor.assumeIsolated {
                self?.protectedApps.reload()
                self?.dockQuit.reload()
            }
        }

        // Pay the panel's first-layout cost now, not on the Cmd+Q path.
        confirmationPanel.prepare()
        keyboardLockPanel.prepare()

        // Switching the feature off ends a lock in progress. The emitted value
        // is used, not the property — `@Published` fires from willSet.
        keyboardLockSettings.$isEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                MainActor.assumeIsolated {
                    guard let self, !enabled, self.keyboardLock.isEngaged else { return }
                    self.keyboardLock.unlock(reason: .settingDisabled)
                }
            }
            .store(in: &cancellables)

        presentLaunchStateIfNeeded()
        startHealthMonitoring()
    }

    /// Sleep must not outlive the app that disabled it. A MacBook that will not
    /// sleep with the lid shut, and no longer has any UI saying so, is a
    /// thermal hazard in a bag.
    ///
    /// `.terminateLater` is only taken when there is something to undo, so an
    /// ordinary quit is unchanged and never prompts.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // First, before anything that might need typing: the sleep revert
        // below can put up a password prompt, and a locked keyboard could not
        // answer it. Quitting destroys the tap anyway; this just does it early.
        keyboardLock.unlock(reason: .quit)

        guard stayAwake.needsRevertOnQuit else { return .terminateNow }

        stayAwake.revertOnQuit { reverted in
            if !reverted { Self.presentRevertFailureAlert() }
            // Quit either way. Refusing to close over a dismissed password
            // prompt would trap the user in an app they asked to quit, and the
            // alert has already told them how to undo it by hand.
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private static func presentRevertFailureAlert() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Sleep is still disabled"
        alert.informativeText = """
            QuitGuard could not turn system sleep back on, so this Mac will not \
            sleep when the lid is closed. A closed MacBook with no external \
            cooling can run hot.

            To undo it yourself, run:
            \(StayAwake.recoveryCommand)
            """
        alert.addButton(withTitle: "Quit Anyway")
        // An accessory app has to activate for a modal alert to come forward.
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
