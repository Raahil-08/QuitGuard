import Combine
import Foundation
import os

/// Whether Cmd + right-click on a Dock tile quits that app.
///
/// A sibling of `ProtectedAppsStore` rather than a field on it: that type is
/// specifically *the set of bundle identifiers Cmd+Q is intercepted for*, and
/// this setting is about neither Cmd+Q nor a set of apps. What the two do share
/// is the access pattern — read from the event tap thread, so the value lives
/// behind a lock and `UserDefaults` is never touched from the callback.
///
/// Defaults to **false**. The feature consumes a system-wide chord before any
/// other app can see it, which is not something to switch on for someone who
/// never asked for it.
final class DockQuitSettings: ObservableObject {

    static let defaultsKey = "DockRightClickQuitEnabled"

    private static let logger = Logger(subsystem: "com.raahil.quitguard", category: "dock")

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var enabled: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // bool(forKey:) is false for a missing key, which is exactly the
        // intended default — no registration needed.
        enabled = defaults.bool(forKey: Self.defaultsKey)

        // Same caveat as ProtectedAppsStore: this fires only for writes made by
        // this process. A `defaults write` from a terminal is picked up by the
        // reload hooks in AppDelegate and the status menu.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            self?.reload()
        }

        Self.logger.notice("Dock right-click quit: \(self.enabled ? "on" : "off", privacy: .public)")
    }

    // MARK: - Tap-thread access

    /// Safe to call from the event tap thread: one uncontended lock and a bool
    /// read. Checked before any bounds test, so a disabled feature costs the
    /// callback nothing beyond this.
    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    // MARK: - Mutation

    func reload() {
        let loaded = defaults.bool(forKey: Self.defaultsKey)

        lock.lock()
        let changed = loaded != enabled
        enabled = loaded
        lock.unlock()

        guard changed else { return }

        Self.logger.notice("Dock right-click quit changed: \(loaded ? "on" : "off", privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }

    func setEnabled(_ newValue: Bool) {
        lock.lock()
        let changed = newValue != enabled
        enabled = newValue
        lock.unlock()

        guard changed else { return }

        defaults.set(newValue, forKey: Self.defaultsKey)
        Self.logger.notice("Dock right-click quit set: \(newValue ? "on" : "off", privacy: .public)")

        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }
}
