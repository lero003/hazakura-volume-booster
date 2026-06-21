import Foundation

struct HazakuraAmpRemoteControlStore {
    let baseDirectory: URL

    private var commandsDirectory: URL {
        baseDirectory.appendingPathComponent("commands", isDirectory: true)
    }

    private var stateURL: URL {
        baseDirectory.appendingPathComponent("state.json")
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    static func appGroupStore() throws -> HazakuraAmpRemoteControlStore {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.keisetsu.hazakura-amp") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return HazakuraAmpRemoteControlStore(baseDirectory: url.appendingPathComponent("RemoteControl", isDirectory: true))
    }

    func enqueue(_ command: HazakuraAmpRemoteCommand) throws {
        try FileManager.default.createDirectory(at: commandsDirectory, withIntermediateDirectories: true)
        let url = commandsDirectory.appendingPathComponent("\(command.createdAt.timeIntervalSince1970)-\(command.id.uuidString).json")
        try encoder.encode(command).write(to: url, options: [.atomic])
    }

    func drainCommands() throws -> [HazakuraAmpRemoteCommand] {
        try FileManager.default.createDirectory(at: commandsDirectory, withIntermediateDirectories: true)
        let urls = try FileManager.default.contentsOfDirectory(
            at: commandsDirectory,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        var commands: [HazakuraAmpRemoteCommand] = []
        for url in urls where url.pathExtension == "json" {
            let data = try Data(contentsOf: url)
            commands.append(try decoder.decode(HazakuraAmpRemoteCommand.self, from: data))
            try FileManager.default.removeItem(at: url)
        }
        return commands
    }

    func writeState(_ state: HazakuraAmpRemoteState) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try encoder.encode(state).write(to: stateURL, options: [.atomic])
    }

    func readState() throws -> HazakuraAmpRemoteState? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        let data = try Data(contentsOf: stateURL)
        return try decoder.decode(HazakuraAmpRemoteState.self, from: data)
    }
}
