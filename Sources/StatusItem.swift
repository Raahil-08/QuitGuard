import AppKit
import Combine

/// Owns the menu bar item. Held for the lifetime of the app by `AppDelegate`;
/// releasing it removes the icon from the menu bar.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let permissions: PermissionGate
    private var cancellables = Set<AnyCancellable>()

    init(permissions: PermissionGate) {
        self.permissions = permissions
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

        rebuildMenu(isTrusted: permissions.isTrusted)

        permissions.$isTrusted
            .removeDuplicates()
            .sink { [weak self] trusted in
                MainActor.assumeIsolated {
                    self?.rebuildMenu(isTrusted: trusted)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Menu

    private func rebuildMenu(isTrusted: Bool) {
        let menu = NSMenu()
        // Re-check on open: the user can revoke the grant while we are running.
        menu.delegate = self

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

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit QuitGuard",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)

        statusItem.menu = menu
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
    func menuWillOpen(_ menu: NSMenu) {
        permissions.refresh()
    }
}
