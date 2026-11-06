import Foundation

/// Credentials and OAuth tokens live in one 0600 file inside Application Support.
/// Nothing here is ever logged.
final class TokenStore {
    struct Credentials: Codable, Equatable {
        var appId: String
        var appSecret: String
    }

    struct Tokens: Codable, Equatable {
        var access: String
        var refresh: String
        var expiresAt: Date
        var refreshExpiresAt: Date
        var scope: String
    }

    private struct Payload: Codable {
        var credentials: Credentials?
        var tokens: Tokens?
    }

    private let url: URL
    private let lock = NSLock()
    private var payload: Payload

    init() {
        let base = AppPaths.supportDirectory
        url = base.appendingPathComponent("credentials.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data) {
            payload = decoded
        } else {
            payload = Payload()
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    var credentials: Credentials? {
        lock.lock(); defer { lock.unlock() }
        refreshFromDiskLocked()
        return payload.credentials
    }

    var tokens: Tokens? {
        lock.lock(); defer { lock.unlock() }
        refreshFromDiskLocked()
        return payload.tokens
    }

    func setCredentials(_ creds: Credentials?) {
        lock.lock(); defer { lock.unlock() }
        refreshFromDiskLocked()
        payload.credentials = creds
        persistLocked()
    }

    func setTokens(_ tokens: Tokens?) {
        lock.lock(); defer { lock.unlock() }
        refreshFromDiskLocked()
        payload.tokens = tokens
        persistLocked()
    }

    /// The app and the CLI write this file; a cached copy would clobber the
    /// other process's fresh refresh token.
    private func refreshFromDiskLocked() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        payload = decoded
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
