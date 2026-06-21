# Handoff

## Current State
- Hazakura Amp has a Safari Web Extension companion slice for YouTube: a small floating Boost / Repeat remote, native messaging handler, and App Group JSON command bridge.
- The native app remains the only audio processor. The YouTube content script does not use Web Audio and only toggles `video.loop` for repeat.
- The app-side Safari extension diagnostics now avoid the Swift `NS_SWIFT_UI_ACTOR` completion annotation on `SFSafariExtensionManager.getStateOfSafariExtension` by using an Objective-C selector bridge and returning UI mutations to the main queue.

## Recent Changes
- Added remote command/state models, file-backed App Group store, and app-side polling bridge.
- Added `YouTubeRemoteExtension/` Manifest V3 resources and `SafariWebExtensionHandler.swift`.
- Added XcodeGen app-extension target `HazakuraAmpSafariExtension` and App Group entitlement `group.dev.hazakura-amp`; Web Extension files are explicitly assigned to the extension target Resources phase so `manifest.json`, `background.js`, `content.js`, and `content.css` are copied into the `.appex`.
- Added app-side Safari extension diagnostics in Dev mode: the app can ask Safari for the extension enabled state and open Safari's extension preferences for the Safari Web Extension bundle identifier. The state check intentionally goes through `SFSafariExtensionManager.perform(...)` because the typed Swift callback crashed on SafariServices' XPC queue before the Dev UI could be used.
- Added Web Extension icon resources and manifest `icons` / `action.default_icon`; `safari-web-extension-converter` no longer warns about missing icons.
- The icon resources are copied as a preserved `Resources/images/` folder inside the `.appex`, matching the manifest paths such as `images/icon-48.png`.
- Polished the YouTube floating remote: the default placement is now top-right, the header can be dragged, the saved position is persisted in extension storage, and the position clamps back into the viewport after resize/collapse.
- Tightened the floating remote styling with a smaller glass panel, compact collapsed state, clearer Repeat active state, and a mobile bottom-right fallback.
- Added YouTube remote resilience polish: the Web Extension now receives native `updatedAt`, polls state every 3 seconds, marks stale state as `App disconnected`, and automatically returns to the normal status when fresh app state appears again.
- Added YouTube remote Boost presets (`100`, `150`, `200`, `300`, `400`) plus a lightweight high-boost clipping warning at 300% and above.
- Added a compact Dev-mode setup checklist for first-run checks: app running, Safari extension state, and audio capture activity.
- Set both the host app and Safari extension to app sandbox with App Group `group.dev.hazakura-amp`.
- Kept the Safari extension bundle id at `dev.hazakura-amp.safari-extension` so Xcode uses the explicit development provisioning profile with App Group entitlement instead of falling back to a wildcard profile.
- App-side Safari diagnostic errors now include domain/code text, for example `SFErrorDomain:1 ...`, so the next smoke report is more actionable.
- Updated `spike/core-audio-tap/README.md` and `docs/ROADMAP.md` with current status and remaining proof.

## Tests
- `python3 -m json.tool spike/core-audio-tap/YouTubeRemoteExtension/manifest.json >/tmp/hazakura-amp-manifest.json` passed.
- `node --check spike/core-audio-tap/YouTubeRemoteExtension/background.js && node --check spike/core-audio-tap/YouTubeRemoteExtension/content.js` passed.
- `rg -n "sponsor|adblock|AudioContext|webkitAudioContext|playbackRate|subtitle|caption|<all_urls>" spike/core-audio-tap/YouTubeRemoteExtension` returned no matches.
- `xcodebuild -project CoreAudioTapPoC.xcodeproj -scheme CoreAudioTapPoC -configuration Debug -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build` passed.
- `xcodebuild -project CoreAudioTapPoC.xcodeproj -scheme CoreAudioTapPoC -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO test` passed: 54 tests, 0 failures.
- `xcodebuild -project CoreAudioTapPoC.xcodeproj -scheme CoreAudioTapPoC -configuration Debug -destination 'platform=macOS' -derivedDataPath build -allowProvisioningUpdates build` passed with Apple Development profiles for `dev.hazakura-amp` and the Safari Web Extension target.
- `xcodebuild -project CoreAudioTapPoC.xcodeproj -scheme CoreAudioTapPoC -destination 'platform=macOS' -derivedDataPath build -only-testing:CoreAudioTapPoCTests/GainProcessorTests/testAppCanOpenAndInspectSafariExtensionSettings test` passed.
- `xcodebuild -project CoreAudioTapPoC.xcodeproj -scheme CoreAudioTapPoC -destination 'platform=macOS' -derivedDataPath build -only-testing:CoreAudioTapPoCTests/GainProcessorTests/testSafariExtensionStateRefreshReturnsThroughMainActor test` passed.
- `xcrun safari-web-extension-converter spike/core-audio-tap/YouTubeRemoteExtension --project-location /tmp/hazakura-amp-webextension-check --app-name HazakuraAmpCheck --bundle-identifier dev.hazakura-amp.check --swift --macos-only --copy-resources --no-open --no-prompt --force` passed without the prior missing-icons warning.
- `xcodebuild -project CoreAudioTapPoC.xcodeproj -scheme CoreAudioTapPoC -destination 'platform=macOS' -derivedDataPath build test` passed: 56 tests, 0 failures.
- `xcodebuild -project CoreAudioTapPoC.xcodeproj -scheme CoreAudioTapPoC -destination 'platform=macOS' -derivedDataPath build clean build` passed.
- `codesign -d --entitlements :-` confirmed the app and extension are signed with app sandbox and App Group `group.dev.hazakura-amp`.
- Installed profile inspection confirmed the extension uses `Mac Team Provisioning Profile: dev.hazakura-amp.safari-extension`, not a wildcard profile.
- `pluginkit -m -D -v -i dev.hazakura-amp.safari-extension` shows one registered plug-in under `/Applications/Hazakura Amp.app/Contents/PlugIns/HazakuraAmpSafariExtension.appex`.
- `/Applications/Hazakura Amp.app` was refreshed from the signed clean Debug build and contains only the Safari extension plug-in; the Web Extension resources are under `Contents/PlugIns/HazakuraAmpSafariExtension.appex/Contents/Resources/`.
- Launch smoke passed: opening `/Applications/Hazakura Amp.app` left the process running.
- Follow-up icon-path fix: `xcodebuild -project CoreAudioTapPoC.xcodeproj -scheme CoreAudioTapPoC -destination 'platform=macOS' -derivedDataPath build build` passed, and the built `.appex` contains `Contents/Resources/images/icon-48.png`, `icon-96.png`, `icon-128.png`, `icon-256.png`, and `icon-512.png`.
- Follow-up focused `xcodebuild ... test` could not complete in the restricted Codex sandbox because `testmanagerd` XPC was blocked; this was an environment failure after build, not a Swift/test assertion failure.
- UI polish validation: `node --check spike/core-audio-tap/YouTubeRemoteExtension/content.js` passed.
- UI polish validation: `python3 -m json.tool spike/core-audio-tap/YouTubeRemoteExtension/manifest.json >/tmp/hazakura-amp-manifest-check.json` passed.
- UI polish validation: `xcodebuild -project spike/core-audio-tap/CoreAudioTapPoC.xcodeproj -scheme CoreAudioTapPoC -configuration Debug -derivedDataPath spike/core-audio-tap/build build` passed with Apple Development signing for the app and Safari extension.
- UI polish validation: the built app contains `Contents/PlugIns/HazakuraAmpSafariExtension.appex/Contents/Resources/content.css`, `content.js`, `manifest.json`, and `images/icon-48.png` / `icon-96.png` / `icon-128.png` / `icon-256.png` / `icon-512.png`.
- UI polish validation: `codesign -dv --verbose=2` confirmed `dev.hazakura-amp` and `dev.hazakura-amp.safari-extension` in the Debug build.
- UI polish focused `xcodebuild ... -only-testing:CoreAudioTapPoCTests/GainProcessorTests/testYouTubeRemoteContentScriptUsesOnlyRepeatAndRemoteControls test` could not complete in the restricted Codex sandbox because `com.apple.testmanagerd.control` was blocked; this was an environment failure after build, not a Swift/test assertion failure.
- Reconnect/safety/setup validation: `node --check spike/core-audio-tap/YouTubeRemoteExtension/content.js` passed.
- Reconnect/safety/setup validation: `node --check spike/core-audio-tap/YouTubeRemoteExtension/background.js` passed.
- Reconnect/safety/setup validation: `python3 -m json.tool spike/core-audio-tap/YouTubeRemoteExtension/manifest.json >/tmp/hazakura-amp-manifest-reconnect-check.json` passed.
- Reconnect/safety/setup validation: plain `xcodebuild ... build` failed in this restricted Codex sandbox at SwiftUI `#Preview` macro expansion (`swift-plugin-server` / sandbox), not at app code type-checking.
- Reconnect/safety/setup validation: `xcodebuild -project spike/core-audio-tap/CoreAudioTapPoC.xcodeproj -scheme CoreAudioTapPoC -configuration Debug -derivedDataPath spike/core-audio-tap/build OTHER_SWIFT_FLAGS='$(inherited) -DDISABLE_SWIFTUI_PREVIEWS' build` passed.
- Reconnect/safety/setup validation: focused `xcodebuild ... test` compiled and signed the selected test bundle but could not run because `com.apple.testmanagerd.control` was blocked by the sandbox; this was an environment failure after build, not an assertion failure.
- Reconnect/safety/setup validation: built `.appex` contains `content.css`, `content.js`, `manifest.json`, and all icon resources under `Contents/Resources/images/`.
- Reconnect/safety/setup validation: `codesign -dv --verbose=2` confirmed the Debug app identifier `dev.hazakura-amp`.
- Reconnect/safety/setup validation: `git diff --check` passed.

## Risks / Unknowns
- Safari manual E2E is not yet verified: opening the app-side extension settings action, enabling the extension, checking YouTube overlay injection, moving Boost, and confirming same-video Repeat.
- The icon-path and UI polish fixes have not been installed to `/Applications/Hazakura Amp.app` from this sandboxed turn; install/copy the latest Debug app before the next Safari smoke.
- Safari visual smoke is still needed for the new reconnect status, boost preset buttons, 300%+ warning, draggable persisted position, collapsed width, and mobile fallback.
- A standalone `swift` script calling `SFSafariExtensionManager` still returns `SFErrorDomain:1`; that script is not the containing app, so treat it as a weak signal. The next decisive proof is the app-side Dev UI after quitting/relaunching Safari.
- If Safari was already open, quit and relaunch Safari before checking Settings > Extensions; Safari/LaunchServices can cache extension discovery.
- `*.codex-backup-*` apps under `/Applications` are retired snapshots only; use `/Applications/Hazakura Amp.app` for smoke.

## Next Actions
- Quit and relaunch Safari, open `/Applications/Hazakura Amp.app`, use Dev mode > Safari extension diagnostics to open the extension settings, enable the extension in Safari, and complete the README manual checklist.

## Avoid
- Do not add YouTube enhancer features such as speed, captions, queue control, ad blocking, sponsor skipping, or media saving in this slice.
- Do not move boost into Web Audio unless the native Hazakura Amp path is deliberately abandoned.
