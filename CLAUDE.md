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

    App.swift                @main, NSApplicationDelegateAdaptor
    QuitInterceptor.swift    the event tap
    PermissionGate.swift     AXIsProcessTrustedWithOptions + state
    ProtectedAppsStore.swift ObservableObject, Set<String> in UserDefaults
    ConfirmationPanel.swift  NSPanel
    SettingsView.swift       SwiftUI app picker
    StatusItem.swift         NSStatusItem, normal/degraded states
    LaunchAtLogin.swift      SMAppService wrapper

## Build check

    xcodegen generate && xcodebuild -scheme QuitGuard build
