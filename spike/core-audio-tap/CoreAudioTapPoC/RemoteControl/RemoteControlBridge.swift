import Foundation

@MainActor
final class HazakuraAmpRemoteControlBridge {
    private let store: HazakuraAmpRemoteControlStore
    private weak var engine: PoCAudioEngine?
    private let pollInterval: TimeInterval
    private var timer: Timer?
    private var isProcessing = false

    init(
        store: HazakuraAmpRemoteControlStore,
        engine: PoCAudioEngine,
        pollInterval: TimeInterval = 0.25
    ) {
        self.store = store
        self.engine = engine
        self.pollInterval = pollInterval
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                do {
                    try await self?.processPendingCommands()
                } catch {
                    self?.engine?.diagnosticLog.record(.warning, "Remote control bridge failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func processPendingCommands() async throws {
        guard !isProcessing, let engine else { return }
        isProcessing = true
        defer { isProcessing = false }

        for command in try store.drainCommands() {
            try Task.checkCancellation()
            await engine.applyRemoteCommandAsync(command)
        }
        try store.writeState(engine.remoteState())
    }

}
