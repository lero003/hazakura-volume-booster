import SwiftUI
import AppKit

enum BoostStatusSeverity: Equatable {
    case normal
    case notice
    case warning
    case error
}

struct BoostStatusPresentation: Equatable {
    let headline: String
    let detail: String
    let severity: BoostStatusSeverity
    let showsErrorBanner: Bool

    static func make(statusText: String, isRunning: Bool, isEnabled: Bool, lastError: String?) -> BoostStatusPresentation {
        if isRunning {
            if !isEnabled {
                return BoostStatusPresentation(
                    headline: "一時停止中（設定値は保持）",
                    detail: "ON に戻すと保存中のブースト値へ復帰します。",
                    severity: .notice,
                    showsErrorBanner: false
                )
            }
            return BoostStatusPresentation(
                headline: statusText,
                detail: "Audio is processed locally. It is not recorded, stored, or transmitted.",
                severity: .normal,
                showsErrorBanner: false
            )
        }

        switch statusText {
        case PoCAudioEngineStatus.sleeping.rawValue:
            return BoostStatusPresentation(
                headline: "sleeping",
                detail: "Sleep preparation forced output gain to 100%.",
                severity: .notice,
                showsErrorBanner: false
            )
        case PoCAudioEngineStatus.waking.rawValue:
            return BoostStatusPresentation(
                headline: "waking",
                detail: "Reconnecting the audio path after wake.",
                severity: .notice,
                showsErrorBanner: false
            )
        case PoCAudioEngineStatus.manualStartRequired.rawValue:
            return BoostStatusPresentation(
                headline: "Start required after wake",
                detail: "Press Start to reconnect the audio path.",
                severity: .notice,
                showsErrorBanner: false
            )
        case PoCAudioEngineStatus.restartRequired.rawValue:
            return BoostStatusPresentation(
                headline: "Restart required",
                detail: "Press Start to rebuild the audio path. \(lastError ?? "")",
                severity: .warning,
                showsErrorBanner: true
            )
        case PoCAudioEngineStatus.permissionDenied.rawValue:
            return BoostStatusPresentation(
                headline: "System audio access is not allowed",
                detail: "Allow CoreAudioTapPoC in System Settings, then press Start again.",
                severity: .warning,
                showsErrorBanner: true
            )
        case PoCAudioEngineStatus.error.rawValue:
            return BoostStatusPresentation(
                headline: "error",
                detail: "Press Start to retry. Open Dev diagnostics if this repeats. \(lastError ?? "")",
                severity: .error,
                showsErrorBanner: true
            )
        default:
            return BoostStatusPresentation(
                headline: "Boost を開始してください",
                detail: "システム音をローカル処理します。録音・保存・送信はしません。",
                severity: .normal,
                showsErrorBanner: false
            )
        }
    }
}

struct ContentView: View {
    @ObservedObject private var engine: PoCAudioEngine
    @State private var isShowingDevMode = false

    init(engine: PoCAudioEngine) {
        self.engine = engine
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Hazakura Boost")
                    .font(.headline)
                Spacer()
                StatusIndicator(isRunning: engine.isRunning)
            }

            StatusMessageView(presentation: statusPresentation)

            Divider()

            HStack {
                Text("Boost")
                Spacer()
                Text(gainLabel)
                    .monospacedDigit()
                    .frame(minWidth: 100, alignment: .trailing)
            }

            Slider(value: $engine.configuredGain, in: 1.0...4.0, step: 0.01) {
                Text("Boost gain")
            } minimumValueLabel: {
                Text("100%").font(.caption2)
            } maximumValueLabel: {
                Text("400%").font(.caption2)
            }
            .disabled(!engine.isRunning || !engine.isEnabled)
            .accessibilityLabel("Boost level")
            .accessibilityValue(gainAccessibilityValue)
            .accessibilityHint("Adjusts the local system audio boost level.")

            HStack(spacing: 8) {
                Button("100%に戻す") {
                    engine.resetToNeutral()
                }
                .disabled(!engine.isRunning)
                .accessibilityLabel("Reset boost to 100 percent")
                .accessibilityHint("Returns output gain to neutral.")

                Spacer()

                Toggle("ON", isOn: $engine.isEnabled)
                    .toggleStyle(.switch)
                    .disabled(!engine.isRunning)
                    .accessibilityLabel("Boost on or off")
                    .accessibilityHint("Turns boost processing on or off while keeping the selected boost value.")
            }

            HStack(spacing: 8) {
                presetButton("100%", value: 1.0)
                presetButton("200%", value: 2.0)
                presetButton("400%", value: 4.0)
            }

            HStack {
                Button(engine.isRunning ? "停止" : "開始") {
                    if engine.isRunning { engine.stop() } else { engine.start() }
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .accessibilityLabel(startStopAccessibilityLabel)
                .accessibilityHint("Starts or stops the audio processing path.")
                Spacer()
                Button("終了") {
                    engine.stop()
                    NSApplication.shared.terminate(nil)
                }
                .controlSize(.large)
                .accessibilityLabel("Quit Hazakura Boost")
                .accessibilityHint("Stops audio processing safely, then quits the app.")
            }

            Toggle("Dev", isOn: $isShowingDevMode)
                .toggleStyle(.switch)
                .font(.caption)
                .accessibilityLabel("Developer diagnostics")
                .accessibilityHint("Shows audio pipeline counters and recent diagnostic events.")

            if isShowingDevMode {
                DevDiagnosticsView(
                    captureBufferCount: engine.captureBufferCount,
                    renderCallCount: engine.renderCallCount,
                    lastObservedGain: engine.lastObservedGain,
                    availableFrames: engine.availableFrames,
                    underrunCount: engine.underrunCount,
                    droppedFrameCount: engine.droppedFrameCount,
                    latestBufferFrameCount: engine.latestBufferFrameCount,
                    health: engine.backendHealth,
                    isRunning: engine.isRunning,
                    logStore: engine.diagnosticLog,
                    diagnosticSnapshot: engine.diagnosticSnapshotText()
                )
            }

            if statusPresentation.showsErrorBanner {
                GroupBox {
                    Text("⚠️ \(statusPresentation.detail)")
                        .font(.caption)
                        .foregroundStyle(statusPresentation.severity == .error ? .red : .orange)
                        .textSelection(.enabled)
                }
            }
        }
        .padding()
        .frame(width: 380)
    }

    // MARK: - Helpers

    private var statusPresentation: BoostStatusPresentation {
        BoostStatusPresentation.make(
            statusText: engine.statusText,
            isRunning: engine.isRunning,
            isEnabled: engine.isEnabled,
            lastError: engine.lastError
        )
    }

    private var gainLabel: String {
        if !engine.isEnabled {
            return "Boost (paused)"
        }
        let percent = Int((engine.configuredGain * 100).rounded())
        if engine.configuredGain == 1.0 { return "100%" }
        return "Boost \(percent)%"
    }

    private var gainAccessibilityValue: String {
        if !engine.isEnabled { return "Paused" }
        return "\(Int((engine.configuredGain * 100).rounded())) percent"
    }

    private var startStopAccessibilityLabel: String {
        engine.isRunning ? "Stop boost processing" : "Start boost processing"
    }

    @ViewBuilder
    private func presetButton(_ title: String, value: Double) -> some View {
        Button(title) {
            engine.configuredGain = value
            engine.isEnabled = true
        }
        .disabled(!engine.isRunning || !engine.isEnabled)
        .controlSize(.small)
    }
}

private struct StatusMessageView: View {
    let presentation: BoostStatusPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(presentation.headline)
                .font(.subheadline)
                .foregroundStyle(headlineColor)
            Text(presentation.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var headlineColor: Color {
        switch presentation.severity {
        case .normal:
            return .primary
        case .notice:
            return .secondary
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}

/// メニューバーアイコン横の稼働状態インジケータ。
struct StatusIndicator: View {
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isRunning ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(isRunning ? "Active" : "Idle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// audio pipeline の診断情報。動作確認用。
struct DiagnosticsView: View {
    let captureBufferCount: UInt64
    let renderCallCount: UInt64
    let lastObservedGain: Float
    let availableFrames: Int
    let underrunCount: UInt64
    let droppedFrameCount: UInt64
    let latestBufferFrameCount: Int
    let health: AudioBackendHealthAssessment
    let isRunning: Bool

    var body: some View {
        GroupBox("Diagnostics") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Capture buffers:")
                    Spacer()
                    Text("\(captureBufferCount)")
                        .monospacedDigit()
                        .foregroundStyle(isRunning && captureBufferCount > 0 ? .primary : .secondary)
                }
                HStack {
                    Text("Render calls:")
                    Spacer()
                    Text("\(renderCallCount)")
                        .monospacedDigit()
                        .foregroundStyle(isRunning && renderCallCount > 0 ? .primary : .secondary)
                }
                HStack {
                    Text("Output gain:")
                    Spacer()
                    Text(String(format: "%.2f×", lastObservedGain))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Available frames:")
                    Spacer()
                    Text("\(availableFrames)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Underruns:")
                    Spacer()
                    Text("\(underrunCount)")
                        .monospacedDigit()
                        .foregroundStyle(underrunCount == 0 ? Color.secondary : Color.orange)
                }
                HStack {
                    Text("Dropped frames:")
                    Spacer()
                    Text("\(droppedFrameCount)")
                        .monospacedDigit()
                        .foregroundStyle(droppedFrameCount == 0 ? Color.secondary : Color.orange)
                }
                HStack {
                    Text("Latest buffer:")
                    Spacer()
                    Text("\(latestBufferFrameCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Health:")
                    Spacer()
                    Text(healthLabel)
                        .monospacedDigit()
                        .foregroundStyle(healthColor)
                }
                if isRunning && captureBufferCount == 0 {
                    Text("⚠️ ScreenCaptureKit の音声バッファがまだ届いていない")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if isRunning && renderCallCount == 0 {
                    Text("⚠️ AVAudioEngine の render callback がまだ呼ばれていない")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
        }
    }

    private var healthLabel: String {
        switch health.level {
        case .ok:
            return "OK"
        case .watch:
            return String(format: "Watch %.2f%%", health.underrunRate * 100)
        case .warning:
            return String(format: "Warning %.2f%%", health.underrunRate * 100)
        }
    }

    private var healthColor: Color {
        switch health.level {
        case .ok:
            return .secondary
        case .watch:
            return .orange
        case .warning:
            return .red
        }
    }
}

/// Dev モード用の診断情報。失敗した audio 境界をアプリ内で確認する。
struct DevDiagnosticsView: View {
    let captureBufferCount: UInt64
    let renderCallCount: UInt64
    let lastObservedGain: Float
    let availableFrames: Int
    let underrunCount: UInt64
    let droppedFrameCount: UInt64
    let latestBufferFrameCount: Int
    let health: AudioBackendHealthAssessment
    let isRunning: Bool
    @ObservedObject var logStore: DiagnosticLogStore
    let diagnosticSnapshot: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DiagnosticsView(
                captureBufferCount: captureBufferCount,
                renderCallCount: renderCallCount,
                lastObservedGain: lastObservedGain,
                availableFrames: availableFrames,
                underrunCount: underrunCount,
                droppedFrameCount: droppedFrameCount,
                latestBufferFrameCount: latestBufferFrameCount,
                health: health,
                isRunning: isRunning
            )

            HStack {
                Text("Event Log")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    copyDiagnostics(diagnosticSnapshot)
                }
                .controlSize(.small)
                Button("Clear") {
                    logStore.clear()
                }
                .controlSize(.small)
                .disabled(logStore.entries.isEmpty)
            }

            if logStore.entries.isEmpty {
                Text("No diagnostic events yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(logStore.entries.reversed())) { entry in
                            DiagnosticLogRow(entry: entry)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .textSelection(.enabled)
            }
        }
    }

    private func copyDiagnostics(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct DiagnosticLogRow: View {
    let entry: DiagnosticLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.timestamp, style: .time)
                    .monospacedDigit()
                Text(entry.level.label)
                    .foregroundStyle(levelColor)
                    .fontWeight(.semibold)
                Spacer()
            }
            Text(entry.message)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption2)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var levelColor: Color {
        switch entry.level {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}

#Preview {
    ContentView(engine: PoCAudioEngine())
}
