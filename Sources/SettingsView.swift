import AppKit
import SwiftUI
import os

// MARK: - Discovery

struct InstalledApp: Identifiable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let path: String
}

/// Enumerates application bundles in /Applications and ~/Applications.
///
/// Scanning reads an Info.plist per bundle, so it runs off the main thread — a
/// stall there would eat into the event tap's time budget and risk the tap being
/// disabled by timeout.
@MainActor
final class InstalledAppsScanner: ObservableObject {

    private static let logger = Logger(subsystem: "com.raahil.quitguard", category: "scanner")

    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var isScanning = false

    /// Scanning happens once per app launch.
    ///
    /// Previously guaranteed by the window being retained, so `onAppear` fired
    /// only once. A TabView can create and destroy tab content as the user
    /// switches, so the guarantee now lives here instead of depending on
    /// SwiftUI's view lifecycle. Re-enumerating /Applications on every tab
    /// switch would be pure waste — the list does not change while the window
    /// is open.
    private var hasScanned = false

    func scan() {
        guard !hasScanned, !isScanning else { return }
        hasScanned = true
        isScanning = true

        Task.detached(priority: .userInitiated) {
            let found = Self.scanDirectories()
            await MainActor.run {
                self.apps = found
                self.isScanning = false
                Self.logger.notice("Scanned \(found.count) applications")
            }
        }
    }

    nonisolated private static func scanDirectories() -> [InstalledApp] {
        let fm = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            // macOS 10.15 moved the bundled apps out of /Applications. Without
            // this root, TextEdit, Mail, Notes, Preview, Music, Messages and
            // Calendar cannot be selected at all. The one-level descent below
            // also picks up /System/Applications/Utilities.
            URL(fileURLWithPath: "/System/Applications"),
        ]

        var byBundleID: [String: InstalledApp] = [:]

        for root in roots {
            // No .skipsHiddenFiles: /Applications/Safari.app is a
            // `restricted,hidden` symlink into the Cryptex volume, so that
            // option silently drops Safari. Dot-prefixed entries are filtered
            // explicitly below instead.
            guard let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { continue }

            for entry in entries {
                if entry.lastPathComponent.hasPrefix(".") {
                    continue
                }
                if entry.pathExtension == "app" {
                    add(entry, to: &byBundleID, fileManager: fm)
                } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    // One level deeper picks up /Applications/Utilities and the
                    // per-vendor folders installers like to create.
                    let nested = (try? fm.contentsOfDirectory(
                        at: entry,
                        includingPropertiesForKeys: nil,
                        options: []
                    )) ?? []
                    for child in nested where child.pathExtension == "app" {
                        add(child, to: &byBundleID, fileManager: fm)
                    }
                }
            }
        }

        return byBundleID.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    nonisolated private static func add(
        _ url: URL,
        to dict: inout [String: InstalledApp],
        fileManager fm: FileManager
    ) {
        // CFBundleIdentifier is read straight from the bundle; nothing is
        // hardcoded anywhere in QuitGuard.
        guard let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier
        else { return }

        let name = fm.displayName(atPath: url.path)
        dict[bundleID] = InstalledApp(bundleID: bundleID, name: name, path: url.path)
    }
}

// MARK: - Tabs

/// The window's two panes.
///
/// Rendered by an `NSToolbar` in `.preference` style rather than by SwiftUI's
/// `TabView`. macOS backs `TabView` with an `NSTabView`, whose tab items are
/// text only — an SF Symbol passed via `.tabItem { Label(...) }` is silently
/// discarded, and no `tabViewStyle` or `labelStyle` changes that. The
/// icon-above-label pill is a toolbar, not a tab bar.
enum SettingsTab: String, CaseIterable {
    case settings
    case about

    var title: String {
        switch self {
        case .settings: return "Settings"
        case .about: return "About"
        }
    }

    /// Filled, because an outline glyph reads thin next to `info.circle` at
    /// toolbar size.
    var systemImage: String {
        switch self {
        case .settings: return "gearshape.fill"
        case .about: return "info.circle"
        }
    }

    var itemIdentifier: NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("com.raahil.quitguard.tab.\(rawValue)")
    }

    init?(itemIdentifier: NSToolbarItem.Identifier) {
        guard let match = Self.allCases.first(where: { $0.itemIdentifier == itemIdentifier })
        else { return nil }
        self = match
    }
}

/// Shared between the AppKit toolbar and the SwiftUI content, which is what
/// lets a toolbar click swap the pane.
final class SettingsTabSelection: ObservableObject {
    @Published var current: SettingsTab = .settings
}

// MARK: - View

struct SettingsView: View {
    @ObservedObject var store: ProtectedAppsStore
    @ObservedObject var dockQuit: DockQuitSettings
    @ObservedObject var launchAtLogin: LaunchAtLogin
    @ObservedObject var stayAwake: StayAwake
    @ObservedObject var keyboardLockSettings: KeyboardLockSettings
    @ObservedObject var tabs: SettingsTabSelection
    @StateObject private var scanner = InstalledAppsScanner()
    @State private var query = ""
    @State private var showSelectedOnly = false

    private var filtered: [InstalledApp] {
        // Selected-only is applied before the text query so the two compose:
        // with the toggle on and text entered you get protected apps matching
        // the text, not all apps matching the text.
        var result = scanner.apps
        if showSelectedOnly {
            result = result.filter { store.contains($0.bundleID) }
        }

        guard !query.isEmpty else { return result }
        return result.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Group {
            switch tabs.current {
            case .settings: settingsTab
            case .about: AboutView()
            }
        }
        .frame(minWidth: 500, minHeight: 580)
        // Outside the switch, so it fires when the window opens rather than
        // each time a pane is swapped in. `scan()` is idempotent as well, so
        // neither alone is load bearing.
        .onAppear { scanner.scan() }
    }

    /// Deliberately not `Form`/`Section`. Two things break there: the grouped
    /// form style promotes a TextField's placeholder to a wrapped label in the
    /// leading column, wrecking the filter row, and the app List expands to its
    /// full content height inside the Form's own scroll view — which pushes the
    /// Behaviour section below 136 rows of apps. A plain VStack keeps the List
    /// as the only scrolling region, which is what this window wants.
    private var settingsTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Protected apps")
            header
            content
            Divider()
            sectionLabel("Behaviour")
            behaviour
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    /// Switches, not checkboxes: these are settings that take effect on their
    /// own. The app rows above stay checkboxes because they are a selection.
    private var behaviour: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                switchRow(
                    "Quit apps with Cmd + right-click in the Dock",
                    isOn: Binding(
                        get: { dockQuit.isEnabled },
                        set: { dockQuit.setEnabled($0) }
                    )
                )

                // Worth stating plainly. Everything else in this window is
                // scoped to the ticked apps, so the natural assumption is that
                // this is too.
                Text("Applies to any app in the Dock, not just the ones ticked above. The app quits immediately — no confirmation. Finder is never quit this way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Reads and writes the same LaunchAtLogin instance the status menu
            // holds, so toggling either moves the other with no cached copy in
            // between. See the note on LaunchAtLogin itself.
            switchRow(
                "Launch QuitGuard at login",
                isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )
            )

            if launchAtLogin.requiresApproval {
                Text("Waiting for approval in System Settings › General › Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                switchRow(
                    "Claude maxxing",
                    isOn: Binding(
                        get: { stayAwake.isEnabled },
                        set: { stayAwake.setEnabled($0) }
                    )
                )
                // Disabled while the password prompt is up. The switch would
                // otherwise accept a second click and stack a second prompt
                // behind the first, where it is invisible.
                .disabled(stayAwake.isBusy)

                Text("Keeps this Mac awake with the lid shut. Changing it asks for an administrator password every time, and QuitGuard turns it back off when it quits. A closed MacBook with no external cooling can run hot during a long workload.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                switchRow(
                    "Keyboard Lock",
                    isOn: Binding(
                        get: { keyboardLockSettings.isEnabled },
                        set: { keyboardLockSettings.setEnabled($0) }
                    )
                )

                // The action itself is in the menu bar menu, not here — it is
                // an action rather than a setting, and should be reachable from
                // any app without opening this window.
                Text("Adds Lock Keyboard to the menu bar menu, for cleaning. Every key is ignored while your mouse keeps working, and the keyboard unlocks automatically after 5 minutes no matter what.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Label left, switch hard right — so switches line up with each other
    /// instead of each starting wherever its own label happens to end.
    ///
    /// The Toggle keeps its title and hides it rather than being given an empty
    /// one: `labelsHidden()` suppresses the drawing, but the string is still
    /// there for VoiceOver.
    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    /// The section label says "Protected apps"; this says what being in it
    /// does, which the label alone does not.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(protectedSummary)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                TextField("Filter by name or bundle identifier", text: $query)
                    .textFieldStyle(.roundedBorder)

                Toggle("Selected only", isOn: $showSelectedOnly)
                    .toggleStyle(.checkbox)
                    // Without this the checkbox is squeezed by the text field,
                    // which takes all the width it is offered.
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var protectedSummary: String {
        let count = store.all.count
        switch count {
        case 0: return "No apps selected — Cmd+Q behaves normally everywhere."
        case 1: return "1 app selected."
        default: return "\(count) apps selected."
        }
    }

    /// The selected-only cases are called out separately: falling back to
    /// "No matches." there reads as though the app is missing from the scan,
    /// when really the filter is just hiding everything unticked.
    private var emptyMessage: String {
        if showSelectedOnly {
            return store.all.isEmpty
                ? "No apps are protected yet."
                : "No protected apps match."
        }
        return query.isEmpty ? "No applications found." : "No matches."
    }

    @ViewBuilder
    private var content: some View {
        if scanner.isScanning && scanner.apps.isEmpty {
            VStack {
                Spacer()
                ProgressView("Scanning applications…")
                Spacer()
            }
        } else if filtered.isEmpty {
            VStack {
                Spacer()
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            List(filtered) { app in
                Toggle(isOn: binding(for: app)) {
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                            .resizable()
                            .frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name)
                            Text(app.bundleID)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }
            .listStyle(.inset)
            // Unticking an app while "Selected only" is on removes its row
            // underneath the pointer. Rows are Identifiable, so a plain
            // implicit animation gives List a stable identity to fade out
            // against instead of snapping the remaining rows upward.
            .animation(.default, value: filtered)
        }
    }

    private func binding(for app: InstalledApp) -> Binding<Bool> {
        Binding(
            get: { store.contains(app.bundleID) },
            set: { store.setProtected($0, for: app.bundleID) }
        )
    }
}

// MARK: - About

/// Placeholder. Name, version and one line of context.
struct AboutView: View {

    /// Read from the bundle, never hardcoded — a literal here would drift from
    /// MARKETING_VERSION the first time it changed.
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?): return "Version \(short) (\(build))"
        case let (short?, nil): return "Version \(short)"
        default: return "Version unknown"
        }
    }

    private var appName: String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? "QuitGuard"
    }

    var body: some View {
        VStack(spacing: 8) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text(appName)
                .font(.title2.weight(.semibold))

            Text(version)
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("A personal tool. Built for one machine, not for the App Store.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - Window

/// Hosts `SettingsView` in a plain NSWindow.
///
/// Deliberately not SwiftUI's `Settings` scene: opening that programmatically
/// from a status item requires the `showSettingsWindow:` selector, which is
/// undocumented and was renamed between macOS 12 and 13. An NSWindow built here
/// is fully supported API and behaves the same on every version.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private var window: NSWindow?
    private let store: ProtectedAppsStore
    private let dockQuit: DockQuitSettings
    private let launchAtLogin: LaunchAtLogin
    private let stayAwake: StayAwake
    private let keyboardLockSettings: KeyboardLockSettings

    /// Owned here rather than by the view: the toolbar is AppKit and outlives
    /// any particular SwiftUI body.
    private let tabs = SettingsTabSelection()

    init(
        store: ProtectedAppsStore,
        dockQuit: DockQuitSettings,
        launchAtLogin: LaunchAtLogin,
        stayAwake: StayAwake,
        keyboardLockSettings: KeyboardLockSettings
    ) {
        self.store = store
        self.dockQuit = dockQuit
        self.launchAtLogin = launchAtLogin
        self.stayAwake = stayAwake
        self.keyboardLockSettings = keyboardLockSettings
    }

    func show() {
        // Every open, first or repeat: a terminal `sudo pmset`, another app, or
        // a reboot can have changed this behind us, and the switch is only
        // honest if it came from a read.
        stayAwake.refresh()

        if let window {
            // Reopening shows whatever SMAppService says now — the user may
            // have changed it in System Settings while this window was closed.
            launchAtLogin.refresh()
            // An accessory app must activate to give a normal window focus.
            // Unlike the confirmation panel, stealing focus is correct here.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(
            rootView: SettingsView(
                store: store,
                dockQuit: dockQuit,
                launchAtLogin: launchAtLogin,
                stayAwake: stayAwake,
                keyboardLockSettings: keyboardLockSettings,
                tabs: tabs
            )
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "QuitGuard"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 520, height: 620))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        // .preference is what produces the System Settings appearance: items
        // centred under the title, SF Symbol above the label, and a pill behind
        // the selected one. It is a plain NSWindow property, so none of this
        // costs the menu bar open path.
        let toolbar = NSToolbar(identifier: "com.raahil.quitguard.settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = tabs.current.itemIdentifier
        window.toolbar = toolbar
        window.toolbarStyle = .preference

        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSToolbarDelegate

    private var tabIdentifiers: [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.itemIdentifier)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        tabIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        tabIdentifiers
    }

    /// Without this the items are buttons rather than a selector, and no pill
    /// is ever drawn.
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        tabIdentifiers
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let tab = SettingsTab(itemIdentifier: itemIdentifier) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.title
        item.paletteLabel = tab.title
        item.image = NSImage(
            systemSymbolName: tab.systemImage,
            accessibilityDescription: tab.title
        )
        item.target = self
        item.action = #selector(selectTab(_:))
        return item
    }

    @objc private func selectTab(_ sender: NSToolbarItem) {
        guard let tab = SettingsTab(itemIdentifier: sender.itemIdentifier) else { return }
        tabs.current = tab
    }
}

// MARK: - Previews

#if DEBUG
extension InstalledAppsScanner {
    /// Synchronous scan for previews only. A same-file extension can reach
    /// `scanDirectories()` despite its `private` modifier.
    nonisolated static func previewScan() -> [InstalledApp] { scanDirectories() }
}

struct SettingsView_Previews: PreviewProvider {
    /// Isolated defaults suite so previewing cannot touch real settings.
    ///
    /// Seeded with a couple of apps so "Selected only" has something to show —
    /// the store starts empty, so the filter would otherwise always render the
    /// empty state. The seeds come from a live scan rather than literal bundle
    /// identifiers: none are hardcoded anywhere in QuitGuard, and taking them
    /// from the scanner guarantees they match the rows the picker lists.
    private static let previewStore: ProtectedAppsStore = {
        let defaults = UserDefaults(suiteName: "com.raahil.quitguard.preview") ?? .standard
        let store = ProtectedAppsStore(defaults: defaults)
        for app in InstalledAppsScanner.previewScan().prefix(2) {
            store.setProtected(true, for: app.bundleID)
        }
        return store
    }()

    /// Each state gets its own defaults suite. Sharing one would make the two
    /// previews fight over the same key, and whichever rendered second would
    /// win — so the "off" preview would silently start showing "on".
    private static func dockQuit(enabled: Bool, suite: String) -> DockQuitSettings {
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let settings = DockQuitSettings(defaults: defaults)
        settings.setEnabled(enabled)
        return settings
    }

    /// The real thing. Previewing reads SMAppService for this app bundle, which
    /// under the canvas is Xcode's preview host — so the switch shows whatever
    /// that reports and must not be trusted as QuitGuard's own login state.
    private static let previewLaunchAtLogin = LaunchAtLogin()

    /// Reads the machine's real `SleepDisabled`, and cannot do otherwise —
    /// there is no stored bool to seed. The canvas therefore shows this switch
    /// in whatever position the development Mac is actually in.
    private static let previewStayAwake = StayAwake()

    /// Own suite, same reason as the Dock toggle: shared keys make previews
    /// fight. On in the second preview so both switch positions are visible.
    private static func keyboardLock(enabled: Bool, suite: String) -> KeyboardLockSettings {
        let settings = KeyboardLockSettings(defaults: UserDefaults(suiteName: suite) ?? .standard)
        settings.setEnabled(enabled)
        return settings
    }

    static var previews: some View {
        SettingsView(
            store: previewStore,
            dockQuit: dockQuit(enabled: false, suite: "com.raahil.quitguard.preview.dockoff"),
            launchAtLogin: previewLaunchAtLogin,
            stayAwake: previewStayAwake,
            keyboardLockSettings: keyboardLock(enabled: false, suite: "com.raahil.quitguard.preview.lockoff"),
            tabs: SettingsTabSelection()
        )
        .previewDisplayName("Dock quit off")

        SettingsView(
            store: previewStore,
            dockQuit: dockQuit(enabled: true, suite: "com.raahil.quitguard.preview.dockon"),
            launchAtLogin: previewLaunchAtLogin,
            stayAwake: previewStayAwake,
            keyboardLockSettings: keyboardLock(enabled: true, suite: "com.raahil.quitguard.preview.lockon"),
            tabs: SettingsTabSelection()
        )
        .previewDisplayName("Dock quit on")
    }
}

struct AboutView_Previews: PreviewProvider {
    static var previews: some View {
        AboutView()
            .frame(width: 520, height: 580)
            .previewDisplayName("About")
    }
}
#endif
