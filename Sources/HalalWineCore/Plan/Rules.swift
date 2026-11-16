import Foundation

/// Launch knowledge kept as data (rules.json) so it can be improved without
/// shipping a new app. The bundled copy is the fallback; a newer copy can be
/// downloaded from the project's repository.
public struct RuleSet: Codable, Sendable, Equatable {
    public var version: Int
    public var defaults: Defaults
    public var rules: [Rule]

    public struct Defaults: Codable, Sendable, Equatable {
        /// Environment for every launch.
        public var environment: [String: String]
        /// Extra environment per backend.
        public var backendEnvironment: [String: [String: String]]
    }

    public struct Rule: Codable, Sendable, Equatable {
        public var id: String
        public var match: Match
        public var windowedArguments: [String]?
        public var steps: [Step]
    }

    /// Every field that is present must match.
    public struct Match: Codable, Sendable, Equatable {
        public var engine: GameEngine?
        public var engineMajor: Int?
        public var renderingMethod: [String]?
        public var primaryAPI: [GraphicsAPI]?
        public var dotNet: Bool?
        /// Inclusive lower bound on the engine version, e.g. "4.3".
        public var versionAtLeast: String?
        /// Exclusive upper bound on the engine version.
        public var versionBelow: String?
    }

    public struct Step: Codable, Sendable, Equatable {
        public var id: String
        public var backend: GraphicsBackend
        public var arguments: [String]?
        public var environment: [String: String]?
    }

    public static let remoteURL = URL(string:
        "https://raw.githubusercontent.com/omarammarthefirst/halalWine/main/Sources/HalalWineCore/Resources/rules.json")!

    /// Rules shipped inside the app.
    public static func bundled() -> RuleSet {
        guard let url = CoreResources.bundle.url(forResource: "rules", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let rules = try? JSONDecoder().decode(RuleSet.self, from: data)
        else { fatalError("Bundled rules.json is missing or invalid") }
        return rules
    }

    /// The newest of the bundled rules and a downloaded copy (if any).
    public static func best(cached url: URL) -> RuleSet {
        let bundled = bundled()
        guard let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(RuleSet.self, from: data),
              cached.version > bundled.version else { return bundled }
        return cached
    }

    func matches(_ m: Match, _ report: GameReport) -> Bool {
        if let engine = m.engine, engine != report.engine { return false }
        if let major = m.engineMajor, major != report.engineMajorVersion { return false }
        if let methods = m.renderingMethod {
            guard let method = report.godot?.renderingMethod, methods.contains(method) else { return false }
        }
        if let apis = m.primaryAPI, !apis.contains(report.primaryAPI) { return false }
        if let dotNet = m.dotNet, dotNet != report.isDotNet { return false }
        if let low = m.versionAtLeast {
            guard let v = report.engineVersion, VersionCompare.compare(v, low) != .orderedAscending else { return false }
        }
        if let high = m.versionBelow {
            guard let v = report.engineVersion, VersionCompare.compare(v, high) == .orderedAscending else { return false }
        }
        return true
    }

    public func rule(for report: GameReport) -> Rule? {
        rules.first { matches($0.match, report) }
    }
}
