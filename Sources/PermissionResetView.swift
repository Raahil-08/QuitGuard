import AppKit
import Combine
import SwiftUI

/// Shown at launch when the Accessibility grant is missing *and* protected apps
/// are already saved.
///
/// That combination means the app was configured and working before, so the
/// first-run system prompt would be misleading — the user has already done this
/// once. It happens when the bundle is re-signed with a different certificate
/// (changing the designated requirement the grant is pinned to) or after some
/// system updates.
struct PermissionResetView: View {
    let protectedCount: Int
    let onOpenSystemSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "exclamationmark.shield")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 3) {
                    Text("QuitGuard lost its Accessibility permission")
                        .font(.headline)
                    Text(savedSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Until it is granted again, Cmd+Q behaves normally everywhere — your protected apps will quit without asking.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Text("This usually happens when QuitGuard is rebuilt with a different signing certificate, since the permission is tied to the one it was granted with.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Open System Settings", action: onOpenSystemSettings)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var savedSummary: String {
        protectedCount == 1
            ? "1 protected app is still saved."
            : "\(protectedCount) protected apps are still saved."
    }
}

@MainActor
final class PermissionResetWindowController: NSObject {
    private var window: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    private let permissions: PermissionGate
    private let protectedApps: ProtectedAppsStore

    init(permissions: PermissionGate, protectedApps: ProtectedAppsStore) {
        self.permissions = permissions
        self.protectedApps = protectedApps
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = PermissionResetView(
            protectedCount: protectedApps.all.count,
            onOpenSystemSettings: { [weak self] in
                self?.permissions.openSystemSettings()
            }
        )

        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "QuitGuard"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // Dismiss itself the moment the grant lands, so the user is not left
        // staring at a stale warning.
        permissions.$isTrusted
            .removeDuplicates()
            .sink { [weak self] trusted in
                MainActor.assumeIsolated {
                    if trusted { self?.close() }
                }
            }
            .store(in: &cancellables)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        cancellables.removeAll()
    }
}
