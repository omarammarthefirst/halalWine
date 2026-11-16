import Foundation
@testable import HalalWineCore

/// Builds tiny but valid Windows executables and Godot packs for tests.
enum Fixtures {
    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
    static func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }

    static func put(_ bytes: [UInt8], at offset: Int, in buffer: inout [UInt8]) {
        if buffer.count < offset + bytes.count { buffer += [UInt8](repeating: 0, count: offset + bytes.count - buffer.count) }
        buffer.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    /// A PE32+ file with one ".rdata" section holding the import table and,
    /// optionally, a "pck" section (Godot 4.5+ embedding).
    static func makePE(machine: UInt16 = 0x8664, subsystem: UInt16 = 2, imports: [String] = [],
                       delayImports: [String] = [], dotNet: Bool = false, pckSection: [UInt8]? = nil) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 0x400)
        b[0] = 0x4D; b[1] = 0x5A
        put(le32(0x80), at: 0x3C, in: &b)
        put(Array("PE\0\0".utf8), at: 0x80, in: &b)
        let sectionCount: UInt16 = pckSection == nil ? 1 : 2
        put(le16(machine) + le16(sectionCount) + le32(0) + le32(0) + le32(0) + le16(240) + le16(0x22), at: 0x84, in: &b)

        let opt = 0x98
        put(le16(0x20B), at: opt, in: &b)
        put(le64(0x1_4000_0000), at: opt + 24, in: &b)
        put(le16(subsystem), at: opt + 68, in: &b)
        put(le32(16), at: opt + 108, in: &b)

        // .rdata contents: import descriptors, delay descriptors, names.
        var rdata = [UInt8](repeating: 0, count: 0x1000)
        let importTable = 0
        let delayTable = 0x200
        var nameCursor = 0x400
        func addName(_ name: String) -> UInt32 {
            let rva = UInt32(0x1000 + nameCursor)
            put(Array(name.utf8) + [0], at: nameCursor, in: &rdata)
            nameCursor += name.utf8.count + 1
            return rva
        }
        for (i, dll) in imports.enumerated() {
            let rva = addName(dll)
            put(le32(rva), at: importTable + i * 20 + 12, in: &rdata)
            put(le32(0x1800), at: importTable + i * 20 + 16, in: &rdata)
        }
        for (i, dll) in delayImports.enumerated() {
            let rva = addName(dll)
            put(le32(1) + le32(rva), at: delayTable + i * 32, in: &rdata)
        }
        if !imports.isEmpty { put(le32(0x1000) + le32(UInt32((imports.count + 1) * 20)), at: opt + 112 + 8, in: &b) }
        if !delayImports.isEmpty { put(le32(0x1200) + le32(UInt32((delayImports.count + 1) * 32)), at: opt + 112 + 13 * 8, in: &b) }
        if dotNet { put(le32(0x1E00) + le32(72), at: opt + 112 + 14 * 8, in: &b) }

        let sections = opt + 240
        put(Array(".rdata\0\0".utf8) + le32(0x1000) + le32(0x1000) + le32(0x1000) + le32(0x400), at: sections, in: &b)
        b += rdata
        if let pck = pckSection {
            let raw = b.count
            put(Array("pck\0\0\0\0\0".utf8) + le32(UInt32(pck.count)) + le32(0x2000) + le32(UInt32(pck.count)) + le32(UInt32(raw)),
                at: sections + 40, in: &b)
            b += pck
        }
        return b
    }

    static func projectBinary(_ settings: [String: String]) -> [UInt8] {
        var out = Array("ECFG".utf8) + le32(UInt32(settings.count))
        for (key, value) in settings.sorted(by: { $0.key < $1.key }) {
            let utf8 = Array(value.utf8)
            let pad = (4 - utf8.count % 4) % 4
            let variant = le32(4) + le32(UInt32(utf8.count)) + utf8 + [UInt8](repeating: 0, count: pad)
            out += le32(UInt32(key.utf8.count)) + Array(key.utf8) + le32(UInt32(variant.count)) + variant
        }
        return out
    }

    /// A Godot pack (format 2 or 3) whose only file is project.binary.
    static func makePCK(format: UInt32, major: UInt32, minor: UInt32, patch: UInt32 = 0,
                        settings: [String: String] = [:], pathPrefix: String = "res://") -> [UInt8] {
        let project = projectBinary(settings)
        let path = Array("\(pathPrefix)project.binary".utf8)
        let padded = path + [UInt8](repeating: 0, count: (4 - path.count % 4) % 4)
        func directory(fileOffset: UInt64) -> [UInt8] {
            le32(1) + le32(UInt32(padded.count)) + padded + le64(fileOffset) + le64(UInt64(project.count))
                + [UInt8](repeating: 0, count: 16) + (format >= 2 ? le32(0) : [])
        }
        var out = Array("GDPC".utf8) + le32(format) + le32(major) + le32(minor) + le32(patch)
        if format == 2 {
            let headerSize = out.count + 4 + 8 + 64
            let dir = directory(fileOffset: 0)
            let fileBase = UInt64(headerSize + dir.count)
            out += le32(0) + le64(fileBase) + [UInt8](repeating: 0, count: 64) + dir + project
        } else {
            let headerSize = out.count + 4 + 8 + 8 + 64
            let fileBase = UInt64(headerSize)
            let dirOffset = UInt64(headerSize + project.count)
            out += le32(2) + le64(fileBase) + le64(dirOffset) + [UInt8](repeating: 0, count: 64) + project + directory(fileOffset: 0)
        }
        return out
    }

    /// Creates a file tree under a fresh temporary folder.
    static func tree(_ files: [String: [UInt8]], folderName: String = "Game") throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("halalwine-tests-\(UUID().uuidString)")
            .appendingPathComponent(folderName)
        for (path, bytes) in files {
            let url = base.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(bytes).write(to: url)
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
