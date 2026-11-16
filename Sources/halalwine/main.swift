import Foundation
import HalalWineCore

// halalwine — command-line companion to the halalWine app.
// Shares the same data folder, runtimes and library as the app.

let usage = """
halalwine — run Windows games on macOS

USAGE
  halalwine inspect <folder|exe> [--json]   Detect engine, graphics API and problems
  halalwine plan <folder|exe> [--all]       Show the launch configurations that will be tried
  halalwine run <folder|exe> [options] [-- game args]
        --step N         use configuration N from `plan` (default 1)
        --fullscreen     do not add windowed-mode arguments
        --avx            let Rosetta advertise AVX (macOS 15+)
        --hud            show the Metal performance HUD
  halalwine runtime status
  halalwine runtime install [--archive FILE] [--manifest URL]
  halalwine runtime import-d3dmetal <Game Porting Toolkit folder or mounted image>
  halalwine icon <exe> <out.ico>            Extract the program icon
  halalwine doctor <log file>               Explain a game log

Data folder: \(AppPaths().root.path)  (override with HALALWINE_HOME)
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(value) { print(String(decoding: data, as: UTF8.self)) }
}

func inspect(_ path: String) -> GameReport {
    do {
        return try GameInspector().inspect(URL(fileURLWithPath: path))
    } catch {
        fail("could not inspect \(path): \(error)")
    }
}

func describe(_ report: GameReport) {
    print("Name:         \(report.displayName)")
    print("Kind:         \(report.kind.rawValue)")
    print("Executable:   \(report.executable)")
    print("Engine:       \(report.engine.rawValue)\(report.engineVersion.map { " \($0)" } ?? "")")
    if let godot = report.godot {
        print("Godot pack:   format \(godot.packFormat), \(godot.embedded ? "embedded" : "separate .pck"), renderer \(godot.renderingMethod ?? "unknown")")
    }
    print("Graphics:     \(report.graphicsAPIs.map(\.rawValue).joined(separator: ", "))")
    print("Architecture: \(report.architecture.rawValue)\(report.isDotNet ? " (.NET)" : "")")
    if let steam = report.store.steamAppID { print("Steam app:    \(steam)") }
    if let gog = report.store.gogID { print("GOG id:       \(gog)") }
    if !report.redFlags.isEmpty { print("Warnings:     \(report.redFlags.map(\.rawValue).joined(separator: ", "))") }
    if !report.otherExecutables.isEmpty { print("Other .exe:   \(report.otherExecutables.prefix(5).joined(separator: ", "))") }
}

func printPlan(_ plan: LaunchPlan) {
    print("Rule: \(plan.ruleID)")
    for (i, config) in plan.configs.enumerated() {
        let env = config.environment.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        print(String(format: "  %d. %-9@ %@ %@", i + 1, config.backend.rawValue as NSString,
                     config.arguments.joined(separator: " ") as NSString, env as NSString))
    }
    for config in plan.unavailable {
        print("  –  \(config.backend.rawValue) \(config.arguments.joined(separator: " "))  (not installed)")
    }
    if !plan.windowedArguments.isEmpty { print("Windowed mode adds: \(plan.windowedArguments.joined(separator: " "))") }
}

let paths = AppPaths()
let store = RuntimeStore(paths: paths)
let rules = RuleSet.best(cached: paths.cachedRules)
var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

switch command {
case "inspect":
    guard let path = args.first else { fail("inspect needs a path") }
    let report = inspect(path)
    if args.contains("--json") { printJSON(report) } else { describe(report) }

case "plan":
    guard let path = args.first else { fail("plan needs a path") }
    let report = inspect(path)
    let available = args.contains("--all") ? Set(GraphicsBackend.allCases) : (store.current?.availableBackends ?? [.wined3d])
    describe(report)
    print("")
    printPlan(LaunchPlanner(rules: rules).plan(for: report, available: available))

case "run":
    guard let path = args.first else { fail("run needs a path") }
    guard let runtime = store.current else { fail("no runtime installed; run `halalwine runtime install`") }
    var gameArgs: [String] = []
    if let dash = args.firstIndex(of: "--") {
        gameArgs = Array(args[(dash + 1)...])
        args = Array(args[..<dash])
    }
    let report = inspect(path)
    let library = GameLibrary(paths: paths)
    var record = library.find(executable: report.executable) ?? GameRecord(report: report, isManagedCopy: false)
    record.preferWindowed = !args.contains("--fullscreen")
    record.advertiseAVX = args.contains("--avx")
    record.extraArguments = gameArgs
    let plan = LaunchPlanner(rules: rules).plan(for: report, available: runtime.availableBackends, history: record.history)
    var step = 1
    if let i = args.firstIndex(of: "--step"), i + 1 < args.count, let n = Int(args[i + 1]) { step = n }
    guard step >= 1, step <= plan.configs.count else { fail("step must be between 1 and \(plan.configs.count)") }
    let config = plan.configs[step - 1]
    print("Launching \(report.displayName) with \(config.backend.rawValue) \(config.arguments.joined(separator: " "))")

    do {
        let prefix = try await PrefixManager(paths: paths).ensurePrefix(for: record.id, runtime: runtime)
        let wineRoot = try runtime.wineRoot(for: config.backend)
        try BackendSetup.prepare(prefix: prefix, backend: config.backend, runtime: runtime)
        let launch = LaunchCommandBuilder.build(gameExecutable: record.executableURL, config: config, plan: plan,
                                                runtime: runtime, wineRoot: wineRoot, prefix: prefix, rules: rules,
                                                settings: record.launchSettings(metalHUD: args.contains("--hud")))
        let log = paths.logs.appendingPathComponent("\(record.id.uuidString).log")
        let session = WineSession(command: launch, logURL: log)
        let doctor = LogDoctor()
        session.onLine = { line in
            print(line)
            if let d = doctor.diagnose(line: line) { print("  ↳ halalwine: \(d)") }
        }
        let done = DispatchSemaphore(value: 0)
        session.onEnd = { code in
            print("Game ended (exit code \(code)). Log: \(log.path)")
            done.signal()
        }
        try session.start()
        record.lastPlayedAt = Date()
        library.upsert(record)
        try? library.save()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { done.wait(); c.resume() }
        }
    } catch {
        fail("\(error)")
    }

case "runtime":
    switch args.first {
    case "status", nil:
        let installed = store.installed()
        if installed.isEmpty { print("No runtime installed.") }
        for runtime in installed {
            print("\(runtime.info.version) (Wine \(runtime.info.wineVersion)) at \(runtime.root.path)")
            print("  backends: \(runtime.availableBackends.sorted().map(\.rawValue).joined(separator: ", "))")
            print("  components: \(runtime.info.components.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", "))")
        }
    case "install":
        do {
            let runtime: InstalledRuntime
            if let i = args.firstIndex(of: "--archive"), i + 1 < args.count {
                runtime = try await store.install(archive: URL(fileURLWithPath: args[i + 1]))
            } else {
                var manifest = RuntimeManifest.defaultURL
                if let i = args.firstIndex(of: "--manifest"), i + 1 < args.count, let url = URL(string: args[i + 1]) { manifest = url }
                runtime = try await store.installLatest(manifestURL: manifest) { received, expected in
                    guard expected > 0 else { return }
                    let pct = Int(Double(received) / Double(expected) * 100)
                    FileHandle.standardError.write(Data("\rDownloading… \(pct)%".utf8))
                }
                FileHandle.standardError.write(Data("\n".utf8))
            }
            print("Installed runtime \(runtime.info.version). Preparing Windows environment…")
            try await PrefixManager(paths: paths).createTemplate(for: runtime)
            print("Done.")
        } catch {
            fail("\(error)")
        }
    case "import-d3dmetal":
        guard args.count >= 2 else { fail("import-d3dmetal needs the Game Porting Toolkit folder") }
        guard let runtime = store.current else { fail("install a runtime first") }
        guard let lib = InstalledRuntime.findRedistLib(in: URL(fileURLWithPath: args[1])) else {
            fail("could not find redist/lib with D3DMetal.framework in \(args[1])")
        }
        do {
            try runtime.installD3DMetal(redistLib: lib)
            print("D3DMetal installed from \(lib.path)")
        } catch {
            fail("\(error)")
        }
    default:
        fail("unknown runtime command; see `halalwine` for help")
    }

case "icon":
    guard args.count >= 2 else { fail("icon needs <exe> <out.ico>") }
    guard let ico = PEResources(url: URL(fileURLWithPath: args[0]))?.iconFile() else { fail("no icon found") }
    do { try ico.write(to: URL(fileURLWithPath: args[1])) } catch { fail("\(error)") }
    print("Wrote \(args[1]) (\(ico.count) bytes)")

case "doctor":
    guard let path = args.first, let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("doctor needs a readable log file") }
    let findings = LogDoctor().diagnose(log: text)
    if findings.isEmpty { print("No known problems found.") }
    for finding in findings { print("• \(finding)") }

case "help", "--help", "-h":
    print(usage)

default:
    fail("unknown command \(command)\n\n\(usage)")
}
