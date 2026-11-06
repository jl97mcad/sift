import Foundation
import WebKit

enum CompanionConfig {
    static func validatedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil else { return nil }
        return components.url
    }

    static func targetURL(base: URL, path: String?) -> URL? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return base
        }
        let normalized = path.hasPrefix("/") ? path : "/" + path
        guard let target = URL(string: normalized, relativeTo: base)?.absoluteURL,
              target.scheme?.lowercased() == base.scheme?.lowercased(),
              target.host?.lowercased() == base.host?.lowercased(),
              target.port == base.port else { return nil }
        return target
    }
}

struct CompanionNavigationPolicy: Equatable {
    enum Decision: Equatable {
        case allow
        case external
    }

    static let defaultSignInHosts: Set<String> = [
        "outlandish.com",
        "larksuite.com",
        "larkoffice.com",
        "feishu.cn"
    ]

    let baseURL: URL
    let signInHosts: Set<String>

    init(baseURL: URL, signInHosts: Set<String> = CompanionNavigationPolicy.defaultSignInHosts) {
        self.baseURL = baseURL
        self.signInHosts = Set(signInHosts.map { $0.lowercased() })
    }

    func decision(for url: URL) -> Decision {
        guard let scheme = url.scheme?.lowercased() else { return .external }
        if scheme == "about" || scheme == "blob" { return .allow }
        guard scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return .external }
        if isBaseOrigin(url) || isSignInHost(host) { return .allow }
        return .external
    }

    private func isBaseOrigin(_ url: URL) -> Bool {
        guard let baseHost = baseURL.host?.lowercased(),
              let host = url.host?.lowercased(),
              baseHost == host,
              baseURL.scheme?.lowercased() == url.scheme?.lowercased() else { return false }
        return defaultPort(baseURL) == defaultPort(url)
    }

    private func isSignInHost(_ host: String) -> Bool {
        signInHosts.contains { allowed in
            host == allowed || host.hasSuffix("." + allowed)
        }
    }

    private func defaultPort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }
}

enum CompanionSession {
    static func hasSessionCookie(for baseURL: URL) -> Bool {
        guard let host = baseURL.host?.lowercased() else { return false }
        let semaphore = DispatchSemaphore(value: 0)
        var found = false
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            found = cookies.contains { cookie in
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                let matchesHost = host == domain || host.hasSuffix("." + domain)
                return matchesHost && cookie.name.lowercased().contains("session")
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 5) == .success else { return false }
        return found
    }
}
