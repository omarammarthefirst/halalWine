import XCTest
@testable import HalalWineCore

final class PEParserTests: XCTestCase {
    func testParsesImportsMachineSubsystemAndDotNet() throws {
        let bytes = Fixtures.makePE(imports: ["KERNEL32.dll", "d3d11.dll", "dxgi.dll"], delayImports: ["d3d12.dll"], dotNet: true)
        let url = try Fixtures.tree(["a.exe": bytes]).appendingPathComponent("a.exe")
        let info = try PEParser.parse(url: url)
        XCTAssertEqual(info.machine, .x64)
        XCTAssertTrue(info.isGUI)
        XCTAssertTrue(info.isDotNet)
        XCTAssertEqual(info.imports, ["KERNEL32.dll", "d3d11.dll", "dxgi.dll"])
        XCTAssertEqual(info.delayImports, ["d3d12.dll"])
        XCTAssertEqual(GameInspector.apis(fromImports: info.allImports), [.d3d12, .d3d11])
    }

    func testRejectsNonPE() throws {
        let url = try Fixtures.tree(["x.exe": Array("hello world, definitely not a program".utf8) + [UInt8](repeating: 0, count: 64)])
            .appendingPathComponent("x.exe")
        XCTAssertThrowsError(try PEParser.parse(url: url))
    }

    func testThirtyTwoBitConsoleProgram() throws {
        let url = try Fixtures.tree(["c.exe": Fixtures.makePE(machine: 0x14C, subsystem: 3)]).appendingPathComponent("c.exe")
        let info = try PEParser.parse(url: url)
        XCTAssertEqual(info.machine, .x86)
        XCTAssertFalse(info.isGUI)
    }
}

final class GodotPackTests: XCTestCase {
    func testFormat2StandalonePackWithCompatibilityRenderer() throws {
        let pck = Fixtures.makePCK(format: 2, major: 4, minor: 2, patch: 1,
                                   settings: ["rendering/renderer/rendering_method": "gl_compatibility",
                                              "application/config/name": "Demo"])
        let url = try Fixtures.tree(["g.pck": pck]).appendingPathComponent("g.pck")
        let info = try XCTUnwrap(GodotPackReader.read(pck: url))
        XCTAssertEqual(info.version, "4.2.1")
        XCTAssertEqual(info.packFormat, 2)
        XCTAssertFalse(info.embedded)
        XCTAssertEqual(info.renderingMethod, "gl_compatibility")
    }

    func testFormat3DefaultsToForwardPlus() throws {
        let pck = Fixtures.makePCK(format: 3, major: 4, minor: 4, settings: ["application/config/name": "Demo"], pathPrefix: "")
        let url = try Fixtures.tree(["g.pck": pck]).appendingPathComponent("g.pck")
        let info = try XCTUnwrap(GodotPackReader.read(pck: url))
        XCTAssertEqual(info.version, "4.4.0")
        XCTAssertEqual(info.renderingMethod, "forward_plus")
    }

    func testPlatformOverrideKeyIsIgnored() {
        let data = Fixtures.projectBinary(["rendering/renderer/rendering_method.mobile": "gl_compatibility",
                                           "rendering/renderer/rendering_method": "mobile"])
        XCTAssertEqual(GodotPackReader.renderingMethod(inProjectBinary: data, major: 4), "mobile")
    }

    func testGodot3DriverName() {
        let data = Fixtures.projectBinary(["rendering/quality/driver/driver_name": "GLES2"])
        XCTAssertEqual(GodotPackReader.renderingMethod(inProjectBinary: data, major: 3), "GLES2")
    }

    func testPackEmbeddedAtEndOfExecutable() throws {
        let pck = Fixtures.makePCK(format: 3, major: 4, minor: 3, settings: ["rendering/renderer/rendering_method": "mobile"])
        let exe = Fixtures.makePE() + pck + Fixtures.le64(UInt64(pck.count)) + Array("GDPC".utf8)
        let url = try Fixtures.tree(["Game.exe": exe]).appendingPathComponent("Game.exe")
        let info = try XCTUnwrap(GodotPackReader.readEmbedded(exe: url, pe: try PEParser.parse(url: url)))
        XCTAssertTrue(info.embedded)
        XCTAssertEqual(info.version, "4.3.0")
        XCTAssertEqual(info.renderingMethod, "mobile")
    }

    func testPackEmbeddedInPESection() throws {
        let pck = Fixtures.makePCK(format: 3, major: 4, minor: 5, settings: [:])
        let url = try Fixtures.tree(["Game.exe": Fixtures.makePE(pckSection: pck)]).appendingPathComponent("Game.exe")
        let info = try XCTUnwrap(GodotPackReader.readEmbedded(exe: url, pe: try PEParser.parse(url: url)))
        XCTAssertEqual(info.version, "4.5.0")
        XCTAssertEqual(info.renderingMethod, "forward_plus")
    }
}

final class InspectorTests: XCTestCase {
    let exe = Fixtures.makePE(imports: ["KERNEL32.dll"])

    func testGodotDotNetGameLikeSlayTheSpire2() throws {
        let root = try Fixtures.tree([
            "SlayTheSpire2.exe": exe,
            "SlayTheSpire2.console.exe": Fixtures.makePE(subsystem: 3),
            "SlayTheSpire2.pck": Fixtures.makePCK(format: 3, major: 4, minor: 5, settings: [:]),
            "data_sts2_windows_x86_64/GodotSharp.dll": [1, 2, 3],
            "steam_api64.dll": [0],
        ], folderName: "Slay.the.Spire.2.v0.111.0")

        let report = try GameInspector().inspect(root)
        XCTAssertEqual(report.kind, .game)
        XCTAssertEqual((report.executable as NSString).lastPathComponent, "SlayTheSpire2.exe")
        XCTAssertEqual(report.engine, .godot)
        XCTAssertEqual(report.engineVersion, "4.5.0")
        XCTAssertTrue(report.isDotNet)
        XCTAssertEqual(report.graphicsAPIs, [.d3d12, .vulkan, .opengl])
        XCTAssertEqual(report.displayName, "Slay the Spire 2")
        XCTAssertTrue(report.redFlags.contains(.usesSteam))

        let rules = RuleSet.bundled()
        let all = LaunchPlanner(rules: rules).plan(for: report, available: Set(GraphicsBackend.allCases))
        XCTAssertEqual(all.ruleID, "godot4")
        XCTAssertEqual(all.configs.map(\.backend), [.d3dmetal, .wined3d, .dxmt, .wined3d])
        XCTAssertEqual(all.configs[0].arguments, ["--rendering-driver", "d3d12"])
        XCTAssertEqual(all.configs[1].arguments, ["--rendering-driver", "opengl3"])
        XCTAssertEqual(all.configs[2].arguments, ["--rendering-driver", "opengl3_angle"])
        XCTAssertEqual(all.windowedArguments, ["--windowed"])

        // Without D3DMetal imported, the first try is WineD3D + OpenGL.
        let free = LaunchPlanner(rules: rules).plan(for: report, available: [.wined3d, .dxmt, .dxvk])
        XCTAssertEqual(free.configs.first?.backend, .wined3d)
        XCTAssertEqual(free.unavailable.map(\.backend), [.d3dmetal])
    }

    func testUnityGame() throws {
        var ggm = [UInt8](repeating: 0, count: 64)
        ggm += Array("2022.3.10f1".utf8) + [0]
        let root = try Fixtures.tree([
            "MyGame.exe": exe,
            "UnityPlayer.dll": [0],
            "UnityCrashHandler64.exe": exe,
            "MyGame_Data/globalgamemanagers": ggm,
            "MonoBleedingEdge/EmbedRuntime/mono.exe": exe,
        ], folderName: "MyGame")
        let report = try GameInspector().inspect(root)
        XCTAssertEqual((report.executable as NSString).lastPathComponent, "MyGame.exe")
        XCTAssertEqual(report.engine, .unity)
        XCTAssertEqual(report.engineVersion, "2022.3.10f1")
        let plan = LaunchPlanner(rules: RuleSet.bundled()).plan(for: report, available: [.wined3d, .dxmt, .dxvk])
        XCTAssertEqual(plan.configs.first, LaunchConfig(stepID: "unity-dxmt-d3d11", backend: .dxmt, arguments: ["-force-d3d11"]))
    }

    func testUnrealGamePrefersShippingExeAndFlagsAntiCheat() throws {
        let root = try Fixtures.tree([
            "Cool.exe": exe,
            "CoolGame/Binaries/Win64/CoolGame-Win64-Shipping.exe": Fixtures.makePE(imports: ["d3d12.dll", "dxgi.dll"]),
            "Engine/Extras/Redist/en-us/UEPrereqSetup_x64.exe": exe,
            "EasyAntiCheat/EasyAntiCheat_EOS_Setup.exe": exe,
            "start_protected_game.exe": exe,
        ], folderName: "Cool")
        let report = try GameInspector().inspect(root)
        XCTAssertTrue(report.executable.hasSuffix("CoolGame-Win64-Shipping.exe"))
        XCTAssertEqual(report.engine, .unreal)
        XCTAssertEqual(report.primaryAPI, .d3d12)
        XCTAssertTrue(report.redFlags.contains(.easyAntiCheat))
        XCTAssertTrue(report.redFlags.contains(where: \.blocksPlay))
        XCTAssertTrue(report.bundledRedistributables.contains { $0.hasSuffix("UEPrereqSetup_x64.exe") })
    }

    func testDroppingAnExeInsideUnrealBinariesFindsTheRoot() {
        let exe = URL(fileURLWithPath: "/Games/Cool/CoolGame/Binaries/Win64/CoolGame-Win64-Shipping.exe")
        XCTAssertEqual(GameInspector.gameRoot(forExecutable: exe).path, "/Games/Cool")
    }

    func testCustomEngineUsesImportsOfSiblingDLLs() throws {
        let root = try Fixtures.tree([
            "Retro.exe": exe,
            "render.dll": Fixtures.makePE(imports: ["d3d9.dll"]),
        ], folderName: "Retro Game")
        let report = try GameInspector().inspect(root)
        XCTAssertEqual(report.engine, .unknown)
        XCTAssertEqual(report.graphicsAPIs, [.d3d9])
        let plan = LaunchPlanner(rules: RuleSet.bundled()).plan(for: report, available: Set(GraphicsBackend.allCases))
        XCTAssertEqual(plan.configs.map(\.backend), [.wined3d])
    }

    func testInstallerIsRecognised() throws {
        let root = try Fixtures.tree([
            "setup_mygame_1.0.exe": exe,
            "setup_mygame_1.0-1.bin": [0],
        ], folderName: "Downloads")
        let report = try GameInspector().inspect(root)
        XCTAssertEqual(report.kind, .installer)
    }

    func testCleanName() {
        XCTAssertEqual(GameInspector.cleanName("Slay.the.Spire.2.v0.111.0"), "Slay the Spire 2")
        XCTAssertEqual(GameInspector.cleanName("Hollow_Knight_v1.5.78"), "Hollow Knight")
        XCTAssertEqual(GameInspector.cleanName("Cool Game (2024) [GOG]"), "Cool Game")
        XCTAssertEqual(GameInspector.cleanName("Celeste"), "Celeste")
    }
}

final class RulesAndPlannerTests: XCTestCase {
    func testBundledRulesAreConsistent() {
        let rules = RuleSet.bundled()
        XCTAssertGreaterThanOrEqual(rules.version, 1)
        XCTAssertEqual(Set(rules.rules.map(\.id)).count, rules.rules.count, "rule ids must be unique")
        for rule in rules.rules { XCTAssertFalse(rule.steps.isEmpty, rule.id) }
        XCTAssertEqual(rules.rules.last?.id, "fallback")
    }

    func testHistoryPutsWorkingFirstAndFailedLast() {
        var report = sampleReport(engine: .unity)
        report.engineVersion = "2021.3.1f1"
        let rules = RuleSet.bundled()
        let base = LaunchPlanner(rules: rules).plan(for: report, available: Set(GraphicsBackend.allCases))
        let working = base.configs[3]
        let failed = base.configs[0]
        let plan = LaunchPlanner(rules: rules).plan(for: report, available: Set(GraphicsBackend.allCases),
                                                    history: LaunchHistory(working: working, failedKeys: [failed.key]))
        XCTAssertEqual(plan.configs.first, working)
        XCTAssertEqual(plan.configs.last, failed)
        XCTAssertEqual(plan.configs.count, base.configs.count)
    }

    func testGodotVersionGates() {
        var report = sampleReport(engine: .godot)
        report.godot = GodotPackInfo(packFormat: 2, major: 4, minor: 2, patch: 0, embedded: false,
                                     encryptedDirectory: false, renderingMethod: "forward_plus")
        report.engineVersion = "4.2.0"
        XCTAssertEqual(RuleSet.bundled().rule(for: report)?.id, "godot4-early")
        report.engineVersion = "4.3.0"
        XCTAssertEqual(RuleSet.bundled().rule(for: report)?.id, "godot4")
        report.godot?.renderingMethod = "gl_compatibility"
        XCTAssertEqual(RuleSet.bundled().rule(for: report)?.id, "godot4-compatibility")
    }

    func testLaunchCommand() throws {
        let runtimeRoot = try Fixtures.tree(["wine/bin/wine": [0], "components/dxvk/x64/d3d11.dll": [0],
                                             "components/dxvk/x64/dxgi.dll": [0]], folderName: "rt")
        let runtime = InstalledRuntime(root: runtimeRoot, info: RuntimeInfo(version: "1", wineVersion: "11.0", components: [:]))
        let report = sampleReport(engine: .unity)
        let rules = RuleSet.bundled()
        let plan = LaunchPlanner(rules: rules).plan(for: report, available: runtime.availableBackends)
        let dxvk = try XCTUnwrap(plan.configs.first { $0.backend == .dxvk })
        let cmd = LaunchCommandBuilder.build(gameExecutable: URL(fileURLWithPath: "/g/Game.exe"), config: dxvk, plan: plan,
                                             runtime: runtime, wineRoot: runtime.baseWine, prefix: URL(fileURLWithPath: "/p"),
                                             rules: rules, settings: LaunchSettings(preferWindowed: true, advertiseAVX: true),
                                             baseEnvironment: ["PATH": "/usr/bin", "DYLD_LIBRARY_PATH": "/x", "WINEDEBUG": "+all"])
        XCTAssertEqual(cmd.arguments, ["/g/Game.exe", "-force-d3d11", "-screen-fullscreen", "0"])
        XCTAssertEqual(cmd.environment["WINEPREFIX"], "/p")
        XCTAssertEqual(cmd.environment["WINEDEBUG"], "fixme-all")
        XCTAssertEqual(cmd.environment["ROSETTA_ADVERTISE_AVX"], "1")
        XCTAssertEqual(cmd.environment["DXVK_ASYNC"], "1")
        XCTAssertNil(cmd.environment["DYLD_LIBRARY_PATH"])
        XCTAssertEqual(cmd.environment["WINEDLLOVERRIDES"], "d3d10core=b;d3d11=n,b;d3d12=b;d3d9=b;dxgi=n,b")
        XCTAssertEqual(cmd.workingDirectory.path, "/g")
        XCTAssertTrue(cmd.environment["PATH"]!.hasPrefix(runtime.baseWine.path + "/bin:"))
    }

}

final class RuntimeTests: XCTestCase {
    func testBackendsAndDXMTVariant() throws {
        let root = try Fixtures.tree([
            "runtime.json": Array(#"{"version":"11.21-1","wineVersion":"11.21","components":{"dxmt":"v0.80"}}"#.utf8),
            "wine/bin/wine": [0],
            "wine/lib/wine/x86_64-windows/d3d11.dll": Array("wined3d".utf8),
            "components/dxmt/x86_64-windows/d3d11.dll": Array("dxmt".utf8),
            "components/dxmt/x86_64-windows/winemetal.dll": [1],
            "components/dxmt/x86_64-unix/winemetal.so": [2],
        ], folderName: "11.21-1")
        let runtime = InstalledRuntime(root: root, info: RuntimeInfo(version: "11.21-1", wineVersion: "11.21", components: ["dxmt": "v0.80"]))
        XCTAssertEqual(runtime.availableBackends, [.wined3d, .dxmt])

        let variant = try runtime.wineRoot(for: .dxmt)
        XCTAssertEqual(try String(contentsOf: variant.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll"), encoding: .utf8), "dxmt")
        XCTAssertTrue(FileOps.exists(variant.appendingPathComponent("lib/wine/x86_64-unix/winemetal.so")))
        // The base tree keeps Wine's own DLL for WineD3D.
        XCTAssertEqual(try String(contentsOf: runtime.baseWine.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll"), encoding: .utf8), "wined3d")
        XCTAssertEqual(try runtime.wineRoot(for: .wined3d), runtime.baseWine)
        XCTAssertThrowsError(try runtime.wineRoot(for: .d3dmetal))

        // Importing D3DMetal from a Game Porting Toolkit layout.
        let gptk = try Fixtures.tree([
            "redist/lib/external/D3DMetal.framework/Versions/A/D3DMetal": [9],
            "redist/lib/wine/x86_64-windows/d3d12.dll": Array("d3dmetal".utf8),
        ], folderName: "GPTK")
        let lib = try XCTUnwrap(InstalledRuntime.findRedistLib(in: gptk))
        try runtime.installD3DMetal(redistLib: lib)
        XCTAssertTrue(runtime.availableBackends.contains(.d3dmetal))
        let metal = try runtime.wineRoot(for: .d3dmetal)
        XCTAssertEqual(try String(contentsOf: metal.appendingPathComponent("lib/wine/x86_64-windows/d3d12.dll"), encoding: .utf8), "d3dmetal")
    }

    func testStoreListsNewestFirst() throws {
        let paths = AppPaths(root: try Fixtures.tree([
            "Runtimes/11.9-1/runtime.json": Array(#"{"version":"11.9-1","wineVersion":"11.9","components":{}}"#.utf8),
            "Runtimes/11.21-1/runtime.json": Array(#"{"version":"11.21-1","wineVersion":"11.21","components":{}}"#.utf8),
        ], folderName: "home"))
        XCTAssertEqual(RuntimeStore(paths: paths).installed().map(\.info.version), ["11.21-1", "11.9-1"])
    }

    func testManifestLatest() throws {
        let json = #"{"schema":1,"runtimes":[{"version":"11.9-1","wineVersion":"11.9","url":"https://x/a.tar.xz"},{"version":"11.21-1","wineVersion":"11.21","url":"https://x/b.tar.xz","sha256":"ab"}]}"#
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.latest?.version, "11.21-1")
    }

    func testVersionCompare() {
        XCTAssertTrue(VersionCompare.isNewer("11.10", than: "11.9"))
        XCTAssertEqual(VersionCompare.compare("4.3", "4.3.0"), .orderedSame)
        XCTAssertEqual(VersionCompare.compare("4.2.1", "4.3"), .orderedAscending)
    }
}

final class LogDoctorTests: XCTestCase {
    let doctor = LogDoctor()

    func testRecognisesCommonFailures() {
        XCTAssertEqual(doctor.diagnose(line: #"0024:err:module:import_dll Library MSVCP140.dll (which is needed by L"C:\\game\\game.exe") not found"#),
                       .needsVCRedist("msvcp140.dll"))
        XCTAssertEqual(doctor.diagnose(line: #"0024:err:module:import_dll Library d3dx9_43.dll (which is needed by L"x") not found"#),
                       .needsDirectXRuntime("d3dx9_43.dll"))
        XCTAssertEqual(doctor.diagnose(line: "wine: Unhandled illegal instruction at address 0000000140001000"), .needsAVX)
        XCTAssertEqual(doctor.diagnose(line: "ERROR: Your video card drivers seem not to support the required Vulkan version."), .rendererFailed)
        XCTAssertEqual(doctor.diagnose(line: "[S_API FAIL] SteamAPI_Init() failed; no appID found."), .needsSteam)
        XCTAssertNil(doctor.diagnose(line: "0024:fixme:ntdll:NtQuerySystemInformation info_class SYSTEM_PERFORMANCE_INFORMATION"))
        XCTAssertEqual(Dependency.from(.needsVCRedist("x")), .vcredist)
    }
}

final class LibraryTests: XCTestCase {
    func testSaveAndLoad() throws {
        let paths = AppPaths(root: try Fixtures.tree([:], folderName: "home"))
        let library = GameLibrary(paths: paths)
        let report = sampleReport(engine: .godot)
        var record = GameRecord(report: report, isManagedCopy: false)
        record.history.working = LaunchConfig(stepID: "x", backend: .dxmt, arguments: ["-a"])
        library.upsert(record)
        try library.save()
        let reloaded = GameLibrary(paths: paths)
        XCTAssertEqual(reloaded.games.count, 1)
        XCTAssertEqual(reloaded.games.first?.id, record.id)
        XCTAssertEqual(reloaded.games.first?.report, record.report)
        XCTAssertEqual(reloaded.find(executable: "/g/Game.exe")?.history.working?.backend, .dxmt)
    }

    func testMergeContentsReplacesFiles() throws {
        let a = try Fixtures.tree(["x/1.txt": Array("new".utf8), "2.txt": [1]], folderName: "a")
        let b = try Fixtures.tree(["x/1.txt": Array("old".utf8), "x/keep.txt": [2]], folderName: "b")
        try FileOps.mergeContents(of: a, into: b)
        XCTAssertEqual(try String(contentsOf: b.appendingPathComponent("x/1.txt"), encoding: .utf8), "new")
        XCTAssertTrue(FileOps.exists(b.appendingPathComponent("x/keep.txt")))
        XCTAssertTrue(FileOps.exists(b.appendingPathComponent("2.txt")))
    }
}

func sampleReport(engine: GameEngine) -> GameReport {
    GameReport(kind: .game, rootFolder: "/g", executable: "/g/Game.exe", displayName: "Game", engine: engine,
               engineVersion: nil, graphicsAPIs: [.d3d11], architecture: .x64, isDotNet: false, godot: nil,
               redFlags: [], store: StoreInfo(), otherExecutables: [], bundledRedistributables: [])
}
