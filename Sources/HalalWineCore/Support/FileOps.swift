import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum FileOps {
    /// Copies a file or folder. On APFS this is an instant copy-on-write clone
    /// that uses no extra disk space until something changes.
    public static func cloneItem(at source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if canImport(Darwin)
        if clonefile(source.path, destination.path, 0) == 0 { return }
        #endif
        try fm.copyItem(at: source, to: destination)
    }

    /// Copies everything inside `source` into `destination`, replacing files
    /// that already exist and keeping symbolic links as links.
    public static func mergeContents(of source: URL, into destination: URL) throws {
        let fm = FileManager.default
        #if os(macOS)
        if fm.fileExists(atPath: "/usr/bin/ditto") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = [source.path, destination.path]
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 { return }
        }
        #endif
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: source.path) {
            let from = source.appendingPathComponent(name)
            let to = destination.appendingPathComponent(name)
            let attrs = try fm.attributesOfItem(atPath: from.path)
            let isLink = (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
            var isDir: ObjCBool = false
            if !isLink, fm.fileExists(atPath: from.path, isDirectory: &isDir), isDir.boolValue {
                try mergeContents(of: from, into: to)
            } else {
                if (try? fm.attributesOfItem(atPath: to.path)) != nil { try fm.removeItem(at: to) }
                try fm.copyItem(at: from, to: to)
            }
        }
    }

    /// Copies a single file over any existing file.
    public static func replaceFile(at destination: URL, with source: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? fm.attributesOfItem(atPath: destination.path)) != nil { try fm.removeItem(at: destination) }
        try fm.copyItem(at: source, to: destination)
    }

    public static func files(in directory: URL, withExtension ext: String) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == ext.lowercased() }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}
