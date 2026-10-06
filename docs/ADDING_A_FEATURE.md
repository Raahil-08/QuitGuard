# Adding a feature

1. Create `Sources/Features/<Name>/` with the component, its settings store (copy the
   `DockQuitSettings` pattern: lock-guarded, UserDefaults, reload hook) and a short `AGENTS.md`.
2. Add a case to the feature catalog (title, description, SF Symbol, permissions needed).
3. Start/stop the component from `AppDelegate` based on the enabled-features store; disabling
   must undo everything it did (taps destroyed, system state reverted).
4. Add menu bar entries in `StatusItem.swift` only when the feature is enabled.
5. Put any hard constraints you discover in `docs/constraints/<name>.md` and link it.
6. Keep pure decision logic separate from taps/AppKit so it can be unit-tested.
7. Update `CHANGELOG.md` and the README feature list.
