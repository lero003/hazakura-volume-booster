# Hazakura Amp! v0.2

Daily-use quality candidate for the active ScreenCaptureKit + ring buffer + AVAudioEngine PoC.

## Highlights

- Reduced the popover to Slider, Start/Stop, Quit, and Dev diagnostics.
- Removed Reset, preset buttons, and the ON/OFF toggle.
- Expanded gain to 0% through 400%.
- Added right-click Quit on the menu bar icon.
- Improved permission-denied recovery text.
- Added version/build/signing/status/health/recent-events diagnostics copy.
- Added `scripts/verify_shutdown_safety.sh` for process and `hbb-poc` residue checks.
- Builds a Developer ID signed release candidate zip named `HazakuraAmp-v0.2.0-developer-id.zip`.

## Known Boundaries

- Not notarized.
- Not a DMG installer.
- Sleep wake may require manual Start after wake.
- Output device auto-follow, hotkeys, Launch at Login, and presets are intentionally deferred.
- Real playback force-quit and output-device-change checks still need user-side manual confirmation.

## Local Verification

```bash
xcodebuild -project CoreAudioTapPoC.xcodeproj -scheme CoreAudioTapPoC -destination 'platform=macOS' -derivedDataPath build test
git diff --check
./scripts/build_release_candidate.sh
./scripts/verify_shutdown_safety.sh
```
