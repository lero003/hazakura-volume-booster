import Foundation
import SafariServices
import os.log

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let log = Logger(subsystem: "dev.hazakura-amp", category: "SafariWebExtension")

    func beginRequest(with context: NSExtensionContext) {
        let response = handle(context: context)
        let item = NSExtensionItem()
        item.userInfo = [SFExtensionMessageKey: response]
        context.completeRequest(returningItems: [item])
    }

    private func handle(context: NSExtensionContext) -> [String: Any] {
        guard let item = context.inputItems.first as? NSExtensionItem,
              let message = item.userInfo?[SFExtensionMessageKey] as? [String: Any],
              let kind = message["kind"] as? String else {
            return ["ok": false, "error": "Invalid Hazakura Amp remote message"]
        }

        do {
            let store = try HazakuraAmpRemoteControlStore.appGroupStore()
            switch kind {
            case "setGain":
                let gain = message["gain"] as? Double ?? 1.0
                try store.enqueue(.setGain(gain))
            case "requestStart":
                try store.enqueue(.requestStart())
            case "requestState":
                break
            default:
                return ["ok": false, "error": "Unsupported Hazakura Amp remote command"]
            }

            return statePayload(from: try store.readState())
        } catch {
            log.error("Safari extension handler failed: \(error.localizedDescription, privacy: .public)")
            return ["ok": false, "error": "Hazakura Amp is not ready"]
        }
    }

    private func statePayload(from state: HazakuraAmpRemoteState?) -> [String: Any] {
        [
            "configuredGain": state?.configuredGain ?? 1.0,
            "displayPercent": state?.displayPercent ?? 100,
            "isRunning": state?.isRunning ?? false,
            "statusText": state?.statusText ?? "app not running",
            "lastError": state?.lastError ?? NSNull(),
            "updatedAt": state?.updatedAt.timeIntervalSince1970 ?? NSNull()
        ]
    }
}
