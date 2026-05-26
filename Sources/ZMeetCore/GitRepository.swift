import Foundation

public struct GitRepository {
    public var repoURL: URL
    public var runner: ProcessRunner

    public init(repoURL: URL, runner: ProcessRunner = ProcessRunner()) {
        self.repoURL = repoURL
        self.runner = runner
    }

    public func ensureInitialized() throws {
        let check = try runner.run(executable: "git", arguments: ["rev-parse", "--is-inside-work-tree"], currentDirectory: repoURL)
        if check.exitCode == 0 {
            return
        }

        let initResult = try runner.run(executable: "git", arguments: ["init"], currentDirectory: repoURL)
        guard initResult.exitCode == 0 else {
            throw ZMeetError.processFailed(command: "git init", exitCode: initResult.exitCode, stderr: initResult.stderr)
        }
    }

    public func commitAll(message: String) throws -> ProcessResult? {
        try ensureInitialized()

        let add = try runner.run(executable: "git", arguments: ["add", "meetings", "transcripts"], currentDirectory: repoURL)
        guard add.exitCode == 0 else {
            throw ZMeetError.processFailed(command: "git add meetings transcripts", exitCode: add.exitCode, stderr: add.stderr)
        }

        let diff = try runner.run(executable: "git", arguments: ["diff", "--cached", "--quiet"], currentDirectory: repoURL)
        if diff.exitCode == 0 {
            return nil
        }

        let commit = try runner.run(executable: "git", arguments: ["commit", "-m", message], currentDirectory: repoURL)
        guard commit.exitCode == 0 else {
            throw ZMeetError.processFailed(command: "git commit", exitCode: commit.exitCode, stderr: commit.stderr)
        }

        return commit
    }
}
