import Foundation

/// Where halalWine keeps its data. Defaults to
/// ~/Library/Application Support/halalWine; override with HALALWINE_HOME.
public struct AppPaths: Sendable {
    public let root: URL

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else if let custom = ProcessInfo.processInfo.environment["HALALWINE_HOME"], !custom.isEmpty {
            self.root = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            #if os(macOS)
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            #else
            let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
            #endif
            self.root = base.appendingPathComponent("halalWine", isDirectory: true)
        }
    }

    public var runtimes: URL { root.appendingPathComponent("Runtimes", isDirectory: true) }
    public var templates: URL { root.appendingPathComponent("Templates", isDirectory: true) }
    public var prefixes: URL { root.appendingPathComponent("Prefixes", isDirectory: true) }
    public var games: URL { root.appendingPathComponent("Games", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    public var cache: URL { root.appendingPathComponent("Cache", isDirectory: true) }
    public var icons: URL { root.appendingPathComponent("Icons", isDirectory: true) }
    public var libraryFile: URL { root.appendingPathComponent("library.json") }
    public var cachedRules: URL { cache.appendingPathComponent("rules.json") }

    public func prefix(for gameID: UUID) -> URL {
        prefixes.appendingPathComponent(gameID.uuidString, isDirectory: true)
    }

    public func ensureDirectories() throws {
        for dir in [root, runtimes, templates, prefixes, games, logs, cache, icons] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
