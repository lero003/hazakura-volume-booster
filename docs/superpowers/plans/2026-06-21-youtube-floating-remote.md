# YouTube Floating Remote Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS-first Safari Web Extension companion that shows a small YouTube floating bar for Hazakura Amp boost control and one-video repeat.

**Architecture:** Hazakura Amp remains the source of truth for audio boost state. The Safari Web Extension renders a YouTube overlay and sends commands through Safari native messaging; the native handler and the app exchange commands through a tiny App Group JSON file bridge so the extension process never touches the audio engine directly.

**Tech Stack:** Swift 6, XCTest, XcodeGen, Safari WebExtension Manifest V3, plain JavaScript/CSS, App Group file storage, existing Core Audio / ScreenCaptureKit pipeline.

---

## File Structure

- Create `spike/core-audio-tap/CoreAudioTapPoC/RemoteControl/RemoteControlModels.swift`
  - Codable command and state payloads shared by the app and the Safari extension handler.
- Create `spike/core-audio-tap/CoreAudioTapPoC/RemoteControl/RemoteControlStore.swift`
  - File-backed JSON inbox and state store, injectable for tests.
- Create `spike/core-audio-tap/CoreAudioTapPoC/RemoteControl/RemoteControlBridge.swift`
  - Main-app polling bridge that applies extension commands to `PoCAudioEngine`.
- Modify `spike/core-audio-tap/CoreAudioTapPoC/Audio/PoCAudioEngine.swift`
  - Add a small `applyRemoteCommand(_:)` and `remoteState()` surface.
- Modify `spike/core-audio-tap/CoreAudioTapPoC/CoreAudioTapPoCApp.swift`
  - Start and stop `RemoteControlBridge` with the app lifecycle.
- Create `spike/core-audio-tap/CoreAudioTapPoC/SafariWebExtensionHandler.swift`
  - Native messaging handler that writes commands and reads app state.
- Create `spike/core-audio-tap/YouTubeRemoteExtension/manifest.json`
  - Safari WebExtension manifest for YouTube host access, storage, native messaging, content script, and background script.
- Create `spike/core-audio-tap/YouTubeRemoteExtension/background.js`
  - Relays overlay messages to Safari native messaging and returns state or errors.
- Create `spike/core-audio-tap/YouTubeRemoteExtension/content.js`
  - Injects the floating bar, synchronizes slider/repeat state, handles YouTube SPA navigation.
- Create `spike/core-audio-tap/YouTubeRemoteExtension/content.css`
  - Compact fixed-position floating bar styling.
- Modify `spike/core-audio-tap/project.yml`
  - Add the Safari Web Extension app extension target and App Group entitlement.
- Modify `spike/core-audio-tap/CoreAudioTapPoC/Resources/HazakuraAmp.entitlements`
  - Add the App Group used by app and extension.
- Modify `spike/core-audio-tap/CoreAudioTapPoCTests/GainProcessorTests.swift`
  - Add focused tests for remote models, store behavior, and engine command application.

## Task 1: Remote Control Models

**Files:**
- Create: `spike/core-audio-tap/CoreAudioTapPoC/RemoteControl/RemoteControlModels.swift`
- Modify: `spike/core-audio-tap/CoreAudioTapPoCTests/GainProcessorTests.swift`

- [ ] **Step 1: Write failing model tests**

Append these tests to `GainProcessorTests.swift`:

```swift
func testRemoteControlClampsGainCommands() throws {
    let low = HazakuraAmpRemoteCommand.setGain(-2.0)
    let high = HazakuraAmpRemoteCommand.setGain(9.0)
    let normal = HazakuraAmpRemoteCommand.setGain(2.2)

    XCTAssertEqual(low.sanitizedGain, 0.0)
    XCTAssertEqual(high.sanitizedGain, 4.0)
    XCTAssertEqual(normal.sanitizedGain, 2.2, accuracy: 0.001)
}

func testRemoteControlCommandRoundTripsThroughJSON() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    encoder.dateEncodingStrategy = .iso8601
    decoder.dateDecodingStrategy = .iso8601

    let command = HazakuraAmpRemoteCommand(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!,
        kind: .setGain,
        gain: 1.75,
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    let data = try encoder.encode(command)
    let decoded = try decoder.decode(HazakuraAmpRemoteCommand.self, from: data)

    XCTAssertEqual(decoded, command)
}

func testRemoteStateContainsOnlyExtensionSafeFields() throws {
    let state = HazakuraAmpRemoteState(
        configuredGain: 2.5,
        isRunning: true,
        statusText: "running",
        lastError: nil,
        updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    XCTAssertEqual(state.displayPercent, 250)
    XCTAssertEqual(state.configuredGain, 2.5, accuracy: 0.001)
    XCTAssertTrue(state.isRunning)
}
```

- [ ] **Step 2: Run the failing tests**

Run:

```bash
cd spike/core-audio-tap
xcodebuild \
  -project CoreAudioTapPoC.xcodeproj \
  -scheme CoreAudioTapPoC \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:CoreAudioTapPoCTests/GainProcessorTests/testRemoteControlClampsGainCommands \
  -only-testing:CoreAudioTapPoCTests/GainProcessorTests/testRemoteControlCommandRoundTripsThroughJSON \
  -only-testing:CoreAudioTapPoCTests/GainProcessorTests/testRemoteStateContainsOnlyExtensionSafeFields \
  test
```

Expected: FAIL because `HazakuraAmpRemoteCommand` and `HazakuraAmpRemoteState` do not exist.

- [ ] **Step 3: Implement the models**

Create `RemoteControlModels.swift`:

```swift
import Foundation

enum HazakuraAmpRemoteCommandKind: String, Codable, Equatable {
    case setGain
    case requestStart
    case requestState
}

struct HazakuraAmpRemoteCommand: Codable, Equatable, Identifiable {
    let id: UUID
    let kind: HazakuraAmpRemoteCommandKind
    let gain: Double?
    let createdAt: Date

    static func setGain(_ gain: Double) -> HazakuraAmpRemoteCommand {
        HazakuraAmpRemoteCommand(id: UUID(), kind: .setGain, gain: gain, createdAt: Date())
    }

    static func requestStart() -> HazakuraAmpRemoteCommand {
        HazakuraAmpRemoteCommand(id: UUID(), kind: .requestStart, gain: nil, createdAt: Date())
    }

    static func requestState() -> HazakuraAmpRemoteCommand {
        HazakuraAmpRemoteCommand(id: UUID(), kind: .requestState, gain: nil, createdAt: Date())
    }

    var sanitizedGain: Double? {
        guard let gain else { return nil }
        return Self.clampGain(gain)
    }

    static func clampGain(_ gain: Double) -> Double {
        guard gain.isFinite else { return 1.0 }
        return min(4.0, max(0.0, gain))
    }
}

struct HazakuraAmpRemoteState: Codable, Equatable {
    let configuredGain: Double
    let isRunning: Bool
    let statusText: String
    let lastError: String?
    let updatedAt: Date

    var displayPercent: Int {
        Int((configuredGain * 100).rounded())
    }
}
```

- [ ] **Step 4: Run the model tests**

Run the same `xcodebuild ... -only-testing` command from Step 2.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add spike/core-audio-tap/CoreAudioTapPoC/RemoteControl/RemoteControlModels.swift spike/core-audio-tap/CoreAudioTapPoCTests/GainProcessorTests.swift
git commit -m "Add Hazakura Amp remote command models"
```

## Task 2: File-Backed Remote Store

**Files:**
- Create: `spike/core-audio-tap/CoreAudioTapPoC/RemoteControl/RemoteControlStore.swift`
- Modify: `spike/core-audio-tap/CoreAudioTapPoCTests/GainProcessorTests.swift`

- [ ] **Step 1: Write failing store tests**

Append:

```swift
func testRemoteControlStorePersistsCommandsAndClearsInbox() throws {
    let directory = temporaryDirectory()
    let store = HazakuraAmpRemoteControlStore(baseDirectory: directory)

    let command = HazakuraAmpRemoteCommand.setGain(1.6)
    try store.enqueue(command)

    let commands = try store.drainCommands()

    XCTAssertEqual(commands, [command])
    XCTAssertTrue(try store.drainCommands().isEmpty)
}

func testRemoteControlStoreWritesAndReadsState() throws {
    let directory = temporaryDirectory()
    let store = HazakuraAmpRemoteControlStore(baseDirectory: directory)
    let state = HazakuraAmpRemoteState(
        configuredGain: 1.8,
        isRunning: false,
        statusText: "stopped",
        lastError: "System audio access was denied",
        updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    try store.writeState(state)

    XCTAssertEqual(try store.readState(), state)
}

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
```

- [ ] **Step 2: Run failing store tests**

Run:

```bash
cd spike/core-audio-tap
xcodebuild \
  -project CoreAudioTapPoC.xcodeproj \
  -scheme CoreAudioTapPoC \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:CoreAudioTapPoCTests/GainProcessorTests/testRemoteControlStorePersistsCommandsAndClearsInbox \
  -only-testing:CoreAudioTapPoCTests/GainProcessorTests/testRemoteControlStoreWritesAndReadsState \
  test
```

Expected: FAIL because `HazakuraAmpRemoteControlStore` does not exist.

- [ ] **Step 3: Implement the store**

Create:

```swift
import Foundation

struct HazakuraAmpRemoteControlStore {
    let baseDirectory: URL

    private var commandsDirectory: URL {
        baseDirectory.appendingPathComponent("commands", isDirectory: true)
    }

    private var stateURL: URL {
        baseDirectory.appendingPathComponent("state.json")
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func appGroupStore() throws -> HazakuraAmpRemoteControlStore {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.hazakura-amp") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return HazakuraAmpRemoteControlStore(baseDirectory: url.appendingPathComponent("RemoteControl", isDirectory: true))
    }

    func enqueue(_ command: HazakuraAmpRemoteCommand) throws {
        try FileManager.default.createDirectory(at: commandsDirectory, withIntermediateDirectories: true)
        let url = commandsDirectory.appendingPathComponent("\(command.createdAt.timeIntervalSince1970)-\(command.id.uuidString).json")
        try encoder.encode(command).write(to: url, options: [.atomic])
    }

    func drainCommands() throws -> [HazakuraAmpRemoteCommand] {
        try FileManager.default.createDirectory(at: commandsDirectory, withIntermediateDirectories: true)
        let urls = try FileManager.default.contentsOfDirectory(
            at: commandsDirectory,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        var commands: [HazakuraAmpRemoteCommand] = []
        for url in urls where url.pathExtension == "json" {
            let data = try Data(contentsOf: url)
            commands.append(try decoder.decode(HazakuraAmpRemoteCommand.self, from: data))
            try FileManager.default.removeItem(at: url)
        }
        return commands
    }

    func writeState(_ state: HazakuraAmpRemoteState) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try encoder.encode(state).write(to: stateURL, options: [.atomic])
    }

    func readState() throws -> HazakuraAmpRemoteState? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        let data = try Data(contentsOf: stateURL)
        return try decoder.decode(HazakuraAmpRemoteState.self, from: data)
    }
}
```

- [ ] **Step 4: Run store tests**

Run the same `xcodebuild ... -only-testing` command from Step 2.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add spike/core-audio-tap/CoreAudioTapPoC/RemoteControl/RemoteControlStore.swift spike/core-audio-tap/CoreAudioTapPoCTests/GainProcessorTests.swift
git commit -m "Add remote control file store"
```

## Task 3: App-Side Bridge

**Files:**
- Create: `spike/core-audio-tap/CoreAudioTapPoC/RemoteControl/RemoteControlBridge.swift`
- Modify: `spike/core-audio-tap/CoreAudioTapPoC/Audio/PoCAudioEngine.swift`
- Modify: `spike/core-audio-tap/CoreAudioTapPoC/CoreAudioTapPoCApp.swift`
- Modify: `spike/core-audio-tap/CoreAudioTapPoCTests/GainProcessorTests.swift`

- [ ] **Step 1: Write failing engine command tests**

Append:

```swift
@MainActor
func testRemoteSetGainCommandUpdatesConfiguredGain() async throws {
    let backend = FakeAudioProcessingBackend()
    let engine = PoCAudioEngine(audioBackend: backend, monitorsOutputDeviceChanges: false)

    engine.applyRemoteCommand(.setGain(2.4))

    XCTAssertEqual(engine.configuredGain, 2.4, accuracy: 0.001)
    XCTAssertFalse(engine.isRunning)
}

@MainActor
func testRemoteStartCommandStartsExistingPipeline() async throws {
    let backend = FakeAudioProcessingBackend()
    let engine = PoCAudioEngine(audioBackend: backend, monitorsOutputDeviceChanges: false)

    await engine.applyRemoteCommandAsync(.requestStart())

    XCTAssertTrue(backend.didStart)
    XCTAssertTrue(engine.isRunning)
}

@MainActor
func testRemoteStateReflectsEngineStatus() throws {
    let backend = FakeAudioProcessingBackend()
    let engine = PoCAudioEngine(audioBackend: backend, monitorsOutputDeviceChanges: false)

    engine.configuredGain = 1.7

    let state = engine.remoteState(now: Date(timeIntervalSince1970: 1_800_000_000))

    XCTAssertEqual(state.configuredGain, 1.7, accuracy: 0.001)
    XCTAssertFalse(state.isRunning)
    XCTAssertEqual(state.statusText, "idle")
}
```

- [ ] **Step 2: Run failing engine command tests**

Run:

```bash
cd spike/core-audio-tap
xcodebuild \
  -project CoreAudioTapPoC.xcodeproj \
  -scheme CoreAudioTapPoC \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:CoreAudioTapPoCTests/GainProcessorTests/testRemoteSetGainCommandUpdatesConfiguredGain \
  -only-testing:CoreAudioTapPoCTests/GainProcessorTests/testRemoteStartCommandStartsExistingPipeline \
  -only-testing:CoreAudioTapPoCTests/GainProcessorTests/testRemoteStateReflectsEngineStatus \
  test
```

Expected: FAIL because the remote engine API does not exist.

- [ ] **Step 3: Add the engine remote API**

Add to `PoCAudioEngine`:

```swift
func applyRemoteCommand(_ command: HazakuraAmpRemoteCommand) {
    switch command.kind {
    case .setGain:
        configuredGain = command.sanitizedGain ?? 1.0
    case .requestStart:
        start()
    case .requestState:
        diagnosticLog.record(.info, "Remote state requested")
    }
}

func applyRemoteCommandAsync(_ command: HazakuraAmpRemoteCommand) async {
    switch command.kind {
    case .setGain, .requestState:
        applyRemoteCommand(command)
    case .requestStart:
        await startAsync()
    }
}

func remoteState(now: Date = Date()) -> HazakuraAmpRemoteState {
    HazakuraAmpRemoteState(
        configuredGain: Self.sanitizedGain(configuredGain),
        isRunning: isRunning,
        statusText: statusText,
        lastError: lastError,
        updatedAt: now
    )
}
```

- [ ] **Step 4: Add the polling bridge**

Create `RemoteControlBridge.swift`:

```swift
import Foundation
import os.log

@MainActor
final class HazakuraAmpRemoteControlBridge {
    private let engine: PoCAudioEngine
    private let store: HazakuraAmpRemoteControlStore
    private let interval: TimeInterval
    private let log = Logger(subsystem: "dev.hazakura-amp", category: "RemoteControl")
    private var timer: Timer?

    init(engine: PoCAudioEngine, store: HazakuraAmpRemoteControlStore, interval: TimeInterval = 0.25) {
        self.engine = engine
        self.store = store
        self.interval = interval
    }

    func start() {
        guard timer == nil else { return }
        writeCurrentState()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.processPendingCommands()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        writeCurrentState()
    }

    func processPendingCommands() {
        do {
            for command in try store.drainCommands() {
                engine.applyRemoteCommand(command)
            }
            writeCurrentState()
        } catch {
            log.error("Remote command processing failed: \(error.localizedDescription, privacy: .public)")
            engine.diagnosticLog.record(.warning, "Remote control bridge failed: \(error.localizedDescription)")
        }
    }

    private func writeCurrentState() {
        do {
            try store.writeState(engine.remoteState())
        } catch {
            log.error("Remote state write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
```

- [ ] **Step 5: Start the bridge in the app delegate**

Add a property to `CoreAudioTapPoCAppDelegate`:

```swift
private var remoteControlBridge: HazakuraAmpRemoteControlBridge?
```

At the end of `applicationDidFinishLaunching(_:)`, add:

```swift
do {
    let store = try HazakuraAmpRemoteControlStore.appGroupStore()
    let bridge = HazakuraAmpRemoteControlBridge(engine: engine, store: store)
    bridge.start()
    remoteControlBridge = bridge
    engine.diagnosticLog.record(.info, "Remote control bridge started")
} catch {
    engine.diagnosticLog.record(.warning, "Remote control bridge unavailable: \(error.localizedDescription)")
}
```

In `applicationWillTerminate(_:)`, before `releaseSingleInstanceLock()`, add:

```swift
remoteControlBridge?.stop()
remoteControlBridge = nil
```

- [ ] **Step 6: Run focused bridge tests**

Run the same `xcodebuild ... -only-testing` command from Step 2.

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add spike/core-audio-tap/CoreAudioTapPoC/Audio/PoCAudioEngine.swift spike/core-audio-tap/CoreAudioTapPoC/CoreAudioTapPoCApp.swift spike/core-audio-tap/CoreAudioTapPoC/RemoteControl/RemoteControlBridge.swift spike/core-audio-tap/CoreAudioTapPoCTests/GainProcessorTests.swift
git commit -m "Add app-side remote control bridge"
```

## Task 4: YouTube Extension Resources

**Files:**
- Create: `spike/core-audio-tap/YouTubeRemoteExtension/manifest.json`
- Create: `spike/core-audio-tap/YouTubeRemoteExtension/background.js`
- Create: `spike/core-audio-tap/YouTubeRemoteExtension/content.js`
- Create: `spike/core-audio-tap/YouTubeRemoteExtension/content.css`

- [ ] **Step 1: Create the manifest**

Create `manifest.json`:

```json
{
  "manifest_version": 3,
  "name": "Hazakura Amp YouTube Remote",
  "description": "A small YouTube overlay for Hazakura Amp boost and one-video repeat.",
  "version": "0.1.0",
  "permissions": ["nativeMessaging", "storage"],
  "host_permissions": ["https://www.youtube.com/*", "https://m.youtube.com/*"],
  "background": {
    "service_worker": "background.js"
  },
  "content_scripts": [
    {
      "matches": ["https://www.youtube.com/*", "https://m.youtube.com/*"],
      "js": ["content.js"],
      "css": ["content.css"],
      "run_at": "document_idle"
    }
  ]
}
```

- [ ] **Step 2: Create the background relay**

Create `background.js`:

```javascript
const runtime = globalThis.browser || globalThis.chrome;
const nativeApplication = "dev.hazakura-amp";

runtime.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || message.source !== "hazakura-amp-youtube") {
    return false;
  }

  runtime.runtime.sendNativeMessage(nativeApplication, message.payload, (response) => {
    const error = runtime.runtime.lastError;
    if (error) {
      sendResponse({
        ok: false,
        error: error.message || "Hazakura Amp is not reachable"
      });
      return;
    }

    sendResponse(response || { ok: true });
  });

  return true;
});
```

- [ ] **Step 3: Create the content script**

Create `content.js`:

```javascript
(() => {
  const runtime = globalThis.browser || globalThis.chrome;
  const rootId = "hazakura-amp-youtube-remote";
  const defaultState = {
    gain: 1,
    repeat: false,
    collapsed: false,
    status: "idle"
  };

  let state = { ...defaultState };
  let currentVideo = null;
  let sendTimer = null;

  function watchPageActive() {
    return location.hostname.includes("youtube.com") && location.pathname === "/watch";
  }

  function findVideo() {
    return document.querySelector("video.html5-main-video") || document.querySelector("video");
  }

  function setRepeat(enabled) {
    currentVideo = findVideo();
    if (currentVideo) {
      currentVideo.loop = enabled;
    }
  }

  function sendNative(payload) {
    return new Promise((resolve) => {
      runtime.runtime.sendMessage(
        { source: "hazakura-amp-youtube", payload },
        (response) => resolve(response || { ok: false, error: "No response from Hazakura Amp" })
      );
    });
  }

  function scheduleGainSend(gain) {
    clearTimeout(sendTimer);
    sendTimer = setTimeout(async () => {
      const response = await sendNative({ kind: "setGain", gain });
      updateStatus(response);
    }, 120);
  }

  function updateStatus(response) {
    const root = document.getElementById(rootId);
    if (!root) return;
    const status = root.querySelector("[data-hazakura-status]");
    if (!response || response.ok === false) {
      state.status = "not connected";
      status.textContent = response?.error || "Hazakura Amp not connected";
      root.dataset.state = "warning";
      return;
    }
    state.status = response.state?.isRunning ? "boosting" : "ready";
    status.textContent = state.status;
    root.dataset.state = response.state?.isRunning ? "active" : "idle";
  }

  function render() {
    if (!watchPageActive()) {
      document.getElementById(rootId)?.remove();
      return;
    }
    if (document.getElementById(rootId)) {
      setRepeat(state.repeat);
      return;
    }

    const root = document.createElement("section");
    root.id = rootId;
    root.dataset.state = "idle";
    root.innerHTML = `
      <button type="button" class="hazakura-amp-collapse" aria-label="Collapse Hazakura Amp remote">-</button>
      <div class="hazakura-amp-body">
        <div class="hazakura-amp-row">
          <span class="hazakura-amp-title">Hazakura Amp</span>
          <span class="hazakura-amp-status" data-hazakura-status>idle</span>
        </div>
        <label class="hazakura-amp-slider-label">
          <span>Boost</span>
          <output data-hazakura-value>100%</output>
          <input data-hazakura-slider type="range" min="0" max="400" step="1" value="100" aria-label="Hazakura Amp boost">
        </label>
        <label class="hazakura-amp-repeat">
          <input data-hazakura-repeat type="checkbox">
          <span>Repeat</span>
        </label>
      </div>
    `;

    document.documentElement.appendChild(root);

    const slider = root.querySelector("[data-hazakura-slider]");
    const output = root.querySelector("[data-hazakura-value]");
    const repeat = root.querySelector("[data-hazakura-repeat]");
    const collapse = root.querySelector(".hazakura-amp-collapse");

    slider.addEventListener("input", () => {
      const percent = Number(slider.value);
      state.gain = percent / 100;
      output.textContent = `${percent}%`;
      scheduleGainSend(state.gain);
    });

    repeat.addEventListener("change", () => {
      state.repeat = repeat.checked;
      setRepeat(state.repeat);
      runtime.storage.local.set({ hazakuraAmpRepeat: state.repeat });
    });

    collapse.addEventListener("click", () => {
      state.collapsed = !state.collapsed;
      root.classList.toggle("is-collapsed", state.collapsed);
      collapse.textContent = state.collapsed ? "+" : "-";
      runtime.storage.local.set({ hazakuraAmpCollapsed: state.collapsed });
    });

    runtime.storage.local.get(["hazakuraAmpRepeat", "hazakuraAmpCollapsed"], (stored) => {
      state.repeat = Boolean(stored.hazakuraAmpRepeat);
      state.collapsed = Boolean(stored.hazakuraAmpCollapsed);
      repeat.checked = state.repeat;
      root.classList.toggle("is-collapsed", state.collapsed);
      collapse.textContent = state.collapsed ? "+" : "-";
      setRepeat(state.repeat);
    });

    sendNative({ kind: "requestState" }).then(updateStatus);
  }

  function onNavigation() {
    currentVideo = null;
    setTimeout(render, 250);
  }

  document.addEventListener("yt-navigate-finish", onNavigation);
  setInterval(() => {
    render();
    setRepeat(state.repeat);
  }, 1000);
  render();
})();
```

- [ ] **Step 4: Create overlay CSS**

Create `content.css`:

```css
#hazakura-amp-youtube-remote {
  position: fixed;
  right: 18px;
  bottom: 92px;
  z-index: 2147483647;
  width: 260px;
  color: #f8fafc;
  background: rgba(17, 24, 39, 0.88);
  border: 1px solid rgba(255, 255, 255, 0.18);
  border-radius: 8px;
  box-shadow: 0 10px 28px rgba(0, 0, 0, 0.28);
  font: 13px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  backdrop-filter: blur(12px);
}

#hazakura-amp-youtube-remote .hazakura-amp-body {
  padding: 10px 12px 12px;
}

#hazakura-amp-youtube-remote.is-collapsed .hazakura-amp-body {
  display: none;
}

#hazakura-amp-youtube-remote .hazakura-amp-collapse {
  position: absolute;
  top: 6px;
  right: 6px;
  width: 22px;
  height: 22px;
  border: 0;
  border-radius: 6px;
  color: inherit;
  background: rgba(255, 255, 255, 0.12);
  cursor: pointer;
}

#hazakura-amp-youtube-remote .hazakura-amp-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding-right: 26px;
  margin-bottom: 8px;
}

#hazakura-amp-youtube-remote .hazakura-amp-title {
  font-weight: 650;
}

#hazakura-amp-youtube-remote .hazakura-amp-status {
  color: #a7f3d0;
  font-size: 12px;
}

#hazakura-amp-youtube-remote[data-state="warning"] .hazakura-amp-status {
  color: #fbbf24;
}

#hazakura-amp-youtube-remote .hazakura-amp-slider-label {
  display: grid;
  grid-template-columns: 1fr auto;
  gap: 6px 10px;
  align-items: center;
}

#hazakura-amp-youtube-remote input[type="range"] {
  grid-column: 1 / -1;
  width: 100%;
}

#hazakura-amp-youtube-remote .hazakura-amp-repeat {
  display: inline-flex;
  gap: 7px;
  align-items: center;
  margin-top: 8px;
}
```

- [ ] **Step 5: Verify static extension files**

Run:

```bash
python3 -m json.tool spike/core-audio-tap/YouTubeRemoteExtension/manifest.json >/tmp/hazakura-amp-manifest.json
rg -n "download|sponsor|adblock|Web Audio|playbackRate|subtitle|caption" spike/core-audio-tap/YouTubeRemoteExtension
```

Expected: the JSON command exits 0. The `rg` command exits 1 with no matches.

- [ ] **Step 6: Commit**

```bash
git add spike/core-audio-tap/YouTubeRemoteExtension
git commit -m "Add YouTube remote extension resources"
```

## Task 5: Safari Native Messaging Handler And Packaging

**Files:**
- Create: `spike/core-audio-tap/CoreAudioTapPoC/SafariWebExtensionHandler.swift`
- Modify: `spike/core-audio-tap/project.yml`
- Modify: `spike/core-audio-tap/CoreAudioTapPoC/Resources/HazakuraAmp.entitlements`

- [ ] **Step 1: Add App Group entitlement**

Add this key to `HazakuraAmp.entitlements`:

```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.dev.hazakura-amp</string>
</array>
```

- [ ] **Step 2: Create native messaging handler**

Create `SafariWebExtensionHandler.swift`:

```swift
import Foundation
import SafariServices
import os.log

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let log = Logger(subsystem: "dev.hazakura-amp", category: "SafariWebExtension")

    func beginRequest(with context: NSExtensionContext) {
        let response = handle(context: context)
        let item = NSExtensionItem()
        item.userInfo = [SFExtensionMessageKey: response]
        context.completeRequest(returningItems: [item])
    }

    private func handle(context: NSExtensionContext) -> [String: Any] {
        guard let item = context.inputItems.first as? NSExtensionItem,
              let message = item.userInfo?[SFExtensionMessageKey] as? [String: Any],
              let kind = message["kind"] as? String else {
            return ["ok": false, "error": "Invalid Hazakura Amp remote message"]
        }

        do {
            let store = try HazakuraAmpRemoteControlStore.appGroupStore()
            switch kind {
            case "setGain":
                let gain = message["gain"] as? Double ?? 1.0
                try store.enqueue(.setGain(gain))
            case "requestStart":
                try store.enqueue(.requestStart())
            case "requestState":
                break
            default:
                return ["ok": false, "error": "Unsupported Hazakura Amp remote command"]
            }

            let state = try store.readState()
            return [
                "ok": true,
                "state": [
                    "configuredGain": state?.configuredGain ?? 1.0,
                    "displayPercent": state?.displayPercent ?? 100,
                    "isRunning": state?.isRunning ?? false,
                    "statusText": state?.statusText ?? "app not running",
                    "lastError": state?.lastError as Any
                ]
            ]
        } catch {
            log.error("Safari extension handler failed: \(error.localizedDescription, privacy: .public)")
            return ["ok": false, "error": "Hazakura Amp is not ready"]
        }
    }
}
```

- [ ] **Step 3: Add the Safari Web Extension target to XcodeGen**

Add a target to `project.yml`:

```yaml
  HazakuraAmpSafariExtension:
    type: app-extension
    platform: macOS
    deploymentTarget: "26.0"
    productName: "Hazakura Amp Safari Extension"
    sources:
      - path: CoreAudioTapPoC/RemoteControl
      - path: CoreAudioTapPoC/SafariWebExtensionHandler.swift
    resources:
      - path: YouTubeRemoteExtension
    info:
      properties:
        CFBundleDisplayName: "Hazakura Amp Safari Extension"
        NSExtension:
          NSExtensionPointIdentifier: com.apple.Safari.web-extension
          NSExtensionPrincipalClass: "$(PRODUCT_MODULE_NAME).SafariWebExtensionHandler"
    entitlements:
      path: CoreAudioTapPoC/Resources/HazakuraAmp.entitlements
    dependencies:
      - sdk: SafariServices.framework
```

Add the extension target as a dependency of `CoreAudioTapPoC`:

```yaml
    dependencies:
      - target: HazakuraAmpSafariExtension
        embed: true
      - sdk: AudioToolbox.framework
      - sdk: AVFAudio.framework
      - sdk: CoreAudio.framework
      - sdk: CoreMedia.framework
      - sdk: ScreenCaptureKit.framework
      - sdk: AppKit.framework
      - sdk: SwiftUI.framework
```

- [ ] **Step 4: Regenerate the Xcode project**

Run:

```bash
cd spike/core-audio-tap
xcodegen generate
```

Expected: exits 0 and updates `CoreAudioTapPoC.xcodeproj`.

- [ ] **Step 5: Build the app target**

Run:

```bash
cd spike/core-audio-tap
xcodebuild \
  -project CoreAudioTapPoC.xcodeproj \
  -scheme CoreAudioTapPoC \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add spike/core-audio-tap/project.yml spike/core-audio-tap/CoreAudioTapPoC.xcodeproj spike/core-audio-tap/CoreAudioTapPoC/Resources/HazakuraAmp.entitlements spike/core-audio-tap/CoreAudioTapPoC/SafariWebExtensionHandler.swift
git commit -m "Wire Safari extension native messaging"
```

## Task 6: End-To-End Verification And Docs

**Files:**
- Modify: `spike/core-audio-tap/README.md`
- Modify: `docs/ROADMAP.md`

- [ ] **Step 1: Run the focused test suite**

Run:

```bash
cd spike/core-audio-tap
xcodebuild \
  -project CoreAudioTapPoC.xcodeproj \
  -scheme CoreAudioTapPoC \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  test
```

Expected: TEST SUCCEEDED.

- [ ] **Step 2: Run a Debug build**

Run:

```bash
cd spike/core-audio-tap
xcodebuild \
  -project CoreAudioTapPoC.xcodeproj \
  -scheme CoreAudioTapPoC \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual Safari smoke**

Run the app:

```bash
open "spike/core-audio-tap/build/Build/Products/Debug/Hazakura Amp.app"
```

Manual checks:

```text
[ ] Enable the Safari extension in Safari settings.
[ ] Open a normal YouTube watch page, for example https://www.youtube.com/watch?v=dQw4w9WgXcQ.
[ ] Confirm one Hazakura Amp floating bar appears.
[ ] Move Boost to 160% and confirm the app Dev diagnostics or audio behavior reflects the value.
[ ] Navigate to another video and confirm the bar remains single-instance.
[ ] Enable Repeat and confirm the same video restarts when it ends.
[ ] Disable Repeat and confirm normal ended behavior returns.
[ ] Confirm YouTube volume, captions, speed, playlist, queue, ads, and downloads are untouched.
```

- [ ] **Step 4: Document the feature state**

Add a short section to `spike/core-audio-tap/README.md`:

```markdown
## Safari YouTube Remote

Hazakura Amp includes a macOS-first Safari Web Extension companion for YouTube.
It shows a small floating bar with a 0-400% Boost slider and a one-video Repeat toggle.

Boost commands are sent to the native Hazakura Amp app. YouTube's own volume,
speed, captions, playlists, queue, ads, and downloads are not modified.
```

Add a roadmap note under the current product quality roadmap:

```markdown
- [ ] Safari YouTube Remote: prove the floating bar, native messaging bridge,
  and one-video repeat on macOS Safari without expanding into a general
  YouTube enhancer.
```

- [ ] **Step 5: Commit docs**

```bash
git add spike/core-audio-tap/README.md docs/ROADMAP.md
git commit -m "Document Safari YouTube remote"
```

## Plan Self-Review

- Spec coverage:
  - Floating bar: Task 4.
  - 0-400% boost: Tasks 1, 3, 4.
  - Native app owns audio: Tasks 2, 3, 5.
  - Repeat only: Task 4.
  - YouTube SPA resilience: Task 4.
  - Permissions and privacy: Tasks 4, 5, 6.
  - Verification: Task 6.
- Scope boundary:
  - No download support.
  - No Web Audio boost.
  - No YouTube enhancer features beyond one-video repeat.
- Command notes:
  - Use `xcodegen generate` before `xcodebuild` after editing `project.yml`.
  - Keep `./scripts/build_release_candidate.sh` for release artifacts, not ordinary local validation.
