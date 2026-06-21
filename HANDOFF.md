# Handoff

## Current State
- Hazakura Amp has a Safari Web Extension companion slice for YouTube: a small floating Boost / Repeat remote, native messaging handler, and App Group JSON command bridge.
- The native app remains the only audio processor. The YouTube content script does not use Web Audio and only toggles `video.loop` for repeat.

## Recent Changes
- Added remote command/state models, file-backed App Group store, and app-side polling bridge.
- Added `YouTubeRemoteExtension/` Manifest V3 resources and `SafariWebExtensionHandler.swift`.
- Added XcodeGen app-extension target `HazakuraAmpSafariExtension` and App Group entitlement `group.dev.keisetsu.hazakura-amp`.
- Updated `spike/core-audio-tap/README.md` and `docs/ROADMAP.md` with current status and remaining proof.

## Tests
- `python3 -m json.tool spike/core-audio-tap/YouTubeRemoteExtension/manifest.json >/tmp/hazakura-amp-manifest.json` passed.
- `node --check spike/core-audio-tap/YouTubeRemoteExtension/background.js && node --check spike/core-audio-tap/YouTubeRemoteExtension/content.js` passed.
- `rg -n "sponsor|adblock|AudioContext|webkitAudioContext|playbackRate|subtitle|caption|<all_urls>" spike/core-audio-tap/YouTubeRemoteExtension` returned no matches.
- `xcodebuild -project CoreAudioTapPoC.xcodeproj -scheme CoreAudioTapPoC -configuration Debug -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build` passed.
- `xcodebuild -project CoreAudioTapPoC.xcodeproj -scheme CoreAudioTapPoC -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO test` passed: 54 tests, 0 failures.

## Risks / Unknowns
- Signed Debug build currently needs Mac App Development provisioning profiles for `dev.keisetsu.hazakura-amp` and `dev.keisetsu.hazakura-amp.safari-extension` with the App Group enabled. Without those profiles, signed build fails.
- Safari manual E2E is not yet verified: enabling the extension, checking YouTube overlay injection, moving Boost, and confirming same-video Repeat.

## Next Actions
- Create or refresh the provisioning profiles for the app and Safari extension bundle IDs with `group.dev.keisetsu.hazakura-amp`.
- Run signed Debug build, then enable the extension in Safari and complete the README manual checklist.

## Avoid
- Do not add YouTube enhancer features such as speed, captions, queue control, ad blocking, sponsor skipping, or media saving in this slice.
- Do not move boost into Web Audio unless the native Hazakura Amp path is deliberately abandoned.
