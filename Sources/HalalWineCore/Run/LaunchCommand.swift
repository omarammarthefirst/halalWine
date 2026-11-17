import Foundation

/// User-level preferences that affect how a game is launched.
public struct LaunchSettings: Codable, Equatable, Sendable {
    public var preferWindowed: Bool
    /// Shows Apple's Metal performance HUD (frame rate) over the game.
    public var metalHUD: Bool
    /// Makes Rosetta advertise AVX/AVX2 (macOS 15+); many newer games need it.
    public var advertiseAVX: Bool
    public var extraArguments: [String]
    public var extraEnvironment: [String: String]

    public init(preferWindowed: Bool = true, metalHUD: Bool = false, advertiseAVX: Bool = false,
                extraArguments: [String] = [], extraEnvironment: [String: String] = [:]) {
        self.preferWindowed = preferWindowed
        self.metalHUD = metalHUD
        self.advertiseAVX = advertiseAVX
        self.extraArguments = extraArguments
        self.extraEnvironment = extraEnvironment
    }
}

/// A fully resolved command: run `executable arguments` in `workingDirectory`.
public struct LaunchCommand: Sendable, Equatable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL
    public var wineRoot: URL
    public var prefix: URL

    public init(executable: URL, arguments: [String], environment: [String: String],
                workingDirectory: URL, wineRoot: URL, prefix: URL) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.wineRoot = wineRoot
        self.prefix = prefix
    }
}

public enum LaunchCommandBuilder {
    public static func build(gameExecutable: URL,
                             config: LaunchConfig,
                             plan: LaunchPlan,
                             runtime: InstalledRuntime,
                             wineRoot: URL,
                             prefix: URL,
                             rules: RuleSet,
                             settings: LaunchSettings,
                             baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> LaunchCommand {
        var env = WineEnvironment.make(wineRoot: wineRoot, prefix: prefix, base: baseEnvironment)
        for (k, v) in rules.defaults.environment { env[k] = v }
        for (k, v) in rules.defaults.backendEnvironment[config.backend.rawValue] ?? [:] { env[k] = v }
        for (k, v) in config.environment { env[k] = v }
        if settings.metalHUD { env["MTL_HUD_ENABLED"] = "1" }
        if settings.advertiseAVX { env["ROSETTA_ADVERTISE_AVX"] = "1" }
        for (k, v) in settings.extraEnvironment { env[k] = v }
        env["WINEDLLOVERRIDES"] = BackendSetup.overridesString(BackendSetup.dllOverrides(for: config.backend, runtime: runtime))

        var arguments = [gameExecutable.path] + config.arguments
        if settings.preferWindowed, let first = plan.windowedArguments.first, !arguments.contains(first) {
            arguments += plan.windowedArguments
        }
        arguments += settings.extraArguments

        return LaunchCommand(
            executable: InstalledRuntime.wineBinary(in: wineRoot),
            arguments: arguments,
            environment: env,
            workingDirectory: gameExecutable.deletingLastPathComponent(),
            wineRoot: wineRoot,
            prefix: prefix
        )
    }
}
