import Foundation

/// Per-launch Wine settings for each graphics backend.
public enum BackendSetup {
    /// DLL name → load order ("b" = Wine's built-in, "n,b" = file in system32 first).
    public static func dllOverrides(for backend: GraphicsBackend, runtime: InstalledRuntime) -> [String: String] {
        let directX = ["d3d9", "d3d10core", "d3d11", "d3d12", "dxgi"]
        var overrides: [String: String] = [:]
        switch backend {
        case .wined3d, .d3dmetal, .dxmt:
            // The variant's built-ins are the backend (WineD3D, D3DMetal or DXMT).
            // Force built-in so DLLs left in system32 by DXVK are ignored.
            for dll in directX { overrides[dll] = "b" }
        case .dxvk:
            for dll in directX { overrides[dll] = "b" }
            for dll in FileOps.files(in: runtime.dxvkComponent.appendingPathComponent("x64"), withExtension: "dll") {
                overrides[dll.deletingPathExtension().lastPathComponent.lowercased()] = "n,b"
            }
        }
        return overrides
    }

    public static func overridesString(_ overrides: [String: String]) -> String {
        overrides.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
    }

    /// Copies the native DLLs a backend needs into the prefix.
    public static func prepare(prefix: URL, backend: GraphicsBackend, runtime: InstalledRuntime) throws {
        let windows = prefix.appendingPathComponent("drive_c/windows")
        let system32 = windows.appendingPathComponent("system32")
        let syswow64 = windows.appendingPathComponent("syswow64")
        switch backend {
        case .dxvk:
            for dll in FileOps.files(in: runtime.dxvkComponent.appendingPathComponent("x64"), withExtension: "dll") {
                try FileOps.replaceFile(at: system32.appendingPathComponent(dll.lastPathComponent), with: dll)
            }
            if FileOps.exists(syswow64) {
                for dll in FileOps.files(in: runtime.dxvkComponent.appendingPathComponent("x32"), withExtension: "dll") {
                    try FileOps.replaceFile(at: syswow64.appendingPathComponent(dll.lastPathComponent), with: dll)
                }
            }
        case .dxmt:
            // DXMT's guide: winemetal.dll must also be present in system32.
            let x64 = runtime.dxmtComponent.appendingPathComponent("x86_64-windows/winemetal.dll")
            if FileOps.exists(x64) { try FileOps.replaceFile(at: system32.appendingPathComponent("winemetal.dll"), with: x64) }
            let x86 = runtime.dxmtComponent.appendingPathComponent("i386-windows/winemetal.dll")
            if FileOps.exists(x86), FileOps.exists(syswow64) {
                try FileOps.replaceFile(at: syswow64.appendingPathComponent("winemetal.dll"), with: x86)
            }
        case .wined3d, .d3dmetal:
            break
        }
    }
}
