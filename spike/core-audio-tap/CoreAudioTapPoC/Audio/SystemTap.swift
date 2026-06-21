//
//  SystemTap.swift
//  CoreAudioTapPoC
//
//  Core Audio Tap と aggregate device をセットアップする PoC 用の薄いラッパ。
//
//  ポイント:
//  - tap は **default output device** に対して張る（システム出力をキャプチャ）
//  - aggregate device は **default output を sub-device として含める** ことで、
//    IO proc が output バッファへ書き戻せるようにする
//    （空の sub-device list だと録音しかできない。audiotee と同じ罠）
//  - muteBehavior = .muted にし、tap 元の音を黙らして二重再生を防ぐ
//    （IO proc 側で必ず同じ音量を出力する責任を持つ）
//  - **kAudioAggregateDeviceTapAutoStartKey = true** を指定し、aggregate 起動時に
//    tap も自動で start する。これがないと IO proc を張ろうとしても
//    'naci' (1852797029) 系のエラーが出ることがある
//  - ループバックを成立させるため、セットアップ後に aggregate device を
//    **新しい default output device** に設定する。終了時は必ず元のデバイスに戻す。
//
//  参照:
//  - https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps
//  - Apple サンプル AudioRecorder.mm および AggregateDevice.swift
//  - docs/ARCHITECTURE.md §3 / docs/TECH_SPIKE.md
//

import AudioToolbox
import CoreAudio
import Foundation
import os.log

/// SystemTap は PoCAudioEngine から単一スレッド（通常はバックグラウンド）で操作される。
/// 内部状態は単一の呼び出し元からしか触られないため @unchecked Sendable とする。
final class SystemTap: SystemTapControlling, @unchecked Sendable {
    private let log = Logger(subsystem: "dev.hazakura-amp", category: "SystemTap")
    private let diagnosticLog: DiagnosticLogStore

    private(set) var tapID: AudioObjectID = kAudioObjectUnknown
    private(set) var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown

    /// セットアップ前の元々の default output device。teardown で必ず復元する。
    private(set) var originalDefaultOutputID: AudioObjectID = kAudioObjectUnknown

    /// tap 名。実運用では Bundle Identifier を含めて他アプリと被らないようにする。
    private let tapName = "dev.hazakura-amp.tap"
    private let aggregateName = "dev.hazakura-amp.aggregate"

    // MARK: - Public

    /// セットアップ後の待機時間（秒）。aggregate / tap の stream が live になるまでの猶予。
    /// 'naci' (1852797029) 系のエラーを避けるための実用的バッファ。
    private static let postSetupDelay: TimeInterval = 0.2

    init(diagnosticLog: DiagnosticLogStore) {
        self.diagnosticLog = diagnosticLog
    }

    func setup() throws {
        guard tapID == kAudioObjectUnknown, aggregateDeviceID == kAudioObjectUnknown else {
            log.warning("SystemTap.setup called when already set up")
            diagnosticLog.record(.warning, "System tap setup skipped because it is already set up")
            return
        }

        // Step 1: 現在の default output device を保存（後で復元する）
        let originalOutputID = try getDefaultOutputDeviceID()
        originalDefaultOutputID = originalOutputID
        log.info("Original default output device id=\(originalOutputID, privacy: .public)")
        diagnosticLog.record(.info, "Original default output device id=\(originalOutputID)")

        // Step 2: default output device の UID を取得
        let defaultOutputUID = try getDeviceUID(deviceID: originalOutputID)
        log.info("Default output device UID: \(defaultOutputUID)")
        diagnosticLog.record(.info, "Default output UID=\(defaultOutputUID)")

        // Step 3: tap 作成
        let excludedBundleID = Bundle.main.bundleIdentifier
        if let excludedBundleID {
            diagnosticLog.record(.info, "Excluding current app from muted tap: \(excludedBundleID)")
        } else {
            diagnosticLog.record(.warning, "Current app bundle id is unavailable; boosted output may also be muted")
        }
        let newTapID = try createTap(deviceUID: defaultOutputUID, excludingBundleID: excludedBundleID)
        log.info("Tap created: id=\(newTapID)")
        diagnosticLog.record(.info, "Process tap created id=\(newTapID)")

        // Step 4: aggregate device 作成（default output を sub-device として含む）
        let newAggregateID = try createAggregateDevice(defaultOutputUID: defaultOutputUID)
        log.info("Aggregate device created: id=\(newAggregateID)")
        diagnosticLog.record(.info, "Aggregate device created id=\(newAggregateID)")

        // Step 5: tap を aggregate に紐付け
        do {
            try attachTapToAggregate(tapID: newTapID, aggregateID: newAggregateID)
            diagnosticLog.record(.info, "Process tap attached to aggregate device")
        } catch {
            log.error("attachTapToAggregate failed, rolling back: \(error.localizedDescription)")
            diagnosticLog.record(.error, "Attach tap failed: \(error.localizedDescription)")
            AudioHardwareDestroyAggregateDevice(newAggregateID)
            AudioHardwareDestroyProcessTap(newTapID)
            originalDefaultOutputID = kAudioObjectUnknown
            throw error
        }

        tapID = newTapID
        aggregateDeviceID = newAggregateID

        // Step 6: aggregate device を default output に設定し、IO proc が駆動されるようにする
        do {
            try setDefaultOutputDevice(deviceID: newAggregateID)
            log.info("Set aggregate device as default output")
            diagnosticLog.record(.info, "Set aggregate as default output")
        } catch {
            log.error("Failed to set aggregate as default output, rolling back: \(error.localizedDescription)")
            diagnosticLog.record(.error, "Set aggregate as default output failed: \(error.localizedDescription)")
            teardown()
            throw error
        }

        log.info("SystemTap setup complete, waiting \(Self.postSetupDelay)s for streams to become live…")
        diagnosticLog.record(.info, "Waiting \(Self.postSetupDelay)s for aggregate streams")

        // Step 7: stream が live になるまでの短い猶予
        Thread.sleep(forTimeInterval: Self.postSetupDelay)

        // 起動後の状態をデバッグログに出しておく
        logStreamState()
        diagnosticLog.record(.info, "System tap setup complete")
    }

    func teardown() {
        // 必ず元の default output を復元してから aggregate/tap を破棄する。
        // 順序を守らないと、復元前に aggregate が消えて一時的に無音になる/ゴミが残る。
        if originalDefaultOutputID != kAudioObjectUnknown {
            let originalID = originalDefaultOutputID
            do {
                try setDefaultOutputDevice(deviceID: originalID)
                log.info("Restored original default output device: id=\(originalID, privacy: .public)")
                diagnosticLog.record(.info, "Restored original default output id=\(originalID)")
            } catch {
                log.error("Failed to restore original default output device: \(error.localizedDescription)")
                diagnosticLog.record(.error, "Failed to restore original output: \(error.localizedDescription)")
            }
            originalDefaultOutputID = kAudioObjectUnknown
        }

        if aggregateDeviceID != kAudioObjectUnknown {
            let currentID = aggregateDeviceID
            let status = AudioHardwareDestroyAggregateDevice(currentID)
            if status != noErr {
                log.error("AudioHardwareDestroyAggregateDevice failed: \(status) (\(Self.fourCC(status)))")
                diagnosticLog.record(.error, "Destroy aggregate failed OSStatus=\(status) '\(Self.fourCC(status))'")
            } else {
                log.info("Aggregate device destroyed: id=\(currentID)")
                diagnosticLog.record(.info, "Aggregate device destroyed id=\(currentID)")
            }
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            let currentID = tapID
            let status = AudioHardwareDestroyProcessTap(currentID)
            if status != noErr {
                log.error("AudioHardwareDestroyProcessTap failed: \(status) (\(Self.fourCC(status)))")
                diagnosticLog.record(.error, "Destroy process tap failed OSStatus=\(status) '\(Self.fourCC(status))'")
            } else {
                log.info("Tap destroyed: id=\(currentID)")
                diagnosticLog.record(.info, "Process tap destroyed id=\(currentID)")
            }
            tapID = kAudioObjectUnknown
        }
    }

    deinit {
        teardown()
    }

    // MARK: - Tap

    private func createTap(deviceUID: String, excludingBundleID: String?) throws -> AudioObjectID {
        let description = Self.makeTapDescription(
            deviceUID: deviceUID,
            excludingBundleID: excludingBundleID
        )
        description.name = tapName
        var id: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateProcessTap(description, &id)
        guard status == noErr else {
            throw makeError("AudioHardwareCreateProcessTap failed", status: status)
        }
        return id
    }

    static func makeTapDescription(deviceUID: String, excludingBundleID: String?) -> CATapDescription {
        let description = CATapDescription()
        description.isPrivate = true
        // .muted は tap 対象プロセスの直接出力を止める。自アプリは除外し、
        // AVAudioEngine のブースト後出力まで黙らせない。
        description.muteBehavior = .muted
        description.isMixdown = true
        description.isMono = false
        description.isExclusive = true
        if let excludingBundleID, !excludingBundleID.isEmpty {
            description.bundleIDs = [excludingBundleID]
        } else {
            description.bundleIDs = []
        }
        description.deviceUID = deviceUID
        description.stream = 0
        return description
    }

    // MARK: - Aggregate device

    private func createAggregateDevice(defaultOutputUID: String) throws -> AudioObjectID {
        // aggregate device は tap からの入力と default output への出力を両方持つ。
        // - default output を sub-device に含めることで、IO proc からの出力が
        //   実際のスピーカー／ヘッドホンへ届くようにする
        // - master sub-device は 0 (NSNumber) を指定。sub-device list の先頭要素を指す
        let uid = "hazakura-amp-\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: aggregateName,
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceSubDeviceListKey: [defaultOutputUID] as CFArray,
            kAudioAggregateDeviceMasterSubDeviceKey: 0 as CFNumber,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]

        var id: AudioObjectID = 0
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr else {
            throw makeError("AudioHardwareCreateAggregateDevice failed", status: status)
        }
        return id
    }

    private func attachTapToAggregate(tapID: AudioObjectID, aggregateID: AudioObjectID) throws {
        // (1) tap の UID を取得
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var tapUID: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        let uidStatus = withUnsafeMutablePointer(to: &tapUID) { tapUIDPtr -> OSStatus in
            AudioObjectGetPropertyData(
                tapID,
                &uidAddress,
                0,
                nil,
                &uidSize,
                tapUIDPtr
            )
        }
        guard uidStatus == noErr else {
            throw makeError("Failed to get tap UID", status: uidStatus)
        }
        log.debug("Tap UID: \(tapUID as String)")

        // (2) aggregate device の tap list に tap を設定
        var tapListAddress = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyTapList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let tapArray = [tapUID] as CFArray
        let setStatus = withUnsafePointer(to: tapArray) { arrayPtr -> OSStatus in
            AudioObjectSetPropertyData(
                aggregateID,
                &tapListAddress,
                0,
                nil,
                UInt32(MemoryLayout<CFArray>.size),
                arrayPtr
            )
        }
        guard setStatus == noErr else {
            throw makeError("Failed to set tap list on aggregate", status: setStatus)
        }
        log.debug("Tap list set on aggregate")
    }

    // MARK: - Default output device

    private func getDefaultOutputDeviceID() throws -> AudioDeviceID {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw makeError("Failed to get default output device ID", status: status)
        }
        return deviceID
    }

    private func getDeviceUID(deviceID: AudioObjectID) throws -> String {
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        let uidStatus = withUnsafeMutablePointer(to: &uid) { uidPtr -> OSStatus in
            AudioObjectGetPropertyData(
                deviceID,
                &uidAddress,
                0,
                nil,
                &uidSize,
                uidPtr
            )
        }
        guard uidStatus == noErr else {
            throw makeError("Failed to get device UID", status: uidStatus)
        }
        return uid as String
    }

    private func getDefaultOutputDeviceUID() throws -> String {
        let deviceID = try getDefaultOutputDeviceID()
        return try getDeviceUID(deviceID: deviceID)
    }

    private func setDefaultOutputDevice(deviceID: AudioDeviceID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &id
        )
        guard status == noErr else {
            throw makeError("Failed to set default output device", status: status)
        }
    }

    // MARK: - Diagnostics

    /// aggregate device の stream 一覧をデバッグログに出す。
    /// 想定: 1 input (tap) + 1 output (default output as sub-device)
    private func logStreamState() {
        let streams = enumerateStreams(aggregateDeviceID)
        log.info("Aggregate device has \(streams.count) stream(s):")
        for stream in streams {
            let dirStr = stream.direction == 0 ? "output" : "input"
            let rateHz = String(format: "%.0f", stream.sampleRate)
            log.info("  stream \(stream.id) [\(dirStr)] sampleRate=\(rateHz)Hz channels=\(stream.channels)")
            diagnosticLog.record(.info, "Stream \(stream.id) \(dirStr) \(rateHz)Hz channels=\(stream.channels)")
        }
    }

    private struct StreamInfo {
        let id: AudioObjectID
        let direction: UInt32  // 0 = output, 1 = input
        let sampleRate: Double
        let channels: UInt32
    }

    private func enumerateStreams(_ deviceID: AudioObjectID) -> [StreamInfo] {
        var streams: [StreamInfo] = []
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard sizeStatus == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var streamIDs = [AudioObjectID](repeating: 0, count: count)
        // `withUnsafeMutablePointer(to: &array)` は配列ヘッダを指してしまうため、
        // 必ず `withUnsafeMutableBytes` でデータ本体のポインタを取得する。
        let listStatus = streamIDs.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let base = rawBuffer.baseAddress else { return kAudioHardwareUnspecifiedError }
            return AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                base
            )
        }
        guard listStatus == noErr else { return [] }

        for streamID in streamIDs {
            var fmt = AudioStreamBasicDescription()
            var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var fmtAddr = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyVirtualFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let fmtStatus = AudioObjectGetPropertyData(streamID, &fmtAddr, 0, nil, &fmtSize, &fmt)
            guard fmtStatus == noErr else { continue }

            var dir: UInt32 = 0
            var dirSize = UInt32(MemoryLayout<UInt32>.size)
            var dirAddr = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyDirection,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectGetPropertyData(streamID, &dirAddr, 0, nil, &dirSize, &dir)

            streams.append(StreamInfo(
                id: streamID,
                direction: dir,
                sampleRate: fmt.mSampleRate,
                channels: fmt.mChannelsPerFrame
            ))
        }
        return streams
    }

    // MARK: - Errors

    private func makeError(_ message: String, status: OSStatus) -> NSError {
        NSError(
            domain: "SystemTap",
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "\(message) (OSStatus=\(status) '\(Self.fourCC(status))')"]
        )
    }

    /// OSStatus を 4 文字コード文字列に変換する。デバッグ用。
    static func fourCC(_ status: OSStatus) -> String {
        let bytes: [UInt8] = [
            UInt8((Int32(status) >> 24) & 0xFF),
            UInt8((Int32(status) >> 16) & 0xFF),
            UInt8((Int32(status) >> 8) & 0xFF),
            UInt8(Int32(status) & 0xFF),
        ]
        // 表示可能文字なら 4 文字に、見つからなければ hex 表記
        if let s = String(bytes: bytes, encoding: .ascii), s.allSatisfy({ $0.isASCII && $0.isLetter }) {
            return s
        }
        return String(format: "0x%08X", UInt32(bitPattern: Int32(status)))
    }
}
