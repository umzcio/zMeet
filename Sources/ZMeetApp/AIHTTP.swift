import Foundation

/// The one URLSession zMeet uses for every AI provider call (Anthropic, OpenAI,
/// Ollama). Ephemeral (no shared cookie/credential/cache storage) and
/// redirect-refusing: Anthropic's key rides in the custom `x-api-key` header,
/// which URLSession does NOT strip on redirect — so any 3xx would replay the
/// credential to the redirect target. No provider API legitimately redirects;
/// refuse them all. Every provider request must go through this session.
enum AIHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300   // map-reduce summary calls can be slow
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config, delegate: RedirectRefuser(), delegateQueue: nil)
    }()

    private final class RedirectRefuser: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)   // surface the 3xx to the caller instead of following it
        }
    }
}
