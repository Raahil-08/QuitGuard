import AppKit
import Combine

/// Owns the menu bar item. Held for the lifetime of the app by `AppDelegate`;
/// releasing it removes the icon from the menu bar.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let permissions: PermissionGate
    private let protectedApps: ProtectedAppsStore
    private let menu = NSMenu()
    private let openSettings: () -> Void
    private var cancellables = Set<AnyCancellable>()

    init(
        permissions: PermissionGate,
        protectedApps: ProtectedAppsStore,
        openSettings: @escaping () -> Void
    ) {
        self.permissions = permissions
        self.protectedApps = protectedApps
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "shield.lefthalf.filled",
                accessibilityDescription: "QuitGuard"
            )
            // Template images adapt to light/dark menu bars automatically.
            image?.isTemplate = true
            button.image = image
        }

        // A single menu instance, repopulated by the delegate each time it opens.
        // Reassigning `statusItem.menu` from `menuWillOpen` would swap the menu
        // out from under the presentation that is already in flight.
        menu.delegate = self
        statusItem.menu = menu

        permissions.$isTrusted
            .removeDuplicates()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.statusItem.button?.needsDisplay = true
                }
            }
            .store(in: &cancellables)
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

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit QuitGuard",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)
    }

    @objc private func showSettings() {
        openSettings()
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
        populate(menu)
    }
}
