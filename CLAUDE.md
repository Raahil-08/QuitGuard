@AGENTS.md

## Claude Code notes

- Before editing a feature folder, read its `AGENTS.md` and the linked `docs/constraints/*.md`.
  Those constraints were chosen deliberately: do not "modernize" or simplify them.
- Do not run `make install` or anything that rewrites the signing identity without being asked;
  it relaunches the app and can invalidate the Accessibility grant.
- Full Xcode may not be selected on this machine (`xcode-select -p`); if `xcodebuild` fails,
  say so rather than assuming the build passed.
