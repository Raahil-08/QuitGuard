# Dock right-click quit

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
