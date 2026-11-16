import Foundation

/// Windows runtimes that games commonly need and Wine does not include.
public enum Dependency: String, Codable, CaseIterable, Sendable {
    case vcredist
    case directx
    case xna

    public static func from(_ diagnosis: Diagnosis) -> Dependency? {
        switch diagnosis {
        case .needsVCRedist: return .vcredist
        case .needsDirectXRuntime: return .directx
        case .needsXNA: return .xna
        default: return nil
        }
    }

    /// Official Microsoft downloads, used only when the game does not ship its own copy.
    var downloads: [URL] {
        switch self {
        case .vcredist:
            return [URL(string: "https://aka.ms/vs/17/release/vc_redist.x64.exe")!,
                    URL(string: "https://aka.ms/vs/17/release/vc_redist.x86.exe")!]
        case .directx:
            return [URL(string: "https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe")!]
        case .xna:
            return [URL(string: "https://download.microsoft.com/download/A/C/2/AC2C903B-E6E8-42C2-9FD7-BEBAC362A930/xnafx40_redist.msi")!]
        }
    }
}

/// Installs dependencies into a game's prefix, preferring installers that
/// ship inside the game folder (Steam's _CommonRedist, Unreal's prerequisites).
public struct DependencyInstaller: Sendable {
    public let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public static func windowsPath(_ url: URL) -> String {
        "Z:" + url.path.replacingOccurrences(of: "/", with: "\\")
    }

    public func install(_ dependency: Dependency, prefix: URL, wineRoot: URL, report: GameReport) async throws {
        try paths.ensureDirectories()
        let root = URL(fileURLWithPath: report.rootFolder)
        let bundled = report.bundledRedistributables.map { root.appendingPathComponent($0) }
        let log = paths.logs.appendingPathComponent("dependencies-\(prefix.lastPathComponent).log")
        let env = WineEnvironment.make(wineRoot: wineRoot, prefix: prefix)
        let wine = InstalledRuntime.wineBinary(in: wineRoot)

        func run(_ args: [String]) async throws {
            try await ProcessRunner.run(wine, args, environment: env, logFile: log, timeout: 1800)
            try await ProcessRunner.run(InstalledRuntime.wineserverBinary(in: wineRoot), ["-w"],
                                        environment: env, logFile: log, timeout: 600)
        }

        switch dependency {
        case .vcredist:
            var installers = bundled.filter {
                let name = $0.lastPathComponent.lowercased()
                return name.hasPrefix("vc_redist") || name.hasPrefix("vcredist") || name.hasPrefix("ueprereqsetup")
            }
            if installers.isEmpty { installers = try await download(dependency) }
            for exe in installers {
                let name = exe.lastPathComponent.lowercased()
                let args = name.hasPrefix("vcredist") ? ["/q", "/norestart"] : ["/install", "/quiet", "/norestart"]
                try await run([exe.path] + args)
            }
        case .directx:
            if let setup = bundled.first(where: { $0.lastPathComponent.lowercased() == "dxsetup.exe" }) {
                try await run([setup.path, "/silent"])
            } else if let redist = try await download(dependency).first {
                let target = prefix.appendingPathComponent("drive_c/halalwine-directx")
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                try await run([redist.path, "/Q", "/T:C:\\halalwine-directx"])
                try await run([target.appendingPathComponent("DXSETUP.exe").path, "/silent"])
                try? FileManager.default.removeItem(at: target)
            }
        case .xna:
            var msi = bundled.first { $0.lastPathComponent.lowercased().hasPrefix("xnafx") }
            if msi == nil { msi = try await download(dependency).first }
            if let msi { try await run(["msiexec", "/i", Self.windowsPath(msi), "/qn"]) }
        }
    }

    private func download(_ dependency: Dependency) async throws -> [URL] {
        var files: [URL] = []
        for url in dependency.downloads {
            let destination = paths.cache.appendingPathComponent("redist/\(url.lastPathComponent)")
            if !FileOps.exists(destination) {
                _ = try await FileDownloader().download(url, to: destination)
            }
            files.append(destination)
        }
        return files
    }
}
