import Foundation

extension URL {
    /// The URL without any `user:password@` part, and the credentials that were in it.
    func splittingCredentials() -> (url: URL, credentials: BasicAuth?) {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let user = components.user else { return (self, nil) }
        let credentials = BasicAuth(username: user, password: components.password ?? "")
        components.user = nil
        components.password = nil
        return (components.url ?? self, credentials)
    }
}
