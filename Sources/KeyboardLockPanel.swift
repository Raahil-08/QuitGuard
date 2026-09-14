import AppKit
import Combine
import SwiftUI
import os

// MARK: - Copy

/// Everything the panel says for a given state. Pure, so the copy and the
/// countdown format are asserted without a window.
struct KeyboardLockPanelText: Equatable {
    let symbol: String
    let title: String
    let detail: String

    nonisolated static func forStatus(_ status: KeyboardLock.Status) -> KeyboardLockPanelText {
        switch status {
        case .locked:
            return KeyboardLockPanelText(
                symbol: "keyboard",
                title: "Keyboard locked",
                detail: "Your mouse still works. Click Unlock when you're done."
            )
        case .notLocked, .unlocked:
            // `.unlocked` never reaches the screen — the panel is ordered out —
            // but it must not be able to read "locked" if it ever did.
            return KeyboardLockPanelText(
                symbol: "exclamationmark.triangle.fill",
                title: "Keyboard not locked right now",
                detail: "Keys are reaching apps. The lock resumes by itself as soon as it can."
            )
        }
    }

    /// "4:59". Rounded up, so the display never reads 0:00 while still locked.
    nonisolated static func countdown(remaining: TimeInterval) -> String {
        let seconds = max(0, Int(remaining.rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - View

struct KeyboardLockContentView: View {
    @ObservedObject var lock: KeyboardLock
    let onUnlock: () -> Void

    var body: some View {
        let text = KeyboardLockPanelText.forStatus(lock.status)
        let warning = lock.status != .locked

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: text.symbol)
                    .font(.system(size: 30))
                    .foregroundStyle(warning ? Color.orange : Color.accentColor)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(text.title)
                        .font(.headline)
                    Text(text.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Display only. The countdown reads the failsafe's own deadline but
            // drives nothing — the unlock does not depend on this view, or on
            // the main thread, at all.
            if let deadline = lock.deadline {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Unlocks automatically in \(KeyboardLockPanelText.countdown(remaining: deadline.timeIntervalSince(context.date)))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                // No key equivalent: while keys are leaking, a stray Return or
                // Space from the cloth must not unlock.
                Button("Unlock Keyboard", action: onUnlock)
                    .controlSize(.large)
            }
        }
        .padding(18)
        .frame(width: 380)
    }
}

// MARK: - Controller

/// Shows the lock panel whenever a lock is engaged.
///
/// A separate instance from the Cmd+Q confirmation panel. The window
/// configuration in `makePanel()` and `position(_:)` is **copied** from
/// `ConfirmationPanelController`, where it is verified against full-screen
/// Spaces, plain Spaces and an AirPlay display. It has to be copied: both are
/// `private` in `ConfirmationPanel.swift`, which is not to be modified. The
/// `ConfirmationPanel` class itself is reused unchanged.
///
/// Keep the two in step. A harness compares `level`, `collectionBehavior` and
/// `styleMask` between the live panels so a drift fails loudly.
@MainActor
final class KeyboardLockPanelController: NSObject {

    private static let logger = Logger(subsystem: "com.raahil.quitguard", category: "lock")

    private let lock: KeyboardLock
    private var panel: ConfirmationPanel?
    private var cancellables = Set<AnyCancellable>()

    init(lock: KeyboardLock) {
        self.lock = lock
        super.init()

        // The emitted value, not `lock.status`: `@Published` fires from
        // willSet, so the property still holds the previous value in here.
        lock.$status
            .map { $0 != .unlocked }
            .removeDuplicates()
            .sink { [weak self] engaged in
                MainActor.assumeIsolated {
                    if engaged { self?.present() } else { self?.dismiss() }
                }
            }
            .store(in: &cancellables)
    }

    func prepare() {
        guard panel == nil else { return }
        let panel = makePanel()
        self.panel = panel
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    private func present() {
        prepare()
        guard let panel else { return }
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        Self.logger.notice("Lock panel shown")
    }

    private func dismiss() {
        panel?.orderOut(nil)
    }

    // MARK: Construction — copied from ConfirmationPanelController

    private func makePanel() -> ConfirmationPanel {
        let panel = ConfirmationPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 190),
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
        panel.title = "Keyboard Lock"
        panel.contentView = NSHostingView(
            rootView: KeyboardLockContentView(
                lock: lock,
                onUnlock: { [weak self] in self?.lock.unlock(reason: .button) }
            )
        )
        // Escape deliberately does nothing. While keys are leaking, a cloth
        // brushing Esc must not end the lock.
        panel.onCancel = nil
        return panel
    }

    /// Centres the panel on the screen containing the mouse, clamped to that
    /// screen's visible frame. Copied verbatim in behaviour.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main

        guard let visible = screen?.visibleFrame else { return }

        let size = panel.frame.size
        let desired = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + visible.height * 0.08
        )
        let origin = NSPoint(
            x: max(visible.minX, min(desired.x, visible.maxX - size.width)),
            y: max(visible.minY, min(desired.y, visible.maxY - size.height))
        )
        panel.setFrameOrigin(origin)
    }
}
