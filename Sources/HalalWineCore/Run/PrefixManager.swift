import Foundation

/// Builds Wine environment variables shared by every Wine invocation.
public enum WineEnvironment {
    public static func make(wineRoot: URL, prefix: URL,
                            base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base.filter { key, _ in
            !key.hasPrefix("DYLD_") && !key.hasPrefix("WINE") && key != "LD_LIBRARY_PATH"
        }
        env["WINEPREFIX"] = prefix.path
        env["WINEDEBUG"] = "-all"
        let systemPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = wineRoot.appendingPathComponent("bin").path + ":" + systemPath
        return env
    }
}

/// Wine prefixes ("bottles"). One template per runtime is created with
/// `wineboot` once; every game then gets an instant copy-on-write clone so
/// games stay isolated without each paying the 30–60 s setup cost.
public struct PrefixManager: Sendable {
    public let paths: AppPaths
    static let templateMarker = ".halalwine-template"

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func templateURL(for runtime: InstalledRuntime) -> URL {
        paths.templates.appendingPathComponent(runtime.info.version, isDirectory: true)
    }

    public func isTemplateReady(for runtime: InstalledRuntime) -> Bool {
        FileOps.exists(templateURL(for: runtime).appendingPathComponent(Self.templateMarker))
    }

    public func createTemplate(for runtime: InstalledRuntime) async throws {
        try paths.ensureDirectories()
        let final = templateURL(for: runtime)
        if isTemplateReady(for: runtime) { return }
        let building = paths.templates.appendingPathComponent(".building-\(runtime.info.version)", isDirectory: true)
        try? FileManager.default.removeItem(at: building)

        let wineRoot = runtime.baseWine
        var env = WineEnvironment.make(wineRoot: wineRoot, prefix: building)
        // Gecko (Internet Explorer engine) is rarely needed by games. Mono
        // (.NET) installs silently when the runtime ships it.
        let hasMono = FileOps.exists(wineRoot.appendingPathComponent("share/wine/mono"))
        env["WINEDLLOVERRIDES"] = hasMono ? "mshtml=" : "mshtml=;mscoree="

        let log = paths.logs.appendingPathComponent("wineboot-\(runtime.info.version).log")
        try await ProcessRunner.run(InstalledRuntime.wineBinary(in: wineRoot), ["wineboot", "--init"],
                                    environment: env, logFile: log, timeout: 900)
        try await ProcessRunner.run(InstalledRuntime.wineserverBinary(in: wineRoot), ["-w"],
                                    environment: env, logFile: log, timeout: 300)
        guard FileOps.exists(building.appendingPathComponent("system.reg")) else {
            throw PrefixError.wineBootFailed(log)
        }
        try Data().write(to: building.appendingPathComponent(Self.templateMarker))
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: building, to: final)
    }

    /// Returns the game's prefix, cloning the template the first time.
    public func ensurePrefix(for gameID: UUID, runtime: InstalledRuntime) async throws -> URL {
        let prefix = paths.prefix(for: gameID)
        if FileOps.exists(prefix.appendingPathComponent("system.reg")) { return prefix }
        try await createTemplate(for: runtime)
        try? FileManager.default.removeItem(at: prefix)
        try FileOps.cloneItem(at: templateURL(for: runtime), to: prefix)
        try? FileManager.default.removeItem(at: prefix.appendingPathComponent(Self.templateMarker))
        return prefix
    }

    /// Stops every Wine process that belongs to a prefix.
    public static func killAll(prefix: URL, wineRoot: URL) async {
        let env = WineEnvironment.make(wineRoot: wineRoot, prefix: prefix)
        _ = try? await ProcessRunner.run(InstalledRuntime.wineserverBinary(in: wineRoot), ["-k"],
                                         environment: env, timeout: 20)
    }
}

public enum PrefixError: Error, Equatable {
    case wineBootFailed(URL)
}
