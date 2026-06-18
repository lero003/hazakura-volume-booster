//
//  PoCAudioEngine.swift
//  CoreAudioTapPoC
//
//  SwiftUI から操作されるオーディオエンジンのオーケストレータ。
//
//  データフロー:
//    [他アプリの音声]
//      ↓ Core Audio process tap (muteBehavior=.muted で原音を止める)
//      ↓ ScreenCaptureKit audio
//      ↓ PCM ring buffer
//      ↓ AVAudioSourceNode (gain 適用)
//      ↓ default output device
//    [スピーカー / ヘッドホン]
//
//  状態:
//  - configuredGain: スライダーで設定された値（0.0〜4.0）。停止中も保持。
//  - effectiveGain:  backend に渡す目標ゲイン。
//
//  参照: docs/ARCHITECTURE.md / docs/TECH_SPIKE.md
//

import AudioToolbox
import Foundation
import os.log

protocol SystemTapControlling: AnyObject {
    var aggregateDeviceID: AudioObjectID { get }

    func setup() throws
    func teardown()
}

enum DiagnosticLogLevel: String, Equatable {
    case info
    case warning
    case error

    var label: String {
        switch self {
        case .info: "Info"
        case .warning: "Warn"
        case .error: "Error"
        }
    }
}

struct DiagnosticLogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let level: DiagnosticLogLevel
    let message: String
}

final class DiagnosticLogStore: ObservableObject {
    @Published private(set) var entries: [DiagnosticLogEntry] = []

    private let maxEntries: Int

    init(maxEntries: Int = 80) {
        self.maxEntries = max(1, maxEntries)
    }

    func record(_ level: DiagnosticLogLevel, _ message: String, timestamp: Date = Date()) {
        entries.append(DiagnosticLogEntry(timestamp: timestamp, level: level, message: message))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }
}

enum PoCAudioEngineStatus: String, CaseIterable {
    case idle
    case running
    case stopped
    case sleeping
    case waking
    case manualStartRequired = "manual start required"
    case restartRequired = "restart required"
    case permissionDenied = "permission denied"
    case error
}

@MainActor
final class PoCAudioEngine: ObservableObject {

    // MARK: - Published state

    /// スライダー設定値（0.0〜4.0 = 0%〜400%）。停止中も保持する。
    @Published var configuredGain: Double = 1.0 {
        didSet {
            let sanitized = Self.sanitizedGain(configuredGain)
            guard sanitized == configuredGain else {
                configuredGain = sanitized
                return
            }
            applyEffectiveGain()
        }
    }

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var statusText: String = "idle"

    // 診断用: capture/render backend の状態
    @Published private(set) var captureBufferCount: UInt64 = 0
    @Published private(set) var renderCallCount: UInt64 = 0
    @Published private(set) var lastObservedGain: Float = 0.0
    @Published private(set) var availableFrames: Int = 0
    @Published private(set) var underrunCount: UInt64 = 0
    @Published private(set) var droppedFrameCount: UInt64 = 0
    @Published private(set) var latestBufferFrameCount: Int = 0
    let diagnosticLog: DiagnosticLogStore

    // MARK: - Internals

    private let log = Logger(subsystem: "dev.keisetsu.hazakura-amp", category: "PoCAudioEngine")
    private let audioBackend: any AudioProcessingBackend
    private let backendFailureRelay: BackendFailureRelay
    private let outputDeviceMonitor = DefaultOutputDeviceMonitor()
    private let monitorsOutputDeviceChanges: Bool
    private let wakeRestoreDelayNanoseconds: UInt64
    private let wakeRestoreRetryDelaysNanoseconds: [UInt64]
    private var diagnosticTimer: Timer?
    private var startTask: Task<Void, Never>?
    private var wakeRestoreTask: Task<Void, Never>?
    private var hasReportedMissingCaptureBuffers = false
    private var hasReportedMissingRenderCalls = false
    private var sleepSnapshot: (configuredGain: Double, wasRunning: Bool)?

    init(
        diagnosticLog: DiagnosticLogStore = DiagnosticLogStore(),
        audioBackend: (any AudioProcessingBackend)? = nil,
        monitorsOutputDeviceChanges: Bool = true,
        wakeRestoreDelayNanoseconds: UInt64 = 1_000_000_000,
        wakeRestoreRetryDelaysNanoseconds: [UInt64] = [2_000_000_000, 5_000_000_000]
    ) {
        let relay = BackendFailureRelay()
        self.diagnosticLog = diagnosticLog
        self.backendFailureRelay = relay
        self.monitorsOutputDeviceChanges = monitorsOutputDeviceChanges
        self.wakeRestoreDelayNanoseconds = wakeRestoreDelayNanoseconds
        self.wakeRestoreRetryDelaysNanoseconds = wakeRestoreRetryDelaysNanoseconds
        self.audioBackend = audioBackend ?? BoostAudioPipeline(
            diagnosticLog: diagnosticLog,
            onBackendFailure: { [relay] message in
                relay.handle(message)
            }
        )
        diagnosticLog.record(.info, "Engine initialized")
        relay.engine = self
    }

    /// 現在の effective gain。UI 表示・IO proc 適用値はこれ。
    var effectiveGain: Double {
        guard isRunning else { return 1.0 }
        return Self.sanitizedGain(configuredGain)
    }

    var backendHealth: AudioBackendHealthAssessment {
        currentDiagnostics.healthAssessment
    }

    // MARK: - Public API

    func start() {
        wakeRestoreTask?.cancel()
        wakeRestoreTask = nil
        sleepSnapshot = nil
        startTask?.cancel()
        startTask = Task { [weak self] in
            await self?.startAsync()
        }
    }

    func startAsync() async {
        guard !isRunning else {
            log.warning("start() called while already running")
            diagnosticLog.record(.warning, "Start ignored because engine is already running")
            return
        }
        do {
            statusText = "starting audio pipeline…"
            diagnosticLog.record(.info, "Starting ScreenCaptureKit audio pipeline")
            try await audioBackend.start()

            isRunning = true
            applyEffectiveGain()

            lastError = nil
            statusText = "running"
            hasReportedMissingCaptureBuffers = false
            hasReportedMissingRenderCalls = false
            log.info("PoC engine started")
            diagnosticLog.record(.info, "Engine started")

            startDiagnosticTimer()
            startOutputDeviceMonitor()
        } catch {
            let errMsg = error.localizedDescription
            log.error("start() failed: \(errMsg, privacy: .public)")
            if Self.isPermissionDeniedError(error) {
                diagnosticLog.record(.warning, "System audio access denied: \(errMsg)")
                lastError = "System audio access was denied"
                statusText = PoCAudioEngineStatus.permissionDenied.rawValue
            } else {
                diagnosticLog.record(.error, errMsg)
                lastError = errMsg
                statusText = PoCAudioEngineStatus.error.rawValue
            }
            cleanupAfterFailure()
        }
    }

    func stop() {
        guard isRunning else { return }
        log.info("stop() called")
        diagnosticLog.record(.info, "Stopping engine")
        startTask?.cancel()
        startTask = nil
        wakeRestoreTask?.cancel()
        wakeRestoreTask = nil
        sleepSnapshot = nil
        diagnosticTimer?.invalidate()
        diagnosticTimer = nil
        outputDeviceMonitor.stop()

        audioBackend.setLinearGain(1.0)
        audioBackend.stop()

        isRunning = false
        statusText = PoCAudioEngineStatus.stopped.rawValue
        captureBufferCount = 0
        renderCallCount = 0
        lastObservedGain = 0.0
        availableFrames = 0
        underrunCount = 0
        droppedFrameCount = 0
        latestBufferFrameCount = 0
        hasReportedMissingCaptureBuffers = false
        hasReportedMissingRenderCalls = false
        diagnosticLog.record(.info, "Engine stopped and gain reset to neutral")
    }

    func shutdownForAppTermination() {
        log.info("shutdownForAppTermination() called")
        diagnosticLog.record(.info, "App termination requested; forcing neutral gain before shutdown")
        startTask?.cancel()
        startTask = nil
        wakeRestoreTask?.cancel()
        wakeRestoreTask = nil
        sleepSnapshot = nil
        diagnosticTimer?.invalidate()
        diagnosticTimer = nil
        outputDeviceMonitor.stop()
        audioBackend.setLinearGain(1.0)
        audioBackend.stop()
        isRunning = false
        statusText = PoCAudioEngineStatus.stopped.rawValue
        lastObservedGain = 0.0
        availableFrames = 0
        underrunCount = 0
        droppedFrameCount = 0
        latestBufferFrameCount = 0
        diagnosticLog.record(.info, "Termination shutdown finished")
    }

    func prepareForSleep() {
        guard isRunning else { return }
        sleepSnapshot = (configuredGain: configuredGain, wasRunning: true)
        startTask?.cancel()
        startTask = nil
        wakeRestoreTask?.cancel()
        wakeRestoreTask = nil
        diagnosticTimer?.invalidate()
        diagnosticTimer = nil
        outputDeviceMonitor.stop()
        audioBackend.setLinearGain(1.0)
        audioBackend.stop()
        isRunning = false
        resetDiagnostics()
        statusText = PoCAudioEngineStatus.sleeping.rawValue
        diagnosticLog.record(.info, "Sleep requested; output gain forced to 100% and audio pipeline stopped")
    }

    func restoreAfterWake() {
        wakeRestoreTask?.cancel()
        wakeRestoreTask = Task { [weak self] in
            guard let self else { return }
            let delay = self.wakeRestoreDelayNanoseconds
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            await self.restoreAfterWakeAsync()
        }
    }

    func restoreAfterWakeAsync() async {
        guard let snapshot = sleepSnapshot else {
            diagnosticLog.record(.info, "Wake detected with no active sleep snapshot")
            return
        }
        sleepSnapshot = nil
        configuredGain = snapshot.configuredGain
        guard snapshot.wasRunning else {
            statusText = PoCAudioEngineStatus.stopped.rawValue
            diagnosticLog.record(.info, "Wake detected; boost was not running before sleep")
            return
        }

        await restoreAudioAfterWakeWithRetries()
    }

    private func restoreAudioAfterWakeWithRetries() async {
        var attemptIndex = 0

        while true {
            do {
                statusText = attemptIndex == 0 ? PoCAudioEngineStatus.waking.rawValue : "waking retry \(attemptIndex)"
                diagnosticLog.record(.info, "Wake restore attempt \(attemptIndex + 1): restarting ScreenCaptureKit audio pipeline")
                try await audioBackend.start()

                isRunning = true
                applyEffectiveGain()

                lastError = nil
                statusText = PoCAudioEngineStatus.running.rawValue
                hasReportedMissingCaptureBuffers = false
                hasReportedMissingRenderCalls = false
                startDiagnosticTimer()
                startOutputDeviceMonitor()
                diagnosticLog.record(.info, "Wake restore finished")
                return
            } catch {
                let errMsg = error.localizedDescription
                log.error("wake restore attempt failed: \(errMsg, privacy: .public)")
                diagnosticLog.record(.warning, "Wake restore attempt \(attemptIndex + 1) failed: \(errMsg)")
                cleanupAfterFailure()

                guard attemptIndex < wakeRestoreRetryDelaysNanoseconds.count else {
                    lastError = nil
                    statusText = PoCAudioEngineStatus.manualStartRequired.rawValue
                    diagnosticLog.record(.warning, "Wake restore paused after \(attemptIndex + 1) attempts; manual Start required: \(errMsg)")
                    return
                }

                let delay = wakeRestoreRetryDelaysNanoseconds[attemptIndex]
                attemptIndex += 1
                if delay > 0 {
                    do {
                        try await Task.sleep(nanoseconds: delay)
                    } catch {
                        return
                    }
                }
            }
        }
    }

    func diagnosticSnapshotText() -> String {
        let diagnostics = audioBackend.diagnostics
        let percent = Int((configuredGain * 100).rounded())
        let health = diagnostics.healthAssessment
        let info = Bundle.main.infoDictionary ?? [:]
        let appVersion = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        let signingKind = info["HazakuraSigningKind"] as? String ?? "unknown"
        let manualStartRequired = statusText == PoCAudioEngineStatus.manualStartRequired.rawValue
        let entries = diagnosticLog.entries.suffix(20).map { entry in
            "[\(entry.level.label)] \(entry.message)"
        }.joined(separator: "\n")
        return """
        Hazakura Amp diagnostics
        appVersion: \(appVersion)
        build: \(build)
        signingKind: \(signingKind)
        status: \(statusText)
        manualStartRequired: \(manualStartRequired)
        running: \(isRunning)
        configuredGain: \(String(format: "%.2f", configuredGain))x (\(percent)%)
        effectiveGain: \(String(format: "%.2f", effectiveGain))x
        captureBufferCount: \(diagnostics.captureBufferCount)
        renderCallCount: \(diagnostics.renderCallCount)
        outputGain: \(String(format: "%.2f", diagnostics.lastObservedGain))x
        availableFrames: \(diagnostics.availableFrames)
        underrunCount: \(diagnostics.underrunCount)
        droppedFrameCount: \(diagnostics.droppedFrameCount)
        latestBufferFrameCount: \(diagnostics.latestBufferFrameCount)
        healthLevel: \(health.level.rawValue)
        health: \(health.summary)
        healthRecommendation: \(health.recommendation)
        lastError: \(lastError ?? "none")

        recentEvents:
        \(entries.isEmpty ? "none" : entries)
        """
    }

    // MARK: - Internals

    private func applyEffectiveGain() {
        let gain = Float(effectiveGain)
        audioBackend.setLinearGain(gain)
        if isRunning {
            diagnosticLog.record(.info, "Applied effective gain \(String(format: "%.2f", gain))x")
        }
    }

    private func cleanupAfterFailure() {
        diagnosticLog.record(.warning, "Cleaning up after startup failure")
        diagnosticTimer?.invalidate()
        diagnosticTimer = nil
        outputDeviceMonitor.stop()
        audioBackend.setLinearGain(1.0)
        audioBackend.stop()
        isRunning = false
        resetDiagnostics()
        diagnosticLog.record(.info, "Cleanup after failure finished")
    }

    private func startDiagnosticTimer() {
        diagnosticTimer?.invalidate()
        diagnosticTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let diagnostics = self.audioBackend.diagnostics
                self.captureBufferCount = diagnostics.captureBufferCount
                self.renderCallCount = diagnostics.renderCallCount
                self.lastObservedGain = diagnostics.lastObservedGain
                self.availableFrames = diagnostics.availableFrames
                self.underrunCount = diagnostics.underrunCount
                self.droppedFrameCount = diagnostics.droppedFrameCount
                self.latestBufferFrameCount = diagnostics.latestBufferFrameCount
                if self.isRunning && diagnostics.captureBufferCount == 0 && !self.hasReportedMissingCaptureBuffers {
                    self.hasReportedMissingCaptureBuffers = true
                    self.diagnosticLog.record(.warning, "ScreenCaptureKit audio buffers have not arrived yet")
                }
                if self.isRunning && diagnostics.renderCallCount == 0 && !self.hasReportedMissingRenderCalls {
                    self.hasReportedMissingRenderCalls = true
                    self.diagnosticLog.record(.warning, "AVAudioEngine render callback has not been called yet")
                }
            }
        }
    }

    private static func sanitizedGain(_ gain: Double) -> Double {
        guard gain.isFinite else { return 1.0 }
        return min(4.0, max(0.0, gain))
    }

    private static func isPermissionDeniedError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let haystack = [
            nsError.domain,
            nsError.localizedDescription,
            nsError.localizedFailureReason ?? "",
            nsError.localizedRecoverySuggestion ?? "",
        ].joined(separator: " ").lowercased()

        return haystack.contains("permission")
            || haystack.contains("denied")
            || haystack.contains("not authorized")
            || haystack.contains("not authorised")
            || haystack.contains("not allowed")
            || haystack.contains("declined")
            || haystack.contains("許可")
            || haystack.contains("拒否")
            || haystack.contains("承認")
    }

    private func startOutputDeviceMonitor() {
        guard monitorsOutputDeviceChanges else { return }
        do {
            try outputDeviceMonitor.start { [weak self] in
                Task { @MainActor in
                    self?.handleRecoverableBackendFailure("Default output device changed; restart boost to continue safely")
                }
            }
            diagnosticLog.record(.info, "Default output device monitor started")
        } catch {
            diagnosticLog.record(.warning, "Default output device monitor unavailable: \(error.localizedDescription)")
        }
    }

    private var currentDiagnostics: AudioBackendDiagnostics {
        AudioBackendDiagnostics(
            captureBufferCount: captureBufferCount,
            renderCallCount: renderCallCount,
            lastObservedGain: lastObservedGain,
            availableFrames: availableFrames,
            underrunCount: underrunCount,
            droppedFrameCount: droppedFrameCount,
            latestBufferFrameCount: latestBufferFrameCount
        )
    }

    private func resetDiagnostics() {
        captureBufferCount = 0
        renderCallCount = 0
        lastObservedGain = 0.0
        availableFrames = 0
        underrunCount = 0
        droppedFrameCount = 0
        latestBufferFrameCount = 0
        hasReportedMissingCaptureBuffers = false
        hasReportedMissingRenderCalls = false
    }

    fileprivate func handleRecoverableBackendFailure(_ message: String) {
        guard isRunning else { return }
        log.error("Recoverable backend failure: \(message, privacy: .public)")
        diagnosticLog.record(.error, message)
        diagnosticLog.record(.warning, "Stopping engine safely; restart required")
        diagnosticTimer?.invalidate()
        diagnosticTimer = nil
        outputDeviceMonitor.stop()
        audioBackend.setLinearGain(1.0)
        audioBackend.stop()
        isRunning = false
        statusText = PoCAudioEngineStatus.restartRequired.rawValue
        lastError = message
        captureBufferCount = 0
        renderCallCount = 0
        lastObservedGain = 0.0
        availableFrames = 0
        underrunCount = 0
        droppedFrameCount = 0
        latestBufferFrameCount = 0
    }
}

private final class BackendFailureRelay: @unchecked Sendable {
    weak var engine: PoCAudioEngine?

    func handle(_ message: String) {
        Task { @MainActor [weak engine] in
            engine?.handleRecoverableBackendFailure(message)
        }
    }
}

private final class DefaultOutputDeviceMonitor: @unchecked Sendable {
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private let queue = DispatchQueue.main

    func start(onChange: @escaping @Sendable () -> Void) throws {
        stop()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            onChange()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )
        guard status == noErr else {
            throw NSError(
                domain: "DefaultOutputDeviceMonitor",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Could not observe default output changes (OSStatus=\(status))"]
            )
        }
        listenerBlock = block
    }

    func stop() {
        guard let listenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listenerBlock
        )
        self.listenerBlock = nil
    }

    deinit {
        stop()
    }
}
