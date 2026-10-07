import AppKit
import Combine

/// Owns the menu bar item. Held for the lifetime of the app by `AppDelegate`;
/// releasing it removes the icon from the menu bar.
@MainActor
final class StatusItemController: NSObject {

    /// Whether QuitGuard is actually intercepting anything right now.
    enum Health: CaseIterable {
        case normal
        /// Permission missing, or the tap exists but the system has disabled it.
        case degraded
    }

    /// Everything the menu bar shows for a given state.
    ///
    /// Pulled out of `applyIcon` as a pure function so all four combinations can
    /// be asserted without a real `NSStatusItem`. It was previously computed
    /// inline, which is how an inverted bolt shipped past a green harness.
    struct Appearance: Equatable {
        let symbol: String
        let toolTip: String
        let accessibilityDescription: String
        /// The extra menu row, or nil when there is nothing to say.
        let sleepMenuRow: String?
    }

    /// `nonisolated`: it reads no state at all, only its arguments.
    nonisolated static func appearance(health: Health, sleepDisabled: Bool) -> Appearance {
        // Two independent axes, deliberately kept in one glyph rather than a
        // second status item. Fill still means "armed" exactly as before; the
        // bolt is added when sleep is disabled.
        //
        // The bolt is not decoration: force-quitting or crashing skips the
        // revert, so a disabled `SleepDisabled` can outlive the app that set
        // it. This is the only thing that shows a relaunched QuitGuard is
        // holding the machine awake without opening Settings.
        let armed = (health == .normal)

        let symbol: String
        switch (armed, sleepDisabled) {
        case (true, false): symbol = "shield.lefthalf.filled"
        case (false, false): symbol = "shield"
        case (true, true): symbol = "bolt.shield.fill"
        case (false, true): symbol = "bolt.shield"
        }

        let armedText = armed ? "QuitGuard is active" : "QuitGuard is not intercepting Cmd+Q"
        let description = armed ? "QuitGuard, active" : "QuitGuard, not intercepting"

        return Appearance(
            symbol: symbol,
            toolTip: sleepDisabled
                ? "\(armedText) — sleep is disabled, this Mac will not sleep with the lid shut"
                : armedText,
            accessibilityDescription: sleepDisabled ? "\(description), sleep disabled" : description,
            // Same shape as the degraded warning: a disabled row naming a state
            // the user cannot otherwise see.
            sleepMenuRow: sleepDisabled ? "Sleep disabled — stays awake with the lid shut" : nil
        )
    }

    private let statusItem: NSStatusItem
    private let permissions: PermissionGate
    private let protectedApps: ProtectedAppsStore
    private let quitProtection: QuitProtectionSettings
    private let dockQuit: DockQuitSettings
    private let launchAtLogin: LaunchAtLogin
    private let stayAwake: StayAwake
    private let keyboardLock: KeyboardLock
    private let keyboardLockSettings: KeyboardLockSettings
    private let menu = NSMenu()
    private let openSettings: () -> Void

    private var health: Health = .normal
    private var cancellables = Set<AnyCancellable>()

    init(
        permissions: PermissionGate,
        protectedApps: ProtectedAppsStore,
        quitProtection: QuitProtectionSettings,
        dockQuit: DockQuitSettings,
        launchAtLogin: LaunchAtLogin,
        stayAwake: StayAwake,
        keyboardLock: KeyboardLock,
        keyboardLockSettings: KeyboardLockSettings,
        openSettings: @escaping () -> Void
    ) {
        self.permissions = permissions
        self.protectedApps = protectedApps
        self.quitProtection = quitProtection
        self.dockQuit = dockQuit
        self.launchAtLogin = launchAtLogin
        self.stayAwake = stayAwake
        self.keyboardLock = keyboardLock
        self.keyboardLockSettings = keyboardLockSettings
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        applyIcon()

        // Sleep can be disabled while no menu is open — a revert that failed at
        // quit, or another process changing it — so the icon follows the
        // published state rather than only being refreshed when the menu opens.
        //
        // The emitted value is used rather than re-reading `isEnabled`:
        // `@Published` fires from `willSet`, so the property still holds the
        // *previous* value while this runs. Re-reading it leaves the icon one
        // update behind, which for a two-state value looks exactly like an
        // inverted indicator.
        stayAwake.$isEnabled
            .removeDuplicates()
            .sink { [weak self] isEnabled in
                MainActor.assumeIsolated { self?.applyIcon(sleepDisabled: isEnabled) }
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

    /// `sleepDisabled` is passed in by the publisher, which knows the new value
    /// before the property does. Everywhere else the settled property is right.
    private func applyIcon(sleepDisabled: Bool? = nil) {
        guard let button = statusItem.button else { return }

        let look = Self.appearance(
            health: health,
            sleepDisabled: sleepDisabled ?? stayAwake.isEnabled
        )

        let image = NSImage(
            systemSymbolName: look.symbol,
            accessibilityDescription: look.accessibilityDescription
        )
        // Template images adapt to light/dark menu bars automatically.
        image?.isTemplate = true
        button.image = image
        button.toolTip = look.toolTip
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

        // Menus are populated on open, by which point the published value has
        // settled — so the property is the right source here.
        if let row = Self.appearance(health: health, sleepDisabled: stayAwake.isEnabled).sleepMenuRow {
            let awake = NSMenuItem(title: row, action: nil, keyEquivalent: "")
            awake.isEnabled = false
            menu.addItem(awake)
        }

        // Only a feature that is on gets a row: with Quit Protection off there
        // is nothing being protected, whatever the ticked list says.
        if quitProtection.isEnabled {
            let count = protectedApps.all.count
            let protectedItem = NSMenuItem(
                title: count == 1 ? "1 app protected" : "\(count) apps protected",
                action: nil,
                keyEquivalent: ""
            )
            protectedItem.isEnabled = false
            menu.addItem(protectedItem)
        }

        menu.addItem(.separator())

        // An action, so it lives here rather than in Settings: reachable with
        // the mouse from any app in two clicks, without opening a window. Shown
        // while engaged even if the feature was switched off meanwhile, so the
        // menu is always a way back out.
        if keyboardLockSettings.isEnabled || keyboardLock.isEngaged {
            let lockItem = NSMenuItem(
                title: keyboardLock.isEngaged ? "Unlock Keyboard" : "Lock Keyboard",
                action: #selector(toggleKeyboardLock),
                keyEquivalent: ""
            )
            lockItem.target = self
            menu.addItem(lockItem)
            menu.addItem(.separator())
        }

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

    @objc private func toggleKeyboardLock() {
        if keyboardLock.isEngaged {
            keyboardLock.unlock(reason: .menu)
        } else {
            keyboardLock.engage()
        }
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
        quitProtection.reload()
        dockQuit.reload()
        launchAtLogin.refresh()
        // Asynchronous, so this menu renders with the last known value and the
        // icon corrects itself a moment later. A synchronous `pmset -g` here
        // would hitch the menu by ~80ms every time it opens.
        stayAwake.refresh()
        keyboardLockSettings.reload()
        populate(menu)
    }
}
