import AppKit
import ApplicationServices
import Combine

/// Tracks whether QuitGuard holds the Accessibility (TCC) grant.
///
/// `CGEvent.tapCreate` with `.cgSessionEventTap` requires this grant; without it
/// the tap is created but never receives events.
///
/// The grant is pinned to the bundle's designated requirement —
/// `identifier "com.raahil.quitguard" and certificate leaf = H"<cert hash>"` —
/// so it survives rebuilds as long as PRODUCT_BUNDLE_IDENTIFIER and
/// CODE_SIGN_IDENTITY are unchanged. See CLAUDE.md.
@MainActor
final class PermissionGate: ObservableObject {

    @Published private(set) var isTrusted: Bool = AXIsProcessTrusted()

    private var pollTimer: Timer?

    // MARK: - Checks

    /// Non-prompting check. Cheap and side-effect free, so it is safe to call on
    /// a timer or on every menu open.
    @discardableResult
    func refresh() -> Bool {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted {
            isTrusted = trusted
        }
        return trusted
    }

    /// Prompting check. Asks the system to show its "open System Settings"
    /// dialog when the grant is missing.
    ///
    /// The dialog is asynchronous and the user may take minutes to act on it, so
    /// the return value describes the state *now*, not after they respond.
    /// `startPolling()` is what actually notices the grant landing.
    @discardableResult
    func requestAccess() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        isTrusted = trusted
        return trusted
    }

    // MARK: - Polling

    /// macOS posts no reliable notification for "the user just granted us
    /// Accessibility", so poll while waiting. Stops as soon as the grant lands,
    /// so this is not a persistent timer.
    func startPolling() {
        guard pollTimer == nil, !isTrusted else { return }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.refresh() {
                    self.stopPolling()
                }
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Opens the exact System Settings pane, for when the user dismissed the
    /// system prompt and needs a way back.
    func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
