# QuitGuard

Personal macOS menu-bar utility (Swift, SwiftUI + AppKit, macOS 13, no third-party deps).
Each capability is a toggleable **feature**: Quit Protection (Cmd+Q confirm), Dock Quit
(Cmd+right-click), Stay Awake (lid-closed, `pmset`), Keyboard Lock (cleaning). Everything
is off until the user enables it in Settings.

## Commands

    make generate     # xcodegen generate (project.yml is the source of truth)
    make build        # Debug compile check
    make install      # Release build -> /Applications, relaunch (the only build to grant Accessibility)
    make identity     # print designated requirement; if it changes, the TCC grant is gone
    make cert         # create the "QuitGuard Local" self-signed identity (idempotent)

Never hand-edit the `.xcodeproj` (generated, gitignored). Requires full Xcode + `brew install xcodegen`.

## Layout

    Sources/App/       App.swift, StatusItem.swift, LaunchAtLogin.swift
    Sources/Core/      PermissionGate, PermissionResetView, FeatureCatalog (Feature, FeatureIdea, FeatureWishlist)
    Sources/Settings/  Settings window: FeaturesPane (switches), protected-apps picker, About
    Tests/QuitGuardTests/  unit tests; pure files are compiled into the bundle (see project.yml)
    Sources/Features/  one folder per feature, each with its own AGENTS.md
        QuitProtection/  DockQuit/  StayAwake/  KeyboardLock/
    docs/constraints/  the hard-won "do not modernize" rules, one file per area
    docs/              ADDING_A_FEATURE.md, ROADMAP.md

## Hard rules (details in docs/constraints/)

- Cmd+Q interception is a `CGEvent` session tap, never `NSEvent` global monitors. [event-interception.md]
- Tap callbacks return in microseconds: no UI, AppKit, UserDefaults or AX inside them. [threading.md]
- Never touch `PRODUCT_BUNDLE_IDENTIFIER` (`com.raahil.quitguard`) or `CODE_SIGN_IDENTITY`
  ("QuitGuard Local"); never ad-hoc sign; no sandbox. [signing.md]
- `pmset` exits 0 even when it refuses; always re-read state. Never handle the admin password. [stay-awake.md]
- Keyboard Lock uses its own tap and an independent failsafe; never widen the quit tap. [keyboard-lock.md]
- Dock quit resolves tiles via `AXURL` off the tap thread; Finder is `com.apple.finder`. [dock-quit.md]
- No hardcoded bundle IDs (read from the store, default empty). Use `SMAppService` for login items.
- QuitGuard cannot protect itself from Cmd+Q.

## Conventions

- Match surrounding code: same naming, comment density, lock-guarded settings stores
  (`DockQuitSettings` is the pattern), explicit reload hooks for `defaults write`.
- Timers go on `RunLoop.main` in `.common` mode.
- New feature = new folder under `Sources/Features/` + one entry in the feature catalog.
  Follow `docs/ADDING_A_FEATURE.md`.

## Verification

Compile with `make build`. Event taps are verified manually (see each feature's constraint
doc for the recipes); keep pure policy logic separate from taps so it can be unit-tested.
