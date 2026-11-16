import AppKit
import CoreGraphics
import Darwin
import Foundation
import HalalWineCore
import ScreenCaptureKit

/// Rosetta 2 runs Wine's Intel code on Apple Silicon.
enum Rosetta {
    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    static var isInstalled: Bool {
        ["/Library/Apple/usr/share/rosetta/rosetta", "/Library/Apple/usr/libexec/oah/libRosettaRuntime"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    static var isNeeded: Bool { isAppleSilicon && !isInstalled }

    /// Tries a normal install first; if macOS wants an administrator, shows
    /// the standard password prompt.
    static func install() async -> Bool {
        _ = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/sbin/softwareupdate"),
                                         ["--install-rosetta", "--agree-to-license"], timeout: 1800)
        if isInstalled { return true }
        let script = "do shell script \"/usr/sbin/softwareupdate --install-rosetta --agree-to-license\" with administrator privileges"
        await MainActor.run {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
        }
        return isInstalled
    }
}

/// Finds windows that belong to Wine processes from our runtime.
enum WindowProbe {
    struct Window {
        let id: CGWindowID
        let pid: pid_t
        let area: CGFloat
    }

    static func largestWindow(ownedByProcessesUnder pathPrefix: String) -> Window? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        var best: Window?
        var owners: [pid_t: Bool] = [:]
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 200, bounds.height >= 150 else { continue }
            let belongs: Bool
            if let cached = owners[pid] {
                belongs = cached
            } else {
                belongs = executablePath(of: pid)?.hasPrefix(pathPrefix) ?? false
                owners[pid] = belongs
            }
            guard belongs else { continue }
            let area = bounds.width * bounds.height
            if area > (best?.area ?? 0) { best = Window(id: number, pid: pid, area: area) }
        }
        return best
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }
}

/// Optional: samples the game window to catch the classic "black screen".
/// Needs the Screen Recording permission, so it is off by default.
enum BlackFrameDetector {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// true = black, false = has content, nil = could not check.
    static func isBlack(windowID: CGWindowID) async -> Bool? {
        guard hasPermission else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = 64
            config.height = 64
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return isMostlyBlack(image)
        } catch {
            return nil
        }
    }

    static func isMostlyBlack(_ image: CGImage) -> Bool {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var dark = 0
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let luma = (Int(pixels[i]) * 299 + Int(pixels[i + 1]) * 587 + Int(pixels[i + 2]) * 114) / 1000
            if luma < 12 { dark += 1 }
        }
        return Double(dark) / Double(side * side) > 0.97
    }
}

/// Imports D3DMetal from Apple's Game Porting Toolkit download (.dmg or folder).
enum D3DMetalImport {
    static func importFrom(_ url: URL, runtime: InstalledRuntime) async throws {
        var mountPoint: URL?
        var searchRoot = url
        if url.pathExtension.lowercased() == "dmg" {
            let mount = FileManager.default.temporaryDirectory.appendingPathComponent("halalwine-gptk-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                                     ["attach", url.path, "-nobrowse", "-readonly", "-noverify",
                                                      "-mountpoint", mount.path],
                                                     input: "Y\n", timeout: 300)
            guard result.status == 0 else { throw RuntimeError.d3dmetalNotFound }
            mountPoint = mount
            searchRoot = mount
        }
        defer {
            if let mountPoint {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                p.arguments = ["detach", mountPoint.path, "-quiet", "-force"]
                try? p.run()
            }
        }
        guard let lib = InstalledRuntime.findRedistLib(in: searchRoot) else { throw RuntimeError.d3dmetalNotFound }
        try await Task.detached { try runtime.installD3DMetal(redistLib: lib) }.value
    }
}

/// Bundles logs and the detection report into a zip on the Desktop so users
/// can send it when asking for help.
enum Diagnostics {
    static func export(game: GameRecord, plan: LaunchPlan, model: AppModel) async throws -> URL {
        let fm = FileManager.default
        let safeName = game.name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        let folder = fm.temporaryDirectory.appendingPathComponent("halalWine-\(safeName)-diagnostics")
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(game).write(to: folder.appendingPathComponent("game.json"))
        try encoder.encode(plan).write(to: folder.appendingPathComponent("plan.json"))

        let process = ProcessInfo.processInfo
        let system = """
        halalWine \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
        macOS \(process.operatingSystemVersionString)
        Apple Silicon: \(Rosetta.isAppleSilicon), Rosetta installed: \(Rosetta.isInstalled)
        Runtime: \(model.runtime?.info.version ?? "none") (Wine \(model.runtime?.info.wineVersion ?? "-"))
        Backends: \(model.runtime?.availableBackends.sorted().map(\.rawValue).joined(separator: ", ") ?? "-")
        Memory: \(process.physicalMemory / 1_073_741_824) GB
        """
        try system.write(to: folder.appendingPathComponent("system.txt"), atomically: true, encoding: .utf8)

        for log in (try? fm.contentsOfDirectory(at: model.paths.logs, includingPropertiesForKeys: nil)) ?? []
        where log.lastPathComponent.hasPrefix(game.id.uuidString) || log.lastPathComponent.contains(game.id.uuidString)
            || log.lastPathComponent.hasPrefix("wineboot") {
            try? fm.copyItem(at: log, to: folder.appendingPathComponent(log.lastPathComponent))
        }

        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let zip = desktop.appendingPathComponent("halalWine-\(safeName)-diagnostics.zip")
        try? fm.removeItem(at: zip)
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"),
                                                 ["-c", "-k", "--keepParent", folder.path, zip.path])
        guard result.status == 0 else { throw RuntimeError.extractionFailed(result.output) }
        return zip
    }
}

extension NSWorkspace {
    func relaunchApp() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
