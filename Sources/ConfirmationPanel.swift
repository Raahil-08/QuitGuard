import AppKit
import os

/// A panel that can take keyboard focus without activating QuitGuard.
///
/// `.nonactivatingPanel` keeps the panel from stealing activation from the app
/// the user is quitting, but an NSPanel does not become key on its own — and
/// without key status the Escape and Return key equivalents never fire.
final class ConfirmationPanel: NSPanel {
    /// Invoked when Escape is pressed anywhere in the panel.
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    /// Escape reaches here even when focus is not on the Cancel button.
    ///
    /// This deliberately does not call `performClose`: the style mask has no
    /// `.closable`, so there is no close button and `performClose` would just
    /// beep.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Presents the "quit this protected app?" confirmation.
@MainActor
final class ConfirmationPanelController: NSObject {

    private static let logger = Logger(subsystem: "com.raahil.quitguard", category: "panel")

    private var panel: ConfirmationPanel?
    private var targetPID: pid_t?

    // MARK: - Presentation

    func present(for target: FrontmostApp) {
        // A second Cmd+Q while the panel is up should surface the existing panel
        // rather than stack another one.
        if let panel, targetPID == target.pid {
            position(panel)
            panel.makeKeyAndOrderFront(nil)
            return
        }

        dismiss()

        let runningApp = NSRunningApplication(processIdentifier: target.pid)
        let panel = makePanel(for: target, icon: runningApp?.icon)
        self.panel = panel
        targetPID = target.pid

        position(panel)
        panel.makeKeyAndOrderFront(nil)

        Self.logger.notice("Confirmation shown for \(target.name, privacy: .public)")
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        targetPID = nil
    }

    // MARK: - Actions

    @objc private func confirmQuit() {
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

    @objc private func cancel() {
        Self.logger.notice("Confirmation cancelled")
        dismiss()
    }

    // MARK: - Construction

    private func makePanel(for target: FrontmostApp, icon: NSImage?) -> ConfirmationPanel {
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
        panel.contentView = makeContentView(for: target, icon: icon)
        panel.onCancel = { [weak self] in
            MainActor.assumeIsolated {
                self?.cancel()
            }
        }

        return panel
    }

    private func makeContentView(for target: FrontmostApp, icon: NSImage?) -> NSView {
        let container = NSView()

        let iconView = NSImageView()
        iconView.image = icon ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Quit \(target.name)?")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail

        let subtitle = NSTextField(labelWithString: "\(target.name) is in your protected apps list.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 2

        let textStack = NSStackView(views: [title, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"          // Escape

        let quitButton = NSButton(title: "Quit", target: self, action: #selector(confirmQuit))
        quitButton.bezelStyle = .rounded
        quitButton.keyEquivalent = "\r"                 // Return — the default button

        let buttonStack = NSStackView(views: [cancelButton, quitButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 10
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(iconView)
        container.addSubview(textStack)
        container.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            iconView.widthAnchor.constraint(equalToConstant: 56),
            iconView.heightAnchor.constraint(equalToConstant: 56),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 16),
            textStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            textStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 28),

            buttonStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            buttonStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
            buttonStack.topAnchor.constraint(greaterThanOrEqualTo: textStack.bottomAnchor, constant: 16),
        ])

        return container
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
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + visible.height * 0.08
        )
        panel.setFrameOrigin(origin)
    }
}
