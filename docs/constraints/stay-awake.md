# Stay Awake (pmset disablesleep)

Keeps the Mac awake with the lid shut, via `pmset -a disablesleep`. Off unless
the user turns it on. IOKit power assertions are **not** an alternative:
clamshell sleep ignores them, which is why this setting exists at all.

- **The key you write is not the key you read.** You set `disablesleep`; the
  state comes back as `SleepDisabled` in `pmset -g`. Grepping for the name you
  wrote matches nothing, and the toggle silently reads "off" forever.
- **`pmset` exits 0 when it refuses.** Run unprivileged it prints
  `'pmset' must be run as root...` and still exits 0. Never infer success from
  the exit status — re-read the state. This is also what snaps the switch back
  when the user cancels: cancel, wrong password, and failure all converge.
- **The read is slow.** `pmset -g` measured 78ms median, 100ms worst. It must
  never run on the main queue — the status menu refreshes it as it opens.
- Privileged changes go through an **`osascript` subprocess**, never in-process
  `NSAppleScript`. Measured: the subprocess's dialog reliably takes keyboard
  focus, the in-process one appears *inactive* behind whatever is frontmost, and
  `NSAppleScript` blocks its thread for as long as the dialog is up. The dialog
  is titled "osascript" either way; `with prompt` is what says who is asking.
  LSUIElement does not affect any of this — SecurityAgent draws the dialog, at
  window layer 1000.
- **Never prompt for or handle the password ourselves.** macOS shows its own.
- Revert on quit runs from `applicationShouldTerminate` via `.terminateLater`,
  and only when *we* enabled it this launch **and** a fresh read still says it
  is on — so a `disablesleep` somebody else set is left alone. That flag records
  our own action; it is not a cached copy of the state.
- The revert costs a second password prompt. That is accepted.
  `AuthorizationExecuteWithPrivileges` would avoid it but is deprecated, and
  `SMJobBless` needs its own signing, which collides with the frozen identity.
- If the revert fails, **quit anyway** after an alert naming
  `sudo pmset -a disablesleep 0`. Trapping the user in an app they asked to
  close is worse than the leftover setting.
- The revert cannot run on force-quit, `SIGKILL`, or a crash. The menu bar icon
  therefore gains a bolt (`bolt.shield.fill` / `bolt.shield`) whenever sleep is
  disabled: it is the only thing that surfaces a leftover without opening
  Settings.
