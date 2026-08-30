import AppKit
import Foundation
import os

/// The "Claude maxxing" toggle: `pmset disablesleep`, which is what keeps a
/// MacBook awake with the lid shut. Ordinary power assertions do not — clamshell
/// sleep ignores them, which is the whole reason this setting exists.
///
/// Modelled on `LaunchAtLogin`: one shared observable object, published state
/// read back from the system rather than a duplicate bool. That matters more
/// here than for login items, because `SleepDisabled` is global, survives
/// reboot, and any `sudo pmset` in a terminal can change it behind us.
@MainActor
final class StayAwake: ObservableObject {

    private static let logger = Logger(subsystem: "com.raahil.quitguard", category: "power")

    /// Printed in the alert when a revert fails, so the user is never left with
    /// sleep disabled and no way to find out how to undo it.
    static let recoveryCommand = "sudo pmset -a disablesleep 0"

    /// Mirrors the system's `SleepDisabled`. Every value published here came
    /// from a real `pmset -g`; nothing is ever inferred from what we asked for.
    @Published private(set) var isEnabled = false

    /// True while an authorization prompt is on screen. The switch disables
    /// itself meanwhile — a second prompt would stack behind the first, where
    /// it is invisible and still holding a thread.
    @Published private(set) var isBusy = false

    /// Records *our own action*, not the state. Set only when a change we asked
    /// for is confirmed; this is what stops the quit-time revert from switching
    /// off a `disablesleep` that something else set.
    private(set) var enabledByUs = false

    private var isReading = false

    init() {
        refresh()
    }

    // MARK: - Reading

    /// Kicks off a read and publishes the result when it lands.
    ///
    /// Deliberately asynchronous. `pmset -g` measured **78ms median, 100ms
    /// worst** on the development machine, and this is called as the status
    /// menu opens — spending that on the main queue would hitch the menu and
    /// break the project's rule about main-thread work.
    func refresh() {
        guard !isReading else { return }
        isReading = true

        DispatchQueue.global(qos: .userInitiated).async {
            let value = Self.readSystemState()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isReading = false
                    self.apply(value, logging: true)
                }
            }
        }
    }

    private func apply(_ value: Bool?, logging: Bool) {
        guard let value else {
            // Absent key: nothing claims sleep is disabled, so the honest
            // reading is "off". Logged because it also means our revert has
            // nothing to check against.
            if isEnabled || logging {
                Self.logger.notice("State read: no SleepDisabled key reported by pmset — treating as off")
            }
            isEnabled = false
            return
        }

        if value != isEnabled {
            Self.logger.notice("State read: SleepDisabled = \(value ? 1 : 0, privacy: .public)")
        }
        isEnabled = value

        // Somebody else turned it off, so we no longer own it.
        if !value { enabledByUs = false }
    }

    /// Parses `pmset -g` for `SleepDisabled`.
    ///
    /// Note the spelling: the key written is `disablesleep`, but the key read
    /// back is `SleepDisabled`. Grepping for the name you set finds nothing.
    nonisolated static func readSystemState() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(text)
    }

    /// Split out from the process call so it can be checked against captured
    /// `pmset` output without needing to change the machine's real state.
    ///
    /// Matches on the whole first field, not a substring: `pmset -g` also emits
    /// a `sleep` line that can read `sleep 1 (sleep prevented by ...)`, and a
    /// looser match would pick up the wrong number from it.
    nonisolated static func parse(_ text: String) -> Bool? {
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0].lowercased() == "sleepdisabled" else { continue }
            return fields[1] == "1"
        }
        return nil
    }

    // MARK: - Changing

    func setEnabled(_ enabled: Bool) {
        guard !isBusy else { return }
        guard enabled != isEnabled else { return }

        isBusy = true
        Self.logger.notice("Change requested: SleepDisabled -> \(enabled ? 1 : 0, privacy: .public)")

        Self.applyPrivileged(enabled) { [weak self] outcome, actual in
            guard let self else { return }
            self.isBusy = false
            // The switch position comes from the re-read, never from what was
            // asked for — so cancel, a wrong password and a pmset failure all
            // land the toggle back on the truth without special-casing.
            self.apply(actual, logging: false)

            switch outcome {
            case .succeeded:
                self.enabledByUs = enabled
                Self.logger.notice("Change succeeded: SleepDisabled is now \(actual == true ? 1 : 0, privacy: .public)")
            case .cancelled:
                Self.logger.notice("Change cancelled by user at the password prompt — SleepDisabled left at \(actual == true ? 1 : 0, privacy: .public)")
            case .failed(let reason):
                Self.logger.error("Change failed — \(reason, privacy: .public)")
            }
        }
    }

    enum ChangeOutcome {
        case succeeded
        case cancelled
        case failed(reason: String)
    }

    /// Runs the privileged `pmset` through `osascript`, then reports the state
    /// it can actually observe afterwards.
    ///
    /// A subprocess rather than in-process `NSAppleScript` for two measured
    /// reasons: the subprocess's dialog reliably takes keyboard focus, where
    /// the in-process one appears inactive behind whatever is frontmost; and
    /// `NSAppleScript` blocks its thread for as long as the dialog is up.
    ///
    /// The dialog is titled "osascript" either way — `with prompt` is what
    /// tells the user who is really asking and why.
    private static func applyPrivileged(
        _ enabled: Bool,
        completion: @escaping @MainActor (ChangeOutcome, Bool?) -> Void
    ) {
        let value = enabled ? "1" : "0"
        let prompt = "QuitGuard needs your password to change the system sleep setting."
        let script = "do shell script \"/usr/bin/pmset -a disablesleep \(value)\""
            + " with prompt \"\(prompt)\""
            + " with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let errorPipe = Pipe()
            process.standardOutput = Pipe()
            process.standardError = errorPipe

            var status: Int32 = -1
            var stderr = ""
            do {
                try process.run()
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                status = process.terminationStatus
                stderr = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            } catch {
                stderr = error.localizedDescription
            }

            // `pmset` exits 0 even when it refuses to do anything — running it
            // unprivileged prints "'pmset' must be run as root..." and still
            // reports success. The only trustworthy signal is the re-read.
            let actual = readSystemState()

            let outcome: ChangeOutcome
            if actual == enabled {
                outcome = .succeeded
            } else if status != 0 && (stderr.contains("-128") || stderr.contains("User canceled")) {
                outcome = .cancelled
            } else {
                outcome = .failed(reason: stderr.isEmpty
                    ? "osascript exited \(status) and the setting did not change"
                    : stderr)
            }

            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(outcome, actual) }
            }
        }
    }

    // MARK: - Quit

    /// Whether quitting needs to do anything at all. False costs nothing: the
    /// app quits immediately with no prompt, which is every launch where this
    /// feature was never used.
    var needsRevertOnQuit: Bool { enabledByUs }

    /// Turns sleep back on if we were the ones who turned it off, and it is
    /// still off. Calls back with whether the machine is safe to leave.
    ///
    /// Best effort by nature: this runs from `applicationShouldTerminate`, which
    /// does not run on force-quit, `SIGKILL`, or a crash. The menu bar icon and
    /// the Settings switch both read real state, so a leftover surfaces on the
    /// next launch instead of hiding.
    func revertOnQuit(completion: @escaping @MainActor (Bool) -> Void) {
        guard enabledByUs else {
            completion(true)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            guard Self.readSystemState() == true else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        Self.logger.notice("Revert on quit: SleepDisabled is already 0, nothing to undo")
                        completion(true)
                    }
                }
                return
            }

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Self.logger.notice("Revert on quit: requesting SleepDisabled -> 0")
                    Self.applyPrivileged(false) { outcome, actual in
                        let reverted = (actual == false)
                        switch outcome {
                        case .succeeded:
                            Self.logger.notice("Revert on quit: succeeded")
                        case .cancelled:
                            Self.logger.error("Revert on quit: cancelled at the password prompt — sleep is STILL disabled")
                        case .failed(let reason):
                            Self.logger.error("Revert on quit: failed — \(reason, privacy: .public)")
                        }
                        completion(reverted)
                    }
                }
            }
        }
    }
}
