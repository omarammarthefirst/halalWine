import Foundation
import HalalWineCore
import SwiftUI

/// The app's own resource bundle (translations), found inside the .app.
enum AppResources {
    static let bundle: Bundle = ResourceLocator.find("halalWine_HalalWineApp") ?? Bundle.module
}

/// Looks up a translated string (Resources/<lang>.lproj/Localizable.strings).
func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: AppResources.bundle, comment: "")
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), locale: Locale(identifier: AppLanguage.effectiveCode), arguments: arguments)
}

/// The app's language: follows macOS unless the user picks one in Settings.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case arabic = "ar"
    case english = "en"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L("settings.language.system")
        case .arabic: return "العربية"
        case .english: return "English"
        }
    }

    static var selected: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: Prefs.appLanguage) ?? "") ?? .system
    }

    /// Takes effect on the next launch (macOS reads AppleLanguages at startup).
    static func select(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: Prefs.appLanguage)
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    /// The language the strings are actually being shown in.
    static var effectiveCode: String {
        let code = AppResources.bundle.preferredLocalizations.first ?? "en"
        return code.hasPrefix("ar") ? "ar" : "en"
    }

    static var isRightToLeft: Bool { effectiveCode == "ar" }
}

extension View {
    /// Keeps layout direction and formatting in sync with the strings' language.
    func appLanguageEnvironment() -> some View {
        environment(\.layoutDirection, AppLanguage.isRightToLeft ? .rightToLeft : .leftToRight)
            .environment(\.locale, Locale(identifier: AppLanguage.effectiveCode))
    }
}

// MARK: - Display names

extension GameEngine {
    var displayName: String {
        switch self {
        case .godot: return "Godot"
        case .unity: return "Unity"
        case .unreal: return "Unreal Engine"
        case .gameMaker: return "GameMaker"
        case .rpgMakerMV: return "RPG Maker MV/MZ"
        case .rpgMakerClassic: return "RPG Maker XP/VX"
        case .renPy: return "Ren'Py"
        case .fna: return "FNA"
        case .monoGame: return "MonoGame"
        case .xna: return "XNA"
        case .source: return "Source"
        case .source2: return "Source 2"
        case .electron: return "Electron"
        case .nwjs: return "NW.js"
        case .love2d: return "LÖVE"
        case .java: return "Java"
        case .unknown: return L("engine.unknown")
        }
    }
}

extension GraphicsAPI {
    var displayName: String {
        switch self {
        case .d3d12: return "DirectX 12"
        case .d3d11: return "DirectX 11"
        case .d3d10: return "DirectX 10"
        case .d3d9: return "DirectX 9"
        case .legacyDirectX: return "DirectX 8"
        case .vulkan: return "Vulkan"
        case .opengl: return "OpenGL"
        case .unknown: return L("engine.unknown")
        }
    }
}

extension GraphicsBackend {
    var displayName: String {
        switch self {
        case .d3dmetal: return "D3DMetal"
        case .dxmt: return "DXMT"
        case .dxvk: return "DXVK"
        case .wined3d: return "WineD3D"
        }
    }

    var explanation: String { L("backend.\(rawValue).about") }
}

extension RedFlag {
    var message: String { L("flag.\(rawValue)") }
}

extension Diagnosis {
    var message: String {
        switch self {
        case .rendererFailed: return L("diag.rendererFailed")
        case .needsVCRedist: return L("diag.needsVCRedist")
        case .needsDirectXRuntime: return L("diag.needsDirectXRuntime")
        case .needsXNA: return L("diag.needsXNA")
        case .needsDotNet: return L("diag.needsDotNet")
        case .needsAVX: return L("diag.needsAVX")
        case .needsSteam: return L("diag.needsSteam")
        case .antiCheat: return L("diag.antiCheat")
        case .missingDLL(let name): return L("diag.missingDLL", name)
        }
    }
}

extension Dependency {
    var displayName: String {
        switch self {
        case .vcredist: return "Microsoft Visual C++"
        case .directx: return "DirectX (June 2010)"
        case .xna: return "XNA Framework 4.0"
        }
    }
}

extension LaunchConfig {
    var summary: String {
        var parts = [backend.displayName]
        if !arguments.isEmpty { parts.append(arguments.joined(separator: " ")) }
        if !environment.isEmpty { parts.append(environment.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")) }
        return parts.joined(separator: " · ")
    }
}
