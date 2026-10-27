import Foundation
import FoundationModels
import Security
import ZMeetCore

// notes-probe: runs zMeet's summarization offline on a saved transcript, the way the
// app does after a meeting, so the notes prompts can be tuned against a real meeting
// without re-processing it. A developer tool; never shipped in the app bundle.
//
//   notes-probe <transcript.md> --provider anthropic|ondevice [--title "<title>"] [--out <dir>] [--no-fallback]
//
// anthropic  the app's remote path: SummarizationPolicy over the configured model
//            (~/.zmeet/config.json), on-device as the fallback. The key is read from
//            zMeet's Keychain item (macOS may ask once to allow it) and never printed.
//            Each Anthropic reply logs one stderr line (status, stop reason, anchors);
//            --no-fallback exits instead of falling back, for quick tuning runs.
// ondevice   StructuredNotesSummarizer over Apple's on-device model, as the app runs it.
//
// Writes <out>/notes-<provider>-<n>.md (the next free n): the cleaned, sanitized notes
// body plus the engine footer, exactly as notes.md would carry them. --out defaults to
// the current directory and may not be inside ~/Documents/zMeet or the configured
// meetings folder, so real meetings are never touched. Prints the engine, word count, headings and elapsed time.

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let usage = "usage: notes-probe <transcript.md> --provider anthropic|ondevice [--title \"<title>\"] [--out <dir>] [--no-fallback]"

// MARK: - Arguments

var args = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail(usage, code: 64) }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}
guard let providerName = option("--provider") else { fail(usage, code: 64) }
let title = option("--title") ?? "Zoom Meeting"
let noFallback = args.contains("--no-fallback")
args.removeAll { $0 == "--no-fallback" }
let outDir = URL(fileURLWithPath: ZMeetPaths.expandTilde(option("--out") ?? "."), isDirectory: true).standardizedFileURL
guard args.count == 1 else { fail(usage, code: 64) }
let transcriptURL = URL(fileURLWithPath: ZMeetPaths.expandTilde(args[0]))

let config: ZMeetConfig
do { config = try ConfigStore().load() } catch { fail("can't read ~/.zmeet/config.json: \(error)") }

// Never write among real meetings: the default folder or the configured one.
let meetingRoots = [
    FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/zMeet").path,
    ZMeetPaths.expandTilde(config.outputPath),
].map { URL(fileURLWithPath: $0, isDirectory: true).resolvingSymlinksInPath().path }
let resolvedOut = outDir.resolvingSymlinksInPath().path
for root in meetingRoots where (resolvedOut + "/").hasPrefix(root + "/") {
    fail("refusing to write inside \(root): pick another --out", code: 64)
}
guard let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8),
      !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    fail("can't read a transcript at \(transcriptURL.path)")
}

// MARK: - Engines

enum Diagnostics {
    static func log(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }

    /// One stderr line per Anthropic reply: why a remote attempt failed is otherwise
    /// invisible, since the policy falls back silently. Never logs the request.
    static func report(_ stream: AnthropicStream, seconds: TimeInterval) {
        var line = "anthropic: HTTP 200 in \(Int(seconds)) s, stop=\(stream.stopReason ?? "-"), out_tokens=\(stream.outputTokens.map(String.init) ?? "-")"
        let cleaned = SummaryOutput.clean(stream.text)
        line += cleaned.hasPrefix("## ")
            ? ", anchors=\(SummaryOutput.hasRequiredSections(cleaned) ? "ok" : "FAIL")"
            : ", fact lines=\(cleaned.split(separator: "\n").count)"
        line += ", first=\(cleaned.prefix(60).debugDescription)"
        log(line)
    }

    static func report(status: Int, body: Data, seconds: TimeInterval) {
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let message = ((obj?["error"] as? [String: Any])?["message"] as? String ?? "-").prefix(200)
        log("anthropic: HTTP \(status) in \(Int(seconds)) s, error=\(message)")
    }
}

/// Stands in for on-device under --no-fallback, so a failed remote run stops at once.
struct NoFallback: Summarizer {
    struct RemoteFailed: Error {}
    func summarize(transcript: String, title: String) async throws -> String { throw RemoteFailed() }
}

/// zMeet's Keychain item, read-only. Same service and accounts as the app's store.
struct KeychainReader: SecretStore {
    func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "edu.umontana.zmeet",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    func write(_ value: String, account: String) throws {}
    func delete(account: String) throws {}
}

/// Ephemeral and redirect-refusing, like the app's AIHTTP.session: the key rides
/// in a custom header that URLSession would replay to a redirect target.
final class RedirectRefuser: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 300
    config.timeoutIntervalForResource = 1_800
    return URLSession(configuration: config, delegate: RedirectRefuser(), delegateQueue: nil)
}()

let onDevice = StructuredNotesSummarizer(
    maxChunkCharacters: AIProvider.onDevice.chunkBudget ?? 10_000,
    complete: { prompt in try await LanguageModelSession().respond(to: prompt).content })

let started = Date()
let markdown: String
let engine: SummaryEngine
switch providerName {
case "anthropic":
    guard let key = KeychainReader().read(account: SecretAccount.anthropicAPIKey), !key.isEmpty else {
        fail("no Anthropic key in the Keychain", code: 2)
    }
    let model = config.model(for: .anthropic)
    let connection = AIConnection(provider: .anthropic, model: model, key: key, ollamaAddress: config.ollamaAddress)
    let remote = connection.summarizer(complete: { prompt in
        let sent = Date()
        do {
            // Same as the app's AIConnection.sendStreaming.
            let (bytes, response) = try await session.bytes(for: AnthropicSummary.makeRequest(key: key, model: model, prompt: prompt))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                var body = Data()
                for try await byte in bytes { body.append(byte) }
                Diagnostics.report(status: status, body: body, seconds: Date().timeIntervalSince(sent))
                return try AnthropicSummary.parseSummary(data: body, status: status)
            }
            var stream = AnthropicStream()
            for try await line in bytes.lines { try stream.consume(line: line) }
            Diagnostics.report(stream, seconds: Date().timeIntervalSince(sent))
            return try stream.result()
        } catch {
            Diagnostics.log("anthropic: \(type(of: error)) \(error) after \(Int(Date().timeIntervalSince(sent))) s")
            throw error
        }
    })
    (markdown, engine) = try await SummarizationPolicy().summarize(
        transcript: transcript, title: title, provider: .anthropic, model: model, remote: remote,
        onDevice: noFallback ? NoFallback() : onDevice)
case "ondevice":
    guard case .available = SystemLanguageModel.default.availability else { fail("Apple Intelligence is unavailable", code: 2) }
    (markdown, engine) = (try await onDevice.summarize(transcript: transcript, title: title), .onDevice)
default:
    fail(usage, code: 64)
}
let elapsed = Date().timeIntervalSince(started)

// MARK: - Output

let body = ZMeetText.sanitizeNoteMarkdown(markdown).trimmingCharacters(in: .whitespacesAndNewlines)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
var n = 1
while FileManager.default.fileExists(atPath: outDir.appending(path: "notes-\(providerName)-\(n).md").path) { n += 1 }
let outURL = outDir.appending(path: "notes-\(providerName)-\(n).md")
try (body + "\n\n_\(engine.attribution)_\n").write(to: outURL, atomically: true, encoding: .utf8)

let words = body.split(whereSeparator: \.isWhitespace).count
let headings = body.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }
print("engine:   \(engine.attribution)")
print("anchors:  \(SummaryOutput.hasRequiredSections(markdown) ? "ok" : "MISSING")")
print("words:    \(words)")
print("headings: \(headings.joined(separator: " | "))")
print(String(format: "elapsed:  %.1f s", elapsed))
print("wrote:    \(outURL.path)")
