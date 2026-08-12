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
