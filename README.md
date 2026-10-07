# QuitGuard

A personal macOS menu bar utility made of toggleable features. All are off
until enabled in Settings:

- **Quit Protection**: intercepts <kbd>Cmd</kbd>+<kbd>Q</kbd> for a chosen list
  of apps and asks for confirmation. Other apps quit normally.
- **Dock Quit**: <kbd>Cmd</kbd>+right-click a Dock tile to quit that app.
- **Stay Awake**: keep the Mac awake with the lid closed (`pmset disablesleep`).
- **Keyboard Lock**: swallow keyboard input while you clean it; mouse stays live.

Requires macOS 13 or later. No dependencies beyond system frameworks.

## Building

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
# once per machine — creates the "QuitGuard Local" signing identity
./scripts/make-signing-cert.sh

make build      # generate + Debug compile check
make install    # Release build into /Applications
```

Sources live in `Sources/{App,Core,Settings,Features/<Name>}`. See `AGENTS.md`
for the layout and `docs/` for constraints and how to add a feature.

`project.yml` is the source of truth; the `.xcodeproj` is generated and
gitignored.

## Accessibility

QuitGuard needs Accessibility permission to observe and consume key events. The
grant is pinned to the app's bundle identifier *and* its signing certificate, so
it survives rebuilds as long as neither changes. See `docs/constraints/signing.md` for the
constraints that keep it that way.

## Debugging

QuitGuard logs to the unified log under its own subsystem:

```sh
/usr/bin/log stream --predicate 'subsystem == "com.raahil.quitguard"'
```

Use the absolute path — `log` is shadowed by a shell function in some profiles,
and the bare command fails with `too many arguments`, which looks exactly like
"the app is producing no output".

## Status

Version 0.1.0, local use only (self-signed). See `CHANGELOG.md` and `docs/ROADMAP.md`.


### Seeding the protected list for testing

```sh
# set the list (replace the bundle IDs with whatever you want to test)
defaults write com.raahil.quitguard ProtectedBundleIDs -array com.apple.TextEdit

# inspect / clear
defaults read com.raahil.quitguard ProtectedBundleIDs
defaults delete com.raahil.quitguard ProtectedBundleIDs
```

The running app re-reads the list whenever you switch apps, so a write from a
terminal takes effect as soon as you activate the app you want to test — no
relaunch needed.
