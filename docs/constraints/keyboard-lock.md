# Keyboard Lock

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
