import AppKit
import HalalWineCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// App-wide state: setup, library, runtime and running games.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let paths = AppPaths()
    @ObservationIgnored let runtimeStore: RuntimeStore
    @ObservationIgnored let library: GameLibrary

    private(set) var games: [GameRecord] = []
    private(set) var runtime: InstalledRuntime?
    private(set) var rules: RuleSet
    var selection: UUID?
    var errorMessage: String?
    var importingName: String?
    var setup = SetupProgress()
    var showSetup: Bool
    var availableRuntimeUpdate: RuntimeRelease?
    var controllers: [UUID: LaunchController] = [:]
    var installersRunning: Set<UUID> = []
    var d3dmetalImporting = false

    // Preferences (also bound with @AppStorage in views).
    var keepGamesInLibrary: Bool { UserDefaults.standard.object(forKey: Prefs.keepGamesInLibrary) as? Bool ?? true }
    var blackScreenDetection: Bool { UserDefaults.standard.bool(forKey: Prefs.blackScreenDetection) }
    var metalHUD: Bool { UserDefaults.standard.bool(forKey: Prefs.metalHUD) }

    private init() {
        // Work on locals first: @Observable does not allow reading `self`
        // before every stored property is initialized.
        let dataPaths = AppPaths()
        try? dataPaths.ensureDirectories()
        let store = RuntimeStore(paths: dataPaths)
        let loadedLibrary = GameLibrary(paths: dataPaths)
        let installed = store.current
        let ready = installed.map { PrefixManager(paths: dataPaths).isTemplateReady(for: $0) } ?? false

        runtimeStore = store
        library = loadedLibrary
        rules = RuleSet.best(cached: dataPaths.cachedRules)
        runtime = installed
        showSetup = !(ready && !Rosetta.isNeeded)
        games = loadedLibrary.games
        selection = loadedLibrary.games.first?.id
    }

    // MARK: - Lifecycle

    func onLaunch() {
        Task { await refreshRules() }
        Task { await checkForRuntimeUpdate() }
    }

    func refreshRules() async {
        guard let data = try? await HTTP.get(RuleSet.remoteURL),
              let remote = try? JSONDecoder().decode(RuleSet.self, from: data),
              remote.version > rules.version else { return }
        try? data.write(to: paths.cachedRules, options: .atomic)
        rules = remote
    }

    func checkForRuntimeUpdate() async {
        guard let installed = runtime,
              let manifest = try? await RuntimeStore.fetchManifest(),
              let latest = manifest.latest,
              VersionCompare.isNewer(latest.version, than: installed.info.version) else { return }
        availableRuntimeUpdate = latest
    }

    // MARK: - Setup (Rosetta + runtime download, like WhiskyWine)

    func beginSetup() {
        setup.step = Rosetta.isNeeded ? .rosetta : .runtime
        if setup.step == .runtime { installRuntime() }
    }

    func installRosetta() {
        setup.isWorking = true
        setup.error = nil
        Task {
            let ok = await Rosetta.install()
            setup.isWorking = false
            if ok {
                setup.step = .runtime
                installRuntime()
            } else {
                setup.error = L("setup.rosetta.failed")
            }
        }
    }

    func installRuntime() {
        guard !setup.isWorking else { return }
        setup.isWorking = true
        setup.error = nil
        setup.phase = .downloading
        setup.received = 0
        setup.expected = 0
        Task {
            do {
                var installed = runtimeStore.current
                if installed == nil || availableRuntimeUpdate != nil {
                    installed = try await runtimeStore.installLatest { received, expected in
                        Task { @MainActor in
                            AppModel.shared.setup.received = received
                            AppModel.shared.setup.expected = expected
                            if expected > 0, received >= expected { AppModel.shared.setup.phase = .installing }
                        }
                    }
                    availableRuntimeUpdate = nil
                }
                guard let installed else { throw RuntimeError.noRuntimePublished }
                runtime = installed
                setup.phase = .preparing
                try await PrefixManager(paths: paths).createTemplate(for: installed)
                setup.phase = .idle
                setup.isWorking = false
                setup.step = .done
            } catch RuntimeError.noRuntimePublished {
                setup.isWorking = false
                setup.error = L("setup.runtime.notPublished")
            } catch {
                setup.isWorking = false
                let detail = "\(error)"
                switch setup.phase {
                case .preparing:
                    setup.error = L("setup.runtime.prepareFailed", paths.logs.path, detail)
                case .installing:
                    setup.error = L("setup.runtime.installFailed", detail)
                default:
                    setup.error = L("setup.runtime.failed", detail)
                }
            }
        }
    }

    func finishSetup() {
        showSetup = false
    }

    // MARK: - Library

    func game(_ id: UUID) -> GameRecord? { games.first { $0.id == id } }

    func update(_ id: UUID, _ change: (inout GameRecord) -> Void) {
        guard var record = library.record(id: id) else { return }
        change(&record)
        library.upsert(record)
        persist()
    }

    private func persist() {
        do {
            try library.save()
        } catch {
            errorMessage = L("error.save", error.localizedDescription)
        }
        games = library.games
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder, .zip] + ["exe", "msi"].compactMap { UTType(filenameExtension: $0) }
        panel.prompt = L("library.add.prompt")
        panel.message = L("library.add.message")
        if panel.runModal() == .OK { addItems(panel.urls) }
    }

    func addItems(_ urls: [URL]) {
        Task {
            for url in urls { await importItem(url) }
        }
    }

    private func importItem(_ url: URL) async {
        importingName = url.deletingPathExtension().lastPathComponent
        defer { importingName = nil }
        let paths = self.paths
        let keep = keepGamesInLibrary
        do {
            let item = try await Task.detached {
                try await GameImporter(paths: paths).importItem(at: url, keepInsideLibrary: keep)
            }.value
            if let existing = library.find(executable: item.report.executable) {
                selection = existing.id
                return
            }
            let record = GameRecord(report: item.report, isManagedCopy: item.isManagedCopy)
            saveIcon(for: record)
            library.upsert(record)
            persist()
            selection = record.id
            if item.report.kind == .installer { await runInstaller(record.id) }
        } catch InspectError.noWindowsProgram {
            errorMessage = L("error.noWindowsProgram", url.lastPathComponent)
        } catch {
            errorMessage = L("error.import", url.lastPathComponent, error.localizedDescription)
        }
    }

    private func saveIcon(for record: GameRecord) {
        guard let ico = PEResources(url: record.executableURL)?.iconFile() else { return }
        try? ico.write(to: iconURL(for: record.id))
    }

    func iconURL(for id: UUID) -> URL { paths.icons.appendingPathComponent("\(id.uuidString).ico") }

    func remove(_ id: UUID, deleteFiles: Bool) {
        controllers[id]?.stop()
        controllers[id] = nil
        if let record = library.record(id: id) {
            try? FileManager.default.removeItem(at: paths.prefix(for: id))
            try? FileManager.default.removeItem(at: iconURL(for: id))
            if deleteFiles, record.isManagedCopy { try? FileManager.default.removeItem(at: record.rootURL) }
        }
        library.remove(id: id)
        persist()
        if selection == id { selection = games.first?.id }
    }

    /// Runs a dropped installer inside the game's own prefix, then finds the
    /// installed game and turns the library entry into it.
    func runInstaller(_ id: UUID) async {
        guard let runtime, let record = game(id) else { return }
        installersRunning.insert(id)
        defer { installersRunning.remove(id) }
        do {
            let prefix = try await PrefixManager(paths: paths).ensurePrefix(for: id, runtime: runtime)
            let before = Set(GameInspector.installLocations(inPrefix: prefix).map(\.path))
            let wineRoot = runtime.baseWine
            let env = WineEnvironment.make(wineRoot: wineRoot, prefix: prefix)
            let exe = record.executableURL
            let args = exe.pathExtension.lowercased() == "msi"
                ? ["msiexec", "/i", DependencyInstaller.windowsPath(exe)]
                : [exe.path]
            let log = paths.logs.appendingPathComponent("\(id.uuidString)-installer.log")
            try await ProcessRunner.run(InstalledRuntime.wineBinary(in: wineRoot), args, environment: env,
                                        currentDirectory: exe.deletingLastPathComponent(), logFile: log, timeout: 6 * 3600)
            try await ProcessRunner.run(InstalledRuntime.wineserverBinary(in: wineRoot), ["-w"], environment: env,
                                        logFile: log, timeout: 600)
            let created = GameInspector.installLocations(inPrefix: prefix).filter { !before.contains($0.path) }
            for folder in created {
                guard let report = try? GameInspector().inspect(folder), report.kind == .game else { continue }
                update(id) {
                    $0.report = report
                    $0.name = report.displayName
                }
                if let updated = game(id) { saveIcon(for: updated) }
                return
            }
            errorMessage = L("error.installerNoGame")
        } catch {
            errorMessage = L("error.installer", error.localizedDescription)
        }
    }

    // MARK: - Playing

    func plan(for record: GameRecord) -> LaunchPlan {
        LaunchPlanner(rules: rules).plan(for: record.report,
                                         available: runtime?.availableBackends ?? [.wined3d],
                                         history: record.history)
    }

    func controller(for id: UUID) -> LaunchController {
        if let existing = controllers[id] { return existing }
        let created = LaunchController(gameID: id, model: self)
        controllers[id] = created
        return created
    }

    func play(_ id: UUID, forcing config: LaunchConfig? = nil) {
        controller(for: id).start(forcing: config)
    }

    func recordSuccess(_ id: UUID, config: LaunchConfig) {
        update(id) {
            $0.history.working = config
            $0.history.failedKeys.removeAll { $0 == config.key }
        }
    }

    func recordFailure(_ id: UUID, config: LaunchConfig) {
        update(id) {
            if $0.history.working?.key == config.key { $0.history.working = nil }
            if !$0.history.failedKeys.contains(config.key) { $0.history.failedKeys.append(config.key) }
        }
    }

    func resetLearnedSettings(_ id: UUID) {
        update(id) {
            $0.history = LaunchHistory()
            $0.advertiseAVX = false
        }
    }

    // MARK: - D3DMetal

    func importD3DMetal() {
        guard let runtime else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.folder, .diskImage]
        panel.message = L("d3dmetal.panel.message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        d3dmetalImporting = true
        Task {
            defer { d3dmetalImporting = false }
            do {
                try await D3DMetalImport.importFrom(url, runtime: runtime)
                self.runtime = runtimeStore.current
            } catch {
                errorMessage = L("d3dmetal.failed")
            }
        }
    }

    func removeD3DMetal() {
        try? runtime?.removeD3DMetal()
        runtime = runtimeStore.current
    }
}

enum Prefs {
    static let keepGamesInLibrary = "keepGamesInLibrary"
    static let blackScreenDetection = "blackScreenDetection"
    static let metalHUD = "metalHUD"
    static let appLanguage = "appLanguage"
}

struct SetupProgress {
    enum Step { case welcome, rosetta, runtime, done }
    enum Phase { case idle, downloading, installing, preparing }
    var step: Step = .welcome
    var phase: Phase = .idle
    var isWorking = false
    var received: Int64 = 0
    var expected: Int64 = 0
    var error: String?

    var fraction: Double? {
        guard phase == .downloading, expected > 0 else { return nil }
        return min(1, Double(received) / Double(expected))
    }
}
