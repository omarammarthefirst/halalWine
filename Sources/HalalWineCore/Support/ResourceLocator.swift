import Foundation

/// Finds SwiftPM resource bundles inside a packaged .app.
///
/// SwiftPM's generated `Bundle.module` only looks next to the executable's
/// bundle root and in the original build folder. In a signed .app the
/// resource bundles must live in Contents/Resources, so look there first and
/// fall back to `Bundle.module` during development (`swift run`, tests).
public enum ResourceLocator {
    public static func find(_ name: String) -> Bundle? {
        var bases: [URL] = []
        if let resources = Bundle.main.resourceURL { bases.append(resources) }
        bases.append(Bundle.main.bundleURL)
        if let exeDir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
            bases.append(exeDir)
            bases.append(exeDir.deletingLastPathComponent().appendingPathComponent("Resources"))
        }
        for base in bases {
            for ext in ["bundle", "resources"] {
                let url = base.appendingPathComponent("\(name).\(ext)")
                if FileManager.default.fileExists(atPath: url.path), let bundle = Bundle(url: url) { return bundle }
            }
        }
        return nil
    }
}

enum CoreResources {
    static let bundle: Bundle = ResourceLocator.find("halalWine_HalalWineCore") ?? Bundle.module
}
