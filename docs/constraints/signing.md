# Packaging and signing

- Menu bar only: `LSUIElement = true`. No Dock icon, no main window.
- **No sandbox.** A sandboxed process cannot create a session event tap.
- Signing is manual, against a self-signed certificate named **"QuitGuard Local"**.
- `CODE_SIGN_IDENTITY` and `PRODUCT_BUNDLE_IDENTIFIER` (`com.raahil.quitguard`)
  are **FROZEN**. The Accessibility (TCC) grant is keyed to the designated
  requirement:

      identifier "com.raahil.quitguard" and certificate leaf = H"<cert sha1>"

  Changing either value produces a different requirement and silently revokes
  the grant.
- Release builds must set `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`. Xcode
  injects `get-task-allow` by default even in Release, which leaves the app
  debuggable — unacceptable for a process holding Accessibility. It does not
  affect the designated requirement, so toggling it does not disturb the grant.
- **Never use ad-hoc signing (`codesign -s -`).** It produces a new identity per
  build and silently breaks the Accessibility grant on every rebuild.
- If the signing identity is missing, recreate it with `scripts/make-signing-cert.sh`.
  Note that a *regenerated* cert has a new hash and will require re-granting
  Accessibility once.
