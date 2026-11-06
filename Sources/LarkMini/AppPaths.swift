import Foundation

enum AppPaths {
    /// Application Support/Sift, migrated once from the old LarkMini folder.
    static let supportDirectory: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = base.appendingPathComponent("Sift", isDirectory: true)
        let legacy = base.appendingPathComponent("LarkMini", isDirectory: true)
        if !fm.fileExists(atPath: current.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: current)
        }
        try? fm.createDirectory(at: current, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        return current
    }()
}
