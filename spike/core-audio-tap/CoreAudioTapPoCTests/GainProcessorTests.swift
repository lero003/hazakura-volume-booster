//
//  GainProcessorTests.swift
//  CoreAudioTapPoCTests
//
//  PoC のオーディオ IO proc は Obj-C++ 側にあり、ここから直接 unit test
//  するのは現実的でない。代わりにゲインの数式ヘルパ (GainProcessor.dB) を
//  テストして、ARCHITECTURE §3 の「linear 4.0 ≈ +12.04 dB」関係を保証する。
//

import XCTest
@testable import CoreAudioTapPoC

final class GainProcessorTests: XCTestCase {

    func testLinearOneMapsToZeroDB() {
        XCTAssertEqual(GainProcessor.dB(forLinear: 1.0), 0.0, accuracy: 0.001)
    }

    func testLinearTwoMapsToPositiveDB() {
        // 20 * log10(2) ≈ 6.02 dB
        XCTAssertEqual(GainProcessor.dB(forLinear: 2.0), 6.0206, accuracy: 0.01)
    }

    func testLinearFourMapsToTwicePositiveDB() {
        // 20 * log10(4) ≈ 12.04 dB
        XCTAssertEqual(GainProcessor.dB(forLinear: 4.0), 12.0412, accuracy: 0.01)
    }

    func testLinearZeroMapsToVeryNegativeDB() {
        // log10(0) 回避のフロア。 -120 dB 程度
        let db = GainProcessor.dB(forLinear: 0.0)
        XCTAssertLessThan(db, -100.0)
    }

    func testLimitedGainLeavesSafeSamplesUnchanged() {
        XCTAssertEqual(GainProcessor.applyLimitedGain(to: 0.25, gain: 2.0), 0.5, accuracy: 0.0001)
        XCTAssertEqual(GainProcessor.applyLimitedGain(to: -0.25, gain: 2.0), -0.5, accuracy: 0.0001)
    }

    func testLimitedGainPreventsOutputClipping() {
        XCTAssertLessThanOrEqual(GainProcessor.applyLimitedGain(to: 0.8, gain: 4.0), 1.0)
        XCTAssertGreaterThanOrEqual(GainProcessor.applyLimitedGain(to: -0.8, gain: 4.0), -1.0)
    }

    func testLimitedGainSoftensPeaksInsteadOfHardClipping() {
        let boosted = GainProcessor.applyLimitedGain(to: 0.75, gain: 2.0)

        XCTAssertLessThan(boosted, 1.0)
        XCTAssertGreaterThan(boosted, 0.9)
    }

    func testAudioPipelineLatencyBudgetKeepsTypicalScreenCaptureAudioChunk() {
        let typicalHundredMillisecondChunkAt48K = 4_800

        XCTAssertGreaterThanOrEqual(
            AudioPipelineTiming.latencyBudgetFrames,
            typicalHundredMillisecondChunkAt48K
        )
    }

    func testAudioPipelineRingCapacityHasJitterHeadroom() {
        XCTAssertGreaterThanOrEqual(
            AudioPipelineTiming.ringBufferCapacityFrames,
            AudioPipelineTiming.latencyBudgetFrames * 2
        )
    }

    func testDiagnosticLogStoreKeepsNewestEntriesWithinLimit() {
        let store = DiagnosticLogStore(maxEntries: 3)

        store.record(.info, "first")
        store.record(.warning, "second")
        store.record(.error, "third")
        store.record(.info, "fourth")

        XCTAssertEqual(store.entries.map(\.message), ["second", "third", "fourth"])
        XCTAssertEqual(store.entries.map(\.level), [.warning, .error, .info])
    }

    func testDiagnosticLogStoreCanBeCleared() {
        let store = DiagnosticLogStore(maxEntries: 3)

        store.record(.error, "AudioIOProc start failed")
        store.clear()

        XCTAssertTrue(store.entries.isEmpty)
    }

    func testInfoPlistDocumentsSystemAudioCaptureWithoutMicrophoneAccess() throws {
        let plist = try loadInfoPlist()

        let audioDescription = try XCTUnwrap(plist["NSAudioCaptureUsageDescription"] as? String)
        XCTAssertTrue(audioDescription.contains("Hazakura Amp uses"))
        XCTAssertFalse(audioDescription.contains("Hazakura Amp!"))
        XCTAssertTrue(audioDescription.contains("system audio output"))
        XCTAssertTrue(audioDescription.contains("does not record, store, or transmit audio"))
        XCTAssertNil(plist["NSMicrophoneUsageDescription"])
    }

    func testInfoPlistUsesV031ReleaseVersion() throws {
        let plist = try loadInfoPlist()

        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, "0.3.1")
        XCTAssertEqual(plist["CFBundleVersion"] as? String, "4")
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "Hazakura Amp")
        XCTAssertFalse((plist["CFBundleDisplayName"] as? String)?.contains("!") ?? true)
    }

    func testXcodeBrandingUsesHazakuraAmpBundleIdentity() throws {
        let projectDefinition = try String(
            contentsOfFile: repositoryFile("spike/core-audio-tap/project.yml"),
            encoding: .utf8
        )
        let scheme = try String(
            contentsOfFile: repositoryFile("spike/core-audio-tap/CoreAudioTapPoC.xcodeproj/xcshareddata/xcschemes/CoreAudioTapPoC.xcscheme"),
            encoding: .utf8
        )
        let projectFile = try String(
            contentsOfFile: repositoryFile("spike/core-audio-tap/CoreAudioTapPoC.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )

        XCTAssertTrue(projectDefinition.contains("PRODUCT_BUNDLE_IDENTIFIER: dev.keisetsu.hazakura-amp"))
        XCTAssertTrue(projectDefinition.contains("CODE_SIGN_ENTITLEMENTS: CoreAudioTapPoC/Resources/HazakuraAmp.entitlements"))
        XCTAssertFalse(projectDefinition.contains("dev.keisetsu.hazakura-volume-booster"))
        XCTAssertFalse(projectDefinition.contains("CoreAudioTapPoC.entitlements"))
        XCTAssertTrue(projectFile.contains("path = \"Hazakura Amp.app\""))
        XCTAssertFalse(projectFile.contains("path = CoreAudioTapPoC.app"))
        XCTAssertTrue(scheme.contains("BuildableName = \"Hazakura Amp.app\""))
        XCTAssertFalse(scheme.contains("BuildableName = \"CoreAudioTapPoC.app\""))
    }

    func testReleaseCandidateScriptUsesVersionedZipName() throws {
        let source = try String(
            contentsOfFile: repositoryFile("spike/core-audio-tap/scripts/build_release_candidate.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("CFBundleShortVersionString"))
        XCTAssertTrue(source.contains("HazakuraAmp-v${APP_VERSION}-developer-id.zip"))
    }

    func testContentViewSourceKeepsOnlyEssentialBoostControls() throws {
        let source = try String(
            contentsOfFile: repositoryFile("spike/core-audio-tap/CoreAudioTapPoC/ContentView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".accessibilityLabel(\"Boost level\")"))
        XCTAssertTrue(source.contains(".accessibilityValue(gainAccessibilityValue)"))
        XCTAssertTrue(source.contains(".accessibilityLabel(startStopAccessibilityLabel)"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Quit Hazakura Amp\")"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Developer diagnostics\")"))
        XCTAssertFalse(source.contains("100%に戻す"))
        XCTAssertFalse(source.contains("Toggle(\"ON\""))
        XCTAssertFalse(source.contains("presetButton("))
        XCTAssertFalse(source.contains("Button(\"0%\""))
        XCTAssertFalse(source.contains("Button(\"100%\""))
        XCTAssertFalse(source.contains("Button(\"200%\""))
        XCTAssertFalse(source.contains("Button(\"400%\""))
    }

    func testStatusPresentationGivesActionableMessagesForStoppedStates() {
        let manual = BoostStatusPresentation.make(
            statusText: "manual start required",
            isRunning: false,
            lastError: nil
        )
        XCTAssertEqual(manual.headline, "復帰後に開始が必要です")
        XCTAssertEqual(manual.detail, "開始を押してオーディオ経路を再接続してください。")
        XCTAssertEqual(manual.severity, .notice)
        XCTAssertFalse(manual.showsErrorBanner)

        let permission = BoostStatusPresentation.make(
            statusText: "permission denied",
            isRunning: false,
            lastError: "System audio access was denied"
        )
        XCTAssertEqual(permission.headline, "システム音声へのアクセスが許可されていません")
        XCTAssertEqual(permission.severity, .warning)
        XCTAssertTrue(permission.detail.contains("システム設定"))
        XCTAssertTrue(permission.detail.contains("プライバシーとセキュリティ"))
        XCTAssertTrue(permission.detail.contains("開始"))

        let restart = BoostStatusPresentation.make(
            statusText: "restart required",
            isRunning: false,
            lastError: "Default output device changed"
        )
        XCTAssertEqual(restart.headline, "再開が必要です")
        XCTAssertEqual(restart.severity, .warning)
        XCTAssertTrue(restart.detail.contains("開始"))
    }

    @MainActor
    func testStartAppliesConfiguredGainAfterEngineBecomesRunning() async throws {
        let backend = FakeAudioProcessingBackend()
        let engine = PoCAudioEngine(audioBackend: backend, monitorsOutputDeviceChanges: false)

        engine.configuredGain = 2.0
        await engine.startAsync()

        XCTAssertTrue(backend.didStart)
        let lastGain = try XCTUnwrap(backend.appliedGains.last)
        XCTAssertEqual(lastGain, 2.0, accuracy: 0.001)
    }

    @MainActor
    func testPermissionDeniedStartFailureForcesNeutralAndStops() async throws {
        let backend = FakeAudioProcessingBackend()
        let engine = PoCAudioEngine(audioBackend: backend, monitorsOutputDeviceChanges: false)

        engine.configuredGain = 3.0
        backend.queuedStartErrors = [
            FakeAudioProcessingBackend.makeError("System audio capture permission denied")
        ]

        await engine.startAsync()

        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(engine.statusText, "permission denied")
        XCTAssertEqual(engine.lastError, "System audio access was denied")
        XCTAssertTrue(backend.didStop)
        XCTAssertEqual(backend.appliedGains.last, 1.0)
    }

    @MainActor
    func testDiagnosticSnapshotIncludesReportContext() async throws {
        let log = DiagnosticLogStore()
        let backend = FakeAudioProcessingBackend()
        backend.diagnostics = AudioBackendDiagnostics(
            captureBufferCount: 8_426,
            renderCallCount: 15_809,
            lastObservedGain: 2.0,
            availableFrames: 1_920,
            underrunCount: 30,
            droppedFrameCount: 0,
            latestBufferFrameCount: 960
        )
        let engine = PoCAudioEngine(
            diagnosticLog: log,
            audioBackend: backend,
            monitorsOutputDeviceChanges: false
        )

        engine.configuredGain = 2.0
        await engine.startAsync()
        log.record(.warning, "Wake restore paused after 3 attempts; manual Start required")

        let snapshot = engine.diagnosticSnapshotText()

        XCTAssertTrue(snapshot.contains("appVersion:"))
        XCTAssertTrue(snapshot.contains("build:"))
        XCTAssertTrue(snapshot.contains("signingKind:"))
        XCTAssertTrue(snapshot.contains("status: running"))
        XCTAssertTrue(snapshot.contains("manualStartRequired: false"))
        XCTAssertTrue(snapshot.contains("captureBufferCount: 8426"))
        XCTAssertEqual(engine.captureBufferCount, 0)
        XCTAssertTrue(snapshot.contains("health:"))
        XCTAssertTrue(snapshot.contains("healthLevel:"))
        XCTAssertTrue(snapshot.contains("recentEvents:"))
        XCTAssertTrue(snapshot.contains("manual Start required"))
    }

    @MainActor
    func testStopResetsBackendGainAndStops() async throws {
        let backend = FakeAudioProcessingBackend()
        let engine = PoCAudioEngine(audioBackend: backend, monitorsOutputDeviceChanges: false)

        engine.configuredGain = 3.0
        await engine.startAsync()
        engine.stop()

        XCTAssertTrue(backend.didStop)
        let lastGain = try XCTUnwrap(backend.appliedGains.last)
        XCTAssertEqual(lastGain, 1.0, accuracy: 0.001)
    }

    @MainActor
    func testEffectiveGainSupportsAttenuationBelowNeutral() async throws {
        let backend = FakeAudioProcessingBackend()
        let engine = PoCAudioEngine(audioBackend: backend, monitorsOutputDeviceChanges: false)

        engine.configuredGain = 0.25
        await engine.startAsync()

        XCTAssertEqual(engine.effectiveGain, 0.25, accuracy: 0.001)
        let lastGain = try XCTUnwrap(backend.appliedGains.last)
        XCTAssertEqual(lastGain, 0.25, accuracy: 0.001)
    }

    func testAudioBackendMeterUsesConfiguredGainAfterOriginalOutputIsMuted() {
        let meter = AudioBackendMeter()

        meter.setLinearGain(4.0)

        XCTAssertEqual(meter.outputGain, 4.0, accuracy: 0.001)
        XCTAssertEqual(meter.diagnostics.lastObservedGain, 4.0, accuracy: 0.001)
    }

    func testAudioBackendMeterReportsBufferHealthDiagnostics() {
        let meter = AudioBackendMeter()

        meter.markCaptureBuffer(frameCount: 480, droppedFrames: 3, availableFrames: 320)
        meter.markRenderCall(requestedFrames: 512, framesRead: 128, availableFrames: 0)

        let diagnostics = meter.diagnostics
        XCTAssertEqual(diagnostics.captureBufferCount, 1)
        XCTAssertEqual(diagnostics.renderCallCount, 1)
        XCTAssertEqual(diagnostics.availableFrames, 0)
        XCTAssertEqual(diagnostics.underrunCount, 1)
        XCTAssertEqual(diagnostics.droppedFrameCount, 3)
        XCTAssertEqual(diagnostics.latestBufferFrameCount, 480)
    }

    func testAudioBackendHealthIsOKWhenPlaybackHasNoUnderrunsOrDrops() {
        let diagnostics = AudioBackendDiagnostics(
            captureBufferCount: 500,
            renderCallCount: 1_000,
            availableFrames: 1_920,
            underrunCount: 0,
            droppedFrameCount: 0,
            latestBufferFrameCount: 960
        )

        let health = diagnostics.healthAssessment

        XCTAssertEqual(health.level, .ok)
        XCTAssertEqual(health.underrunRate, 0.0, accuracy: 0.0001)
    }

    func testAudioBackendHealthWatchesLowRateUnderrunsWithoutDrops() {
        let diagnostics = AudioBackendDiagnostics(
            captureBufferCount: 8_426,
            renderCallCount: 15_809,
            availableFrames: 1_920,
            underrunCount: 30,
            droppedFrameCount: 0,
            latestBufferFrameCount: 960
        )

        let health = diagnostics.healthAssessment

        XCTAssertEqual(health.level, .watch)
        XCTAssertEqual(health.underrunRate, 0.0019, accuracy: 0.0001)
        XCTAssertTrue(health.summary.contains("0.19%"))
    }

    func testAudioBackendHealthWarnsOnDroppedFrames() {
        let diagnostics = AudioBackendDiagnostics(
            captureBufferCount: 100,
            renderCallCount: 100,
            underrunCount: 0,
            droppedFrameCount: 1
        )

        let health = diagnostics.healthAssessment

        XCTAssertEqual(health.level, .warning)
        XCTAssertTrue(health.summary.contains("dropped 1"))
    }

    func testAudioBackendHealthWarnsOnHighUnderrunRate() {
        let diagnostics = AudioBackendDiagnostics(
            captureBufferCount: 100,
            renderCallCount: 1_000,
            underrunCount: 10,
            droppedFrameCount: 0
        )

        let health = diagnostics.healthAssessment

        XCTAssertEqual(health.level, .warning)
        XCTAssertEqual(health.underrunRate, 0.01, accuracy: 0.0001)
    }

    func testSystemTapDescriptionMutesOtherProcessesButExcludesThisApp() {
        let description = SystemTap.makeTapDescription(
            deviceUID: "test-output-device",
            excludingBundleID: "dev.keisetsu.hazakura-amp"
        )

        XCTAssertEqual(description.deviceUID, "test-output-device")
        XCTAssertEqual(description.bundleIDs, ["dev.keisetsu.hazakura-amp"])
        XCTAssertTrue(description.isExclusive)
        XCTAssertEqual(description.muteBehavior, .muted)
        XCTAssertTrue(description.isMixdown)
        XCTAssertFalse(description.isMono)
        XCTAssertTrue(description.isPrivate)
    }

    func testPCMFloatRingBufferReadsInterleavedSamplesInOrder() {
        let buffer = PCMFloatRingBuffer(capacityFrames: 4, channelCount: 2)

        buffer.writeInterleaved([0.1, 0.2, 0.3, 0.4], frameCount: 2, sourceChannelCount: 2)

        XCTAssertEqual(buffer.availableFrames, 2)
        XCTAssertEqual(buffer.readInterleaved(frameCount: 2, outputChannelCount: 2), [0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(buffer.availableFrames, 0)
    }

    func testPCMFloatRingBufferDropsOldestFramesWhenCapacityIsExceeded() {
        let buffer = PCMFloatRingBuffer(capacityFrames: 2, channelCount: 2)

        let result = buffer.writeInterleaved(
            [0.1, 0.2, 0.3, 0.4, 0.5, 0.6],
            frameCount: 3,
            sourceChannelCount: 2
        )

        XCTAssertEqual(result.droppedFrames, 1)
        XCTAssertEqual(result.latestBufferFrameCount, 3)
        XCTAssertEqual(result.availableFrames, 2)
        XCTAssertEqual(buffer.availableFrames, 2)
        XCTAssertEqual(buffer.readInterleaved(frameCount: 2, outputChannelCount: 2), [0.3, 0.4, 0.5, 0.6])
    }

    func testPCMFloatRingBufferCanTrimToMostRecentFrames() {
        let buffer = PCMFloatRingBuffer(capacityFrames: 4, channelCount: 2)

        buffer.writeInterleaved(
            [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8],
            frameCount: 4,
            sourceChannelCount: 2
        )

        let droppedFrames = buffer.trimToMostRecentFrames(2)

        XCTAssertEqual(droppedFrames, 2)
        XCTAssertEqual(buffer.availableFrames, 2)
        XCTAssertEqual(buffer.readInterleaved(frameCount: 2, outputChannelCount: 2), [0.5, 0.6, 0.7, 0.8])
    }

    @MainActor
    func testConfiguredGainSanitizesInvalidValues() {
        let backend = FakeAudioProcessingBackend()
        let engine = PoCAudioEngine(audioBackend: backend, monitorsOutputDeviceChanges: false)

        engine.configuredGain = .nan
        XCTAssertEqual(engine.configuredGain, 1.0, accuracy: 0.001)

        engine.configuredGain = 0.25
        XCTAssertEqual(engine.configuredGain, 0.25, accuracy: 0.001)

        engine.configuredGain = -1.0
        XCTAssertEqual(engine.configuredGain, 0.0, accuracy: 0.001)

        engine.configuredGain = 9.0
        XCTAssertEqual(engine.configuredGain, 4.0, accuracy: 0.001)
    }

    func testMenuBarStatusItemSourceSupportsRightClickQuit() throws {
        let source = try String(
            contentsOfFile: repositoryFile("spike/core-audio-tap/CoreAudioTapPoC/CoreAudioTapPoCApp.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("RightClickableStatusButton"))
        XCTAssertTrue(source.contains("rightMouseUp"))
        XCTAssertTrue(source.contains("quitMenu"))
        XCTAssertTrue(source.contains("NSApplication.shared.terminate(nil)"))
    }

    func testAppDelegateInstallsRemoteControlBridge() throws {
        let source = try String(
            contentsOfFile: repositoryFile("spike/core-audio-tap/CoreAudioTapPoC/CoreAudioTapPoCApp.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("HazakuraAmpRemoteControlBridge"))
        XCTAssertTrue(source.contains("HazakuraAmpRemoteControlStore.appGroupStore()"))
        XCTAssertTrue(source.contains("remoteControlBridge?.start()"))
        XCTAssertTrue(source.contains("remoteControlBridge?.stop()"))
    }

    func testYouTubeRemoteExtensionManifestStaysNarrow() throws {
        let manifest = try String(
            contentsOfFile: repositoryFile("spike/core-audio-tap/YouTubeRemoteExtension/manifest.json"),
            encoding: .utf8
        )

        XCTAssertTrue(manifest.contains("\"manifest_version\": 3"))
        XCTAssertTrue(manifest.contains("\"nativeMessaging\""))
        XCTAssertTrue(manifest.contains("\"storage\""))
        XCTAssertTrue(manifest.contains("\"*://*.youtube.com/*\""))
        XCTAssertTrue(manifest.contains("\"content.js\""))
        XCTAssertTrue(manifest.contains("\"content.css\""))
        XCTAssertFalse(manifest.contains("<all_urls>"))
    }

    func testYouTubeRemoteContentScriptUsesOnlyRepeatAndRemoteControls() throws {
        let source = try String(
            contentsOfFile: repositoryFile("spike/core-audio-tap/YouTubeRemoteExtension/content.js"),
            encoding: .utf8
        )
        let css = try String(
            contentsOfFile: repositoryFile("spike/core-audio-tap/YouTubeRemoteExtension/content.css"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("hazakura-amp-floating-bar"))
        XCTAssertTrue(source.contains("video.loop = repeatEnabled"))
        XCTAssertTrue(source.contains("setGain"))
        XCTAssertTrue(source.contains("requestState"))
        XCTAssertFalse(source.contains("AudioContext"))
        XCTAssertFalse(source.contains("webkitAudioContext"))
        XCTAssertFalse(source.contains("download"))
        XCTAssertTrue(css.contains(".hazakura-amp-floating-bar"))
    }

    func testShutdownSafetyVerificationScriptChecksForTapResidue() throws {
        let source = try String(
            contentsOfFile: repositoryFile("spike/core-audio-tap/scripts/verify_shutdown_safety.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("system_profiler SPAudioDataType"))
        XCTAssertTrue(source.contains("hazakura-amp"))
        XCTAssertTrue(source.contains("pgrep"))
        XCTAssertTrue(source.contains("PROCESS_NAME=\"${PROCESS_NAME:-Hazakura Amp}\""))
        XCTAssertFalse(source.contains("PROCESS_NAME=\"${PROCESS_NAME:-CoreAudioTapPoC}\""))
    }

    @MainActor
    func testShutdownForAppTerminationForcesNeutralBeforeStop() async throws {
        let backend = FakeAudioProcessingBackend()
        let engine = PoCAudioEngine(audioBackend: backend, monitorsOutputDeviceChanges: false)

        engine.configuredGain = 3.0
        await engine.startAsync()
        engine.shutdownForAppTermination()

        XCTAssertTrue(backend.didStop)
        XCTAssertEqual(backend.appliedGains.suffix(2), [3.0, 1.0])
        XCTAssertFalse(engine.isRunning)
    }

    @MainActor
    func testSleepPreparationStopsBackendAfterForcingNeutralAndPreservesConfiguredGain() async throws {
        let backend = FakeAudioProcessingBackend()
        let engine = PoCAudioEngine(audioBackend: backend, monitorsOutputDeviceChanges: false)

        engine.configuredGain = 2.5
        await engine.startAsync()
        engine.prepareForSleep()

        XCTAssertFalse(engine.isRunning)
        XCTAssertTrue(backend.didStop)
        XCTAssertEqual(engine.configuredGain, 2.5, accuracy: 0.001)
        XCTAssertEqual(backend.appliedGains.suffix(2), [2.5, 1.0])
        XCTAssertEqual(engine.statusText, "sleeping")
    }

    @MainActor
    func testWakeRestoreRestartsBackendWithSavedGain() async throws {
        let backend = FakeAudioProcessingBackend()
        let engine = PoCAudioEngine(
            audioBackend: backend,
            monitorsOutputDeviceChanges: false,
            wakeRestoreDelayNanoseconds: 0,
            wakeRestoreRetryDelaysNanoseconds: []
        )

        engine.configuredGain = 2.5
        await engine.startAsync()
        engine.prepareForSleep()
        await engine.restoreAfterWakeAsync()

        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(backend.startCount, 2)
        XCTAssertEqual(backend.stopCount, 1)
        XCTAssertEqual(engine.configuredGain, 2.5, accuracy: 0.001)
        XCTAssertEqual(backend.appliedGains.last, 2.5)
        XCTAssertEqual(engine.statusText, "running")
    }

    @MainActor
    func testWakeRestoreRetriesWhenFirstRestartFails() async throws {
        let backend = FakeAudioProcessingBackend()
        let engine = PoCAudioEngine(
            audioBackend: backend,
            monitorsOutputDeviceChanges: false,
            wakeRestoreDelayNanoseconds: 0,
            wakeRestoreRetryDelaysNanoseconds: [0]
        )

        engine.configuredGain = 2.5
        await engine.startAsync()
        engine.prepareForSleep()
        backend.queuedStartErrors = [FakeAudioProcessingBackend.makeError("wake start failed once")]

        await engine.restoreAfterWakeAsync()

        XCTAssertTrue(engine.isRunning)
        XCTAssertNil(engine.lastError)
        XCTAssertEqual(backend.startCount, 3)
        XCTAssertGreaterThanOrEqual(backend.stopCount, 2)
        XCTAssertEqual(backend.appliedGains.last, 2.5)
        XCTAssertEqual(engine.statusText, "running")
    }

    @MainActor
    func testWakeRestoreFallsBackToManualStartWhenRetriesFail() async throws {
        let backend = FakeAudioProcessingBackend()
        let engine = PoCAudioEngine(
            audioBackend: backend,
            monitorsOutputDeviceChanges: false,
            wakeRestoreDelayNanoseconds: 0,
            wakeRestoreRetryDelaysNanoseconds: [0, 0]
        )

        engine.configuredGain = 2.5
        await engine.startAsync()
        engine.prepareForSleep()
        backend.queuedStartErrors = [
            FakeAudioProcessingBackend.makeError("wake start failed 1"),
            FakeAudioProcessingBackend.makeError("wake start failed 2"),
            FakeAudioProcessingBackend.makeError("wake start failed 3"),
        ]

        await engine.restoreAfterWakeAsync()

        XCTAssertFalse(engine.isRunning)
        XCTAssertNil(engine.lastError)
        XCTAssertEqual(engine.statusText, "manual start required")
        XCTAssertEqual(engine.configuredGain, 2.5, accuracy: 0.001)
        XCTAssertEqual(backend.startCount, 4)
        XCTAssertGreaterThanOrEqual(backend.stopCount, 4)

        await engine.startAsync()

        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.statusText, "running")
        XCTAssertEqual(backend.appliedGains.last, 2.5)
    }

    @MainActor
    func testWakeRestoreDoesNotStartWhenNoSleepSnapshotExists() async {
        let backend = FakeAudioProcessingBackend()
        let engine = PoCAudioEngine(
            audioBackend: backend,
            monitorsOutputDeviceChanges: false,
            wakeRestoreDelayNanoseconds: 0,
            wakeRestoreRetryDelaysNanoseconds: []
        )

        await engine.restoreAfterWakeAsync()

        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(backend.startCount, 0)
    }

    @MainActor
    func testRemoteSetGainCommandUpdatesConfiguredGain() {
        let backend = FakeAudioProcessingBackend()
        let engine = PoCAudioEngine(audioBackend: backend, monitorsOutputDeviceChanges: false)

        engine.applyRemoteCommand(.setGain(2.4))

        XCTAssertEqual(engine.configuredGain, 2.4, accuracy: 0.001)
        XCTAssertFalse(engine.isRunning)
    }

    @MainActor
    func testRemoteStartCommandStartsExistingPipeline() async {
        let backend = FakeAudioProcessingBackend()
        let engine = PoCAudioEngine(audioBackend: backend, monitorsOutputDeviceChanges: false)

        await engine.applyRemoteCommandAsync(.requestStart())

        XCTAssertTrue(backend.didStart)
        XCTAssertTrue(engine.isRunning)
    }

    @MainActor
    func testRemoteStateReflectsEngineStatus() {
        let backend = FakeAudioProcessingBackend()
        let engine = PoCAudioEngine(audioBackend: backend, monitorsOutputDeviceChanges: false)

        engine.configuredGain = 1.7
        let state = engine.remoteState(now: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertEqual(state.configuredGain, 1.7, accuracy: 0.001)
        XCTAssertFalse(state.isRunning)
        XCTAssertEqual(state.statusText, "idle")
        XCTAssertNil(state.lastError)
        XCTAssertEqual(state.updatedAt, Date(timeIntervalSince1970: 1_800_000_000))
    }

    @MainActor
    func testRemoteControlBridgeDrainsCommandsAndPublishesState() async throws {
        let backend = FakeAudioProcessingBackend()
        let engine = PoCAudioEngine(audioBackend: backend, monitorsOutputDeviceChanges: false)
        let store = HazakuraAmpRemoteControlStore(baseDirectory: temporaryDirectory())
        let bridge = HazakuraAmpRemoteControlBridge(store: store, engine: engine)

        try store.enqueue(.setGain(2.1))
        try store.enqueue(.requestState())

        try await bridge.processPendingCommands()

        XCTAssertEqual(engine.configuredGain, 2.1, accuracy: 0.001)
        XCTAssertTrue(try store.drainCommands().isEmpty)
        let state = try XCTUnwrap(store.readState())
        XCTAssertEqual(state.configuredGain, 2.1, accuracy: 0.001)
        XCTAssertFalse(state.isRunning)
    }

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

    private func loadInfoPlist() throws -> [String: Any] {
        let path = repositoryFile("spike/core-audio-tap/CoreAudioTapPoC/Resources/Info.plist")
        return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: Any])
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func repositoryFile(_ relativePath: String) -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repositoryRoot.appendingPathComponent(relativePath).path
    }
}

private final class FakeAudioProcessingBackend: AudioProcessingBackend, @unchecked Sendable {
    private(set) var didStart = false
    private(set) var didStop = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var appliedGains: [Float] = []

    var diagnostics = AudioBackendDiagnostics()
    var queuedStartErrors: [Error] = []

    func start() async throws {
        didStart = true
        startCount += 1
        if !queuedStartErrors.isEmpty {
            throw queuedStartErrors.removeFirst()
        }
    }

    func stop() {
        didStop = true
        stopCount += 1
    }

    func setLinearGain(_ linearGain: Float) {
        appliedGains.append(linearGain)
    }

    static func makeError(_ message: String) -> NSError {
        NSError(
            domain: "FakeAudioProcessingBackend",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
