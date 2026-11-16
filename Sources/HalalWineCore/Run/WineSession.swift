import Foundation

/// A running game: the Wine process plus a watcher that reports when every
/// process in the prefix has exited (launchers often exit early and leave the
/// real game running, so the first process exiting is not "the end").
public final class WineSession: @unchecked Sendable {
    public let command: LaunchCommand
    public let logURL: URL
    public let startedAt = Date()

    /// Called for each line the game or Wine prints (on a background queue).
    public var onLine: (@Sendable (String) -> Void)?
    /// Called once when all Wine processes for the prefix have ended.
    public var onEnd: (@Sendable (_ exitCode: Int32) -> Void)?

    private let process = Process()
    private let lock = NSLock()
    private var logHandle: FileHandle?
    private var partialLine = ""
    private var loggedBytes = 0
    private var ended = false
    private var exitCode: Int32 = 0
    private static let maxLogBytes = 25 * 1024 * 1024

    public init(command: LaunchCommand, logURL: URL) {
        self.command = command
        self.logURL = logURL
    }

    public var processID: Int32 { process.processIdentifier }
    public var isRunning: Bool { lock.locked { !ended } }

    public func start() throws {
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Append, so every attempt of one Play press stays in the log.
        if !FileManager.default.fileExists(atPath: logURL.path) {
            _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        logHandle = try FileHandle(forWritingTo: logURL)
        _ = try? logHandle?.seekToEnd()
        let header = "\n===== \(ISO8601DateFormatter().string(from: startedAt)) =====\n"
            + "$ \(command.executable.path) \(command.arguments.joined(separator: " "))\n"
            + "WINEDLLOVERRIDES=\(command.environment["WINEDLLOVERRIDES"] ?? "")\n\n"
        logHandle?.write(Data(header.utf8))

        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = command.environment
        process.currentDirectoryURL = command.workingDirectory
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self?.consume(data)
            }
        }
        process.terminationHandler = { [weak self] proc in
            self?.processExited(code: proc.terminationStatus)
        }
        try process.run()
    }

    /// Stops the game and everything else running in its prefix.
    public func terminate() async {
        await PrefixManager.killAll(prefix: command.prefix, wineRoot: command.wineRoot)
        if process.isRunning { process.terminate() }
    }

    private func consume(_ data: Data) {
        lock.lock()
        if loggedBytes < Self.maxLogBytes {
            logHandle?.write(data)
            loggedBytes += data.count
        }
        partialLine += String(decoding: data, as: UTF8.self)
        var lines: [String] = []
        while let newline = partialLine.firstIndex(of: "\n") {
            lines.append(String(partialLine[..<newline]))
            partialLine = String(partialLine[partialLine.index(after: newline)...])
        }
        if partialLine.count > 8192 { lines.append(partialLine); partialLine = "" }
        let callback = onLine
        lock.unlock()
        for line in lines { callback?(line) }
    }

    private func processExited(code: Int32) {
        lock.locked { exitCode = code }
        // The first process is gone; wait until the prefix is empty.
        let env = WineEnvironment.make(wineRoot: command.wineRoot, prefix: command.prefix)
        let wineserver = InstalledRuntime.wineserverBinary(in: command.wineRoot)
        Task.detached { [weak self] in
            _ = try? await ProcessRunner.run(wineserver, ["-w"], environment: env, timeout: 60 * 60 * 24)
            self?.finish()
        }
    }

    private func finish() {
        lock.lock()
        guard !ended else { lock.unlock(); return }
        ended = true
        let code = exitCode
        try? logHandle?.close()
        logHandle = nil
        let callback = onEnd
        lock.unlock()
        callback?(code)
    }
}

extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
