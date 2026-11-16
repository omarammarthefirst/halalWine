import Foundation

/// Facts read from a Godot resource pack (.pck), standalone or embedded in the .exe.
public struct GodotPackInfo: Codable, Equatable, Sendable {
    public var packFormat: UInt32
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var embedded: Bool
    public var encryptedDirectory: Bool
    /// Godot 4: "forward_plus", "mobile" or "gl_compatibility".
    /// Godot 3: "GLES3" or "GLES2". Nil when it could not be read.
    public var renderingMethod: String?

    public var version: String { "\(major).\(minor).\(patch)" }
}

/// Parses the pack header and, when the directory is not encrypted, the
/// project's settings to learn which renderer the game was made for.
/// Format reference: godot/core/io/file_access_pack.cpp (pack formats 1–4).
public enum GodotPackReader {
    static let magic: UInt32 = 0x4350_4447 // "GDPC"

    public static func read(pck url: URL) -> GodotPackInfo? {
        guard let r = try? FileReader(url: url), r.u32(at: 0) == magic else { return nil }
        return parse(r, start: 0, embedded: false)
    }

    /// Godot 4.5+ stores the pack in a "pck" PE section; older versions append
    /// it to the end of the executable followed by its size and the magic.
    public static func readEmbedded(exe url: URL, pe: PEInfo?) -> GodotPackInfo? {
        guard let r = try? FileReader(url: url) else { return nil }
        if let section = pe?.sections.first(where: { $0.name == "pck" }) {
            let start = UInt64(section.rawOffset)
            for delta in 0..<8 where r.u32(at: start + UInt64(delta)) == magic {
                return parse(r, start: start + UInt64(delta), embedded: true)
            }
        }
        guard r.size > 16, r.u32(at: r.size - 4) == magic, let packSize = r.u64(at: r.size - 12),
              packSize < r.size else { return nil }
        let start = r.size - 12 - packSize
        guard r.u32(at: start) == magic else { return nil }
        return parse(r, start: start, embedded: true)
    }

    static func parse(_ r: FileReader, start: UInt64, embedded: Bool) -> GodotPackInfo? {
        let header = r.read(at: start + 4, count: 16)
        guard let format = header.le32(0), let major = header.le32(4), let minor = header.le32(8),
              let patch = header.le32(12), (1...4).contains(format), (2...9).contains(major) else { return nil }

        var info = GodotPackInfo(packFormat: format, major: Int(major), minor: Int(minor), patch: Int(patch),
                                 embedded: embedded, encryptedDirectory: false, renderingMethod: nil)
        var cursor = start + 20
        var fileBase: UInt64 = 0
        let directoryOffset: UInt64
        if format >= 2 {
            let flags = r.u32(at: cursor) ?? 0
            fileBase = r.u64(at: cursor + 4) ?? 0
            cursor += 12
            if format >= 3 || (flags & 2) != 0 { fileBase &+= start }
            info.encryptedDirectory = (flags & 1) != 0
            if format >= 3 {
                directoryOffset = (r.u64(at: cursor) ?? 0) &+ start
            } else {
                directoryOffset = cursor + 64 // 16 reserved words
            }
        } else {
            directoryOffset = cursor + 64
        }
        guard !info.encryptedDirectory, directoryOffset < r.size else { return info }

        // Read the directory in one bounded chunk and walk it.
        let chunk = r.read(at: directoryOffset, count: 32 * 1024 * 1024)
        guard let fileCount = chunk.le32(0) else { return info }
        var c = 4
        for _ in 0..<Swift.min(Int(fileCount), 1_000_000) {
            guard let pathLength = chunk.le32(c), pathLength <= 8192, c + 4 + Int(pathLength) <= chunk.count else { break }
            c += 4
            let path = String(decoding: chunk[c..<(c + Int(pathLength))].prefix { $0 != 0 }, as: UTF8.self)
            c += Int(pathLength)
            guard let offset = chunk.le64(c), let size = chunk.le64(c + 8) else { break }
            c += 16 + 16 // offset, size, md5
            var fileFlags: UInt32 = 0
            if format >= 2 {
                fileFlags = chunk.le32(c) ?? 0
                c += 4
            }
            guard path == "res://project.binary" || path == "project.binary" else { continue }
            if (fileFlags & 1) != 0 { break } // encrypted file
            let candidates = format >= 2 ? [fileBase &+ offset] : [start &+ offset, offset]
            for position in candidates {
                let data = r.read(at: position, count: Int(Swift.min(size, 4 * 1024 * 1024)))
                if data.starts(with: Array("ECFG".utf8)) {
                    info.renderingMethod = renderingMethod(inProjectBinary: data, major: Int(major))
                    break
                }
            }
            break
        }
        return info
    }

    /// Looks up the renderer setting in a binary project.godot ("ECFG").
    static func renderingMethod(inProjectBinary data: [UInt8], major: Int) -> String {
        let key: String
        let values: [String]
        let fallback: String
        if major >= 4 {
            key = "rendering/renderer/rendering_method"
            values = ["gl_compatibility", "forward_plus", "mobile"]
            fallback = "forward_plus"
        } else {
            key = "rendering/quality/driver/driver_name"
            values = ["GLES2", "GLES3"]
            fallback = "GLES3"
        }
        let needle = Array(key.utf8)
        var from = 0
        while let i = data.firstIndex(of: needle, from: from) {
            let after = i + needle.count
            // Skip platform overrides such as "rendering_method.mobile".
            if after < data.count, data[after] != UInt8(ascii: ".") {
                // Entry layout: [u32 key length][key][u32 value length][variant].
                // A String variant is [u32 type = 4][u32 length][UTF-8 bytes].
                if let type = data.le32(after + 4), type & 0xFF == 4, let length = data.le32(after + 8),
                   length < 64, after + 12 + Int(length) <= data.count {
                    let value = String(decoding: data[(after + 12)..<(after + 12 + Int(length))], as: UTF8.self)
                    if values.contains(value) { return value }
                }
                // Unknown encoding: take whichever known value appears first.
                let window = Array(data[after..<Swift.min(data.count, after + 48)])
                let hits = values.compactMap { v in window.firstIndex(of: Array(v.utf8)).map { ($0, v) } }
                if let first = hits.min(by: { $0.0 < $1.0 }) { return first.1 }
            }
            from = after
        }
        return fallback
    }
}
