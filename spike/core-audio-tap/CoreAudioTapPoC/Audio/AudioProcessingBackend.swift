//
//  AudioProcessingBackend.swift
//  CoreAudioTapPoC
//

import Foundation

struct AudioBackendDiagnostics: Equatable {
    var captureBufferCount: UInt64 = 0
    var renderCallCount: UInt64 = 0
    var lastObservedGain: Float = 0.0
    var availableFrames: Int = 0
    var underrunCount: UInt64 = 0
    var droppedFrameCount: UInt64 = 0
    var latestBufferFrameCount: Int = 0
}

protocol AudioProcessingBackend: AnyObject, Sendable {
    var diagnostics: AudioBackendDiagnostics { get }

    func start() async throws
    func stop()
    func setLinearGain(_ linearGain: Float)
}

final class AudioBackendMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var captureBuffers: UInt64 = 0
    private var renderCalls: UInt64 = 0
    private var currentLinearGain: Float = 1.0
    private var currentOutputGain: Float = 0.0
    private var currentAvailableFrames: Int = 0
    private var underruns: UInt64 = 0
    private var droppedFrames: UInt64 = 0
    private var latestBufferFrames: Int = 0

    var linearGain: Float {
        lock.withLock { currentLinearGain }
    }

    var outputGain: Float {
        lock.withLock { currentOutputGain }
    }

    var diagnostics: AudioBackendDiagnostics {
        lock.withLock {
            AudioBackendDiagnostics(
                captureBufferCount: captureBuffers,
                renderCallCount: renderCalls,
                lastObservedGain: currentOutputGain,
                availableFrames: currentAvailableFrames,
                underrunCount: underruns,
                droppedFrameCount: droppedFrames,
                latestBufferFrameCount: latestBufferFrames
            )
        }
    }

    func resetCounters() {
        lock.withLock {
            captureBuffers = 0
            renderCalls = 0
            currentAvailableFrames = 0
            underruns = 0
            droppedFrames = 0
            latestBufferFrames = 0
        }
    }

    func setLinearGain(_ gain: Float) {
        lock.withLock {
            currentLinearGain = gain
            currentOutputGain = max(0.0, gain)
        }
    }

    func markCaptureBuffer(frameCount: Int, droppedFrames: Int, availableFrames: Int) {
        lock.withLock {
            captureBuffers &+= 1
            latestBufferFrames = max(0, frameCount)
            self.droppedFrames &+= UInt64(max(0, droppedFrames))
            currentAvailableFrames = max(0, availableFrames)
        }
    }

    func markRenderCall(requestedFrames: Int, framesRead: Int, availableFrames: Int) {
        lock.withLock {
            renderCalls &+= 1
            if max(0, framesRead) < max(0, requestedFrames) {
                underruns &+= 1
            }
            currentAvailableFrames = max(0, availableFrames)
        }
    }
}
