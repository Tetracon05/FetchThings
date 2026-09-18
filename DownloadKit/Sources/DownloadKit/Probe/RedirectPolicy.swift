import Foundation

enum RedirectPolicy {
    /// Headers that are safe to carry to a different origin.
    private static let portable: Set<String> = [
        "accept", "accept-encoding", "accept-language", "range", "if-range", "user-agent", "referer",
    ]

    /// Decides what a redirect may carry, given the request the user configured (`original`).
    ///
    /// - Landing on the origin the user named: URLSession silently drops `Authorization` on every
    ///   redirect, even to the same host, so whatever the original request carried is put back.
    /// - Landing anywhere else (scheme, host or port differs): every header that could hold a
    ///   credential is dropped, so `Authorization`, `Cookie` and custom tokens never reach a host the
    ///   user did not name. Only the headers in `portable` continue.
    /// - Non-http(s) targets are refused (returns `nil`).
    static func sanitize(_ redirected: URLRequest, trusting original: URLRequest) -> URLRequest? {
        guard let target = redirected.url, let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        var request = redirected
        let trusted = original.url.map(origin(of:))

        if trusted == origin(of: target) {
            for (name, value) in original.allHTTPHeaderFields ?? [:] where request.value(forHTTPHeaderField: name) == nil {
                request.setValue(value, forHTTPHeaderField: name)
            }
        } else {
            for name in request.allHTTPHeaderFields?.keys ?? [:].keys where !portable.contains(name.lowercased()) {
                request.setValue(nil, forHTTPHeaderField: name)
            }
        }
        return request
    }

    static func origin(of url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host(percentEncoded: false)?.lowercased() ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }
}

/// Task-level delegate applying `RedirectPolicy` to probe requests.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    private let original: URLRequest

    init(original: URLRequest) {
        self.original = original
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(RedirectPolicy.sanitize(request, trusting: original))
    }
}
