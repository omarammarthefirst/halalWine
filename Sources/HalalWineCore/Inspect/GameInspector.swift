import Foundation

public enum InspectError: Error, Equatable {
    case notFound
    case noWindowsProgram
}

/// Looks at a dropped folder or .exe and works out what it is: which file is
/// the game, which engine built it, which graphics API it wants, and anything
/// that will stop it from running on a Mac.
public struct GameInspector {
    public init() {}

    struct Candidate {
        var url: URL
        var relativePath: String
        var depth: Int
        var pe: PEInfo?
        var score = 0
    }

    // MARK: - Entry point

    public func inspect(_ url: URL) throws -> GameReport {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw InspectError.notFound }

        let root: URL
        var ranked: [Candidate]
        var explicitChoice: Candidate?

        if isDirectory.boolValue {
            root = url.standardizedFileURL
            ranked = rank(collectExecutables(in: root), folderName: root.lastPathComponent)
        } else {
            let ext = url.pathExtension.lowercased()
            guard ext == "exe" || ext == "msi" else { throw InspectError.noWindowsProgram }
            root = Self.gameRoot(forExecutable: url.standardizedFileURL)
            ranked = rank(collectExecutables(in: root), folderName: root.lastPathComponent)
            let chosen = url.standardizedFileURL
            explicitChoice = ranked.first { $0.url.path == chosen.path }
                ?? Candidate(url: chosen, relativePath: chosen.lastPathComponent, depth: 0,
                             pe: try? PEParser.parse(url: chosen))
        }

        let redistributables = ranked.filter { Self.isRedistributable($0.relativePath) }
        let playable = ranked.filter { !Self.isRedistributable($0.relativePath) && !Self.isExcludedName($0.url) }
        guard let main = explicitChoice ?? playable.first ?? ranked.first else { throw InspectError.noWindowsProgram }

        let exe = main.url
        let exeDir = exe.deletingLastPathComponent()
        let pe = main.pe ?? (try? PEParser.parse(url: exe))
        let resources = PEResources(url: exe)
        let versionStrings = resources?.versionStrings() ?? [:]

        var report = GameReport(
            kind: Self.looksLikeInstaller(exe, versionStrings: versionStrings) ? .installer : .game,
            rootFolder: root.path,
            executable: exe.path,
            displayName: "",
            engine: .unknown,
            engineVersion: nil,
            graphicsAPIs: [],
            architecture: pe?.machine ?? .unknown,
            isDotNet: pe?.isDotNet ?? false,
            godot: nil,
            redFlags: [],
            store: storeInfo(root: root, exeDir: exeDir),
            otherExecutables: playable.filter { $0.url.path != exe.path }.prefix(12).map(\.relativePath),
            bundledRedistributables: redistributables.map(\.relativePath)
        )

        if report.kind == .game {
            detectEngine(into: &report, exe: exe, pe: pe, versionStrings: versionStrings)
        }
        report.graphicsAPIs = graphicsAPIs(for: report, exe: exe, pe: pe)
        report.redFlags = redFlags(root: root, report: report)
        report.displayName = displayName(report: report, exe: exe, root: root, versionStrings: versionStrings)
        return report
    }

    /// Top-level folders an installer may have created inside a Wine prefix.
    public static func installLocations(inPrefix prefix: URL) -> [URL] {
        let driveC = prefix.appendingPathComponent("drive_c")
        let parents = ["Program Files", "Program Files (x86)", "GOG Games", "Games", "Epic Games"]
            .map { driveC.appendingPathComponent($0) }
        var result: [URL] = []
        let fm = FileManager.default
        for parent in parents {
            guard let items = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if ["common files", "internet explorer", "windows media player", "windows nt", "microsoft.net"]
                    .contains(item.lastPathComponent.lowercased()) { continue }
                result.append(item)
            }
        }
        return result
    }

    // MARK: - Finding executables

    func collectExecutables(in root: URL) -> [Candidate] {
        let fm = FileManager.default
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var result: [Candidate] = []
        var visited = 0
        while let item = enumerator.nextObject() as? URL {
            visited += 1
            if visited > 60_000 || result.count > 400 { break }
            let path = item.standardizedFileURL.path
            let relative = path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : item.lastPathComponent
            let depth = relative.split(separator: "/").count - 1
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if depth >= 5 || Self.skippedDirectories.contains(item.lastPathComponent.lowercased()) {
                    enumerator.skipDescendants()
                }
                continue
            }
            let ext = item.pathExtension.lowercased()
            if ext == "exe" || ext == "msi" {
                result.append(Candidate(url: item.standardizedFileURL, relativePath: relative, depth: depth))
            }
        }
        return result
    }

    func rank(_ candidates: [Candidate], folderName: String) -> [Candidate] {
        let folderKey = Self.normalized(Self.cleanName(folderName))
        let fm = FileManager.default
        var scored: [Candidate] = []
        for var c in candidates.prefix(150) {
            c.pe = c.url.pathExtension.lowercased() == "exe" ? (try? PEParser.parse(url: c.url)) : nil
            let name = c.url.deletingPathExtension().lastPathComponent
            let lower = name.lowercased()
            let dir = c.url.deletingLastPathComponent()
            var s = 0
            if let pe = c.pe {
                if pe.isGUI { s += 20 }
                if pe.machine == .x64 { s += 10 }
                if pe.machine == .arm64 { s -= 30 }
            } else {
                s -= 40
            }
            if fm.fileExists(atPath: dir.appendingPathComponent("\(name)_Data").path) { s += 60 }
            if fm.fileExists(atPath: dir.appendingPathComponent("\(name).pck").path) { s += 60 }
            if lower.hasSuffix("-win64-shipping") || lower.hasSuffix("-wingdk-shipping") { s += 60 }
            if fm.fileExists(atPath: dir.appendingPathComponent("data.win").path) { s += 30 }
            let key = Self.normalized(name)
            if key.count >= 3, !folderKey.isEmpty, folderKey.contains(key) || key.contains(folderKey) { s += 25 }
            s -= c.depth * 6
            if lower.contains("launcher") { s -= 25 }
            if lower.contains("server") { s -= 40 }
            if ["editor", "config", "settings", "benchmark", "tool"].contains(where: { lower.contains($0) }) { s -= 20 }
            if Self.isExcludedName(c.url) { s -= 200 }
            if Self.isRedistributable(c.relativePath) { s -= 300 }
            if let size = try? c.url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_000_000 {
                s += Swift.min(15, Int(log2(Double(size) / 1_000_000)))
            }
            c.score = s
            scored.append(c)
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.relativePath < $1.relativePath }
    }

    static let skippedDirectories: Set<String> = [
        "monobleedingedge", "jre", "java", "dotnet", "__installer", "$recycle.bin",
        "easyanticheat", "battleye", "crashreportclient", "thirdparty", "node_modules",
    ]

    static func isRedistributable(_ relativePath: String) -> Bool {
        let lower = relativePath.lowercased()
        let name = (lower as NSString).lastPathComponent
        if ["_commonredist/", "redist/", "redistributable", "directx/", "vcredist/", "prereq"].contains(where: { lower.contains($0) }) {
            return true
        }
        return ["vc_redist", "vcredist", "ueprereqsetup", "dxsetup", "dxwebsetup", "oalinst", "xnafx", "physx",
                "dotnetfx", "ndp4", "windowsdesktop-runtime"].contains { name.hasPrefix($0) }
    }

    static func isExcludedName(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".console.exe") { return true } // Godot console wrapper
        let prefixes = ["unins", "uninstall", "unitycrashhandler", "crashreportclient", "crashpad_handler",
                        "crashhandler", "easyanticheat", "start_protected_game", "beservice", "battleye",
                        "notification_helper", "steamerrorreporter", "cefsharp", "zfgamebrowser", "python",
                        "createdump", "7z", "unitycrash", "quicksfv", "dxdiag"]
        if prefixes.contains(where: { name.hasPrefix($0) }) { return true }
        return ["crash", "uninstall", "errorreport", "bugreport"].contains { name.contains($0) }
    }

    static func looksLikeInstaller(_ exe: URL, versionStrings: [String: String]) -> Bool {
        let name = exe.lastPathComponent.lowercased()
        if exe.pathExtension.lowercased() == "msi" { return true }
        if name.contains("uninst") { return false }
        if name.hasPrefix("setup") || name.contains("install") || name.contains("-setup") || name.contains("_setup") {
            return true
        }
        let description = (versionStrings["FileDescription"] ?? "").lowercased()
        if description.contains("setup") || description.contains("installer") { return true }
        guard let reader = try? FileReader(url: exe) else { return false }
        let head = reader.read(at: 0, count: 4 * 1024 * 1024)
        return ["Inno Setup", "Nullsoft Install System", "NullsoftInst", "InstallShield"]
            .contains { head.contains(bytes: Array($0.utf8)) }
    }

    /// For an .exe inside an Unreal "Binaries/Win64" folder the game root is
    /// two levels above "Binaries"; otherwise it is the .exe's folder.
    static func gameRoot(forExecutable exe: URL) -> URL {
        let parts = exe.deletingLastPathComponent().pathComponents
        if let i = parts.lastIndex(where: { $0.lowercased() == "binaries" }), i >= 2 {
            return URL(fileURLWithPath: NSString.path(withComponents: Array(parts[0..<(i - 1)])))
        }
        return exe.deletingLastPathComponent()
    }

    // MARK: - Engines

    func detectEngine(into report: inout GameReport, exe: URL, pe: PEInfo?, versionStrings: [String: String]) {
        let fm = FileManager.default
        let dir = exe.deletingLastPathComponent()
        let base = exe.deletingPathExtension().lastPathComponent
        func has(_ relative: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(relative).path) }
        let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let lowerFiles = Set(files.map { $0.lowercased() })

        // Godot: a .pck next to the program, or one embedded inside it.
        var godot: GodotPackInfo?
        if has("\(base).pck") {
            godot = GodotPackReader.read(pck: dir.appendingPathComponent("\(base).pck"))
        }
        if godot == nil, let pck = files.first(where: { $0.lowercased().hasSuffix(".pck") }) {
            godot = GodotPackReader.read(pck: dir.appendingPathComponent(pck))
        }
        if godot == nil {
            godot = GodotPackReader.readEmbedded(exe: exe, pe: pe)
        }
        let saysGodot = (versionStrings["CompanyName"] ?? "").contains("Godot")
            || (versionStrings["FileDescription"] ?? "").contains("Godot")
        if godot != nil || saysGodot {
            report.engine = .godot
            report.godot = godot
            report.engineVersion = godot?.version
            let dataDirs = files.filter { $0.hasPrefix("data_") }
            if dataDirs.contains(where: { has("\($0)/GodotSharp.dll") || has("\($0)/Assemblies/GodotSharp.dll") }) {
                report.isDotNet = true
            }
            return
        }

        if lowerFiles.contains("unityplayer.dll") || has("\(base)_Data") {
            report.engine = .unity
            report.engineVersion = unityVersion(dataDir: dir.appendingPathComponent("\(base)_Data"))
            return
        }

        let lowerName = base.lowercased()
        if lowerName.hasSuffix("-win64-shipping") || lowerName.hasSuffix("-wingdk-shipping")
            || exe.path.lowercased().contains("/binaries/win64/")
            || fm.fileExists(atPath: URL(fileURLWithPath: report.rootFolder).appendingPathComponent("Engine/Binaries").path) {
            report.engine = .unreal
            return
        }

        if lowerFiles.contains("data.win") { report.engine = .gameMaker; return }

        if has("www/js/rpg_core.js") { report.engine = .rpgMakerMV; report.engineVersion = "MV"; return }
        if has("js/rmmz_core.js") || has("www/js/rmmz_core.js") { report.engine = .rpgMakerMV; report.engineVersion = "MZ"; return }

        if lowerFiles.contains("game.ini"),
           lowerFiles.contains(where: { $0.hasPrefix("rgss") && $0.hasSuffix(".dll") }) || has("System") {
            report.engine = .rpgMakerClassic
            return
        }

        if has("renpy") && has("lib") { report.engine = .renPy; return }

        if lowerFiles.contains("fna.dll") { report.engine = .fna; return }
        if lowerFiles.contains("monogame.framework.dll") { report.engine = .monoGame; return }
        if lowerFiles.contains(where: { $0.hasPrefix("microsoft.xna.framework") }) { report.engine = .xna; return }

        if lowerFiles.contains("engine2.dll") { report.engine = .source2; return }
        if has("bin/engine.dll") || has("bin/win64/engine.dll") { report.engine = .source; return }

        if lowerFiles.contains("nw.dll") || lowerFiles.contains("nw_elf.dll") { report.engine = .nwjs; return }
        if has("resources/app.asar") || has("resources/app") { report.engine = .electron; return }

        if lowerFiles.contains("love.dll") { report.engine = .love2d; return }
        if has("jre") || lowerFiles.contains(where: { $0.hasSuffix(".jar") }) { report.engine = .java; return }
    }

    func unityVersion(dataDir: URL) -> String? {
        let pattern = try? NSRegularExpression(pattern: #"(?:20[0-9]{2}|6000|[45])\.[0-9]+\.[0-9]+[abfpx][0-9]+"#)
        for file in ["globalgamemanagers", "mainData", "data.unity3d", "level0", "globalgamemanagers.assets"] {
            guard let reader = try? FileReader(url: dataDir.appendingPathComponent(file)) else { continue }
            let head = reader.read(at: 0, count: 4096).map { (32...126).contains($0) ? $0 : 32 }
            let text = String(decoding: head, as: UTF8.self)
            if let match = pattern?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range, in: text) {
                return String(text[range])
            }
        }
        return nil
    }

    // MARK: - Graphics APIs

    func graphicsAPIs(for report: GameReport, exe: URL, pe: PEInfo?) -> [GraphicsAPI] {
        let imports = pe?.allImports ?? []
        let fromImports = Self.apis(fromImports: imports)
        let dir = exe.deletingLastPathComponent()
        let fm = FileManager.default

        switch report.engine {
        case .godot:
            if let method = report.godot?.renderingMethod, method == "gl_compatibility" || method.hasPrefix("GLES") {
                return [.opengl]
            }
            if let major = report.godot?.major, major < 4 { return [.opengl] }
            return [.d3d12, .vulkan, .opengl]
        case .unity:
            return [.d3d11, .d3d12]
        case .unreal:
            let usesD3D12 = imports.contains("d3d12.dll")
                || fm.fileExists(atPath: URL(fileURLWithPath: report.rootFolder).appendingPathComponent("Engine/Binaries/Win64/D3D12").path)
            return usesD3D12 ? [.d3d12, .d3d11] : [.d3d11, .d3d12]
        case .gameMaker:
            return fromImports.contains(.d3d9) ? [.d3d9] : [.d3d11]
        case .rpgMakerMV, .nwjs, .electron:
            return [.d3d11, .opengl]
        case .rpgMakerClassic, .xna, .source:
            return [.d3d9]
        case .renPy, .love2d, .java:
            return [.opengl]
        case .fna:
            return [.opengl, .d3d11, .vulkan]
        case .monoGame:
            let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            return files.contains(where: { $0.lowercased().hasPrefix("sharpdx") }) ? [.d3d11] : [.opengl]
        case .source2:
            return [.d3d11, .vulkan]
        case .unknown:
            if !fromImports.isEmpty { return fromImports }
            // Custom engines often keep the renderer in a DLL next to the program.
            var union = Set<String>()
            let dlls = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
                .filter { $0.pathExtension.lowercased() == "dll" }
                .prefix(40)
            for dll in dlls {
                if let size = try? dll.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 200_000_000 { continue }
                if let info = try? PEParser.parse(url: dll) { union.formUnion(info.allImports) }
            }
            let fromDLLs = Self.apis(fromImports: union)
            return fromDLLs.isEmpty ? [.unknown] : fromDLLs
        }
    }

    static func apis(fromImports imports: Set<String>) -> [GraphicsAPI] {
        var result: [GraphicsAPI] = []
        if imports.contains("d3d12.dll") { result.append(.d3d12) }
        if imports.contains("d3d11.dll") || (imports.contains("dxgi.dll") && !imports.contains("d3d12.dll")) {
            result.append(.d3d11)
        }
        if imports.contains(where: { $0.hasPrefix("d3d10") }) { result.append(.d3d10) }
        if imports.contains("d3d9.dll") { result.append(.d3d9) }
        if imports.contains("d3d8.dll") || imports.contains("ddraw.dll") { result.append(.legacyDirectX) }
        if imports.contains("vulkan-1.dll") { result.append(.vulkan) }
        if imports.contains("opengl32.dll") { result.append(.opengl) }
        return result
    }

    // MARK: - Red flags, store, name

    func redFlags(root: URL, report: GameReport) -> [RedFlag] {
        var flags = Set<RedFlag>()
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            var visited = 0
            while let item = enumerator.nextObject() as? URL {
                visited += 1
                if visited > 40_000 { break }
                if enumerator.level > 3 { enumerator.skipDescendants() }
                let name = item.lastPathComponent.lowercased()
                if name.hasPrefix("easyanticheat") || name == "start_protected_game.exe" { flags.insert(.easyAntiCheat) }
                if name == "battleye" || name.hasPrefix("beservice") || name.hasSuffix("_be.exe") { flags.insert(.battlEye) }
                if name == "vgk.sys" || name == "vgc.exe" { flags.insert(.riotVanguard) }
                if ["gameguard", "xigncode", "xhunter1.sys", "mhyprot2.sys", "eaanticheat", "anticheatexpert", "nprotect"]
                    .contains(where: { name.hasPrefix($0) }) { flags.insert(.otherAntiCheat) }
                if name == "steam_api.dll" || name == "steam_api64.dll" { flags.insert(.usesSteam) }
                if name.hasPrefix("uplay_r1_loader") || name.hasPrefix("upc_r1_loader") || name.hasPrefix("upc_r2_loader") {
                    flags.insert(.needsPublisherLauncher)
                }
            }
        }
        if report.architecture == .arm64 { flags.insert(.unsupportedArchitecture) }
        if [.renPy, .love2d, .java].contains(report.engine) { flags.insert(.mayHaveMacVersion) }
        return RedFlag.allCases.filter { flags.contains($0) }
    }

    func storeInfo(root: URL, exeDir: URL) -> StoreInfo {
        var info = StoreInfo()
        let fm = FileManager.default
        for dir in [exeDir, root] {
            let appIDFile = dir.appendingPathComponent("steam_appid.txt")
            if info.steamAppID == nil, let text = try? String(contentsOf: appIDFile, encoding: .utf8) {
                let digits = text.filter(\.isNumber)
                if !digits.isEmpty { info.steamAppID = digits }
            }
            for file in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            where file.lowercased().hasPrefix("goggame-") && file.lowercased().hasSuffix(".info") {
                if let data = fm.contents(atPath: dir.appendingPathComponent(file).path),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    info.gogID = info.gogID ?? (json["gameId"] as? String)
                    info.gogName = info.gogName ?? (json["name"] as? String)
                }
            }
        }
        info.isEpic = fm.fileExists(atPath: root.appendingPathComponent(".egstore").path)
        return info
    }

    static let genericNames: Set<String> = [
        "godot engine", "unity player", "unrealgame", "ue4game", "ue5game", "launcher", "game", "setup",
        "application", "nw.js", "electron", "rpg maker", "player", "bootstrappackagedgame", "main", "app",
    ]

    func displayName(report: GameReport, exe: URL, root: URL, versionStrings: [String: String]) -> String {
        let options = [
            report.store.gogName,
            versionStrings["ProductName"],
            versionStrings["FileDescription"],
            Self.cleanName(root.lastPathComponent),
            Self.cleanName(exe.deletingPathExtension().lastPathComponent),
        ]
        for option in options {
            guard let name = option?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name.count <= 60,
                  !Self.genericNames.contains(name.lowercased()) else { continue }
            if report.kind == .installer, name.lowercased().contains("setup") { continue }
            return name
        }
        return exe.deletingPathExtension().lastPathComponent
    }

    /// "Slay.the.Spire.2.v0.111.0" → "Slay the Spire 2".
    public static func cleanName(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[ ._-]+v?[0-9]+(\.[0-9]+)+.*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"-Win64-Shipping$"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"[._]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func normalized(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
