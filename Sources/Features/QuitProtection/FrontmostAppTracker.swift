import AppKit

/// A snapshot of the app that was frontmost at the moment a key event arrived.
struct FrontmostApp {
    let pid: pid_t
    let bundleID: String
    let name: String
}

/// Caches the frontmost application so the event tap callback never has to call
/// into AppKit.
///
/// Two reasons this exists rather than reading `NSWorkspace.shared
/// .frontmostApplication` directly:
///
/// 1. The callback runs on a dedicated thread with a microsecond budget, and
///    NSWorkspace is main-thread affine.
/// 2. Reading it later, from a `DispatchQueue.main.async` block, races the
///    quit we are reacting to — the app may already have gone away, so we would
///    log whatever became frontmost next.
///
/// Updated on the main thread, read under an uncontended lock from the tap
/// thread.
final class FrontmostAppTracker {
    private let lock = NSLock()
    private var current: FrontmostApp?

    init() {
        store(NSWorkspace.shared.frontmostApplication)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.store(app)
        }
    }

    /// Safe to call from the event tap thread.
    func snapshot() -> FrontmostApp? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    private func store(_ app: NSRunningApplication?) {
        let snapshot: FrontmostApp?
        if let app, let bundleID = app.bundleIdentifier {
            snapshot = FrontmostApp(
                pid: app.processIdentifier,
                bundleID: bundleID,
                name: app.localizedName ?? bundleID
            )
        } else {
            // Bundle-less processes can be frontmost. Clearing avoids attributing
            // a Cmd+Q to whichever app happened to be frontmost before them.
            snapshot = nil
        }

        lock.lock()
        current = snapshot
        lock.unlock()
    }
}
