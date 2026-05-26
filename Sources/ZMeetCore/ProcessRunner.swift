import Foundation

public struct ProcessResult: Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
}

public struct ProcessRunner {
    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil
    ) throws -> ProcessResult {
        let process = Process()
        let resolved = resolveExecutable(executable, arguments: arguments)
        process.executableURL = resolved.executableURL
        process.arguments = resolved.arguments
        process.currentDirectoryURL = currentDirectory

        let captureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zmeet-process-\(UUID().uuidString)", isDirectory: true)
        try ZMeetPaths.ensureDirectory(captureDirectory)
        defer { try? FileManager.default.removeItem(at: captureDirectory) }

        let stdoutURL = captureDirectory.appendingPathComponent("stdout.txt")
        let stderrURL = captureDirectory.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        try process.run()
        process.waitUntilExit()

        let stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    public func runShell(_ command: String, currentDirectory: URL? = nil) throws -> ProcessResult {
        try run(executable: "/bin/zsh", arguments: ["-lc", command], currentDirectory: currentDirectory)
    }

    public func startDetached(
        executable: String,
        arguments: [String],
        logURL: URL,
        currentDirectory: URL? = nil
    ) throws -> Int32 {
        try ZMeetPaths.ensureDirectory(logURL.deletingLastPathComponent())
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)

        let process = Process()
        let resolved = resolveExecutable(executable, arguments: arguments)
        process.executableURL = resolved.executableURL
        process.arguments = resolved.arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw ZMeetError.recorderFailedToStart(error.localizedDescription)
        }

        try? logHandle.close()
        return process.processIdentifier
    }

    private func resolveExecutable(_ executable: String, arguments: [String]) -> (executableURL: URL, arguments: [String]) {
        if executable.contains("/") {
            return (URL(fileURLWithPath: executable), arguments)
        }

        return (URL(fileURLWithPath: "/usr/bin/env"), [executable] + arguments)
    }
}
