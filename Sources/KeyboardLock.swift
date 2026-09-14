import AppKit
import Carbon
import IOKit
import os

// MARK: - Policy

/// What the lock tap does with a single event.
///
/// Pure, so every case can be asserted without creating a tap or locking a real
/// keyboard. The tap callback is a thin shell around `decide`.
enum LockTapPolicy {

    static let mask: CGEventMask = (1 as CGEventMask) << CGEventType.keyDown.rawValue
        | (1 as CGEventMask) << CGEventType.keyUp.rawValue
        | (1 as CGEventMask) << CGEventType.flagsChanged.rawValue

    static let modifierBits: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
    static let escapeKeyCode: Int64 = 53

    enum Decision: Equatable {
        case swallow
        case pass
    }

    /// What the tap has let through so far — which is what the session believes.
    struct State: Equatable {
        /// Modifiers the session currently thinks are held.
        var delivered: CGEventFlags
        /// An Escape key-down was passed for Force Quit, so its key-up must be too.
        var escapeDown = false
    }

    static func decide(
        type: CGEventType,
        flags: CGEventFlags,
        keyCode: Int64,
        state: State
    ) -> (Decision, State) {
        let mods = flags.intersection(modifierBits)
        var next = state

        switch type {
        case .keyDown:
            // Force Quit is Cmd+Opt+Esc; holding Shift as well force-quits the
            // frontmost app directly. Only the Escape event passes — the
            // modifier presses are still swallowed, and the hot key matches on
            // the flags stamped onto the Escape event itself.
            if keyCode == escapeKeyCode,
               mods.contains([.maskCommand, .maskAlternate]),
               !mods.contains(.maskControl) {
                next.escapeDown = true
                return (.pass, next)
            }
            return (.swallow, state)

        case .keyUp:
            // Pair a passed Escape down with its up regardless of the flags by
            // then — the user may well have let go of Cmd first.
            if keyCode == escapeKeyCode && state.escapeDown {
                next.escapeDown = false
                return (.pass, next)
            }
            return (.swallow, state)

        case .flagsChanged:
            // Release-only passthrough. Swallowing a *release* leaves the
            // session believing the modifier is still held — measured:
            // `combinedSessionState` and `NSEvent.modifierFlags` both keep
            // reporting it until the next event of any kind. A release that
            // only removes modifiers the session already has cannot type
            // anything, and since the matching press was swallowed it can never
            // complete a double-tap-modifier hot key.
            if state.delivered.isSuperset(of: mods) && mods != state.delivered {
                next.delivered = mods
                return (.pass, next)
            }
            return (.swallow, state)

        default:
            return (.pass, state)
        }
    }
}

// MARK: - Secure input

enum SecureInput {

    /// True when another process holds secure event input, which blinds every
    /// keyboard tap. Either source is enough: this errs toward reporting the
    /// lock as not working, never toward claiming a lock that isn't.
    ///
    /// `IsSecureEventInputEnabled()` was measured seeing another app's secure
    /// input from a separately launched app. The registry key is the same one
    /// `ioreg` prints, read in-process: 0.02ms, against 81ms for spawning
    /// `ioreg`. Its PID is deliberately ignored — it named the frontmost app,
    /// never the real holder, in every run.
    static func isEnabled() -> Bool {
        if IsSecureEventInputEnabled() { return true }
        return registryReportsHolder()
    }

    private static func registryReportsHolder() -> Bool {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard let users = IORegistryEntryCreateCFProperty(
            root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [[String: Any]] else { return false }

        return users.contains { user in
            (user["kCGSSessionUserIDKey"] as? Int).map { uid_t($0) } == getuid()
                && user["kCGSSessionSecureInputPID"] != nil
        }
    }
}

// MARK: - Tap context

/// Shared between the tap thread, the failsafe queue and the main thread.
///
/// Two locks, on purpose. `stateLock` guards the policy state and is only ever
/// held by the callback for a few bit operations. `releaseLock` guards release
/// bookkeeping and is **never** taken across a blocking call. The failsafe
/// needs only `releaseLock`, so a callback wedged anywhere cannot hold up an
/// auto-unlock.
final class LockTapContext: @unchecked Sendable {

    private static let logger = Logger(subsystem: "com.raahil.quitguard", category: "lock")

    private let stateLock = NSLock()
    private var state: LockTapPolicy.State

    private let releaseLock = NSLock()
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var releaseReason: String?

    init(initial: LockTapPolicy.State) {
        state = initial
    }

    /// Returns false if no run loop source could be made for the port.
    func attach(port: CFMachPort) -> Bool {
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        releaseLock.lock()
        self.port = port
        self.source = source
        releaseLock.unlock()
        return source != nil
    }

    /// Runs on the tap thread until the tap is released.
    ///
    /// The run loop is published under the lock *before* the source is added,
    /// so a release racing thread start either stops this loop or invalidates
    /// the source first — and a run loop with no valid source returns at once.
    func runTapLoop() {
        guard let runLoop = CFRunLoopGetCurrent() else { return }
        releaseLock.lock()
        self.runLoop = runLoop
        let source = self.source
        let released = releaseReason != nil
        releaseLock.unlock()

        guard let source, !released else { return }
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CFRunLoopRun()
    }

    // MARK: Tap thread

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            releaseLock.lock()
            let port = self.port
            let released = releaseReason != nil
            releaseLock.unlock()

            // Never re-arm a tap that has been released on purpose.
            if !released, let port {
                CGEvent.tapEnable(tap: port, enable: true)
                let why = (type == .tapDisabledByTimeout) ? "timeout" : "user input"
                Self.logger.notice("Lock tap disabled by \(why, privacy: .public) — re-armed")
            }
            return Unmanaged.passUnretained(event)
        }

        stateLock.lock()
        let (decision, next) = LockTapPolicy.decide(
            type: type,
            flags: event.flags,
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            state: state
        )
        state = next
        stateLock.unlock()

        return decision == .pass ? Unmanaged.passUnretained(event) : nil
    }

    // MARK: Any thread

    /// Stops the tap swallowing anything, from any thread, without needing the
    /// tap thread or the main thread to make progress.
    ///
    /// `CGEvent.tapEnable(false)` tells the window server to stop routing to
    /// the port; invalidating the port removes the tap outright. Neither waits
    /// on the callback. Returns true only for the call that actually released.
    @discardableResult
    func release(reason: String) -> Bool {
        releaseLock.lock()
        guard releaseReason == nil else {
            releaseLock.unlock()
            return false
        }
        releaseReason = reason
        let port = self.port
        let runLoop = self.runLoop
        releaseLock.unlock()

        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
        return true
    }

    var reasonReleased: String? {
        releaseLock.lock()
        defer { releaseLock.unlock() }
        return releaseReason
    }

    var isPortValid: Bool {
        releaseLock.lock()
        let port = self.port
        releaseLock.unlock()
        return port.map { CFMachPortIsValid($0) } ?? false
    }

    var isTapEnabled: Bool {
        releaseLock.lock()
        let port = self.port
        releaseLock.unlock()
        guard let port, CFMachPortIsValid(port) else { return false }
        return CGEvent.tapIsEnabled(tap: port)
    }
}

/// C function pointer: a closure literal that captures nothing.
private let lockTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<LockTapContext>.fromOpaque(refcon).takeUnretainedValue()
        .handle(type: type, event: event)
}

// MARK: - Failsafe

/// Releases the lock at a wall-clock deadline, no matter what.
///
/// Scheduled on its **own serial dispatch queue**, which is the whole point:
///
/// - not the main run loop, where the panel lives — a wedged main thread would
///   stall a `Timer` there;
/// - not the tap thread's run loop — a wedged callback blocks that loop, so
///   anything scheduled on it would never fire;
/// - independent of the lock tap's health — firing only calls
///   `LockTapContext.release`, which needs neither of those threads.
///
/// Wall clock rather than uptime: `DispatchTime` stops while the Mac sleeps, so
/// an uptime deadline would silently stretch across a closed lid.
///
/// The timer holds a strong reference to itself until it fires or is
/// cancelled, so a bug that drops the owner early cannot drop the failsafe.
final class LockFailsafe: @unchecked Sendable {

    let deadline: Date

    private let queue = DispatchQueue(label: "com.raahil.quitguard.lock.failsafe", qos: .userInitiated)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var finished = false

    init(duration: TimeInterval, onFire: @escaping @Sendable () -> Void) {
        deadline = Date(timeIntervalSinceNow: duration)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(wallDeadline: .now() + duration, leeway: .milliseconds(250))
        timer.setEventHandler { [self] in
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let source = self.timer
            self.timer = nil
            lock.unlock()

            onFire()
            // Cancelling releases the handler block, which is what breaks the
            // deliberate self-reference.
            source?.cancel()
        }
        self.timer = timer
        // Resumed immediately: releasing a never-resumed dispatch source crashes.
        timer.resume()
    }

    /// Returns true if this call stopped it before it fired.
    @discardableResult
    func cancel() -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        finished = true
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
        return true
    }
}

// MARK: - Keyboard lock

/// Swallows keyboard input for cleaning. The mouse is never affected.
///
/// Uses a **separate** event tap, created on lock and destroyed on unlock. The
/// Cmd+Q / Dock chord tap in `QuitInterceptor` is never touched: a tap's mask
/// is fixed at `tapCreate`, so widening that one would put every key release
/// and modifier change on the machine through it forever, feature on or off.
/// Inserted at the head later, this tap sees keys before that one does, so
/// Cmd+Q is swallowed during a lock too.
@MainActor
final class KeyboardLock: ObservableObject {

    private static let logger = Logger(subsystem: "com.raahil.quitguard", category: "lock")

    nonisolated static let defaultFailsafe: TimeInterval = 5 * 60

    /// How long the tap may stay disabled before the lock is ended as degraded.
    /// A live tap thread re-arms within milliseconds; one that has not in this
    /// long is not coming back, and a panel saying "not locked" for the rest of
    /// five minutes helps nobody.
    static let degradedAfter: TimeInterval = 3

    enum Status: Equatable {
        case unlocked
        /// Engaged, the tap is armed, and nothing is blinding it.
        case locked
        /// Engaged, but keys are reaching apps — the tap is disabled or another
        /// app holds secure input. One state, because the distinction is not
        /// actionable for the person at the keyboard.
        case notLocked
    }

    enum UnlockReason: String {
        case button
        case menu
        case timer
        case degraded
        case settingDisabled = "disabled in Settings"
        case quit
    }

    @Published private(set) var status: Status = .unlocked
    @Published private(set) var deadline: Date?

    var isEngaged: Bool { status != .unlocked }

    private let failsafeDuration: TimeInterval
    private var context: LockTapContext?
    private var failsafe: LockFailsafe?
    private var pollTimer: Timer?
    private var engagedAt = Date()
    private var tapDisabledSince: Date?
    private var lastSecureInput = false
    private var lastTapEnabled = true

    init(failsafeDuration: TimeInterval = KeyboardLock.defaultFailsafe) {
        self.failsafeDuration = failsafeDuration
    }

    // MARK: Engage

    @discardableResult
    func engage() -> Bool {
        guard status == .unlocked else { return true }

        // Seeded from the session's own belief, so a modifier already held
        // when the lock engages can still be released through the tap.
        let seed = LockTapPolicy.State(
            delivered: CGEventSource.flagsState(.combinedSessionState)
                .intersection(LockTapPolicy.modifierBits)
        )
        let context = LockTapContext(initial: seed)

        // The failsafe is armed BEFORE the tap exists, so there is no moment at
        // which keys can be swallowed without a deadline already running.
        let failsafe = LockFailsafe(duration: failsafeDuration) { [context] in
            guard context.release(reason: UnlockReason.timer.rawValue) else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.finish() }
            }
        }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: LockTapPolicy.mask,
            callback: lockTapCallback,
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ) else {
            failsafe.cancel()
            Self.logger.error("Lock NOT engaged — CGEvent.tapCreate failed (is the Accessibility grant missing?)")
            return false
        }
        guard context.attach(port: port) else {
            context.release(reason: "run loop source unavailable")
            failsafe.cancel()
            Self.logger.error("Lock NOT engaged — could not create a run loop source")
            return false
        }

        // Its own thread, never main: a main-thread stall would eat the
        // callback's budget, the system would disable the tap by timeout, and
        // keys would leak while the panel is too wedged to say so. The closure
        // holds the context, so it outlives any callback still in flight.
        let thread = Thread { [context] in
            context.runTapLoop()
        }
        thread.name = "com.raahil.quitguard.lock.tap"
        thread.qualityOfService = .userInteractive
        thread.start()

        self.context = context
        self.failsafe = failsafe
        engagedAt = Date()
        deadline = failsafe.deadline
        tapDisabledSince = nil
        lastSecureInput = false
        lastTapEnabled = true
        status = .locked

        let at = failsafe.deadline.formatted(date: .omitted, time: .standard)
        Self.logger.notice("Lock engaged — failsafe unlocks at \(at, privacy: .public) (\(Int(self.failsafeDuration))s)")

        // Evaluated now, not half a second from now: the panel must never
        // claim a lock that secure input is already defeating.
        poll()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // .common so it keeps running while a menu is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        return true
    }

    // MARK: Unlock

    func unlock(reason: UnlockReason) {
        guard status != .unlocked, let context else { return }
        failsafe?.cancel()
        context.release(reason: reason.rawValue)
        finish()
    }

    /// Tidies up after whichever path released the tap first. Logs that path's
    /// reason — a button click racing the timer must not be logged as the one
    /// that won if the timer had already let go.
    private func finish() {
        guard status != .unlocked else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        failsafe?.cancel()

        let reason = context?.reasonReleased ?? "unknown"
        let held = Int(Date().timeIntervalSince(engagedAt).rounded())
        Self.logger.notice("Unlocked — reason: \(reason, privacy: .public), after \(held)s")

        context = nil
        failsafe = nil
        deadline = nil
        status = .unlocked
    }

    // MARK: Poll

    private func poll() {
        guard status != .unlocked, let context else { return }

        guard context.isPortValid else {
            unlock(reason: .degraded)
            return
        }

        // Observed only. Re-arming is left to the callback, because a
        // successful re-arm there proves the tap thread is alive; re-arming a
        // wedged tap from here would stall every keystroke on the machine
        // until the system timed it out again.
        let tapEnabled = context.isTapEnabled
        if tapEnabled != lastTapEnabled {
            Self.logger.notice("\(tapEnabled ? "Lock tap enabled again — keyboard locked" : "Lock tap disabled — keys are getting through", privacy: .public)")
            lastTapEnabled = tapEnabled
        }
        if tapEnabled {
            tapDisabledSince = nil
        } else {
            let since = tapDisabledSince ?? Date()
            tapDisabledSince = since
            if Date().timeIntervalSince(since) >= Self.degradedAfter {
                unlock(reason: .degraded)
                return
            }
        }

        let secure = SecureInput.isEnabled()
        if secure != lastSecureInput {
            Self.logger.notice("\(secure ? "Secure input ON while locked — keys are getting through" : "Secure input OFF — keyboard locked again", privacy: .public)")
            lastSecureInput = secure
        }

        let next: Status = (tapEnabled && !secure) ? .locked : .notLocked
        if next != status { status = next }
    }
}
