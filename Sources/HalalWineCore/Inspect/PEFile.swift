import Foundation

/// What we learn from a Windows executable's headers.
public struct PEInfo: Codable, Equatable, Sendable {
    public enum Machine: String, Codable, Sendable {
        case x86, x64, arm64, unknown
    }

    public struct Section: Codable, Equatable, Sendable {
        public var name: String
        public var virtualAddress: UInt32
        public var virtualSize: UInt32
        public var rawOffset: UInt32
        public var rawSize: UInt32
    }

    public var machine: Machine
    public var subsystem: UInt16
    public var isDotNet: Bool
    public var imports: [String]
    public var delayImports: [String]
    public var sections: [Section]
    public var resourceRVA: UInt32
    public var resourceSize: UInt32

    /// 2 = Windows GUI, 3 = console.
    public var isGUI: Bool { subsystem == 2 }

    /// Lower-cased names of every DLL the program links against.
    public var allImports: Set<String> { Set((imports + delayImports).map { $0.lowercased() }) }

    func fileOffset(forRVA rva: UInt32) -> UInt64? {
        for s in sections {
            let span = Swift.max(s.virtualSize, s.rawSize)
            if rva >= s.virtualAddress, rva < s.virtualAddress &+ span {
                let delta = rva - s.virtualAddress
                guard delta < s.rawSize else { return nil }
                return UInt64(s.rawOffset) + UInt64(delta)
            }
        }
        return nil
    }
}

public enum PEError: Error, Equatable {
    case notAWindowsProgram
    case truncated
}

/// Minimal, defensive PE/COFF parser: headers, sections, import tables,
/// .NET marker and resource directory location.
public enum PEParser {
    public static func parse(url: URL) throws -> PEInfo {
        let reader = try FileReader(url: url)
        return try parse(reader)
    }

    static func parse(_ r: FileReader) throws -> PEInfo {
        let dos = r.read(at: 0, count: 64)
        guard dos.count == 64, dos[0] == 0x4D, dos[1] == 0x5A, let lfanew = dos.le32(0x3C) else {
            throw PEError.notAWindowsProgram
        }
        let peOffset = UInt64(lfanew)
        let header = r.read(at: peOffset, count: 24)
        guard header.count == 24, header[0] == 0x50, header[1] == 0x45, header[2] == 0, header[3] == 0,
              let machineRaw = header.le16(4), let sectionCount = header.le16(6),
              let optionalSize = header.le16(20)
        else { throw PEError.notAWindowsProgram }

        let optOffset = peOffset + 24
        let opt = r.read(at: optOffset, count: Int(optionalSize))
        guard opt.count >= 70, let magic = opt.le16(0) else { throw PEError.truncated }
        let isPE32Plus = magic == 0x20B

        let subsystem = opt.le16(68) ?? 0
        let imageBase: UInt64 = isPE32Plus ? (opt.le64(24) ?? 0) : UInt64(opt.le32(28) ?? 0)
        let dataDirStart = isPE32Plus ? 112 : 96
        let dataDirCount = Int((isPE32Plus ? opt.le32(108) : opt.le32(92)) ?? 0)

        func dataDirectory(_ index: Int) -> (rva: UInt32, size: UInt32) {
            guard index < dataDirCount,
                  let rva = opt.le32(dataDirStart + index * 8),
                  let size = opt.le32(dataDirStart + index * 8 + 4)
            else { return (0, 0) }
            return (rva, size)
        }

        // Section table.
        let count = Int(Swift.min(sectionCount, 96))
        let table = r.read(at: optOffset + UInt64(optionalSize), count: count * 40)
        var sections: [PEInfo.Section] = []
        for i in 0..<(table.count / 40) {
            let base = i * 40
            let nameBytes = table[base..<(base + 8)].prefix { $0 != 0 }
            sections.append(PEInfo.Section(
                name: String(decoding: nameBytes, as: UTF8.self),
                virtualAddress: table.le32(base + 12) ?? 0,
                virtualSize: table.le32(base + 8) ?? 0,
                rawOffset: table.le32(base + 20) ?? 0,
                rawSize: table.le32(base + 16) ?? 0
            ))
        }

        var info = PEInfo(
            machine: {
                switch machineRaw {
                case 0x14C: return .x86
                case 0x8664: return .x64
                case 0xAA64: return .arm64
                default: return .unknown
                }
            }(),
            subsystem: subsystem,
            isDotNet: dataDirectory(14).rva != 0,
            imports: [],
            delayImports: [],
            sections: sections,
            resourceRVA: dataDirectory(2).rva,
            resourceSize: dataDirectory(2).size
        )

        // Regular imports: 20-byte descriptors, name RVA at +12.
        let importDir = dataDirectory(1)
        if importDir.rva != 0, let off = info.fileOffset(forRVA: importDir.rva) {
            let raw = r.read(at: off, count: 20 * 512)
            var i = 0
            while i + 20 <= raw.count {
                let nameRVA = raw.le32(i + 12) ?? 0
                let firstThunk = raw.le32(i + 16) ?? 0
                if nameRVA == 0 && firstThunk == 0 { break }
                if let nameOff = info.fileOffset(forRVA: nameRVA),
                   let name = r.read(at: nameOff, count: 256).cString(at: 0), !name.isEmpty {
                    info.imports.append(name)
                }
                i += 20
            }
        }

        // Delay-load imports: 32-byte descriptors, name at +4 (VA for old-style).
        let delayDir = dataDirectory(13)
        if delayDir.rva != 0, let off = info.fileOffset(forRVA: delayDir.rva) {
            let raw = r.read(at: off, count: 32 * 256)
            var i = 0
            while i + 32 <= raw.count {
                let attributes = raw.le32(i) ?? 0
                let nameField = raw.le32(i + 4) ?? 0
                if nameField == 0 { break }
                let rva = (attributes & 1) == 1
                    ? nameField
                    : UInt32(truncatingIfNeeded: UInt64(nameField) &- imageBase)
                if let nameOff = info.fileOffset(forRVA: rva),
                   let name = r.read(at: nameOff, count: 256).cString(at: 0), !name.isEmpty {
                    info.delayImports.append(name)
                }
                i += 32
            }
        }
        return info
    }
}
