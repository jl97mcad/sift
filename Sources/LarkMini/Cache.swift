import Foundation

struct CachePayload: Codable {
    var chats: [Chat]
    var previews: [String: Preview]
    var savedAt: Date
}

/// Last known chats and previews so the panel paints before the network answers.
enum Cache {
    private static var url: URL {
        AppPaths.supportDirectory.appendingPathComponent("cache.json")
    }

    static func load() -> CachePayload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CachePayload.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    static func save(_ payload: CachePayload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
