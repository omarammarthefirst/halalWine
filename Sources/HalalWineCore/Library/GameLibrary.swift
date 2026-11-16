import Foundation

/// A game in the user's library.
public struct GameRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var report: GameReport
    public var addedAt: Date
    public var lastPlayedAt: Date?
    public var history: LaunchHistory
    public var preferWindowed: Bool
    public var advertiseAVX: Bool
    public var extraArguments: [String]
    public var installedDependencies: [Dependency]
    /// True when the game folder lives inside halalWine's own Games folder.
    public var isManagedCopy: Bool

    public init(id: UUID = UUID(), report: GameReport, isManagedCopy: Bool) {
        self.id = id
        self.name = report.displayName
        self.report = report
        self.addedAt = Date()
        self.lastPlayedAt = nil
        self.history = LaunchHistory()
        self.preferWindowed = true
        self.advertiseAVX = false
        self.extraArguments = []
        self.installedDependencies = []
        self.isManagedCopy = isManagedCopy
    }

    public var executableURL: URL { URL(fileURLWithPath: report.executable) }
    public var rootURL: URL { URL(fileURLWithPath: report.rootFolder) }
    public var isMissing: Bool { !FileOps.exists(executableURL) }

    public func launchSettings(metalHUD: Bool) -> LaunchSettings {
        LaunchSettings(preferWindowed: preferWindowed, metalHUD: metalHUD, advertiseAVX: advertiseAVX,
                       extraArguments: extraArguments)
    }
}

/// The library, stored as JSON in the app's data folder.
public final class GameLibrary {
    public private(set) var games: [GameRecord] = []
    private let file: URL

    public init(paths: AppPaths) {
        file = paths.libraryFile
        if let data = try? Data(contentsOf: file) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            games = (try? decoder.decode([GameRecord].self, from: data)) ?? []
        }
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(games).write(to: file, options: .atomic)
    }

    public func upsert(_ record: GameRecord) {
        if let i = games.firstIndex(where: { $0.id == record.id }) {
            games[i] = record
        } else {
            games.append(record)
        }
    }

    public func remove(id: UUID) {
        games.removeAll { $0.id == id }
    }

    public func record(id: UUID) -> GameRecord? { games.first { $0.id == id } }

    public func find(executable path: String) -> GameRecord? { games.first { $0.report.executable == path } }
}
