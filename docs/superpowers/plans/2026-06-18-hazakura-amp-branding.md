# Hazakura Amp Branding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the built macOS app surface to `Hazakura Amp` and add a real app icon.

**Architecture:** Keep target and scheme identifiers stable, and change only product-facing branding. Use an asset catalog `AppIcon` generated from the approved speaker + leaf mark.

**Tech Stack:** Xcode project, XcodeGen `project.yml`, macOS asset catalog, SwiftUI/AppKit strings, shell-based Xcode verification.

---

### Task 1: Add Icon Assets

**Files:**
- Create: `spike/core-audio-tap/CoreAudioTapPoC/Assets.xcassets/Contents.json`
- Create: `spike/core-audio-tap/CoreAudioTapPoC/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Create: generated icon PNG files in `spike/core-audio-tap/CoreAudioTapPoC/Assets.xcassets/AppIcon.appiconset/`

- [x] Create the asset catalog and app icon set.
- [x] Generate all macOS icon slots from the approved SVG-style mark.
- [x] Confirm every image listed in `Contents.json` exists.

### Task 2: Wire Branding Into The Build

**Files:**
- Modify: `spike/core-audio-tap/project.yml`
- Modify: `spike/core-audio-tap/CoreAudioTapPoC.xcodeproj/project.pbxproj`
- Modify: `spike/core-audio-tap/CoreAudioTapPoC/Resources/Info.plist`

- [x] Set `PRODUCT_NAME` to `Hazakura Amp`.
- [x] Set `ASSETCATALOG_COMPILER_APPICON_NAME` to `AppIcon`.
- [x] Add `CFBundleDisplayName` as `Hazakura Amp`.
- [x] Keep bundle identifiers, target names, and schemes unchanged.

### Task 3: Update App-Facing Copy

**Files:**
- Modify: `spike/core-audio-tap/CoreAudioTapPoC/ContentView.swift`
- Modify: `spike/core-audio-tap/CoreAudioTapPoC/CoreAudioTapPoCApp.swift`
- Modify: `spike/core-audio-tap/CoreAudioTapPoC/Audio/PoCAudioEngine.swift`
- Modify: `spike/core-audio-tap/scripts/build_release_candidate.sh`
- Modify: `README.md`
- Modify: `docs/UI_DESIGN.md`

- [x] Replace visible user-facing legacy product strings with `Hazakura Amp`.
- [x] Replace permission and copyright app-copy strings with `Hazakura Amp`.
- [x] Update the release zip name to use `HazakuraAmp`.
- [x] Avoid broad internal source renames.

### Task 4: Verify

- [x] Run `xcodebuild -project CoreAudioTapPoC.xcodeproj -scheme CoreAudioTapPoC -configuration Debug -destination 'platform=macOS' -derivedDataPath build build`.
- [x] Inspect `build/Build/Products/Debug/Hazakura Amp.app`.
- [x] Read `Contents/Info.plist` and confirm `CFBundleName` / `CFBundleDisplayName`.
- [x] Confirm no source behavior outside branding changed.

Verification recorded on 2026-06-18:

- `xcodebuild -project CoreAudioTapPoC.xcodeproj -scheme CoreAudioTapPoC -destination 'platform=macOS' -derivedDataPath build test`
- `xcodebuild -project CoreAudioTapPoC.xcodeproj -scheme CoreAudioTapPoC -configuration Debug -destination 'platform=macOS' -derivedDataPath build build`
- `CFBundleName` and `CFBundleDisplayName` both resolve to `Hazakura Amp`; Bundle Identifier resolves to `dev.hazakura-amp`.
