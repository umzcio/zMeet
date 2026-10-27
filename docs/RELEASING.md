# Releasing zMeet

zMeet ships as a signed, notarized `.dmg` with Sparkle auto-updates. This is the
distribution pipeline.

## One-time setup

1. **Signing identity** — `scripts/build-app.sh` signs with the Developer ID Application
   certificate of team `TEAM_ID` (set at its top), looked up in the keychain, and refuses
   any other team's certificate. `ZMEET_SIGN_IDENTITY` (hash or name) overrides the lookup.
   `security find-identity -v -p codesigning` lists what's installed.

2. **Sparkle update-signing key** — already generated (`generate_keys`); the private key
   lives in your login keychain and the public key (`SUPublicEDKey`) is baked into
   `build-app.sh`. To see it again: `.build/artifacts/sparkle/Sparkle/bin/generate_keys -p`.

3. **Notary credentials** — a notarytool Keychain profile named `notary` for the same
   team (`scripts/notarize.sh` uses it; `NOTARY_PROFILE` overrides the name):
   ```sh
   xcrun notarytool store-credentials notary \
     --apple-id "you@example.com" \
     --team-id  "YOURTEAMID" \
     --password "app-specific-password"   # create at appleid.apple.com
   ```
   Check it with `xcrun notarytool history --keychain-profile notary`.

4. **Hosting** — decide where the `.dmg` is downloaded from and where `appcast.xml` lives.
   - `SUFeedURL` in `build-app.sh` = the appcast URL the app polls (e.g. a stable
     `raw.githubusercontent.com/.../appcast.xml` or GitHub Pages URL).
   - `DOWNLOAD_URL_PREFIX` (env or default in `release.sh`) = where the `.dmg` is hosted
     (e.g. a GitHub release's asset base URL).

## Cutting a release

1. Bump `VERSION`/`BUILD` in `scripts/build-app.sh` and commit — `release.sh` refuses a version argument that doesn't match, and only auto-tags on a clean tree.
2. `scripts/release.sh 1.16.0` — runs the test suite, builds + signs, packages the `.dmg`, notarizes + staples (twice: pre- and post-staple), generates the signed appcast in `build/dist/`, and tags `v1.16.0`.

   Hosting the `.dmg` somewhere other than the default? Override `DOWNLOAD_URL_PREFIX`:
   ```sh
   DOWNLOAD_URL_PREFIX="https://github.com/OWNER/zMeet/releases/download/v0.2.0/" \
     scripts/release.sh 0.2.0
   ```
3. `git push origin main v1.16.0`
4. `gh release create v1.16.0 build/dist/zMeet-1.16.0.dmg --title "v1.16.0" --notes "..."`
5. `cp build/dist/appcast.xml appcast.xml && git commit -am "v1.16.0 release: appcast" && git push` — auto-update goes live at this step.
6. `scripts/update-cask.sh 1.16.0` (after the release exists, so the download URL resolves).

Existing installs will pick up the update on their next scheduled check (or via
**Check for Updates…** in the menu), verify the EdDSA signature, download, and
self-install.

## Individual scripts

| Script | Does |
|--------|------|
| `build-app.sh` | Compile, bundle, embed+sign Sparkle, sign the app |
| `make-dmg.sh [version]` | Package `build/zMeet.app` into a branded drag-to-Applications `.dmg` with [create-dmg](https://github.com/create-dmg/create-dmg) (`brew install create-dmg`); the background is drawn by `render-dmg-background.swift` |
| `notarize.sh <dmg>` | Submit to Apple notary, staple the ticket |
| `release.sh <version>` | All of the above + generate the signed appcast |
| `update-cask.sh <version>` | Bump the `zmeet` cask in [umzcio/homebrew-tap](https://github.com/umzcio/homebrew-tap) |

## Troubleshooting

- Any build fails with a Sparkle `XCFramework Info.plist not found` error →
  `rm -rf .build && swift build` (stale artifact cache, e.g. after moving the checkout).
