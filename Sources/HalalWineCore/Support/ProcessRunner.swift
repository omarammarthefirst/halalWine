import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var output: String
}

public enum ProcessRunner {
    /// Runs a program to completion off the main thread.
    ///
    /// Wine programs leave helper processes (wineserver) holding inherited
    /// pipes open, so for those pass `logFile` to send output to a file
    /// instead of capturing it.
    @discardableResult
    public static func run(_ executable: URL,
                           _ arguments: [String],
                           environment: [String: String]? = nil,
                           currentDirectory: URL? = nil,
                           logFile: URL? = nil,
                           input: String? = nil,
                           timeout: TimeInterval? = nil) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                if let environment { process.environment = environment }
                if let currentDirectory { process.currentDirectoryURL = currentDirectory }

                var pipe: Pipe?
                var logHandle: FileHandle?
                if let logFile {
                    if !FileManager.default.fileExists(atPath: logFile.path) {
                        _ = FileManager.default.createFile(atPath: logFile.path, contents: nil)
                    }
                    logHandle = try? FileHandle(forWritingTo: logFile)
                    _ = try? logHandle?.seekToEnd()
                    process.standardOutput = logHandle
                    process.standardError = logHandle
                } else {
                    let p = Pipe()
                    pipe = p
                    process.standardOutput = p
                    process.standardError = p
                }
                let inputPipe: Pipe? = input == nil ? nil : Pipe()
                process.standardInput = inputPipe ?? FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                if let inputPipe, let input {
                    inputPipe.fileHandleForWriting.write(Data(input.utf8))
                    try? inputPipe.fileHandleForWriting.close()
                }

                var watchdog: DispatchWorkItem?
                if let timeout {
                    let item = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
                    watchdog = item
                }

                var output = Data()
                if let pipe { output = pipe.fileHandleForReading.readDataToEndOfFile() }
                process.waitUntilExit()
                watchdog?.cancel()
                try? logHandle?.close()
                continuation.resume(returning: ProcessResult(status: process.terminationStatus,
                                                             output: String(decoding: output, as: UTF8.self)))
            }
        }
    }
}
