import Foundation

public enum GameEngine: String, Codable, Sendable, CaseIterable {
    case godot, unity, unreal, gameMaker, rpgMakerMV, rpgMakerClassic, renPy
    case fna, monoGame, xna, source, source2, electron, nwjs, love2d, java, unknown
}

/// Graphics APIs a Windows game can use, in the order a game prefers them.
public enum GraphicsAPI: String, Codable, Sendable, CaseIterable {
    case d3d12, d3d11, d3d10, d3d9, legacyDirectX, vulkan, opengl, unknown
}

/// Things worth telling the user about before they press Play.
public enum RedFlag: String, Codable, Sendable, CaseIterable {
    /// Kernel anti-cheat: these games do not work on a Mac.
    case easyAntiCheat, battlEye, riotVanguard, otherAntiCheat
    /// The game talks to Steam and may refuse to start without it.
    case usesSteam
    /// Needs the Ubisoft/EA launcher.
    case needsPublisherLauncher
    /// Built for Windows on ARM; cannot run.
    case unsupportedArchitecture
    /// This engine usually ships a native macOS version; check the store first.
    case mayHaveMacVersion

    public var blocksPlay: Bool {
        switch self {
        case .easyAntiCheat, .battlEye, .riotVanguard, .otherAntiCheat, .unsupportedArchitecture: return true
        default: return false
        }
    }
}

public struct StoreInfo: Codable, Equatable, Sendable {
    public var steamAppID: String?
    public var gogID: String?
    public var gogName: String?
    public var isEpic: Bool = false
}

public enum ItemKind: String, Codable, Sendable {
    case game
    case installer
}

/// The result of inspecting a dropped folder or file.
public struct GameReport: Codable, Equatable, Sendable {
    public var kind: ItemKind
    public var rootFolder: String
    public var executable: String
    public var displayName: String
    public var engine: GameEngine
    public var engineVersion: String?
    public var graphicsAPIs: [GraphicsAPI]
    public var architecture: PEInfo.Machine
    public var isDotNet: Bool
    public var godot: GodotPackInfo?
    public var redFlags: [RedFlag]
    public var store: StoreInfo
    /// Other executables found, relative to the root folder, best first.
    public var otherExecutables: [String]
    /// Redistributable installers the game ships with (relative paths).
    public var bundledRedistributables: [String]

    public var primaryAPI: GraphicsAPI { graphicsAPIs.first ?? .unknown }

    public var engineMajorVersion: Int? {
        if let godot { return godot.major }
        guard let v = engineVersion, let first = v.split(whereSeparator: { !$0.isNumber }).first else { return nil }
        return Int(first)
    }

    /// A stable identity used to remember settings across reinstalls.
    public var fingerprint: String {
        if let id = store.steamAppID { return "steam:\(id)" }
        if let id = store.gogID { return "gog:\(id)" }
        let exe = (executable as NSString).lastPathComponent.lowercased()
        return "exe:\(exe):\(displayName.lowercased())"
    }
}
