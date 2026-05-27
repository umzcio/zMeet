# zMeet Branding

Status: **in progress.** Wordmark + palette decided; app icon deferred.

## Palette — "Mint terminal"

Dev-tool / terminal energy: bright mint on near-black.

| Role | Hex |
|------|-----|
| Accent (mint) | `#2EE08A` |
| Accent deep | `#16A35E` |
| Surface (elevated) | `#1E2420` |
| Background (near-black) | `#0D110F` |
| Text / light mint | `#E0F5E9` |
| Muted mint | `#7FD9A8` |
| Recording (kept) | red |

## Wordmark — DECIDED

`zMeet` = a **cursive `z`** (Dancing Script, mint `#2EE08A`) + **`Meet`** in the mono UI font.
A blinking terminal cursor may follow it in marketing contexts. Now live in the app menu header.

- Font: **Dancing Script** (OFL), bundled at `scripts/assets/DancingScript.ttf`
  (license `scripts/assets/DancingScript-OFL.txt`). Copied into the app bundle's
  `Contents/Resources/Fonts/` and auto-registered via `ATSApplicationFontsPath`.

## App icon — DEFERRED

Currently a placeholder: the system `waveform.circle.fill` glyph (mint), no custom `.icns`.

Explored but not chosen (mockups kept in `docs/branding/`):
- `zmeet-brand-1..4` — waveform / monogram / z-wave / terminal-prompt directions.
- `zmeet-brand-1b/1c/1d` — cursive-z-as-waveform, z-behind-wave.
- `zmeet-brand-1e/1f/FINAL` — white microphone with a mint cursive `z` woven over it
  (the reference direction). Closest so far is `zmeet-brand-FINAL-mic-z.html`, but not
  yet locked — revisit later, then generate the real `.icns` + a simplified menu-bar glyph.

## Notes

- Recording state stays **red** regardless of the mint brand color.
- Pre-publish: see the scrub checklist (memory) before open-sourcing.
