import Combine
import Foundation
import os

/// Whether Cmd+Q is intercepted at all.
///
/// The master switch above `ProtectedAppsStore`: that type is *which* apps, this
/// is *whether*. Same access pattern as `DockQuitSettings` — read from the event
/// tap thread, so the value lives behind a lock and `UserDefaults` is never
/// touched from the callback.
///
/// An existing install has no stored value but may already have ticked apps.
/// Those users were protected before this switch existed, so the first read
/// resolves to on for them (see `resolveInitialValue`) and to off for a fresh
/// install, which is the "nothing runs until chosen" default.
final class QuitProtectionSettings: ObservableObject {

    static let defaultsKey = "QuitProtectionEnabled"

    private static let logger = Logger(subsystem: "com.raahil.quitguard", category: "quitprotection")

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var enabled: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = Self.resolveInitialValue(defaults: defaults)

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            self?.reload()
        }

        Self.logger.notice("Quit protection: \(self.enabled ? "on" : "off", privacy: .public)")
    }

    /// Pure, so the migration can be tested without a running app.
    static func initialValue(stored: Bool?, hasProtectedApps: Bool) -> Bool {
        stored ?? hasProtectedApps
    }

    private static func resolveInitialValue(defaults: UserDefaults) -> Bool {
        let stored = defaults.object(forKey: defaultsKey) as? Bool
        let hasApps = !(defaults.stringArray(forKey: ProtectedAppsStore.defaultsKey) ?? []).isEmpty
        return initialValue(stored: stored, hasProtectedApps: hasApps)
    }

    // MARK: - Tap-thread access

    /// Safe to call from the event tap thread: one uncontended lock and a bool
    /// read.
    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    // MARK: - Mutation

    func reload() {
        let loaded = Self.resolveInitialValue(defaults: defaults)

        lock.lock()
        let changed = loaded != enabled
        enabled = loaded
        lock.unlock()

        guard changed else { return }

        Self.logger.notice("Quit protection changed: \(loaded ? "on" : "off", privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }

    func setEnabled(_ newValue: Bool) {
        lock.lock()
        let changed = newValue != enabled
        enabled = newValue
        lock.unlock()

        // Written even when unchanged: a migrated value has never been stored,
        // and an explicit choice should stop depending on the apps list.
        defaults.set(newValue, forKey: Self.defaultsKey)

        guard changed else { return }

        Self.logger.notice("Quit protection set: \(newValue ? "on" : "off", privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }
}
