//
//  PCMFloatRingBuffer.swift
//  CoreAudioTapPoC
//

import AudioToolbox
import AVFAudio
import Foundation

final class PCMFloatRingBuffer: @unchecked Sendable {
    struct WriteResult: Equatable {
        let droppedFrames: Int
        let latestBufferFrameCount: Int
        let availableFrames: Int
    }

    private let lock = NSLock()
    private let capacityFrames: Int
    private let channelCount: Int
    private var storage: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var storedFrames = 0

    init(capacityFrames: Int, channelCount: Int) {
        self.capacityFrames = max(1, capacityFrames)
        self.channelCount = max(1, channelCount)
        self.storage = Array(repeating: 0.0, count: self.capacityFrames * self.channelCount)
    }

    var availableFrames: Int {
        lock.withLock { storedFrames }
    }

    @discardableResult
    func trimToMostRecentFrames(_ frameLimit: Int) -> Int {
        lock.withLock {
            trimToMostRecentFramesLocked(frameLimit)
        }
    }

    func clear() {
        lock.withLock {
            storage.replaceSubrange(storage.indices, with: repeatElement(0.0, count: storage.count))
            readIndex = 0
            writeIndex = 0
            storedFrames = 0
        }
    }

    @discardableResult
    func writeInterleaved(_ samples: [Float], frameCount: Int, sourceChannelCount: Int) -> WriteResult {
        samples.withUnsafeBufferPointer { source in
            writeInterleaved(source, frameCount: frameCount, sourceChannelCount: sourceChannelCount)
        }
    }

    @discardableResult
    func writeInterleaved(
        _ samples: UnsafeBufferPointer<Float>,
        frameCount: Int,
        sourceChannelCount: Int
    ) -> WriteResult {
        guard frameCount > 0, sourceChannelCount > 0, !samples.isEmpty else {
            return WriteResult(droppedFrames: 0, latestBufferFrameCount: 0, availableFrames: availableFrames)
        }

        return lock.withLock {
            let framesToWrite = min(frameCount, capacityFrames)
            var droppedFrames = max(0, frameCount - capacityFrames)
            if frameCount > capacityFrames {
                let skippedFrames = frameCount - capacityFrames
                writeFrames(
                    samples,
                    sourceStartFrame: skippedFrames,
                    frameCount: framesToWrite,
                    sourceChannelCount: sourceChannelCount
                )
            } else {
                let overflow = max(0, storedFrames + framesToWrite - capacityFrames)
                if overflow > 0 {
                    readIndex = (readIndex + overflow) % capacityFrames
                    storedFrames -= overflow
                    droppedFrames += overflow
                }
                writeFrames(
                    samples,
                    sourceStartFrame: 0,
                    frameCount: framesToWrite,
                    sourceChannelCount: sourceChannelCount
                )
            }
            return WriteResult(
                droppedFrames: droppedFrames,
                latestBufferFrameCount: frameCount,
                availableFrames: storedFrames
            )
        }
    }

    @discardableResult
    func write(fromAudioBufferList audioBufferList: UnsafePointer<AudioBufferList>, frameCount: Int) -> WriteResult {
        guard frameCount > 0 else {
            return WriteResult(droppedFrames: 0, latestBufferFrameCount: 0, availableFrames: availableFrames)
        }

        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        guard !buffers.isEmpty else {
            return WriteResult(droppedFrames: 0, latestBufferFrameCount: frameCount, availableFrames: availableFrames)
        }

        return lock.withLock {
            let framesToWrite = min(frameCount, capacityFrames)
            var droppedFrames = max(0, frameCount - capacityFrames)
            let overflow = max(0, storedFrames + framesToWrite - capacityFrames)
            if overflow > 0 {
                readIndex = (readIndex + overflow) % capacityFrames
                storedFrames -= overflow
                droppedFrames += overflow
            }

            let sourceStartFrame = max(0, frameCount - framesToWrite)
            for frameOffset in 0..<framesToWrite {
                let sourceFrame = sourceStartFrame + frameOffset
                let destinationFrame = writeIndex
                for channel in 0..<channelCount {
                    storage[index(frame: destinationFrame, channel: channel)] = sample(
                        in: buffers,
                        frame: sourceFrame,
                        channel: channel
                    )
                }
                writeIndex = (writeIndex + 1) % capacityFrames
                storedFrames += 1
            }
            return WriteResult(
                droppedFrames: droppedFrames,
                latestBufferFrameCount: frameCount,
                availableFrames: storedFrames
            )
        }
    }

    func readInterleaved(frameCount: Int, outputChannelCount: Int) -> [Float] {
        let requestedFrames = max(0, frameCount)
        let channels = max(1, outputChannelCount)
        var output = Array(repeating: Float(0.0), count: requestedFrames * channels)
        _ = output.withUnsafeMutableBufferPointer { pointer in
            readInterleaved(into: pointer, frameCount: requestedFrames, outputChannelCount: channels, gain: 1.0)
        }
        return output
    }

    @discardableResult
    func readInterleaved(
        into output: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        outputChannelCount: Int,
        gain: Float
    ) -> Int {
        guard frameCount > 0, outputChannelCount > 0 else { return 0 }

        return lock.withLock {
            let framesToRead = min(frameCount, storedFrames)
            output.initialize(repeating: 0.0)

            for frame in 0..<framesToRead {
                for channel in 0..<outputChannelCount {
                    let sourceChannel = min(channel, channelCount - 1)
                    output[(frame * outputChannelCount) + channel] =
                        GainProcessor.applyLimitedGain(
                            to: storage[index(frame: readIndex, channel: sourceChannel)],
                            gain: gain
                        )
                }
                readIndex = (readIndex + 1) % capacityFrames
                storedFrames -= 1
            }

            return framesToRead
        }
    }

    @discardableResult
    func read(
        into outputData: UnsafeMutablePointer<AudioBufferList>,
        frameCount: Int,
        gain: Float
    ) -> Int {
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
        guard frameCount > 0, !outputBuffers.isEmpty else { return 0 }

        return lock.withLock {
            zero(outputBuffers, frameCount: frameCount)

            let framesToRead = min(frameCount, storedFrames)
            for frame in 0..<framesToRead {
                if outputBuffers.count == 1 {
                    writeInterleavedOutput(outputBuffers[0], frame: frame, sourceFrame: readIndex, gain: gain)
                } else {
                    writePlanarOutput(outputBuffers, frame: frame, sourceFrame: readIndex, gain: gain)
                }
                readIndex = (readIndex + 1) % capacityFrames
                storedFrames -= 1
            }
            return framesToRead
        }
    }

    private func writeFrames(
        _ samples: UnsafeBufferPointer<Float>,
        sourceStartFrame: Int,
        frameCount: Int,
        sourceChannelCount: Int
    ) {
        for frameOffset in 0..<frameCount {
            let sourceFrame = sourceStartFrame + frameOffset
            for channel in 0..<channelCount {
                let sourceChannel = min(channel, sourceChannelCount - 1)
                let sourceIndex = (sourceFrame * sourceChannelCount) + sourceChannel
                storage[index(frame: writeIndex, channel: channel)] =
                    sourceIndex < samples.count ? samples[sourceIndex] : 0.0
            }
            writeIndex = (writeIndex + 1) % capacityFrames
            storedFrames = min(capacityFrames, storedFrames + 1)
        }
    }

    private func trimToMostRecentFramesLocked(_ frameLimit: Int) -> Int {
        let targetFrames = max(0, min(frameLimit, capacityFrames))
        guard storedFrames > targetFrames else { return 0 }

        let framesToDrop = storedFrames - targetFrames
        readIndex = (readIndex + framesToDrop) % capacityFrames
        storedFrames = targetFrames
        return framesToDrop
    }

    private func sample(
        in buffers: UnsafeMutableAudioBufferListPointer,
        frame: Int,
        channel: Int
    ) -> Float {
        if buffers.count == 1 {
            let buffer = buffers[0]
            let channels = max(1, Int(buffer.mNumberChannels))
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return 0.0 }
            return data[(frame * channels) + min(channel, channels - 1)]
        }

        let buffer = buffers[min(channel, buffers.count - 1)]
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return 0.0 }
        return data[frame]
    }

    private func zero(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        for index in buffers.indices {
            let channelCount = max(1, Int(buffers[index].mNumberChannels))
            let sampleCount = frameCount * channelCount
            if let data = buffers[index].mData?.assumingMemoryBound(to: Float.self) {
                data.initialize(repeating: 0.0, count: sampleCount)
            }
            buffers[index].mDataByteSize = UInt32(sampleCount * MemoryLayout<Float>.size)
        }
    }

    private func writeInterleavedOutput(
        _ buffer: AudioBuffer,
        frame: Int,
        sourceFrame: Int,
        gain: Float
    ) {
        let outputChannels = max(1, Int(buffer.mNumberChannels))
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
        for channel in 0..<outputChannels {
            let sourceChannel = min(channel, channelCount - 1)
            data[(frame * outputChannels) + channel] =
                GainProcessor.applyLimitedGain(
                    to: storage[index(frame: sourceFrame, channel: sourceChannel)],
                    gain: gain
                )
        }
    }

    private func writePlanarOutput(
        _ buffers: UnsafeMutableAudioBufferListPointer,
        frame: Int,
        sourceFrame: Int,
        gain: Float
    ) {
        for channel in buffers.indices {
            guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let sourceChannel = min(channel, channelCount - 1)
            data[frame] = GainProcessor.applyLimitedGain(
                to: storage[index(frame: sourceFrame, channel: sourceChannel)],
                gain: gain
            )
        }
    }

    private func index(frame: Int, channel: Int) -> Int {
        (frame * channelCount) + channel
    }
}
