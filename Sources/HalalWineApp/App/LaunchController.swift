import Foundation
import HalalWineCore
import Observation

/// Finds working settings for one game: launch, watch, fix or fall back,
/// ask the player, and remember what worked.
@MainActor
@Observable
final class LaunchController {
    enum Phase: Equatable {
        case idle
        case preparing
        case installing(Dependency)
        case starting(attempt: Int, total: Int)
        case checking(attempt: Int, total: Int)
        /// A window is up: ask the player whether the game looks right.
        case confirm(attempt: Int, total: Int)
        case running
        case blocked(BlockReason)
        case failed
        case finished
    }

    enum BlockReason: Equatable {
        case needsSteam
        case antiCheat
        case noRuntime
        case missingFiles
    }

    private enum Outcome {
        case worked
        case failed
        case retry
        case stopped
        case blocked(BlockReason)
    }

    let gameID: UUID
    private(set) var phase: Phase = .idle
    private(set) var currentConfig: LaunchConfig?
    private(set) var lastDiagnosis: Diagnosis?

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private var session: WineSession?
    @ObservationIgnored private var verdict: Bool?
    @ObservationIgnored private var sessionEnded = false
    @ObservationIgnored private var pending: [Diagnosis] = []
    @ObservationIgnored private var stopRequested = false

    init(gameID: UUID, model: AppModel) {
        self.gameID = gameID
        self.model = model
    }

    var isActive: Bool {
        switch phase {
        case .idle, .failed, .finished, .blocked: return false
        default: return true
        }
    }

    func start(forcing config: LaunchConfig? = nil) {
        guard !isActive else { return }
        Task { await run(forcing: config) }
    }

    /// The player's answer to "Is the game working?".
    func answer(_ working: Bool) { verdict = working }

    func stop() {
        stopRequested = true
        if let session { Task { await session.terminate() } }
    }

    func dismiss() {
        if !isActive { phase = .idle }
    }

    // MARK: - Loop

    private func run(forcing: LaunchConfig?) async {
        stopRequested = false
        lastDiagnosis = nil
        guard let runtime = model.runtime else { phase = .blocked(.noRuntime); return }
        guard var game = model.game(gameID) else { phase = .failed; return }
        guard !game.isMissing else { phase = .blocked(.missingFiles); return }

        phase = .preparing
        let plan = model.plan(for: game)
        let configs = forcing.map { [$0] } ?? plan.configs
        guard !configs.isEmpty else { phase = .failed; return }

        let prefix: URL
        do {
            prefix = try await PrefixManager(paths: model.paths).ensurePrefix(for: game.id, runtime: runtime)
        } catch {
            phase = .failed
            return
        }

        var index = 0
        var retries = 0
        while index < configs.count {
            if stopRequested { phase = .finished; return }
            let config = configs[index]
            currentConfig = config
            let outcome = await attempt(config, number: index + 1, total: configs.count,
                                        game: game, plan: plan, runtime: runtime, prefix: prefix)
            game = model.game(gameID) ?? game
            switch outcome {
            case .worked:
                model.recordSuccess(gameID, config: config)
                phase = .finished
                return
            case .stopped:
                phase = .finished
                return
            case .blocked(let reason):
                phase = .blocked(reason)
                return
            case .retry where retries < 3:
                retries += 1
            case .retry, .failed:
                model.recordFailure(gameID, config: config)
                retries = 0
                index += 1
            }
        }
        phase = .failed
    }

    private func attempt(_ config: LaunchConfig, number: Int, total: Int, game: GameRecord,
                         plan: LaunchPlan, runtime: InstalledRuntime, prefix: URL) async -> Outcome {
        phase = .starting(attempt: number, total: total)
        verdict = nil
        sessionEnded = false
        pending = []

        let wineRoot: URL
        do {
            wineRoot = try await Task.detached { try runtime.wineRoot(for: config.backend) }.value
            try BackendSetup.prepare(prefix: prefix, backend: config.backend, runtime: runtime)
        } catch {
            return .failed
        }

        let command = LaunchCommandBuilder.build(gameExecutable: game.executableURL, config: config, plan: plan,
                                                 runtime: runtime, wineRoot: wineRoot, prefix: prefix,
                                                 rules: model.rules, settings: game.launchSettings(metalHUD: model.metalHUD))
        let session = WineSession(command: command, logURL: model.paths.logs.appendingPathComponent("\(game.id.uuidString).log"))
        let doctor = LogDoctor()
        session.onLine = { [weak self] line in
            guard let found = doctor.diagnose(line: line) else { return }
            Task { @MainActor in self?.pending.append(found) }
        }
        session.onEnd = { [weak self] _ in
            Task { @MainActor in self?.sessionEnded = true }
        }
        do {
            try session.start()
        } catch {
            return .failed
        }
        self.session = session
        defer { self.session = nil }
        model.update(game.id) { $0.lastPlayedAt = Date() }

        let started = Date()
        var windowSeenAt: Date?
        var windowID: UInt32?
        var blackSamples = 0
        var lastBlackCheck = Date.distantPast

        while true {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if stopRequested {
                await session.terminate()
                await waitForEnd()
                return .stopped
            }

            // 1. React to what the log says.
            while !pending.isEmpty {
                let finding = pending.removeFirst()
                lastDiagnosis = finding
                switch finding {
                case .rendererFailed:
                    await session.terminate()
                    await waitForEnd()
                    return .failed
                case .needsAVX where !game.advertiseAVX:
                    model.update(game.id) { $0.advertiseAVX = true }
                    await session.terminate()
                    await waitForEnd()
                    return .retry
                case .needsVCRedist, .needsDirectXRuntime, .needsXNA:
                    guard let dependency = Dependency.from(finding),
                          !game.installedDependencies.contains(dependency) else { continue }
                    await session.terminate()
                    await waitForEnd()
                    phase = .installing(dependency)
                    try? await DependencyInstaller(paths: model.paths)
                        .install(dependency, prefix: prefix, wineRoot: runtime.baseWine, report: game.report)
                    model.update(game.id) { $0.installedDependencies.append(dependency) }
                    return .retry
                default:
                    continue
                }
            }

            // 2. The game closed on its own.
            if sessionEnded {
                if let verdict { return verdict ? .worked : .failed }
                if let seen = windowSeenAt, Date().timeIntervalSince(seen) > 60 { return .worked }
                if lastDiagnosis == .needsSteam { return .blocked(.needsSteam) }
                if lastDiagnosis == .antiCheat { return .blocked(.antiCheat) }
                return .failed
            }

            // 3. The player answered.
            if let verdict {
                if verdict {
                    phase = .running
                    await waitForEnd(timeout: nil)
                    return .worked
                }
                await session.terminate()
                await waitForEnd()
                return .failed
            }

            // 4. Watch for the game's window and (optionally) a black screen.
            if windowSeenAt == nil, let window = WindowProbe.largestWindow(ownedByProcessesUnder: runtime.root.path) {
                windowSeenAt = Date()
                windowID = window.id
                phase = .checking(attempt: number, total: total)
            }
            if let seen = windowSeenAt {
                let shown = Date().timeIntervalSince(seen)
                if case .checking = phase {
                    if model.blackScreenDetection, let id = windowID, shown > 8 {
                        if Date().timeIntervalSince(lastBlackCheck) > 4 {
                            lastBlackCheck = Date()
                            switch await BlackFrameDetector.isBlack(windowID: id) {
                            case .some(true):
                                blackSamples += 1
                                if blackSamples >= 3 {
                                    await session.terminate()
                                    await waitForEnd()
                                    return .failed
                                }
                            case .some(false), .none:
                                phase = .confirm(attempt: number, total: total)
                            }
                        }
                    } else if shown > 3 {
                        phase = .confirm(attempt: number, total: total)
                    }
                }
            } else if Date().timeIntervalSince(started) > 45, case .starting = phase {
                // Still no window: it may be loading. Let the player decide.
                phase = .confirm(attempt: number, total: total)
            }
        }
    }

    private func waitForEnd(timeout: TimeInterval? = 30) async {
        let start = Date()
        while !sessionEnded {
            if let timeout, Date().timeIntervalSince(start) > timeout { return }
            if stopRequested, timeout == nil, let session {
                await session.terminate()
                stopRequested = false
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }
}
