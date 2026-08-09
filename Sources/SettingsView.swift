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

    func scan() {
        guard !isScanning else { return }
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

// MARK: - View

struct SettingsView: View {
    @ObservedObject var store: ProtectedAppsStore
    @StateObject private var scanner = InstalledAppsScanner()
    @State private var query = ""

    private var filtered: [InstalledApp] {
        guard !query.isEmpty else { return scanner.apps }
        return scanner.apps.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 440, minHeight: 460)
        .onAppear { scanner.scan() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask before quitting these apps")
                .font(.headline)

            Text(protectedSummary)
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("Filter by name or bundle identifier", text: $query)
                .textFieldStyle(.roundedBorder)
        }
        .padding(14)
    }

    private var protectedSummary: String {
        let count = store.all.count
        switch count {
        case 0: return "No apps selected — Cmd+Q behaves normally everywhere."
        case 1: return "1 app selected."
        default: return "\(count) apps selected."
        }
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
                Text(query.isEmpty ? "No applications found." : "No matches.")
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
        }
    }

    private func binding(for app: InstalledApp) -> Binding<Bool> {
        Binding(
            get: { store.contains(app.bundleID) },
            set: { store.setProtected($0, for: app.bundleID) }
        )
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
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let store: ProtectedAppsStore

    init(store: ProtectedAppsStore) {
        self.store = store
    }

    func show() {
        if let window {
            // An accessory app must activate to give a normal window focus.
            // Unlike the confirmation panel, stealing focus is correct here.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(store: store))
        let window = NSWindow(contentViewController: hosting)
        window.title = "QuitGuard"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 460, height: 520))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Previews

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    /// Isolated defaults suite so previewing cannot touch real settings.
    private static let previewStore = ProtectedAppsStore(
        defaults: UserDefaults(suiteName: "com.raahil.quitguard.preview") ?? .standard
    )

    static var previews: some View {
        SettingsView(store: previewStore)
            .previewDisplayName("App picker")
    }
}
#endif
