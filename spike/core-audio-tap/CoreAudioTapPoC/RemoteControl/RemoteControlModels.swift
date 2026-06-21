import Foundation

enum HazakuraAmpRemoteCommandKind: String, Codable, Equatable {
    case setGain
    case requestStart
    case requestState
}

struct HazakuraAmpRemoteCommand: Codable, Equatable, Identifiable {
    let id: UUID
    let kind: HazakuraAmpRemoteCommandKind
    let gain: Double?
    let createdAt: Date

    static func setGain(_ gain: Double) -> HazakuraAmpRemoteCommand {
        HazakuraAmpRemoteCommand(id: UUID(), kind: .setGain, gain: gain, createdAt: Date())
    }

    static func requestStart() -> HazakuraAmpRemoteCommand {
        HazakuraAmpRemoteCommand(id: UUID(), kind: .requestStart, gain: nil, createdAt: Date())
    }

    static func requestState() -> HazakuraAmpRemoteCommand {
        HazakuraAmpRemoteCommand(id: UUID(), kind: .requestState, gain: nil, createdAt: Date())
    }

    var sanitizedGain: Double {
        Self.clampGain(gain ?? 1.0)
    }

    static func clampGain(_ gain: Double) -> Double {
        guard gain.isFinite else { return 1.0 }
        return min(4.0, max(0.0, gain))
    }

    static func == (lhs: HazakuraAmpRemoteCommand, rhs: HazakuraAmpRemoteCommand) -> Bool {
        lhs.id == rhs.id &&
            lhs.kind == rhs.kind &&
            lhs.gain == rhs.gain &&
            abs(lhs.createdAt.timeIntervalSince1970 - rhs.createdAt.timeIntervalSince1970) < 0.001
    }
}

struct HazakuraAmpRemoteState: Codable, Equatable {
    let configuredGain: Double
    let isRunning: Bool
    let statusText: String
    let lastError: String?
    let updatedAt: Date

    var displayPercent: Int {
        Int((configuredGain * 100).rounded())
    }
}
