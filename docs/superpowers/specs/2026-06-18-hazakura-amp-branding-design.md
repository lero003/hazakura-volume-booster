# Hazakura Amp Branding Design

## Goal

Replace temporary app-facing branding with `Hazakura Amp!` and add a real app icon.

## Approved Direction

Use a speaker + hazakura leaf mark. The direction is based on visual option A, with the quieter utility tone from option C.

## Scope

- Set the built app product name to `Hazakura Amp!`, so the bundle is `Hazakura Amp!.app`.
- Add a macOS app icon asset using a calm pink / white / muted green palette and dark speaker geometry.
- Keep the existing target, scheme, source folder, and internal PoC identifiers to avoid a broad project rename.
- Keep the menu-bar SF Symbol for now because a tiny template icon has different constraints from a colorful app icon.
- Update app-facing legacy product strings to `Hazakura Amp!` where they appear in the UI, accessibility text, permission copy, diagnostics header, release artifact names, and README naming notes.

## Verification

- Build the Xcode project with the existing `CoreAudioTapPoC` scheme.
- Inspect the built app path, `CFBundleName`, and icon build setting.
- No audio behavior changes are intended.
