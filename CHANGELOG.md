# Changelog

## Unreleased
- Settings: new Features tab (grouped Form, one switch per feature), Protected Apps tab, About.
- New Quit Protection master switch. Existing installs with ticked apps migrate to on; fresh installs start off.
- Stay Awake relabelled from "Claude maxxing".
- "Coming soon" idea rows record interest (`WantedFeatureIdeas` default).
- Unit tests for the keyboard-lock policy, protected-apps store, quit-protection migration and catalog.
- Restructured sources into `App/`, `Core/`, `Settings/`, `Features/<Name>/`.
- AGENTS.md is now canonical; CLAUDE.md imports it. Constraints moved to `docs/constraints/`.
