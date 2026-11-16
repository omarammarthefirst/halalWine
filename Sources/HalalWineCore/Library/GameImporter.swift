import Foundation

public struct ImportedItem: Sendable {
    public var report: GameReport
    public var isManagedCopy: Bool
}

/// Turns a dropped folder, .exe or .zip into an inspected game.
///
/// When "keep games inside halalWine" is on, the folder is cloned into the
/// app's Games folder so the game keeps working if the user cleans up their
/// Downloads. On APFS the clone is instant and takes no extra space; if a clone
/// is not possible (another disk) the game is used where it is.
public struct GameImporter: Sendable {
    public let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func importItem(at url: URL, keepInsideLibrary: Bool) async throws -> ImportedItem {
        try paths.ensureDirectories()
        let ext = url.pathExtension.lowercased()

        if ext == "zip" {
            let destination = uniqueFolder(named: GameInspector.cleanName(url.deletingPathExtension().lastPathComponent))
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            #if os(macOS)
            let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", url.path, destination.path])
            #else
            let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-q", url.path, "-d", destination.path])
            #endif
            guard result.status == 0 else { throw RuntimeError.extractionFailed(result.output) }
            return ImportedItem(report: try GameInspector().inspect(singleChildFolder(of: destination)), isManagedCopy: true)
        }

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let inspector = GameInspector()
        let original = try inspector.inspect(url)

        guard keepInsideLibrary, original.kind == .game, !original.rootFolder.hasPrefix(paths.root.path) else {
            return ImportedItem(report: original, isManagedCopy: false)
        }
        let sourceRoot = URL(fileURLWithPath: original.rootFolder)
        let destination = uniqueFolder(named: sourceRoot.lastPathComponent)
        guard Self.cloneOnly(sourceRoot, to: destination) else {
            return ImportedItem(report: original, isManagedCopy: false)
        }
        let relativeExe = String(original.executable.dropFirst(original.rootFolder.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let target = isDirectory.boolValue && relativeExe.isEmpty ? destination : destination.appendingPathComponent(relativeExe)
        var report = try inspector.inspect(isDirectory.boolValue ? destination : target)
        if !isDirectory.boolValue { report.displayName = original.displayName }
        return ImportedItem(report: report, isManagedCopy: true)
    }

    /// Clones without falling back to a slow full copy.
    static func cloneOnly(_ source: URL, to destination: URL) -> Bool {
        #if os(macOS)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            return clonefile(source.path, destination.path, 0) == 0
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    func uniqueFolder(named name: String) -> URL {
        let base = name.isEmpty ? "Game" : name
        var candidate = paths.games.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileOps.exists(candidate) {
            candidate = paths.games.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }

    /// Zips often contain a single top-level folder; use it as the game root.
    func singleChildFolder(of folder: URL) -> URL {
        let children = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
        if children.count == 1, (try? children[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return children[0]
        }
        return folder
    }
}
