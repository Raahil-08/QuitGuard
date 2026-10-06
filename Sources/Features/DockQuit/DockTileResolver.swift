import AppKit
import ApplicationServices
import os

/// What a point over the Dock turned out to be.
///
/// Every non-`app` case means "swallowed, but there is nothing to quit". They
/// are separate cases rather than a bare nil so the log says which one happened
/// — a chord that silently does nothing is otherwise impossible to diagnose.
enum DockTileResolution {
    case app(FrontmostApp)
    /// No tile at that point: empty strip space, or the AXList itself, which is
    /// what the hit test returns at the strip's left and right edges.
    case noTile
    case notAnApplication(subrole: String)
    case notRunning(title: String)
    case excluded(bundleID: String)
    case unreadableBundle(path: String)
    case ambiguous(bundleID: String, count: Int)
    case dockUnavailable

    var logDescription: String {
        switch self {
        case .app(let target):
            return "\(target.name) [\(target.bundleID)] pid \(target.pid)"
        case .noTile:
            return "no tile at that point"
        case .notAnApplication(let subrole):
            return "not an application tile (\(subrole))"
        case .notRunning(let title):
            return "\(title) is not running"
        case .excluded(let bundleID):
            return "\(bundleID) is excluded"
        case .unreadableBundle(let path):
            return "no bundle identifier for \(path)"
        case .ambiguous(let bundleID, let count):
            return "\(count) running instances of \(bundleID) — refusing to guess"
        case .dockUnavailable:
            return "the Dock is not running"
        }
    }
}

/// Resolves a screen point over the Dock to the running application whose tile
/// sits there.
///
/// **Main thread only.** `AXUIElementCopyElementAtPosition` is synchronous IPC
/// into the Dock process and `Bundle(url:)` reads an Info.plist off disk.
/// Neither belongs anywhere near the tap callback, which is why the callback
/// swallows on a cached rect and defers this to a main-queue block.
///
/// Identity comes from the tile's `AXURL`, not its title. Titles collide —
/// there are routinely nine running processes called "Safari Web Content" —
/// and a title match would have to guess between them. A bundle identifier read
/// from the bundle the Dock itself points at cannot.
final class DockTileResolver {

    private static let logger = Logger(subsystem: "com.raahil.quitguard", category: "dock")

    /// Compared lower-cased. Finder's real bundle identifier is
    /// `com.apple.finder`, lower-case f — an exact match against the
    /// conventional spelling `com.apple.Finder` silently fails to exclude it.
    static let excludedBundleIDs: Set<String> = ["com.apple.finder"]

    /// A wedged Dock must not hang the main thread. Generous next to the 13µs
    /// this normally takes, but it only has to be short enough not to be felt.
    private static let messagingTimeout: Float = 0.25

    func resolve(at point: CGPoint) -> DockTileResolution {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: DockBoundsTracker.dockBundleID)
            .first
        else { return .dockUnavailable }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(dockElement, Self.messagingTimeout)

        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            dockElement, Float(point.x), Float(point.y), &hit
        ) == .success, let tile = hit else {
            // kAXErrorNoValue — off the tiles entirely.
            return .noTile
        }

        // The strip's edges hit-test to the AXList rather than to any tile.
        guard Self.string(tile, kAXRoleAttribute as String) == "AXDockItem" else {
            return .noTile
        }

        let subrole = Self.string(tile, kAXSubroleAttribute as String) ?? "(none)"
        guard subrole == "AXApplicationDockItem" else {
            // Folder, stack, separator or Trash. All legitimate tiles, none of
            // them an app to quit.
            return .notAnApplication(subrole: subrole)
        }

        let title = Self.string(tile, kAXTitleAttribute as String) ?? "(untitled)"

        // Present only on application tiles, which is why the subrole check
        // comes first. A non-running app still has a tile.
        var runningRef: CFTypeRef?
        let isRunning = AXUIElementCopyAttributeValue(
            tile, "AXIsApplicationRunning" as CFString, &runningRef
        ) == .success
            && CFGetTypeID(runningRef!) == CFBooleanGetTypeID()
            && CFBooleanGetValue((runningRef as! CFBoolean))
        guard isRunning else { return .notRunning(title: title) }

        guard let url = Self.url(tile, kAXURLAttribute as String) else {
            return .unreadableBundle(path: title)
        }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            return .unreadableBundle(path: url.path)
        }

        guard !Self.excludedBundleIDs.contains(bundleID.lowercased()) else {
            return .excluded(bundleID: bundleID)
        }

        let matches = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard let app = matches.first else {
            // AXIsApplicationRunning said yes a moment ago. It quit in between,
            // or the Dock is showing a tile for a bundle at a different path.
            return .notRunning(title: title)
        }
        guard matches.count == 1 else {
            // Two live processes for one tile. Which one the user meant is a
            // guess, and the wrong guess quits an app they did not point at.
            return .ambiguous(bundleID: bundleID, count: matches.count)
        }

        return .app(FrontmostApp(
            pid: app.processIdentifier,
            bundleID: bundleID,
            name: app.localizedName ?? title
        ))
    }

    // MARK: - AX plumbing

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, attribute as CFString, &out
        ) == .success else { return nil }
        return out as? String
    }

    private static func url(_ element: AXUIElement, _ attribute: String) -> URL? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, attribute as CFString, &out
        ) == .success, let value = out, CFGetTypeID(value) == CFURLGetTypeID() else { return nil }
        return (value as! NSURL) as URL
    }
}
