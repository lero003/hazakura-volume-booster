# Hazakura Amp v0.3.1

Patch release on top of v0.3.0. One focused fix plus README/doc alignment.

## Highlights

- **Popover no longer clips off-screen**: when the menu bar icon sits near the right edge of the screen, the popover now shifts left to stay within the visible screen area. `NSPopover` exposes no positioning API, so the popover's inner window origin is corrected after it is shown.
- **Menu bar icon decision finalized**: the transient `Boost NNN%` label introduced and then reverted during v0.3 development is gone. ON/OFF is communicated by icon shape only (outline when idle, filled when running, `speaker.wave.3.fill` above 200%). The status item width is fixed (`squareLength`) so the icon never shifts.
- **README aligned**: startup steps, verification checklist, and version references now reflect the Japanese-first UI, status-aware icon, health color coding, and popover positioning.

## Known Boundaries

- Not notarized.
- Not a DMG installer.
- Sleep wake may require manual 開始 after wake.
- Output device auto-follow, hotkeys, Launch at Login, and presets are intentionally deferred.
- Real playback force-quit and output-device-change checks still need user-side manual confirmation.

## Local Verification

```bash
xcodegen generate
git diff --check   # project.pbxproj must be stable after regeneration
xcodebuild -project CoreAudioTapPoC.xcodeproj -scheme CoreAudioTapPoC -destination 'platform=macOS' -derivedDataPath build test
./scripts/build_release_candidate.sh
./scripts/verify_shutdown_safety.sh
```
