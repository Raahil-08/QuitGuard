import AppKit
import Combine

/// Owns the menu bar item. Held for the lifetime of the app by `AppDelegate`;
/// releasing it removes the icon from the menu bar.
@MainActor
final class StatusItemController: NSObject {

    /// Whether QuitGuard is actually intercepting anything right now.
    enum Health {
        case normal
        /// Permission missing, or the tap exists but the system has disabled it.
        case degraded
    }

    private let statusItem: NSStatusItem
    private let permissions: PermissionGate
    private let protectedApps: ProtectedAppsStore
    private let dockQuit: DockQuitSettings
    private let launchAtLogin: LaunchAtLogin
    private let stayAwake: StayAwake
    private let menu = NSMenu()
    private let openSettings: () -> Void

    private var health: Health = .normal
    private var cancellables = Set<AnyCancellable>()

    init(
        permissions: PermissionGate,
        protectedApps: ProtectedAppsStore,
        dockQuit: DockQuitSettings,
        launchAtLogin: LaunchAtLogin,
        stayAwake: StayAwake,
        openSettings: @escaping () -> Void
    ) {
        self.permissions = permissions
        self.protectedApps = protectedApps
        self.dockQuit = dockQuit
        self.launchAtLogin = launchAtLogin
        self.stayAwake = stayAwake
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        applyIcon()

        // Sleep can be disabled while no menu is open — a revert that failed at
        // quit, or another process changing it — so the icon follows the
        // published state rather than only being refreshed when the menu opens.
        stayAwake.$isEnabled
            .removeDuplicates()
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.applyIcon() }
            }
            .store(in: &cancellables)

        // A single menu instance, repopulated by the delegate each time it opens.
        // Reassigning `statusItem.menu` from `menuWillOpen` would swap the menu
        // out from under the presentation that is already in flight.
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - Health

    func setHealth(_ newHealth: Health) {
        guard newHealth != health else { return }
        health = newHealth
        applyIcon()
    }

    private func applyIcon() {
        guard let button = statusItem.button else { return }

        // Two independent axes, deliberately kept in one glyph rather than a
        // second status item. Fill still means "armed" exactly as before; the
        // bolt is added when sleep is disabled.
        //
        // The bolt is not decoration: force-quitting or crashing skips the
        // revert, so a disabled `SleepDisabled` can outlive the app that set
        // it. This is the only thing that shows a relaunched QuitGuard is
        // holding the machine awake without opening Settings.
        let awake = stayAwake.isEnabled
        let armed = (health == .normal)

        let symbol: String
        switch (armed, awake) {
        case (true, false): symbol = "shield.lefthalf.filled"
        case (false, false): symbol = "shield"
        case (true, true): symbol = "bolt.shield.fill"
        case (false, true): symbol = "bolt.shield"
        }

        let armedText = armed ? "QuitGuard is active" : "QuitGuard is not intercepting Cmd+Q"
        let description = armed ? "QuitGuard, active" : "QuitGuard, not intercepting"

        let image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: awake ? "\(description), sleep disabled" : description
        )
        // Template images adapt to light/dark menu bars automatically.
        image?.isTemplate = true
        button.image = image
        button.toolTip = awake
            ? "\(armedText) — sleep is disabled, this Mac will not sleep with the lid shut"
            : armedText
    }

    // MARK: - Menu

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        let isTrusted = permissions.isTrusted

        let status = NSMenuItem(
            title: isTrusted ? "Accessibility: Granted" : "Accessibility: Not granted",
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)

        if !isTrusted {
            let grant = NSMenuItem(
                title: "Grant Accessibility Access…",
                action: #selector(grantAccess),
                keyEquivalent: ""
            )
            grant.target = self
            menu.addItem(grant)
        } else if health == .degraded {
            let warning = NSMenuItem(
                title: "Event tap inactive — retrying",
                action: nil,
                keyEquivalent: ""
            )
            warning.isEnabled = false
            menu.addItem(warning)
        }

        if stayAwake.isEnabled {
            // Same shape as the degraded warning above: a disabled row naming a
            // state the user cannot otherwise see.
            let awake = NSMenuItem(
                title: "Sleep disabled — stays awake with the lid shut",
                action: nil,
                keyEquivalent: ""
            )
            awake.isEnabled = false
            menu.addItem(awake)
        }

        let count = protectedApps.all.count
        let protectedItem = NSMenuItem(
            title: count == 1 ? "1 app protected" : "\(count) apps protected",
            action: nil,
            keyEquivalent: ""
        )
        protectedItem.isEnabled = false
        menu.addItem(protectedItem)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        let login = NSMenuItem(
            title: launchAtLogin.requiresApproval
                ? "Launch at Login (needs approval)"
                : "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        login.target = self
        login.state = launchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit QuitGuard",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func showSettings() {
        openSettings()
    }

    @objc private func toggleLaunchAtLogin() {
        launchAtLogin.toggle()
    }

    @objc private func grantAccess() {
        // Prompt first; if the user already dismissed the system dialog once it
        // will not reappear, so fall back to opening the settings pane directly.
        if !permissions.requestAccess() {
            permissions.openSystemSettings()
            permissions.startPolling()
        }
    }
}

extension StatusItemController: NSMenuDelegate {
    /// Called immediately before the menu is displayed. The correct place to
    /// refresh state — unlike `menuWillOpen`, it is expected to mutate `menu`.
    func menuNeedsUpdate(_ menu: NSMenu) {
        permissions.refresh()
        // Picks up a `defaults write` made from a terminal without a relaunch.
        protectedApps.reload()
        dockQuit.reload()
        launchAtLogin.refresh()
        // Asynchronous, so this menu renders with the last known value and the
        // icon corrects itself a moment later. A synchronous `pmset -g` here
        // would hitch the menu by ~80ms every time it opens.
        stayAwake.refresh()
        populate(menu)
    }
}
