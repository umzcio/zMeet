import Foundation
import ZMeetCore

struct CLI {
    let args: [String]
    let configStore = ConfigStore()

    func run() -> Int32 {
        guard let command = args.first else {
            printHelp()
            return 0
        }

        do {
            switch command {
            case "init":
                try initialize()
            case "start":
                try start()
            case "stop":
                try stop()
            case "process":
                try process()
            case "status":
                try status()
            case "list":
                try list()
            case "devices":
                try devices()
            case "config":
                try config()
            case "help", "--help", "-h":
                printHelp()
            default:
                throw ZMeetError.invalidCommand(command)
            }
            return 0
        } catch {
            fputs("zmeet: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private func initialize() throws {
        let options = Options(Array(args.dropFirst()))
        let defaultRepo = "~/Documents/Github/zMeetNotes"
        let repoPath = options.value(for: "repo") ?? defaultRepo
        let config = try configStore.bootstrap(notesRepoPath: repoPath)

        let repoURL = URL(fileURLWithPath: ZMeetPaths.expandTilde(config.notesRepoPath), isDirectory: true)
        try GitRepository(repoURL: repoURL).ensureInitialized()
        try writeNotesReadmeIfMissing(repoURL: repoURL)

        print("Initialized zMeet")
        print("Config: \(configStore.configURL.path)")
        print("Notes repo: \(repoURL.path)")
    }

    private func start() throws {
        let options = Options(Array(args.dropFirst()))
        let title = options.value(for: "title") ?? options.positionals.joined(separator: " ")
        let sourceApp = options.value(for: "app")
        let session = try manager().start(title: title, sourceApp: sourceApp)

        print("Recording started")
        print("ID: \(session.id)")
        print("Title: \(session.title)")
        print("Audio: \(session.audioPath)")
        print("ffmpeg log: \(session.ffmpegLogPath)")
    }

    private func stop() throws {
        let session = try manager().stop()
        print("Recording stopped")
        print("ID: \(session.id)")
        print("Audio: \(session.audioPath)")
        print("Next: zmeet process --id \(session.id)")
    }

    private func process() throws {
        let options = Options(Array(args.dropFirst()))
        let session = try manager().process(id: options.value(for: "id"))
        print("Processed meeting")
        print("ID: \(session.id)")
        if let notePath = session.notePath {
            print("Note: \(notePath)")
        }
        if let transcriptPath = session.transcriptPath {
            print("Transcript: \(transcriptPath)")
        }
    }

    private func status() throws {
        if let session = try manager().status() {
            print("Recording")
            print("ID: \(session.id)")
            print("Title: \(session.title)")
            print("Started: \(ZMeetDates.iso8601(session.startedAt))")
            print("Audio: \(session.audioPath)")
        } else {
            print("No active recording")
        }
    }

    private func list() throws {
        let sessions = try manager().listSessions()
        if sessions.isEmpty {
            print("No sessions")
            return
        }

        for session in sessions {
            print("\(session.id)  \(session.status.rawValue)  \(session.title)")
        }
    }

    private func devices() throws {
        let result = try manager().listAudioDevices()
        let combined = [result.stdout, result.stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        print(combined)
    }

    private func config() throws {
        guard args.count > 1 else {
            let data = try Data(contentsOf: configStore.configURL)
            print(String(decoding: data, as: UTF8.self))
            return
        }

        let subcommand = args[1]
        switch subcommand {
        case "path":
            print(configStore.configURL.path)
        case "set":
            try configSet(Array(args.dropFirst(2)))
        default:
            throw ZMeetError.invalidCommand("config \(subcommand)")
        }
    }

    private func configSet(_ arguments: [String]) throws {
        guard arguments.count >= 2 else {
            throw ZMeetError.invalidCommand("config set <key> <value>")
        }

        let key = arguments[0]
        let value = arguments.dropFirst().joined(separator: " ")
        var config = try configStore.load()

        switch key {
        case "notesRepoPath":
            config.notesRepoPath = ZMeetPaths.expandTilde(value)
        case "appDataPath":
            config.appDataPath = ZMeetPaths.expandTilde(value)
        case "ffmpegPath":
            config.ffmpegPath = value
        case "ffmpegAudioInput":
            config.ffmpegAudioInput = value
        case "transcriptionCommand":
            config.transcriptionCommand = value == "nil" ? nil : value
        case "summaryCommand":
            config.summaryCommand = value == "nil" ? nil : value
        case "gitAutoCommit":
            config.gitAutoCommit = ["1", "true", "yes", "on"].contains(value.lowercased())
        default:
            throw ZMeetError.invalidCommand("Unknown config key \(key)")
        }

        try configStore.write(config)
        print("Updated \(key)")
    }

    private func manager() throws -> SessionManager {
        SessionManager(config: try configStore.load())
    }

    private func writeNotesReadmeIfMissing(repoURL: URL) throws {
        let readmeURL = repoURL.appendingPathComponent("README.md")
        guard !FileManager.default.fileExists(atPath: readmeURL.path) else {
            return
        }

        let readme = """
        # zMeet Notes

        This repository is the canonical Markdown knowledge base for zMeet meeting notes.

        - `meetings/` contains one summary note per meeting.
        - `transcripts/` contains raw or cleaned transcripts.
        - Audio files stay outside this repo by default under `~/.zmeet/audio`.
        """

        try readme.write(to: readmeURL, atomically: true, encoding: .utf8)
    }

    private func printHelp() {
        print("""
        zMeet Phase 1 CLI

        Commands:
          zmeet init [--repo ~/Documents/Github/zMeetNotes]
          zmeet devices
          zmeet start --title "Weekly Sync" [--app zoom]
          zmeet stop
          zmeet process [--id <session-id>]
          zmeet status
          zmeet list
          zmeet config
          zmeet config path
          zmeet config set <key> <value>

        Config keys:
          notesRepoPath, appDataPath, ffmpegPath, ffmpegAudioInput,
          transcriptionCommand, summaryCommand, gitAutoCommit
        """)
    }
}

struct Options {
    var values: [String: String] = [:]
    var positionals: [String] = []

    init(_ args: [String]) {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg.hasPrefix("--") {
                let key = String(arg.dropFirst(2))
                if index + 1 < args.count, !args[index + 1].hasPrefix("--") {
                    values[key] = args[index + 1]
                    index += 2
                } else {
                    values[key] = "true"
                    index += 1
                }
            } else {
                positionals.append(arg)
                index += 1
            }
        }
    }

    func value(for key: String) -> String? {
        values[key]
    }
}

let exitCode = CLI(args: Array(CommandLine.arguments.dropFirst())).run()
exit(exitCode)
