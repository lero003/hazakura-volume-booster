import Foundation
import SafariServices

private enum SafariExtensionStatusClient {
    static let extensionBundleIdentifier = "dev.hazakura-amp.safari-extension"

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain):\(nsError.code) \(nsError.localizedDescription)"
    }

    static func getExtensionState(
        _ onResult: @escaping @Sendable (Bool?, String?) -> Void
    ) {
        let selector = NSSelectorFromString("getStateOfSafariExtensionWithIdentifier:completionHandler:")
        let completion: @convention(block) (SFSafariExtensionState?, NSError?) -> Void = { state, error in
            let errorMessage = error.map(describe)
            let enabled = state?.isEnabled
            onResult(enabled, errorMessage)
        }
        _ = SFSafariExtensionManager.perform(
            selector,
            with: Self.extensionBundleIdentifier,
            with: completion
        )
    }

    static func showExtensionPreferences(
        _ onResult: @escaping @Sendable (String?) -> Void
    ) {
        SFSafariApplication.showPreferencesForExtension(
            withIdentifier: Self.extensionBundleIdentifier
        ) { error in
            let errorMessage = error.map(describe)
            onResult(errorMessage)
        }
    }
}

final class SafariExtensionController: ObservableObject, @unchecked Sendable {
    @Published private(set) var statusText = "未確認"
    @Published private(set) var detailText = "Safari 拡張の状態はまだ確認していません。"
    @Published private(set) var lastError: String?
    @Published private(set) var isEnabled: Bool?

    func refreshState() {
        statusText = "確認中"
        detailText = "Safari に登録された拡張状態を確認しています。"
        lastError = nil

        SafariExtensionStatusClient.getExtensionState { [weak self] isEnabled, errorMessage in
            DispatchQueue.main.async {
                self?.applyState(isEnabled: isEnabled, errorMessage: errorMessage)
            }
        }
    }

    func openPreferences() {
        SafariExtensionStatusClient.showExtensionPreferences { [weak self] errorMessage in
            DispatchQueue.main.async {
                if let errorMessage {
                    self?.statusText = "設定を開けません"
                    self?.detailText = "Safari が拡張設定を開けませんでした。"
                    self?.lastError = errorMessage
                } else {
                    self?.statusText = "設定を開きました"
                    self?.detailText = "Safari の拡張設定で Hazakura Amp Safari Extension を確認してください。"
                    self?.lastError = nil
                }
            }
        }
    }

    private func applyState(isEnabled: Bool?, errorMessage: String?) {
        if let errorMessage {
            self.isEnabled = nil
            statusText = "未検出"
            detailText = "Safari が拡張を認識できませんでした。"
            lastError = errorMessage
            return
        }

        guard let isEnabled else {
            self.isEnabled = nil
            statusText = "未検出"
            detailText = "Safari から拡張状態が返りませんでした。"
            lastError = nil
            return
        }

        self.isEnabled = isEnabled
        statusText = isEnabled ? "有効" : "無効"
        detailText = isEnabled
            ? "Safari 拡張は有効です。YouTube の動画ページでフローティングバーを確認してください。"
            : "Safari 拡張は登録されていますが無効です。Safari の拡張設定で有効化してください。"
        lastError = nil
    }
}
