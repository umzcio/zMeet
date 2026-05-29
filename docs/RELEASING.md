# Releasing zMeet

zMeet ships as a signed, notarized `.dmg` with Sparkle auto-updates. This is the
distribution pipeline.

## One-time setup

1. **Signing identity** — set `IDENTITY` at the top of `scripts/build-app.sh` to your
   Developer ID Application certificate (`security find-identity -p codesigning` lists them).

2. **Sparkle update-signing key** — already generated (`generate_keys`); the private key
   lives in your login keychain and the public key (`SUPublicEDKey`) is baked into
   `build-app.sh`. To see it again: `.build/artifacts/sparkle/Sparkle/bin/generate_keys -p`.

3. **Notary credentials** — store an app-specific password as a keychain profile:
   ```sh
   xcrun notarytool store-credentials zmeet-notary \
     --apple-id "you@example.com" \
     --team-id  "YOURTEAMID" \
     --password "app-specific-password"   # create at appleid.apple.com
   ```

4. **Hosting** — decide where the `.dmg` is downloaded from and where `appcast.xml` lives.
   - `SUFeedURL` in `build-app.sh` = the appcast URL the app polls (e.g. a stable
     `raw.githubusercontent.com/.../appcast.xml` or GitHub Pages URL).
   - `DOWNLOAD_URL_PREFIX` (env or default in `release.sh`) = where the `.dmg` is hosted
     (e.g. a GitHub release's asset base URL).

## Cutting a release

1. Bump `VERSION`/`BUILD` in `scripts/build-app.sh`.
2. Run:
   ```sh
   DOWNLOAD_URL_PREFIX="https://github.com/OWNER/zMeet/releases/download/v0.2.0/" \
     scripts/release.sh 0.2.0
   ```
   This builds + signs the app, packages the `.dmg`, notarizes + staples it, and
   generates a signed `appcast.xml` in `build/dist/`.
3. Upload `build/dist/zMeet-0.2.0.dmg` to the release.
4. Publish `build/dist/appcast.xml` at the `SUFeedURL` location.

Existing installs will pick up the update on their next scheduled check (or via
**Check for Updates…** in the menu), verify the EdDSA signature, download, and
self-install.

## Individual scripts

| Script | Does |
|--------|------|
| `build-app.sh` | Compile, bundle, embed+sign Sparkle, sign the app |
| `make-dmg.sh [version]` | Package `build/zMeet.app` into a drag-to-Applications `.dmg` |
| `notarize.sh <dmg>` | Submit to Apple notary, staple the ticket |
| `release.sh <version>` | All of the above + generate the signed appcast |

> Note: notarization and live auto-update require the repo to be published with real
> hosting in place. Until then, the app builds and runs; **Check for Updates…** simply
> reports no update (the placeholder `SUFeedURL` 404s).
