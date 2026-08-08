# QuitGuard

A macOS menu bar utility that intercepts <kbd>Cmd</kbd>+<kbd>Q</kbd> for a
user-selected list of apps and shows a confirmation panel instead of quitting
immediately. Apps that aren't on the list quit normally.

Requires macOS 13 or later. No dependencies beyond system frameworks.

## Building

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
# once per machine — creates the "QuitGuard Local" signing identity
./scripts/make-signing-cert.sh

xcodegen generate
xcodebuild -scheme QuitGuard build
```

`project.yml` is the source of truth; the `.xcodeproj` is generated and
gitignored.

## Accessibility

QuitGuard needs Accessibility permission to observe and consume key events. The
grant is pinned to the app's bundle identifier *and* its signing certificate, so
it survives rebuilds as long as neither changes. See `CLAUDE.md` for the
constraints that keep it that way.

## Status

Stage 1 complete: menu bar skeleton, signing configured.
