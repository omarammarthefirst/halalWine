import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Published list of runtimes (Runtime/manifest.json in the repository).
public struct RuntimeManifest: Codable, Sendable, Equatable {
    public var schema: Int
    public var runtimes: [RuntimeRelease]

    public var latest: RuntimeRelease? {
        runtimes.max { VersionCompare.compare($0.version, $1.version) == .orderedAscending }
    }

    public static let defaultURL = URL(string:
        "https://raw.githubusercontent.com/omarammarthefirst/halalWine/main/Runtime/manifest.json")!
}

public struct RuntimeRelease: Codable, Sendable, Equatable {
    public var version: String
    public var wineVersion: String
    public var url: URL
    public var sha256: String?
    public var size: Int64?
    public var components: [String: String]?
}

/// runtime.json inside every runtime archive.
public struct RuntimeInfo: Codable, Sendable, Equatable {
    public var version: String
    public var wineVersion: String
    public var components: [String: String]
}

public enum RuntimeError: Error, Equatable {
    case invalidArchive
    case noRuntimePublished
    case missingWine
    case d3dmetalNotInstalled
    case d3dmetalNotFound
    case extractionFailed(String)
}

/// A runtime unpacked under Runtimes/<version>:
///
///     wine/                       Wine itself (bin, lib, share)
///     components/dxmt/            x86_64-unix, x86_64-windows, i386-windows
///     components/dxvk/            x64, x32
///     variants/<backend>/         copy-on-write clones of wine/ with a backend's
///                                 DLLs installed as built-ins (DXMT, D3DMetal)
public struct InstalledRuntime: Sendable, Equatable {
    public let root: URL
    public let info: RuntimeInfo

    public init(root: URL, info: RuntimeInfo) {
        self.root = root
        self.info = info
    }

    public var baseWine: URL { root.appendingPathComponent("wine", isDirectory: true) }
    public var dxmtComponent: URL { root.appendingPathComponent("components/dxmt", isDirectory: true) }
    public var dxvkComponent: URL { root.appendingPathComponent("components/dxvk", isDirectory: true) }
    var variants: URL { root.appendingPathComponent("variants", isDirectory: true) }
    static let variantMarker = ".halalwine-variant"

    public var hasDXMT: Bool {
        FileOps.exists(dxmtComponent.appendingPathComponent("x86_64-windows/d3d11.dll"))
            && FileOps.exists(dxmtComponent.appendingPathComponent("x86_64-unix/winemetal.so"))
    }

    public var hasDXVK: Bool { !FileOps.files(in: dxvkComponent.appendingPathComponent("x64"), withExtension: "dll").isEmpty }

    public var hasD3DMetal: Bool {
        FileOps.exists(variants.appendingPathComponent("d3dmetal/\(Self.variantMarker)"))
    }

    public var availableBackends: Set<GraphicsBackend> {
        var set: Set<GraphicsBackend> = [.wined3d]
        if hasDXMT { set.insert(.dxmt) }
        if hasDXVK { set.insert(.dxvk) }
        if hasD3DMetal { set.insert(.d3dmetal) }
        return set
    }

    public static func wineBinary(in wineRoot: URL) -> URL {
        let wine = wineRoot.appendingPathComponent("bin/wine")
        return FileOps.exists(wine) ? wine : wineRoot.appendingPathComponent("bin/wine64")
    }

    public static func wineserverBinary(in wineRoot: URL) -> URL {
        wineRoot.appendingPathComponent("bin/wineserver")
    }

    /// The Wine tree to run for a backend, creating its variant if needed.
    public func wineRoot(for backend: GraphicsBackend) throws -> URL {
        guard FileOps.exists(Self.wineBinary(in: baseWine)) else { throw RuntimeError.missingWine }
        switch backend {
        case .wined3d, .dxvk:
            return baseWine
        case .dxmt:
            return try ensureDXMTVariant()
        case .d3dmetal:
            guard hasD3DMetal else { throw RuntimeError.d3dmetalNotInstalled }
            return variants.appendingPathComponent("d3dmetal", isDirectory: true)
        }
    }

    /// DXMT replaces Wine's own DirectX DLLs, so it lives in its own clone of
    /// the Wine tree. WineD3D stays untouched in the base tree.
    func ensureDXMTVariant() throws -> URL {
        let target = variants.appendingPathComponent("dxmt", isDirectory: true)
        let stamp = "\(info.version)|\(info.components["dxmt"] ?? "")"
        let marker = target.appendingPathComponent(Self.variantMarker)
        if let existing = try? String(contentsOf: marker, encoding: .utf8), existing == stamp { return target }

        try? FileManager.default.removeItem(at: target)
        try FileOps.cloneItem(at: baseWine, to: target)
        for arch in ["x86_64-unix", "x86_64-windows", "i386-windows"] {
            let from = dxmtComponent.appendingPathComponent(arch)
            guard FileOps.exists(from) else { continue }
            try FileOps.mergeContents(of: from, into: target.appendingPathComponent("lib/wine/\(arch)"))
        }
        try stamp.write(to: marker, atomically: true, encoding: .utf8)
        return target
    }

    /// Installs Apple's D3DMetal from the Game Porting Toolkit's `redist/lib`
    /// folder (on the disk image the user downloaded from Apple).
    public func installD3DMetal(redistLib: URL) throws {
        guard FileOps.exists(redistLib.appendingPathComponent("external"))
                || FileOps.exists(redistLib.appendingPathComponent("wine")) else { throw RuntimeError.d3dmetalNotFound }
        let target = variants.appendingPathComponent("d3dmetal", isDirectory: true)
        try? FileManager.default.removeItem(at: target)
        try FileOps.cloneItem(at: baseWine, to: target)
        try FileOps.mergeContents(of: redistLib, into: target.appendingPathComponent("lib"))
        try "\(info.version)|gptk".write(to: target.appendingPathComponent(Self.variantMarker), atomically: true, encoding: .utf8)
    }

    public func removeD3DMetal() throws {
        try FileManager.default.removeItem(at: variants.appendingPathComponent("d3dmetal"))
    }

    /// Finds `redist/lib` inside a mounted Game Porting Toolkit image or folder.
    public static func findRedistLib(in folder: URL) -> URL? {
        let direct = [folder, folder.appendingPathComponent("lib"), folder.appendingPathComponent("redist/lib")]
        if let hit = direct.first(where: { FileOps.exists($0.appendingPathComponent("external/D3DMetal.framework")) }) {
            return hit
        }
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        while let item = enumerator.nextObject() as? URL {
            if enumerator.level > 4 { enumerator.skipDescendants(); continue }
            if item.lastPathComponent == "D3DMetal.framework" {
                return item.deletingLastPathComponent().deletingLastPathComponent()
            }
        }
        return nil
    }
}

/// Installed runtimes on disk.
public final class RuntimeStore {
    public let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func installed() -> [InstalledRuntime] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: paths.runtimes, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir -> InstalledRuntime? in
            guard !dir.lastPathComponent.hasPrefix("."),
                  let data = try? Data(contentsOf: dir.appendingPathComponent("runtime.json")),
                  let info = try? JSONDecoder().decode(RuntimeInfo.self, from: data) else { return nil }
            return InstalledRuntime(root: dir, info: info)
        }
        .sorted { VersionCompare.isNewer($0.info.version, than: $1.info.version) }
    }

    public var current: InstalledRuntime? { installed().first }

    /// Unpacks a runtime archive (.tar.xz / .tar.gz) into Runtimes/<version>.
    public func install(archive: URL) async throws -> InstalledRuntime {
        try paths.ensureDirectories()
        let fm = FileManager.default
        let incoming = paths.runtimes.appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: incoming) }

        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xf", archive.path, "-C", incoming.path])
        guard result.status == 0 else { throw RuntimeError.extractionFailed(result.output) }

        var runtimeDir: URL?
        if FileOps.exists(incoming.appendingPathComponent("runtime.json")) {
            runtimeDir = incoming
        } else {
            for child in (try? fm.contentsOfDirectory(at: incoming, includingPropertiesForKeys: nil)) ?? []
            where FileOps.exists(child.appendingPathComponent("runtime.json")) {
                runtimeDir = child
            }
        }
        guard let runtimeDir,
              let data = try? Data(contentsOf: runtimeDir.appendingPathComponent("runtime.json")),
              let info = try? JSONDecoder().decode(RuntimeInfo.self, from: data) else { throw RuntimeError.invalidArchive }

        let destination = paths.runtimes.appendingPathComponent(info.version, isDirectory: true)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: runtimeDir, to: destination)
        #if os(macOS)
        _ = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-dr", "com.apple.quarantine", destination.path])
        #endif
        return InstalledRuntime(root: destination, info: info)
    }

    public static func fetchManifest(from url: URL = RuntimeManifest.defaultURL) async throws -> RuntimeManifest {
        let data = try await HTTP.get(url)
        return try JSONDecoder().decode(RuntimeManifest.self, from: data)
    }

    /// Downloads, verifies and installs the newest published runtime.
    public func installLatest(manifestURL: URL = RuntimeManifest.defaultURL,
                              progress: FileDownloader.Progress? = nil) async throws -> InstalledRuntime {
        let manifest = try await Self.fetchManifest(from: manifestURL)
        guard let release = manifest.latest else { throw RuntimeError.noRuntimePublished }
        try paths.ensureDirectories()
        let archive = paths.cache.appendingPathComponent(release.url.lastPathComponent)
        _ = try await FileDownloader(progress: progress).download(release.url, to: archive)
        defer { try? FileManager.default.removeItem(at: archive) }
        if let expected = release.sha256, !expected.isEmpty {
            guard try Checksum.sha256(of: archive).lowercased() == expected.lowercased() else {
                throw DownloadError.checksumMismatch
            }
        }
        return try await install(archive: archive)
    }
}

public enum HTTP {
    /// Adds a throwaway query so CDN caches (raw.githubusercontent.com keeps
    /// files for ~5 minutes) never hand out a stale manifest or rule file.
    public static func freshURL(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))]
        return parts.url ?? url
    }

    public static func get(_ url: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            var request = URLRequest(url: freshURL(url))
            request.cachePolicy = .reloadIgnoringLocalCacheData
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error { return continuation.resume(throwing: error) }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    return continuation.resume(throwing: DownloadError.badStatus(http.statusCode))
                }
                continuation.resume(returning: data ?? Data())
            }.resume()
        }
    }
}
