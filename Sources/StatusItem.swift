import AppKit

/// Owns the menu bar item. Held for the lifetime of the app by `AppDelegate`;
/// releasing it removes the icon from the menu bar.
final class StatusItemController {
    private let statusItem: NSStatusItem

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "shield.lefthalf.filled",
                accessibilityDescription: "QuitGuard"
            )
            // Template images adapt to light/dark menu bars automatically.
            image?.isTemplate = true
            button.image = image
        }

        statusItem.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let quit = NSMenuItem(
            title: "Quit QuitGuard",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)

        return menu
    }
}
