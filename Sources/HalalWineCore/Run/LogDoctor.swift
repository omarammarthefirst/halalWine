import Foundation

/// Something recognisable in a game's log, and what to do about it.
public enum Diagnosis: Codable, Hashable, Sendable {
    /// The chosen renderer could not start: try the next configuration now.
    case rendererFailed
    /// A Microsoft Visual C++ runtime DLL is missing.
    case needsVCRedist(String)
    /// An old DirectX runtime DLL (d3dx9, xinput1_3, …) is missing.
    case needsDirectXRuntime(String)
    case needsXNA
    case needsDotNet
    /// The game uses AVX instructions; Rosetta must advertise them.
    case needsAVX
    /// The game requires the Steam client to be running.
    case needsSteam
    case antiCheat
    case missingDLL(String)

    public var isFatalForConfig: Bool {
        switch self {
        case .rendererFailed: return true
        default: return false
        }
    }
}

/// Reads Wine/game log lines and recognises known failures.
public struct LogDoctor: Sendable {
    public init() {}

    static let rendererFailures = [
        "your video card drivers seem not to support",
        "unable to initialize direct3d 12",
        "unable to initialize vulkan",
        "unable to initialize opengl",
        "couldn't load the d3d12 library",
        "could not create d3d12",
        "failed to create d3d11 device",
        "failed to create d3d12 device",
        "failed to initialize graphics",
        "failed to initialize player",
        "dx12 is not supported on your system",
        "dx11 feature level 10.0 is required",
        "no suitable d3d12 adapter",
        "vk_error_incompatible_driver",
        "d3d12createdevice failed",
        "invalid rendering driver",
    ]

    static let vcRuntimePrefixes = ["msvcp1", "vcruntime1", "msvcr1", "mfc1", "concrt1", "vcomp1", "msvcp7", "msvcr7"]
    static let directXRuntimePrefixes = ["d3dx9_", "d3dx10_", "d3dx11_", "d3dcompiler_4", "xinput1_1", "xinput1_2",
                                         "xinput1_3", "x3daudio1_", "xaudio2_", "xapofx1_", "d3dcsx_"]

    public func diagnose(line: String) -> Diagnosis? {
        let lower = line.lowercased()

        if lower.contains("import_dll"), lower.contains("not found"),
           let dll = Self.extract(after: "library ", in: line)?.lowercased() {
            if Self.vcRuntimePrefixes.contains(where: { dll.hasPrefix($0) }) { return .needsVCRedist(dll) }
            if Self.directXRuntimePrefixes.contains(where: { dll.hasPrefix($0) }) { return .needsDirectXRuntime(dll) }
            if dll.hasPrefix("mscoree") { return .needsDotNet }
            return .missingDLL(dll)
        }
        if lower.contains("illegal_instruction") || lower.contains("illegal instruction") || lower.contains("c000001d") {
            return .needsAVX
        }
        if Self.rendererFailures.contains(where: { lower.contains($0) }) { return .rendererFailed }
        if lower.contains("steamapi_init") && lower.contains("fail") || lower.contains("[s_api fail]")
            || lower.contains("steam must be running") { return .needsSteam }
        if lower.contains("microsoft.xna.framework") && (lower.contains("could not load") || lower.contains("filenotfound")) {
            return .needsXNA
        }
        if lower.contains("wine mono is not installed") || lower.contains("err:mscoree") { return .needsDotNet }
        if lower.contains("easyanticheat") && (lower.contains("error") || lower.contains("fail")) { return .antiCheat }
        return nil
    }

    public func diagnose(log: String) -> [Diagnosis] {
        var seen = Set<Diagnosis>()
        var ordered: [Diagnosis] = []
        for line in log.split(separator: "\n") {
            if let d = diagnose(line: String(line)), seen.insert(d).inserted { ordered.append(d) }
        }
        return ordered
    }

    static func extract(after marker: String, in line: String) -> String? {
        guard let range = line.range(of: marker, options: .caseInsensitive) else { return nil }
        let rest = line[range.upperBound...]
        let token = rest.split(separator: " ").first.map(String.init)
        return token?.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
}
