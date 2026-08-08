import AppKit
import CoreGraphics
import os

/// The C event tap callback.
///
/// Trampolines straight into `QuitInterceptor.handle` via the `refcon` pointer.
/// A CGEventTapCallBack is a C function pointer and cannot capture context, so
/// the instance is passed as an unmanaged pointer in `userInfo`.
private let quitInterceptorCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }
    let interceptor = Unmanaged<QuitInterceptor>.fromOpaque(refcon).takeUnretainedValue()
    return interceptor.handle(type: type, event: event)
}

/// Installs the session-wide Cmd+Q event tap.
///
/// A matching Cmd+Q is consumed when the frontmost app is in
/// `ProtectedAppsStore`, and passed through untouched otherwise.
///
/// The tap runs on its own thread rather than the main run loop. If the callback
/// ran on main, any main-thread stall — SwiftUI layout, enumerating
/// /Applications in the settings picker — would eat into the tap's time budget
/// and get it disabled by timeout.
final class QuitInterceptor {

    static let logger = Logger(subsystem: "com.raahil.quitguard", category: "tap")

    /// Keycode 12 is physical 'q'. CGKeyCode values describe key position, not
    /// the character produced, so this holds across keyboard layouts.
    private static let keycodeQ: Int64 = 12

    private let frontmost: FrontmostAppTracker
    private let protectedApps: ProtectedAppsStore

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?

    init(frontmost: FrontmostAppTracker, protectedApps: ProtectedAppsStore) {
        self.frontmost = frontmost
        self.protectedApps = protectedApps
    }

    // MARK: - Lifecycle

    var isInstalled: Bool { eventTap != nil }

    /// Whether the tap exists *and* the system has it enabled. Stage 7 polls this.
    var isTapEnabled: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let eventMask = (1 as CGEventMask) << CGEventType.keyDown.rawValue

        // .cgSessionEventTap  — session-wide, sees events for every app.
        // .headInsertEventTap — ahead of other taps, so we decide first.
        // .defaultTap         — active tap; a listen-only tap could not consume
        //                       events, which is the whole point of this app.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: quitInterceptorCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Self.logger.error("CGEvent.tapCreate failed — is the Accessibility grant missing?")
            return false
        }

        eventTap = tap
        startTapThread(with: tap)
        return true
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let tapRunLoop {
            if let runLoopSource {
                CFRunLoopRemoveSource(tapRunLoop, runLoopSource, .commonModes)
            }
            CFRunLoopStop(tapRunLoop)
        }
        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
        Self.logger.notice("Event tap removed")
    }

    /// Re-arms a tap the system has switched off. Stage 7 calls this from a timer.
    func reEnableIfNeeded() {
        guard let eventTap, !CGEvent.tapIsEnabled(tap: eventTap) else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        Self.logger.notice("Event tap was disabled; re-enabled")
    }

    private func startTapThread(with tap: CFMachPort) {
        // Created here rather than on the tap thread so `stop()` can always see
        // it, even if it is called immediately after `start()`.
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source

        let ready = DispatchSemaphore(value: 0)

        let thread = Thread { [weak self] in
            guard let self else {
                ready.signal()
                return
            }

            self.tapRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)

            // Published everything `stop()` needs; safe to let start() return.
            ready.signal()

            Self.logger.notice("Event tap installed and enabled")
            CFRunLoopRun()

            Self.logger.notice("Event tap run loop exited")
        }
        thread.name = "com.raahil.quitguard.eventtap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()

        // Wait for the thread to arm the tap so `start()` is synchronous. This
        // is microseconds and happens only at install time. Without it, a
        // `stop()` racing a fresh `start()` would leave the thread parked with a
        // live source, and the next `start()` would create a second tap.
        _ = ready.wait(timeout: .now() + 2.0)
    }

    // MARK: - Callback

    /// Runs on the tap thread. Must return in microseconds — no AppKit, no
    /// allocation-heavy work, no UI. Anything expensive is dispatched to main.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system silently disables taps whose callback overruns its budget,
        // and on some user input events. Nothing re-arms them automatically —
        // without this the app appears dead until relaunch.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let reason = (type == .tapDisabledByTimeout) ? "timeout" : "user input"
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            Self.logger.error("Event tap disabled by \(reason, privacy: .public); re-armed")
            return nil
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        guard event.getIntegerValueField(.keyboardEventKeycode) == Self.keycodeQ else {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        guard flags.contains(.maskCommand) else {
            return Unmanaged.passUnretained(event)
        }

        // Cmd+Option+Q is the system Log Out shortcut and Cmd+Ctrl+Q locks the
        // screen. Requiring these modifiers to be absent — rather than just
        // checking for Command — is what keeps those working.
        guard !flags.contains(.maskAlternate),
              !flags.contains(.maskControl),
              !flags.contains(.maskShift) else {
            return Unmanaged.passUnretained(event)
        }

        // Snapshot now, decide now: reading this from an async block would race
        // the quit we are reacting to.
        guard let target = frontmost.snapshot() else {
            // Fail open. If we cannot say which app this belongs to, we have no
            // basis to block it, and swallowing a Cmd+Q the user cannot explain
            // is worse than letting a protected app quit.
            DispatchQueue.main.async {
                Self.logger.notice("Cmd+Q passed through: no bundle-identified frontmost app")
            }
            return Unmanaged.passUnretained(event)
        }

        guard protectedApps.contains(target.bundleID) else {
            DispatchQueue.main.async {
                Self.logger.notice(
                    "Cmd+Q passed through -> \(target.name, privacy: .public) [\(target.bundleID, privacy: .public)] (not protected)"
                )
            }
            return Unmanaged.passUnretained(event)
        }

        DispatchQueue.main.async {
            Self.logger.notice(
                "Cmd+Q SWALLOWED -> \(target.name, privacy: .public) [\(target.bundleID, privacy: .public)] pid \(target.pid)"
            )
        }

        // Stage 4: consume the event outright. Stage 5 puts the confirmation
        // panel here; returning nil is what stops the app from ever seeing it.
        return nil
    }
}
