# Threading and behaviour that must not regress

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
