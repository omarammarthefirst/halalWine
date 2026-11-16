import Foundation

/// The four ways a Windows game's graphics can reach the Mac's GPU.
public enum GraphicsBackend: String, Codable, Sendable, CaseIterable, Comparable {
    /// Apple's D3DMetal (Game Porting Toolkit): DirectX 11/12 → Metal. Imported by the user.
    case d3dmetal
    /// DXMT: DirectX 10/11 → Metal. Open source, bundled.
    case dxmt
    /// DXVK + MoltenVK: DirectX 10/11 → Vulkan → Metal. Open source, bundled.
    case dxvk
    /// Wine's own WineD3D: DirectX ≤ 11 and OpenGL → OpenGL. Always available.
    case wined3d

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// One concrete way to launch a game.
public struct LaunchConfig: Codable, Hashable, Sendable, Identifiable {
    public var stepID: String
    public var backend: GraphicsBackend
    public var arguments: [String]
    public var environment: [String: String]

    public init(stepID: String, backend: GraphicsBackend, arguments: [String] = [], environment: [String: String] = [:]) {
        self.stepID = stepID
        self.backend = backend
        self.arguments = arguments
        self.environment = environment
    }

    /// Identity used to remember what worked or failed.
    public var key: String {
        let env = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return "\(backend.rawValue)|\(arguments.joined(separator: " "))|\(env)"
    }

    public var id: String { key }
}

/// What we remember about a game between launches.
public struct LaunchHistory: Codable, Equatable, Sendable {
    public var working: LaunchConfig?
    public var failedKeys: [String]

    public init(working: LaunchConfig? = nil, failedKeys: [String] = []) {
        self.working = working
        self.failedKeys = failedKeys
    }
}

public struct LaunchPlan: Codable, Equatable, Sendable {
    public var ruleID: String
    /// Configurations to try, best first.
    public var configs: [LaunchConfig]
    /// Configurations that need a backend that is not installed (e.g. D3DMetal).
    public var unavailable: [LaunchConfig]
    /// Arguments added when the user prefers windowed mode.
    public var windowedArguments: [String]
}
