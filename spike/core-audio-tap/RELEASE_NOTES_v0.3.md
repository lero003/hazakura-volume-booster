# Hazakura Amp v0.3

UI polish and project-quality candidate. The audio path (ScreenCaptureKit + ring buffer + AVAudioEngine) is unchanged; this release focuses on a reproducible build, removing dead code, and a product-grade menu bar UI.

## Highlights

- **Reproducible `xcodegen generate`**: added `productName: "Hazakura Amp"` to `project.yml` so the generated product reference and scheme stay `Hazakura Amp.app` instead of reverting to `CoreAudioTapPoC.app` on every regeneration.
- **Removed dead code**: deleted the unused v1 IOProc experiment (`AudioIOProc.h`/`.mm`), the bridging header, the `AudioIOProcControlling` protocol, and the `SWIFT_OBJC_BRIDGING_HEADER` setting. The active path is unchanged.
- **Japanese UI**: unified all user-facing popover strings to Japanese (buttons, status messages, diagnostics labels). VoiceOver `accessibilityLabel`/`accessibilityHint` stay English.
- **Menu bar icon reflects state**: idle shows an outline speaker, running shows a filled speaker (`speaker.wave.3.fill` above 200%). The status item width is fixed so the icon never shifts when state changes.
- **Popover sizing**: fixed max height so the Dev diagnostics section no longer grows the popover unbounded; the event log keeps its 160pt scroll cap.
- **Health color coding**: Dev diagnostics now color the health line green (OK) / orange (Watch) / red (Warning).

## Known Boundaries

- Not notarized.
- Not a DMG installer.
- Sleep wake may require manual Start after wake.
- Output device auto-follow, hotkeys, Launch at Login, and presets are intentionally deferred.
- The menu bar icon communicates ON/OFF by shape only; the exact percent is shown inside the popover.
- Real playback force-quit and output-device-change checks still need user-side manual confirmation.

## Local Verification

```bash
xcodegen generate
git diff --check   # project.pbxproj must be stable after regeneration
xcodebuild -project CoreAudioTapPoC.xcodeproj -scheme CoreAudioTapPoC -destination 'platform=macOS' -derivedDataPath build test
./scripts/build_release_candidate.sh
./scripts/verify_shutdown_safety.sh
```
