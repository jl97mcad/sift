import Foundation
import Darwin

/// Unsent text, device-local. Each save writes a new 0600 file, syncs it to disk, renames it
/// over the old one and syncs the folder, so a crash leaves the previous or the new drafts.
struct DraftFile: Codable, Equatable {
    var chats: [String: String] = [:]
    var control = ""

    static let url = AppPaths.supportDirectory.appendingPathComponent("drafts.json")

    /// Moves drafts an earlier build kept in preferences into the file once.
    static func load(from url: URL = url, defaults: UserDefaults = .standard) -> DraftFile {
        if let data = try? Data(contentsOf: url), let drafts = try? JSONDecoder().decode(DraftFile.self, from: data) {
            return drafts
        }
        let legacy = DraftFile(chats: defaults.dictionary(forKey: "drafts") as? [String: String] ?? [:],
                               control: defaults.string(forKey: "controlDraft") ?? "")
        if (try? legacy.save(to: url)) != nil {
            defaults.removeObject(forKey: "drafts")
            defaults.removeObject(forKey: "controlDraft")
        }
        return legacy
    }

    func save(to url: URL = url) throws {
        var trimmed = self
        trimmed.chats = chats.filter { !$0.value.isEmpty }
        let data = try JSONEncoder().encode(trimmed)
        let folder = url.deletingLastPathComponent()
        let staged = folder.appendingPathComponent(".drafts-\(UUID().uuidString)")
        let fd = open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var failure: Int32 = 0
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0 { if errno == EINTR { continue }; failure = errno; return }
                offset += written
            }
        }
        if failure == 0, fsync(fd) != 0 { failure = errno }
        close(fd)
        if failure == 0, rename(staged.path, url.path) != 0 { failure = errno }
        guard failure == 0 else {
            unlink(staged.path)
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        let directory = open(folder.path, O_RDONLY | O_CLOEXEC)
        if directory >= 0 { fsync(directory); close(directory) }
    }
}
