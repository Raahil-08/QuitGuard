import AppKit
import ApplicationServices
import os

/// Caches the screen rect of the Dock's tile strip so the event tap can decide,
/// with arithmetic alone, whether a right-click landed on the Dock.
///
/// The tap callback cannot do the real work itself. Resolving a tile means
/// `AXUIElementCopyElementAtPosition`, which is synchronous IPC into the Dock
/// process: measured at 13µs median on a healthy system, but with no bounded
/// worst case — a wedged Dock would stall the callback well past its budget and
/// get the tap disabled. So the callback tests a cached rect, and the actual AX
/// resolution happens later on the main queue.
///
/// The cache is deliberately biased towards *not* matching. `bounds` is nil
/// until a refresh succeeds, and `contains(_:)` returns false when it is nil, so
/// every failure mode — no Accessibility grant, Dock restarting, an autohidden
/// or repositioned Dock we failed to measure — degrades to "the chord does
/// nothing" rather than "the tap swallows right-clicks".
final class DockBoundsTracker {

    static let logger = Logger(subsystem: "com.raahil.quitguard", category: "dock")

    static let dockBundleID = "com.apple.dock"

    /// The Dock animates tiles in and out. Measuring immediately after an app
    /// launches catches the strip mid-resize, so refreshes are debounced.
    private static let refreshDelay: TimeInterval = 0.7

    /// A wedged Dock must not hang the main thread either. The refresh is not on
    /// any hot path, so this only has to be short enough not to be noticed.
    private static let messagingTimeout: Float = 0.25

    private let lock = NSLock()
    private var bounds: CGRect?

    private var pendingRefresh: DispatchWorkItem?

    init() {
        let workspace = NSWorkspace.shared.notificationCenter

        // The tile strip grows and shrinks as apps come and go, so a rect
        // measured once goes stale the first time the user opens anything.
        for name: NSNotification.Name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.bundleIdentifier == Self.dockBundleID {
                    // Dock restart. Drop the stale rect immediately rather than
                    // waiting out the debounce with bounds pointing at wherever
                    // the old Dock was.
                    self?.store(nil, reason: "Dock restarted")
                }
                self?.scheduleRefresh()
            }
        }

        // Resolution changes, display arrangement changes, and moving the Dock
        // to another screen all land here.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.store(nil, reason: "screen parameters changed")
            self?.scheduleRefresh()
        }

        refresh()
    }

    // MARK: - Tap-thread access

    /// Safe to call from the event tap thread: one uncontended lock and a
    /// containment test. Returns false whenever the bounds are unknown.
    func contains(_ point: CGPoint) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let bounds else { return false }
        return bounds.contains(point)
    }

    /// For logging and diagnostics. Not on the tap path.
    var current: CGRect? {
        lock.lock()
        defer { lock.unlock() }
        return bounds
    }

    // MARK: - Refresh

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.refreshDelay, execute: work)
    }

    /// Measures the Dock's tile strip. Main thread only — this makes AX calls.
    func refresh() {
        guard AXIsProcessTrusted() else {
            store(nil, reason: "not Accessibility-trusted")
            return
        }
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.dockBundleID)
            .first
        else {
            store(nil, reason: "Dock is not running")
            return
        }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(dockElement, Self.messagingTimeout)

        guard let list = Self.tileList(of: dockElement) else {
            store(nil, reason: "no AXList in the Dock's AX tree")
            return
        }
        guard let frame = Self.frame(of: list) else {
            store(nil, reason: "AXList has no readable position/size")
            return
        }
        guard frame.width > 0, frame.height > 0 else {
            store(nil, reason: "AXList frame is empty")
            return
        }

        store(frame, reason: nil)
    }

    private func store(_ newValue: CGRect?, reason: String?) {
        lock.lock()
        let changed = newValue != bounds
        bounds = newValue
        lock.unlock()

        guard changed else { return }

        if let newValue {
            let rect = String(
                format: "(%.0f, %.0f) %.0fx%.0f",
                newValue.minX, newValue.minY, newValue.width, newValue.height
            )
            Self.logger.notice("Dock bounds: \(rect, privacy: .public)")
        } else {
            Self.logger.notice(
                "Dock bounds cleared — \(reason ?? "unknown", privacy: .public); Cmd+right-click is inert"
            )
        }
    }

    // MARK: - AX plumbing

    /// The Dock exposes exactly one AXList holding every tile. Matching on role
    /// rather than taking `children[0]` so a future Dock that adds a sibling
    /// element does not silently hand back the wrong rect.
    private static func tileList(of dockElement: AXUIElement) -> AXUIElement? {
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            dockElement, kAXChildrenAttribute as CFString, &childrenRef
        ) == .success,
            let children = childrenRef as? [AXUIElement]
        else { return nil }

        return children.first { child in
            var roleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                child, kAXRoleAttribute as CFString, &roleRef
            ) == .success else { return false }
            return (roleRef as? String) == (kAXListRole as String)
        }
    }

    /// AX reports positions in top-left-origin global screen coordinates, which
    /// is the same space `CGEvent.location` uses. No flipping is needed, and
    /// introducing any would break the bounds test.
    static func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &positionRef
        ) == .success,
            AXUIElementCopyAttributeValue(
                element, kAXSizeAttribute as CFString, &sizeRef
            ) == .success,
            let positionValue = positionRef, CFGetTypeID(positionValue) == AXValueGetTypeID(),
            let sizeValue = sizeRef, CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }

        return CGRect(origin: origin, size: size)
    }
}
