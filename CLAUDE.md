# QuitGuard — hard constraints

A macOS menu bar utility that intercepts Cmd+Q for a user-selected list of apps
and shows a confirmation panel instead of quitting immediately. Unlisted apps
quit normally.

These constraints are non-obvious and were chosen deliberately. **Do not
"modernize" or simplify them.** Each one exists because the obvious alternative
does not work.

## Event interception

- Interception MUST use `CGEvent.tapCreate` with
  `tap: .cgSessionEventTap`, `place: .headInsertEventTap`, `options: .defaultTap`.
- **NEVER use `NSEvent.addGlobalMonitorForEvents`.** Global monitors can observe
  events but cannot consume them, so they cannot do this job at all. This is the
  single most common wrong turn.
- The tap callback must return in microseconds. Never present UI or do work
  synchronously inside it. All UI goes through `DispatchQueue.main.async`.
- MUST handle `.tapDisabledByTimeout` and `.tapDisabledByUserInput` by calling
  `CGEvent.tapEnable` to re-arm. The system silently disables taps; without this
  the app appears dead until relaunch.

## Matching

- Match keycode `12` ('q') with `.maskCommand` set, and explicitly REQUIRE that
  `.maskAlternate`, `.maskControl` and `.maskShift` are NOT set.
- Cmd+Option+Q is the system Log Out shortcut. Passing it through untouched is
  mandatory.

## Quitting

- On confirm, call `NSRunningApplication.terminate()`.
- Do NOT re-post the keystroke — the tap would re-intercept its own event.
- `terminate()` sends the standard quit Apple Event, so unsaved-changes dialogs
  still work.

## Dock right-click quit

Cmd + right-click on a Dock tile quits that app **immediately, with no
confirmation**. Off by default. Applies to every app, protected or not — the
protected list has no effect on this path.

The only thing between this chord and data loss is that `terminate()` sends the
standard quit Apple Event, so an app with unsaved work still shows its own save
dialog. Do not replace it with anything more forceful.

- **Never call AX from the tap callback.** `AXUIElementCopyElementAtPosition`
  is synchronous IPC into the Dock: 13µs median, but with no bounded worst
  case. The callback decides using a cached rect
  (`DockBoundsTracker.contains`, ~40ns) and resolves the tile afterwards on
  the main queue. `Bundle(url:)` reads a plist off disk and is main-queue only
  for the same reason.
- The cached rect must fail *closed to inert*: nil bounds means the chord does
  nothing, never that the tap swallows every right-click. Bounds are
  invalidated on screen-parameter changes and Dock restart, and re-measured on
  app launch/terminate — the strip resizes whenever a tile appears.
- Identity comes from the tile's `AXURL`, never its `AXTitle`. Titles collide
  routinely (nine live "Safari Web Content" processes is normal), and matching
  on `localizedName` would have to guess between them.
- **Finder's bundle identifier is `com.apple.finder`, lower-case f.** An exact
  match against the conventional spelling `com.apple.Finder` compiles, reads
  correctly, and silently fails to exclude it. The comparison is lower-cased.
- The resolution predicate is `AXRole == "AXDockItem"` **and** `AXSubrole ==
  "AXApplicationDockItem"` **and** `AXIsApplicationRunning == true`. The role
  check is not redundant: the strip's left and right edges hit-test to the
  `AXList` itself.
- A swallowed click that resolves to nothing does nothing — no quit, no beep.
  It is logged, because a chord that silently does nothing is otherwise
  undiagnosable.

## Packaging and signing

- Menu bar only: `LSUIElement = true`. No Dock icon, no main window.
- **No sandbox.** A sandboxed process cannot create a session event tap.
- Signing is manual, against a self-signed certificate named **"QuitGuard Local"**.
- `CODE_SIGN_IDENTITY` and `PRODUCT_BUNDLE_IDENTIFIER` (`com.raahil.quitguard`)
  are **FROZEN**. The Accessibility (TCC) grant is keyed to the designated
  requirement:

      identifier "com.raahil.quitguard" and certificate leaf = H"<cert sha1>"

  Changing either value produces a different requirement and silently revokes
  the grant.
- Release builds must set `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`. Xcode
  injects `get-task-allow` by default even in Release, which leaves the app
  debuggable — unacceptable for a process holding Accessibility. It does not
  affect the designated requirement, so toggling it does not disturb the grant.
- **Never use ad-hoc signing (`codesign -s -`).** It produces a new identity per
  build and silently breaks the Accessibility grant on every rebuild.
- If the signing identity is missing, recreate it with `scripts/make-signing-cert.sh`.
  Note that a *regenerated* cert has a new hash and will require re-granting
  Accessibility once.

## Sleep disabling ("Claude maxxing")

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

## Keyboard Lock

Swallows keyboard input for cleaning; the mouse is never locked. Off unless the
user enables it; engaged from the status menu.

- **A separate tap, created on lock and destroyed on unlock.** Never widen the
  `QuitInterceptor` tap. A tap's mask is fixed at `tapCreate` — there is no API
  to change it — so "restore the mask on unlock" is only achievable by never
  touching the original. Verified with `CGGetEventTapList`: the process's tap
  list after unlock is identical to before the lock.
- The lock mask is exactly `keyDown | keyUp | flagsChanged | NX_SYSDEFINED (14)`.
  No mouse event type is in it.
- **Media keys live in `NX_SYSDEFINED`, which also carries aux mouse buttons
  (subtype 7), power and sleep events.** Only subtype 8
  (`NX_SUBTYPE_AUX_CONTROL_BUTTONS`) *presses* are swallowed; releases, power
  and Caps Lock pass, and every other subtype passes. A `CGEvent` has no
  documented field for subtype or data1, and `NSEvent(cgEvent:)` is AppKit, so
  raw fields are read: subtype in **83 and 99** (both must say 8), data1 in
  **149**. Found by diffing every field; cross-checked against `NSEvent`.
- **Never read field 149 before the subtype check.** It is a compound field,
  and reading it on a subtype that does not carry one *aborts the process*
  (SkyLight assertion `event_carries_compound_data_field`) — subtypes 6 and 9.
  The assertion is keyed on the subtype value, so gating on subtype 8 is a
  guarantee. `decideSystemDefined` takes data1 as an autoclosure for this
  reason; do not make it eager.
- **Release-only modifier passthrough.** Swallowing a modifier *release* leaves
  `combinedSessionState` and `NSEvent.modifierFlags` reporting it held until the
  next event of any kind (measured). So a `flagsChanged` that only removes
  modifiers the session already believes are down is passed; presses are
  swallowed. The seed is `combinedSessionState` at engage time.
- **Cmd+Opt+Esc passes**, and Cmd+Opt+Shift+Esc. Only the Escape event is
  passed, plus its paired key-up; the modifier presses are still swallowed.
- **The failsafe runs on its own dispatch queue**, never the main run loop or
  the tap thread's run loop. It releases via `LockTapContext.release`, which
  needs neither thread and never waits on the callback's lock. Verified with
  the tap thread wedged forever in its callback *and* main wedged: it fired on
  time and invalidated the port. Wall-clock (`wallDeadline`), so sleep does not
  stretch it. It retains itself until it fires or is cancelled.
- The failsafe is armed **before** `tapCreate`, so no instant exists where keys
  are swallowed without a deadline running.
- Never re-arm the lock tap from the poll. Only the callback re-arms, because a
  successful re-arm there proves the tap thread is alive; re-arming a wedged tap
  stalls every keystroke on the machine until it times out again. A tap disabled
  for 3 seconds ends the lock with reason `degraded`.
- **"Not locked" is one state** covering both a disabled tap and secure input,
  with one piece of copy. Keys are reaching apps either way; the distinction is
  not actionable.
- **Secure input:** `IsSecureEventInputEnabled()` OR the `IOConsoleUsers`
  registry key, read in-process (0.02ms; spawning `ioreg` is 81ms). Never name
  the holding app — `kCGSSessionSecureInputPID` named the frontmost app, never
  the real holder, in every run.
- Unlock first in `applicationShouldTerminate`: the sleep revert may put up a
  password prompt that a locked keyboard could not answer.
- Secure-input detection does not latch. It cleared within 100ms of the holder
  exiting after a normal Disable, SIGKILL, SIGTERM and SIGABRT (none calling
  Disable), and immediately on Disable with the process still alive. An
  unbalanced Enable/Enable/Disable stays on while the holder lives — that is
  the real system state, and the tap really is blind then.
- Testing: launch secure-input helpers with `open -n`, not
  `NSWorkspace.openApplication`, which reported success without the helper ever
  running. `NSRunningApplication.terminate()` returns true but cannot quit a
  helper with no event loop; wait for the process to actually exit (or signal
  it) before asserting that secure input has cleared. And never post a synthetic mouse event in the same instant as a
  synthetic modifier release — it is stamped with the pre-release flags and puts
  the modifier back into the session, with no lock involved at all.

## Platform

- Target macOS 13.
- Use `SMAppService` for login items, not the deprecated `SMLoginItemSetEnabled`.
- No third-party dependencies. System frameworks only.
- Never hardcode bundle IDs in source. Always read from the store, default empty.

## Project layout

XcodeGen is used; `project.yml` is the source of truth and `.xcodeproj` is
generated and gitignored. Never hand-edit the `.xcodeproj`.

    App.swift                 @main, NSApplicationDelegateAdaptor
    QuitInterceptor.swift     the event tap
    PermissionGate.swift      AXIsProcessTrustedWithOptions + state
    ProtectedAppsStore.swift  ObservableObject, Set<String> in UserDefaults
    ConfirmationPanel.swift   NSPanel
    SettingsView.swift        SwiftUI app picker
    StatusItem.swift          NSStatusItem, normal/degraded states
    LaunchAtLogin.swift       SMAppService wrapper
    FrontmostAppTracker.swift cached frontmost app, readable from the tap thread
    PermissionResetView.swift "permission was reset" screen
    DockBoundsTracker.swift   cached Dock strip rect, readable from the tap thread
    DockTileResolver.swift    AX hit-test -> running app, main thread only
    DockQuitSettings.swift    the Cmd + right-click toggle, default off
    StayAwake.swift           pmset disablesleep, read back from the system
    KeyboardLock.swift        lock tap, pure policy, failsafe, secure input check
    KeyboardLockPanel.swift   unlock panel; window config copied from ConfirmationPanel
    KeyboardLockSettings.swift the Keyboard Lock toggle, default off

## Threading

- The tap runs on its own `userInteractive` thread, not the main run loop. A
  main-thread stall would eat the callback's time budget and get the tap
  disabled by timeout.
- Anything the callback reads must be lock-protected and allocation-light.
  Never call AppKit or `UserDefaults` from it — a defaults read can round-trip
  to `cfprefsd`.
- Repeating timers are added to `RunLoop.main` in `.common` mode. A
  `Timer.scheduledTimer` stops firing while a menu is being tracked, which is
  exactly when the user is checking whether the app still works.

## Behaviour that must not regress

- Only ticked apps are ever blocked. Every other path returns the event
  unmodified.
- The tap fails open: if the frontmost app cannot be identified, the event is
  passed through rather than swallowed.
- `UserDefaults.didChangeNotification` fires only for same-process writes, so a
  `defaults write` from a terminal needs the explicit reload hooks.
- The app scanner must not pass `.skipsHiddenFiles`. `/Applications/Safari.app`
  is a `restricted,hidden` symlink into the Cryptex volume, and that option
  silently drops Safari from the picker.

## Build check

    xcodegen generate && xcodebuild -scheme QuitGuard build
