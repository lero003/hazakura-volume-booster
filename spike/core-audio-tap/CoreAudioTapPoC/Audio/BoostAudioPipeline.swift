//
//  BoostAudioPipeline.swift
//  CoreAudioTapPoC
//

import AVFAudio
import Foundation

enum AudioPipelineTiming {
    static let ringBufferCapacityFrames = 16_384
    static let latencyBudgetFrames = 8_192
}

final class BoostAudioPipeline: AudioProcessingBackend, @unchecked Sendable {
    private let ringBuffer = PCMFloatRingBuffer(
        capacityFrames: AudioPipelineTiming.ringBufferCapacityFrames,
        channelCount: 2
    )
    private let meter = AudioBackendMeter()
    private let diagnosticLog: DiagnosticLogStore
    private let systemOutputMuter: any SystemTapControlling
    private let onBackendFailure: (@Sendable (String) -> Void)?
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var captureSource: ScreenCaptureAudioSource?

    var diagnostics: AudioBackendDiagnostics {
        meter.diagnostics
    }

    init(
        diagnosticLog: DiagnosticLogStore,
        systemOutputMuter: (any SystemTapControlling)? = nil,
        onBackendFailure: (@Sendable (String) -> Void)? = nil
    ) {
        self.diagnosticLog = diagnosticLog
        self.systemOutputMuter = systemOutputMuter ?? SystemTap(diagnosticLog: diagnosticLog)
        self.onBackendFailure = onBackendFailure
    }

    func start() async throws {
        stop()
        ringBuffer.clear()
        meter.resetCounters()

        do {
            diagnosticLog.record(.info, "Muting original system output with Core Audio process tap")
            try systemOutputMuter.setup()
        } catch {
            diagnosticLog.record(.error, "Original output mute setup failed: \(error.localizedDescription)")
            throw error
        }

        let audioEngine = AVAudioEngine()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let source = AVAudioSourceNode(format: format) { [ringBuffer, meter] isSilence, _, frameCount, outputData in
            let framesRead = ringBuffer.read(
                into: outputData,
                frameCount: Int(frameCount),
                gain: meter.outputGain
            )
            meter.markRenderCall(
                requestedFrames: Int(frameCount),
                framesRead: framesRead,
                availableFrames: ringBuffer.availableFrames
            )
            isSilence.pointee = ObjCBool(framesRead == 0 || meter.outputGain == 0.0)
            return noErr
        }

        audioEngine.attach(source)
        audioEngine.connect(source, to: audioEngine.mainMixerNode, format: format)
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            systemOutputMuter.teardown()
            throw error
        }

        let capture = ScreenCaptureAudioSource(
            ringBuffer: ringBuffer,
            meter: meter,
            diagnosticLog: diagnosticLog,
            onStoppedWithError: onBackendFailure
        )
        do {
            try await capture.start()
        } catch {
            audioEngine.stop()
            systemOutputMuter.teardown()
            throw error
        }

        engine = audioEngine
        sourceNode = source
        captureSource = capture
        diagnosticLog.record(.info, "Original output muted; boosted pipeline is now the audible path")
    }

    func stop() {
        captureSource?.stop()
        captureSource = nil
        engine?.stop()
        engine = nil
        sourceNode = nil
        systemOutputMuter.teardown()
        ringBuffer.clear()
        meter.resetCounters()
    }

    func setLinearGain(_ linearGain: Float) {
        meter.setLinearGain(linearGain)
    }
}
