import Combine
import Foundation
import os

/// Whether the Keyboard Lock action is offered in the status menu.
///
/// Simpler than `DockQuitSettings`: nothing reads this from a tap thread. The
/// lock tap never consults it — it exists only while a lock is engaged — so a
/// plain main-actor published value is enough.
///
/// Defaults to **false**.
@MainActor
final class KeyboardLockSettings: ObservableObject {

    static let defaultsKey = "KeyboardLockEnabled"

    private static let logger = Logger(subsystem: "com.raahil.quitguard", category: "lock")

    private let defaults: UserDefaults

    @Published private(set) var isEnabled: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.defaultsKey)
    }

    /// Picks up a `defaults write` from a terminal, which does not notify this
    /// process. Called from the status menu as it opens.
    func reload() {
        let loaded = defaults.bool(forKey: Self.defaultsKey)
        if loaded != isEnabled { isEnabled = loaded }
    }

    func setEnabled(_ newValue: Bool) {
        guard newValue != isEnabled else { return }
        defaults.set(newValue, forKey: Self.defaultsKey)
        isEnabled = newValue
        Self.logger.notice("Keyboard Lock feature \(newValue ? "enabled" : "disabled", privacy: .public) in Settings")
    }
}
