# Event interception, matching and quitting

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
