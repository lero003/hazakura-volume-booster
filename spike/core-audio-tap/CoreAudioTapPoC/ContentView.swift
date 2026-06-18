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

    static func make(statusText: String, isRunning: Bool, lastError: String?) -> BoostStatusPresentation {
        if isRunning {
            return BoostStatusPresentation(
                headline: "動作中",
                detail: "オーディオはローカルで処理されます。録音・保存・送信は行いません。",
                severity: .normal,
                showsErrorBanner: false
            )
        }

        switch statusText {
        case PoCAudioEngineStatus.sleeping.rawValue:
            return BoostStatusPresentation(
                headline: "スリープ中",
                detail: "スリープ準備で出力ゲインを 100% に戻しました。",
                severity: .notice,
                showsErrorBanner: false
            )
        case PoCAudioEngineStatus.waking.rawValue:
            return BoostStatusPresentation(
                headline: "復帰中",
                detail: "スリープ復帰後にオーディオ経路を再接続しています。",
                severity: .notice,
                showsErrorBanner: false
            )
        case PoCAudioEngineStatus.manualStartRequired.rawValue:
            return BoostStatusPresentation(
                headline: "復帰後に開始が必要です",
                detail: "開始を押してオーディオ経路を再接続してください。",
                severity: .notice,
                showsErrorBanner: false
            )
        case PoCAudioEngineStatus.restartRequired.rawValue:
            return BoostStatusPresentation(
                headline: "再開が必要です",
                detail: "開始を押してオーディオ経路を再構築してください。\(lastError ?? "")",
                severity: .warning,
                showsErrorBanner: true
            )
        case PoCAudioEngineStatus.permissionDenied.rawValue:
            return BoostStatusPresentation(
                headline: "システム音声へのアクセスが許可されていません",
                detail: "システム設定 > プライバシーとセキュリティ で Hazakura Amp を許可してから、再度 開始 を押してください。",
                severity: .warning,
                showsErrorBanner: true
            )
        case PoCAudioEngineStatus.error.rawValue:
            return BoostStatusPresentation(
                headline: "エラーが発生しました",
                detail: "開始を押して再試行してください。繰り返す場合は Dev 診断を開いてください。\(lastError ?? "")",
                severity: .error,
                showsErrorBanner: true
            )
        default:
            return BoostStatusPresentation(
                headline: "ブーストを開始してください",
                detail: "システム音をローカル処理します。録音・保存・送信は行いません。",
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
                Text("Hazakura Amp")
                    .font(.headline)
                Spacer()
                StatusIndicator(isRunning: engine.isRunning)
            }

            StatusMessageView(presentation: statusPresentation)

            Divider()

            HStack {
                Text("ブースト")
                    .font(.subheadline)
                Spacer()
                Text(gainLabel)
                    .monospacedDigit()
                    .frame(minWidth: 100, alignment: .trailing)
            }

            Slider(value: $engine.configuredGain, in: 0.0...4.0, step: 0.01) {
                Text("ブーストゲイン")
            } minimumValueLabel: {
                Text("0%").font(.caption2)
            } maximumValueLabel: {
                Text("400%").font(.caption2)
            }
            .disabled(!engine.isRunning)
            .accessibilityLabel("Boost level")
            .accessibilityValue(gainAccessibilityValue)
            .accessibilityHint("Adjusts the local system audio boost level.")

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
                    engine.shutdownForAppTermination()
                    NSApplication.shared.terminate(nil)
                }
                .controlSize(.large)
                .accessibilityLabel("Quit Hazakura Amp")
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
        .frame(maxHeight: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Helpers

    private var statusPresentation: BoostStatusPresentation {
        BoostStatusPresentation.make(
            statusText: engine.statusText,
            isRunning: engine.isRunning,
            lastError: engine.lastError
        )
    }

    private var gainLabel: String {
        let percent = Int((engine.configuredGain * 100).rounded())
        if engine.configuredGain == 1.0 { return "100%" }
        return "ブースト \(percent)%"
    }

    private var gainAccessibilityValue: String {
        return "\(Int((engine.configuredGain * 100).rounded())) percent"
    }

    private var startStopAccessibilityLabel: String {
        engine.isRunning ? "Stop boost processing" : "Start boost processing"
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
            Text(isRunning ? "動作中" : "停止中")
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
        GroupBox("診断") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("キャプチャバッファ:")
                    Spacer()
                    Text("\(captureBufferCount)")
                        .monospacedDigit()
                        .foregroundStyle(isRunning && captureBufferCount > 0 ? .primary : .secondary)
                }
                HStack {
                    Text("レンダー呼び出し:")
                    Spacer()
                    Text("\(renderCallCount)")
                        .monospacedDigit()
                        .foregroundStyle(isRunning && renderCallCount > 0 ? .primary : .secondary)
                }
                HStack {
                    Text("出力ゲイン:")
                    Spacer()
                    Text(String(format: "%.2f×", lastObservedGain))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("利用可能フレーム:")
                    Spacer()
                    Text("\(availableFrames)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("アンダーラン:")
                    Spacer()
                    Text("\(underrunCount)")
                        .monospacedDigit()
                        .foregroundStyle(underrunCount == 0 ? Color.secondary : Color.orange)
                }
                HStack {
                    Text("ドロップフレーム:")
                    Spacer()
                    Text("\(droppedFrameCount)")
                        .monospacedDigit()
                        .foregroundStyle(droppedFrameCount == 0 ? Color.secondary : Color.orange)
                }
                HStack {
                    Text("最新バッファ:")
                    Spacer()
                    Text("\(latestBufferFrameCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("ヘルス:")
                    Spacer()
                    Text(healthLabel)
                        .monospacedDigit()
                        .foregroundStyle(healthColor)
                }
                if isRunning && captureBufferCount == 0 {
                    Text("⚠️ ScreenCaptureKit の音声バッファがまだ届いていません")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if isRunning && renderCallCount == 0 {
                    Text("⚠️ AVAudioEngine のレンダー呼び出しがまだ発生していいません")
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
            return String(format: "注意 %.2f%%", health.underrunRate * 100)
        case .warning:
            return String(format: "警告 %.2f%%", health.underrunRate * 100)
        }
    }

    private var healthColor: Color {
        switch health.level {
        case .ok:
            return .green
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
                Text("イベントログ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("コピー") {
                    copyDiagnostics(diagnosticSnapshot)
                }
                .controlSize(.small)
                Button("クリア") {
                    logStore.clear()
                }
                .controlSize(.small)
                .disabled(logStore.entries.isEmpty)
            }

            if logStore.entries.isEmpty {
                Text("診断イベントはまだありません")
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
