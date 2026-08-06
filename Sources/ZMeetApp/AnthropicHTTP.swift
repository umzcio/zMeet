import Foundation

/// The one URLSession zMeet uses for Anthropic API calls. Ephemeral (no shared
/// cookie/credential/cache storage) and redirect-refusing: the API key rides in
/// the custom `x-api-key` header, which URLSession does NOT strip on redirect
/// the way it strips Authorization — so any 3xx would replay the credential to
/// the redirect target. The API never legitimately redirects; refuse them all.
enum AnthropicHTTP {
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
