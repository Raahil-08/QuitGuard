import AppKit
import SwiftUI
import os

/// A panel that can take keyboard focus without activating QuitGuard.
///
/// `.nonactivatingPanel` keeps the panel from stealing activation from the app
/// the user is quitting, but an NSPanel does not become key on its own — and
/// without key status neither SwiftUI's `.defaultAction`/`.cancelAction`
/// shortcuts nor AppKit's Escape handling reach the responder chain.
final class ConfirmationPanel: NSPanel {
    /// Invoked when Escape is pressed anywhere in the panel.
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    /// Escape reaches here even when focus is not on the Cancel button.
    ///
    /// This deliberately does not call `performClose`: the style mask has no
    /// `.closable`, so there is no close button and `performClose` would just
    /// beep. It also backs up SwiftUI's `.cancelAction` — whichever handles the
    /// key first wins, and `cancel()` is idempotent.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

// MARK: - Contents

/// Drives the panel's contents. Held for the app's lifetime so the panel and its
/// hosting view can be built once and reused; only these values change per Cmd+Q.
@MainActor
final class ConfirmationModel: ObservableObject {
    @Published var appName: String = ""
    @Published var icon: NSImage?
    /// Why the panel is asking. Varies by trigger — the Dock path reaches apps
    /// that are not in the protected list, so the Cmd+Q wording would be a lie.
    @Published var detail: String = ""
}

/// What triggered a confirmation. Only affects the panel's wording.
///
/// One case, because Cmd+Q is the only path that confirms — the Dock chord
/// terminates outright and never reaches this panel.
enum QuitPrompt {
    /// Cmd+Q on an app in the protected list.
    case protectedApp

    func detail(for appName: String) -> String {
        switch self {
        case .protectedApp:
            return "\(appName) is in your protected apps list."
        }
    }
}

struct ConfirmationContentView: View {
    @ObservedObject var model: ConfirmationModel
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                iconView

                VStack(alignment: .leading, spacing: 3) {
                    Text("Quit \(model.appName)?")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(model.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Quit", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var iconView: some View {
        Group {
            if let icon = model.icon {
                Image(nsImage: icon)
                    .resizable()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: 56, height: 56)
    }
}

// MARK: - Controller

/// Presents the "quit this protected app?" confirmation.
@MainActor
final class ConfirmationPanelController: NSObject {

    private static let logger = Logger(subsystem: "com.raahil.quitguard", category: "panel")

    private let model = ConfirmationModel()
    private var panel: ConfirmationPanel?
    private var targetPID: pid_t?

    // MARK: - Presentation

    /// Builds the panel and its hosting view once, ahead of any Cmd+Q.
    ///
    /// Called from `applicationDidFinishLaunching`. The first layout of an
    /// NSHostingView costs several milliseconds; this window has to be on screen
    /// the instant the user presses Cmd+Q, so that cost is paid at launch and
    /// the instance is reused for every subsequent confirmation.
    func prepare() {
        guard panel == nil else { return }

        let panel = makePanel()
        self.panel = panel

        // Force the first layout pass now, off the Cmd+Q path.
        panel.contentView?.layoutSubtreeIfNeeded()

        Self.logger.notice("Confirmation panel prebuilt")
    }

    func present(for target: FrontmostApp, prompt: QuitPrompt = .protectedApp) {
        // No-op when already built; guards against a Cmd+Q arriving before
        // prepare() for any reason.
        prepare()
        guard let panel else { return }

        model.appName = target.name
        model.detail = prompt.detail(for: target.name)
        model.icon = NSRunningApplication(processIdentifier: target.pid)?.icon
        targetPID = target.pid

        position(panel)
        panel.makeKeyAndOrderFront(nil)

        Self.logger.notice(
            "Confirmation shown for \(target.name, privacy: .public) via \(String(describing: prompt), privacy: .public)"
        )
    }

    func dismiss() {
        panel?.orderOut(nil)
        targetPID = nil
        // The panel instance is deliberately retained for reuse.
    }

    // MARK: - Actions

    @objc func confirmQuit() {
        guard let pid = targetPID else {
            dismiss()
            return
        }
        dismiss()

        guard let app = NSRunningApplication(processIdentifier: pid) else {
            Self.logger.notice("Confirmed quit, but pid \(pid) is no longer running")
            return
        }

        // terminate() sends the standard quit Apple Event, so unsaved-changes
        // dialogs still appear. Re-posting the keystroke instead would be
        // re-intercepted by our own tap.
        let requested = app.terminate()
        Self.logger.notice("terminate() for pid \(pid) requested=\(requested)")
    }

    @objc func cancel() {
        Self.logger.notice("Confirmation cancelled")
        dismiss()
    }

    // MARK: - Construction

    private func makePanel() -> ConfirmationPanel {
        let panel = ConfirmationPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 148),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        // .canJoinAllSpaces puts it on whichever Space is current, and
        // .fullScreenAuxiliary lets it draw over a full-screen app instead of
        // forcing a Space switch.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentView = NSHostingView(
            rootView: ConfirmationContentView(
                model: model,
                onCancel: { [weak self] in self?.cancel() },
                onConfirm: { [weak self] in self?.confirmQuit() }
            )
        )
        panel.onCancel = { [weak self] in
            MainActor.assumeIsolated {
                self?.cancel()
            }
        }

        return panel
    }

    /// Centres the panel on the screen containing the mouse, not the screen that
    /// happens to hold the menu bar.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main

        guard let visible = screen?.visibleFrame else { return }

        let size = panel.frame.size
        // Slightly above centre reads better than dead centre for a dialog.
        let desired = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + visible.height * 0.08
        )

        // The 0.08 nudge is unconditional, so on a short display — or if the
        // panel ever grows taller — it can push the title bar up under the menu
        // bar. Clamp to visibleFrame. If the panel is somehow larger than the
        // visible area, min() wins first and it pins to the bottom-left corner
        // instead of landing off screen entirely.
        let origin = NSPoint(
            x: max(visible.minX, min(desired.x, visible.maxX - size.width)),
            y: max(visible.minY, min(desired.y, visible.maxY - size.height))
        )
        panel.setFrameOrigin(origin)

        // Logged so a placement bug is diagnosable from the log alone. The
        // frame/visibleFrame delta is what reveals menu bar and Dock insets,
        // which is where full-screen and multi-display cases go wrong.
        let full = screen?.frame ?? .zero
        let placement = String(
            format: "origin (%.0f, %.0f) size %.0fx%.0f frame (%.0f, %.0f, %.0f, %.0f) "
                + "visibleFrame (%.0f, %.0f, %.0f, %.0f)",
            origin.x, origin.y, size.width, size.height,
            full.minX, full.minY, full.width, full.height,
            visible.minX, visible.minY, visible.width, visible.height
        )
        let clamped = (origin == desired) ? "no" : "yes"
        Self.logger.notice("Panel placed: \(placement, privacy: .public) clamped=\(clamped, privacy: .public)")
    }
}

// MARK: - Previews

#if DEBUG
struct ConfirmationContentView_Previews: PreviewProvider {
    private static func sampleModel(_ prompt: QuitPrompt) -> ConfirmationModel {
        let m = ConfirmationModel()
        m.appName = "Safari"
        m.detail = prompt.detail(for: m.appName)
        m.icon = NSWorkspace.shared.icon(forFile: "/Applications/Safari.app")
        return m
    }

    static var previews: some View {
        ConfirmationContentView(model: sampleModel(.protectedApp), onCancel: {}, onConfirm: {})
            .frame(width: 380, height: 148)
            .previewDisplayName("Cmd+Q, protected app")
    }
}
#endif
