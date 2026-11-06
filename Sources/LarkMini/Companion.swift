import Foundation
import WebKit

enum CompanionPath {
    static let fallback = "/companion/app"

    static func accepted(_ raw: String?) -> String {
        guard let raw else { return fallback }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let normalized = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        let boundary = normalized.firstIndex { $0 == "?" || $0 == "#" } ?? normalized.endIndex
        let path = String(normalized[..<boundary])
        let suffix = String(normalized[boundary...])
        let decoded = path.removingPercentEncoding ?? path
        let segments = decoded.split(separator: "/", omittingEmptySubsequences: false)
        guard decoded.hasPrefix("/companion/"),
              !segments.contains(where: { $0 == ".." || $0 == "." }) else { return fallback }
        return path + suffix
    }
}

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
        URL(string: CompanionPath.accepted(path), relativeTo: base)?.absoluteURL
    }

    static func originMatches(scheme: String, host: String, port: Int, base: URL) -> Bool {
        guard let baseScheme = base.scheme?.lowercased(),
              let baseHost = base.host?.lowercased() else { return false }
        let originScheme = scheme.lowercased()
        let basePort = base.port ?? (baseScheme == "https" ? 443 : 80)
        let originPort = port == 0 ? (originScheme == "https" ? 443 : 80) : port
        return originScheme == baseScheme && host.lowercased() == baseHost && originPort == basePort
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

extension Notification.Name {
    static let companionStatusRequest = Notification.Name("com.jonathan.sift.companion-status-request")
}

enum CompanionSession {
    static func sessionCookieExists(for baseURL: URL, completion: @escaping (Bool) -> Void) {
        guard let host = baseURL.host?.lowercased() else {
            completion(false)
            return
        }
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            completion(cookies.contains { cookie in
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                let matchesHost = host == domain || host.hasSuffix("." + domain)
                return matchesHost && cookie.name.lowercased().contains("session")
            })
        }
    }

    static func hasSessionCookie(for baseURL: URL) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var found = false
        sessionCookieExists(for: baseURL) { exists in
            found = exists
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 5) == .success else { return false }
        return found
    }
}
