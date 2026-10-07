import Combine
import Foundation

/// Every feature QuitGuard has today, with the text the Features pane shows.
///
/// The toggles themselves stay in each feature's own settings store (each has
/// its own threading needs); this is only the shared description, so adding a
/// feature means one folder plus one case here.
enum Feature: String, CaseIterable, Identifiable {
    case quitProtection
    case dockQuit
    case stayAwake
    case keyboardLock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quitProtection: return "Quit Protection"
        case .dockQuit: return "Dock Quit"
        case .stayAwake: return "Stay Awake (lid closed)"
        case .keyboardLock: return "Keyboard Lock"
        }
    }

    var summary: String {
        switch self {
        case .quitProtection:
            return "Asks for confirmation before Cmd+Q quits the apps you choose on the Protected Apps tab."
        case .dockQuit:
            return "Cmd + right-click a Dock tile to quit that app. Applies to any app in the Dock and quits immediately, with no confirmation. Finder is never quit this way."
        case .stayAwake:
            return "Keeps this Mac awake with the lid shut. Changing it asks for an administrator password every time, and QuitGuard turns it back off when it quits. A closed MacBook with no external cooling can run hot during a long workload."
        case .keyboardLock:
            return "Adds Lock Keyboard to the menu bar menu, for cleaning. Every key is ignored while your mouse keeps working, and the keyboard unlocks automatically after 5 minutes no matter what."
        }
    }

    var systemImage: String {
        switch self {
        case .quitProtection: return "shield.lefthalf.filled"
        case .dockQuit: return "dock.rectangle"
        case .stayAwake: return "bolt.shield"
        case .keyboardLock: return "keyboard"
        }
    }

    var needsAccessibility: Bool {
        switch self {
        case .quitProtection, .dockQuit, .keyboardLock: return true
        case .stayAwake: return false
        }
    }

    var needsAdminPassword: Bool { self == .stayAwake }

    /// Short badge text for the pane, or nil when the feature needs nothing.
    var requirementNote: String? {
        switch (needsAccessibility, needsAdminPassword) {
        case (true, _): return "Needs Accessibility"
        case (false, true): return "Asks for admin password"
        case (false, false): return nil
        }
    }
}

/// Features that do not exist yet. Shown as "Coming soon" rows so a click
/// records interest before anything is built.
enum FeatureIdea: String, CaseIterable, Identifiable {
    case holdToQuit
    case autoQuitIdle
    case timedStayAwake
    case hideDesktopIcons
    case darkModeToggle
    case hideMenuBarIcons
    case muteOnLidClose

    var id: String { rawValue }

    var title: String {
        switch self {
        case .holdToQuit: return "Hold to quit"
        case .autoQuitIdle: return "Auto-quit idle apps"
        case .timedStayAwake: return "Timed Stay Awake"
        case .hideDesktopIcons: return "Hide desktop icons"
        case .darkModeToggle: return "Quick dark-mode toggle"
        case .hideMenuBarIcons: return "Menu bar icon hiding"
        case .muteOnLidClose: return "Mute on lid close"
        }
    }

    var summary: String {
        switch self {
        case .holdToQuit: return "Hold Cmd+Q for about a second instead of seeing a dialog."
        case .autoQuitIdle: return "Quit apps you have not used for a chosen number of hours."
        case .timedStayAwake: return "Stay Awake for a set time, then turn itself off."
        case .hideDesktopIcons: return "One switch to clear the desktop for screenshots and calls."
        case .darkModeToggle: return "Flip light and dark appearance from the menu bar."
        case .hideMenuBarIcons: return "Tuck rarely used menu bar icons out of the way."
        case .muteOnLidClose: return "Mute audio when the lid closes."
        }
    }
}

/// Which ideas the user has asked for. Plain UserDefaults, main-actor only:
/// nothing reads it from a tap thread.
@MainActor
final class FeatureWishlist: ObservableObject {

    static let defaultsKey = "WantedFeatureIdeas"

    private let defaults: UserDefaults

    @Published private(set) var wanted: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        wanted = Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    func isWanted(_ idea: FeatureIdea) -> Bool {
        wanted.contains(idea.rawValue)
    }

    func setWanted(_ isWanted: Bool, for idea: FeatureIdea) {
        if isWanted {
            wanted.insert(idea.rawValue)
        } else {
            wanted.remove(idea.rawValue)
        }
        defaults.set(wanted.sorted(), forKey: Self.defaultsKey)
    }
}
