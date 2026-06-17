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
    func testEffectiveGainDoesNotDropBelowNeutral() async {
        let backend = FakeAudioProcessingBackend()
        let engine = PoCAudioEngine(audioBackend: backend, monitorsOutputDeviceChanges: false)

        engine.configuredGain = 0.25
        await engine.startAsync()

        XCTAssertEqual(engine.effectiveGain, 1.0, accuracy: 0.001)
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
            excludingBundleID: "dev.keisetsu.hazakura-volume-booster.poc"
        )

        XCTAssertEqual(description.deviceUID, "test-output-device")
        XCTAssertEqual(description.bundleIDs, ["dev.keisetsu.hazakura-volume-booster.poc"])
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
        XCTAssertEqual(engine.configuredGain, 1.0, accuracy: 0.001)

        engine.configuredGain = 9.0
        XCTAssertEqual(engine.configuredGain, 4.0, accuracy: 0.001)
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
            wakeRestoreDelayNanoseconds: 0
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
    func testWakeRestoreDoesNotStartWhenNoSleepSnapshotExists() async {
        let backend = FakeAudioProcessingBackend()
        let engine = PoCAudioEngine(
            audioBackend: backend,
            monitorsOutputDeviceChanges: false,
            wakeRestoreDelayNanoseconds: 0
        )

        await engine.restoreAfterWakeAsync()

        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(backend.startCount, 0)
    }
}

private final class FakeAudioProcessingBackend: AudioProcessingBackend, @unchecked Sendable {
    private(set) var didStart = false
    private(set) var didStop = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var appliedGains: [Float] = []

    var diagnostics = AudioBackendDiagnostics()

    func start() async throws {
        didStart = true
        startCount += 1
    }

    func stop() {
        didStop = true
        stopCount += 1
    }

    func setLinearGain(_ linearGain: Float) {
        appliedGains.append(linearGain)
    }
}
