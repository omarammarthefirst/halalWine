import Foundation

/// Little-endian helpers over byte arrays. Every accessor is bounds-checked and
/// returns nil instead of trapping, because we read untrusted files.
extension Array where Element == UInt8 {
    func le16(_ i: Int) -> UInt16? {
        guard i >= 0, i + 2 <= count else { return nil }
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func le32(_ i: Int) -> UInt32? {
        guard i >= 0, i + 4 <= count else { return nil }
        var v: UInt32 = 0
        for k in 0..<4 { v |= UInt32(self[i + k]) << (8 * UInt32(k)) }
        return v
    }

    func le64(_ i: Int) -> UInt64? {
        guard i >= 0, i + 8 <= count else { return nil }
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(self[i + k]) << (8 * UInt64(k)) }
        return v
    }

    /// Reads a NUL-terminated ASCII/UTF-8 string.
    func cString(at i: Int, maxLength: Int = 512) -> String? {
        guard i >= 0, i < count else { return nil }
        let end = Swift.min(count, i + maxLength)
        var j = i
        while j < end && self[j] != 0 { j += 1 }
        return String(decoding: self[i..<j], as: UTF8.self)
    }

    /// Naive substring search; fine for the small buffers we scan.
    func firstIndex(of needle: [UInt8], from start: Int = 0) -> Int? {
        guard !needle.isEmpty, count >= needle.count else { return nil }
        var i = Swift.max(0, start)
        let last = count - needle.count
        let first = needle[0]
        while i <= last {
            if self[i] == first {
                var match = true
                for k in 1..<needle.count where self[i + k] != needle[k] {
                    match = false
                    break
                }
                if match { return i }
            }
            i += 1
        }
        return nil
    }

    func contains(bytes needle: [UInt8]) -> Bool { firstIndex(of: needle) != nil }

    /// Reads a NUL-terminated UTF-16LE string.
    func utf16String(at i: Int, maxChars: Int = 512) -> String? {
        guard i >= 0, i + 1 < count else { return nil }
        var units: [UInt16] = []
        var j = i
        while j + 1 < count, units.count < maxChars {
            let u = UInt16(self[j]) | UInt16(self[j + 1]) << 8
            if u == 0 { break }
            units.append(u)
            j += 2
        }
        return String(decoding: units, as: UTF16.self)
    }
}

/// Random-access reader that never loads a whole file (game executables and
/// Godot packs can be several gigabytes).
final class FileReader {
    let size: UInt64
    private let handle: FileHandle

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    func read(at offset: UInt64, count: Int) -> [UInt8] {
        guard count > 0, offset < size else { return [] }
        let n = Int(Swift.min(UInt64(count), size - offset))
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: n) else { return [] }
            return [UInt8](data)
        } catch {
            return []
        }
    }

    func u32(at offset: UInt64) -> UInt32? { read(at: offset, count: 4).le32(0) }
    func u64(at offset: UInt64) -> UInt64? { read(at: offset, count: 8).le64(0) }
}

extension String {
    var utf16LEBytes: [UInt8] {
        var out: [UInt8] = []
        for u in utf16 { out.append(UInt8(u & 0xFF)); out.append(UInt8(u >> 8)) }
        return out
    }
}
