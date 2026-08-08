import Combine
import Foundation
import os

/// The set of bundle identifiers whose Cmd+Q should be intercepted.
///
/// Deliberately seeded **empty**. Nothing is ever hardcoded here — an app that
/// silently protected bundles the user never chose would be worse than one that
/// protects nothing.
///
/// Read from the event tap thread via `contains(_:)`, so the backing set lives
/// behind a lock rather than being main-actor isolated. `UserDefaults` itself is
/// never touched from the tap thread: reads can round-trip to `cfprefsd`, which
/// is far outside the callback's time budget.
final class ProtectedAppsStore: ObservableObject {

    static let defaultsKey = "ProtectedBundleIDs"

    private static let logger = Logger(subsystem: "com.raahil.quitguard", category: "store")

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var storage: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storage = Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])

        // UserDefaults.didChangeNotification only fires for writes made by this
        // process, so it does nothing for a `defaults write` from a terminal. It
        // is kept for in-process writes; external writes are picked up by the
        // reload hooks in AppDelegate and the status menu.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            self?.reload()
        }

        Self.logger.notice("Protected apps loaded: \(self.storage.sorted().joined(separator: ", "), privacy: .public)")
    }

    // MARK: - Tap-thread access

    /// Safe to call from the event tap thread: one uncontended lock and a hash
    /// lookup.
    func contains(_ bundleID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.contains(bundleID)
    }

    var all: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    // MARK: - Mutation

    /// Re-reads the defaults domain. Called on `UserDefaults.didChangeNotification`
    /// and whenever the status menu opens, so a `defaults write` from a terminal
    /// takes effect without relaunching.
    func reload() {
        let loaded = Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])

        lock.lock()
        let changed = loaded != storage
        storage = loaded
        lock.unlock()

        guard changed else { return }

        Self.logger.notice("Protected apps changed: \(loaded.sorted().joined(separator: ", "), privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }

    func setProtected(_ isProtected: Bool, for bundleID: String) {
        lock.lock()
        if isProtected {
            storage.insert(bundleID)
        } else {
            storage.remove(bundleID)
        }
        let updated = storage
        lock.unlock()

        defaults.set(updated.sorted(), forKey: Self.defaultsKey)

        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }
}
