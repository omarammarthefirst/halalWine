import Foundation

/// Reads the resource tree of a PE file: the program icon and version strings
/// (product name), so the library can show a real name and picture.
public struct PEResources {
    private let reader: FileReader
    private let info: PEInfo
    private let base: UInt64

    static let rtIcon: UInt32 = 3
    static let rtGroupIcon: UInt32 = 14
    static let rtVersion: UInt32 = 16

    init?(reader: FileReader, info: PEInfo) {
        guard info.resourceRVA != 0, let off = info.fileOffset(forRVA: info.resourceRVA) else { return nil }
        self.reader = reader
        self.info = info
        self.base = off
    }

    public init?(url: URL) {
        guard let reader = try? FileReader(url: url), let info = try? PEParser.parse(reader) else { return nil }
        self.init(reader: reader, info: info)
    }

    private struct Entry {
        var id: UInt32?   // nil when the entry is named
        var offset: UInt32
        var isDirectory: Bool
    }

    private func entries(atDirectory offset: UInt32) -> [Entry] {
        let header = reader.read(at: base + UInt64(offset), count: 16)
        guard let named = header.le16(12), let ids = header.le16(14) else { return [] }
        let total = Swift.min(Int(named) + Int(ids), 4096)
        let raw = reader.read(at: base + UInt64(offset) + 16, count: total * 8)
        var result: [Entry] = []
        for i in 0..<(raw.count / 8) {
            guard let nameField = raw.le32(i * 8), let dataField = raw.le32(i * 8 + 4) else { continue }
            result.append(Entry(
                id: (nameField & 0x8000_0000) == 0 ? nameField : nil,
                offset: dataField & 0x7FFF_FFFF,
                isDirectory: (dataField & 0x8000_0000) != 0
            ))
        }
        return result
    }

    /// Returns (resource id, data) for every resource of a type (first language only).
    func resources(ofType type: UInt32, limit: Int = 256) -> [(id: UInt32?, data: [UInt8])] {
        guard let typeEntry = entries(atDirectory: 0).first(where: { $0.id == type && $0.isDirectory }) else { return [] }
        var out: [(UInt32?, [UInt8])] = []
        for nameEntry in entries(atDirectory: typeEntry.offset).prefix(limit) {
            var leaf = nameEntry
            if nameEntry.isDirectory {
                guard let lang = entries(atDirectory: nameEntry.offset).first(where: { !$0.isDirectory }) else { continue }
                leaf = lang
            }
            let dataEntry = reader.read(at: base + UInt64(leaf.offset), count: 16)
            guard let rva = dataEntry.le32(0), let size = dataEntry.le32(4), size > 0, size < 16 * 1024 * 1024,
                  let off = info.fileOffset(forRVA: rva) else { continue }
            out.append((nameEntry.id, reader.read(at: off, count: Int(size))))
        }
        return out
    }

    /// Rebuilds a standalone .ico file from the first icon group.
    public func iconFile() -> Data? {
        guard let group = resources(ofType: Self.rtGroupIcon, limit: 1).first?.data,
              let count = group.le16(4), count > 0 else { return nil }
        var icons: [UInt32: [UInt8]] = [:]
        for res in resources(ofType: Self.rtIcon, limit: 512) {
            if let id = res.id { icons[id] = res.data }
        }

        var entries: [(header: [UInt8], data: [UInt8])] = []
        for i in 0..<Int(count) {
            let e = 6 + i * 14
            guard e + 14 <= group.count, let id = group.le16(e + 12), let image = icons[UInt32(id)] else { continue }
            entries.append((Array(group[e..<(e + 8)]), image))
        }
        guard !entries.isEmpty else { return nil }

        var out: [UInt8] = [0, 0, 1, 0, UInt8(entries.count & 0xFF), UInt8(entries.count >> 8)]
        var offset = 6 + 16 * entries.count
        for entry in entries {
            out += entry.header
            out += le32(UInt32(entry.data.count))
            out += le32(UInt32(offset))
            offset += entry.data.count
        }
        for entry in entries { out += entry.data }
        return Data(out)
    }

    /// Reads strings such as "ProductName" and "FileDescription" from the
    /// version resource.
    public func versionStrings(keys: [String] = ["ProductName", "FileDescription", "CompanyName"]) -> [String: String] {
        guard let blob = resources(ofType: Self.rtVersion, limit: 1).first?.data else { return [:] }
        var result: [String: String] = [:]
        for key in keys {
            let needle = (key + "\0").utf16LEBytes
            guard var i = blob.firstIndex(of: needle) else { continue }
            i += needle.count
            while i % 4 != 0 { i += 1 }
            if let value = blob.utf16String(at: i, maxChars: 256)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty, value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                result[key] = value
            }
        }
        return result
    }

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
    }
}
