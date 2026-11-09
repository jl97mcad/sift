import Foundation

struct AppState: Codable, Equatable {
    var pinned: [String] = []
    var lastSeen: [String: String] = [:]
    var meOpenId: String = ""
    var settings = Settings()
    /// Agent seats in rail order. Each follows its own handoffs.
    var seats: [ControlSeat] = []
    var muted: [String: Date] = [:]

    init() {}

    /// The Control seat: the one named Control, or the only seat. Setting it replaces that seat,
    /// adds one at the front, or (nil) removes it. The CLI's `control` commands use this.
    var control: ControlSeat? {
        get { controlIndex.map { seats[$0] } }
        set {
            let index = seats.firstIndex { $0.id == newValue?.id } ?? controlIndex
            switch (newValue, index) {
            case (let seat?, let index?): seats[index] = seat
            case (let seat?, nil): seats.insert(seat, at: 0)
            case (nil, let index?): seats.remove(at: index)
            case (nil, nil): break
            }
        }
    }

    private var controlIndex: Int? { seats.firstIndex(where: \.isControl) ?? (seats.count == 1 ? 0 : nil) }

    private enum CodingKeys: String, CodingKey {
        case pinned, lastSeen, meOpenId, settings, control, seats, muted
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pinned, forKey: .pinned)
        try container.encode(lastSeen, forKey: .lastSeen)
        try container.encode(meOpenId, forKey: .meOpenId)
        try container.encode(settings, forKey: .settings)
        try container.encode(seats, forKey: .seats)
        try container.encode(muted, forKey: .muted)
    }

    /// Old files must not fail to decode when a field is added, or every
    /// update would persist defaults over the user's pins.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pinned = try container.decodeIfPresent([String].self, forKey: .pinned) ?? []
        lastSeen = try container.decodeIfPresent([String: String].self, forKey: .lastSeen) ?? [:]
        meOpenId = try container.decodeIfPresent(String.self, forKey: .meOpenId) ?? ""
        settings = try container.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
        // Files from before seats held one `control`; it becomes the first seat.
        seats = try container.decodeIfPresent([ControlSeat].self, forKey: .seats)
            ?? (try container.decodeIfPresent(ControlSeat.self, forKey: .control)).map { [$0] } ?? []
        muted = try container.decodeIfPresent([String: Date].self, forKey: .muted) ?? [:]
    }
}


/// Non-secret state shared by the app and the `sift` CLI.
/// Lives beside the credentials file, readable only by the user.
final class StateFile {
    static let shared = StateFile()

    private let url: URL
    private let lock = NSLock()
    private var state: AppState

    init(url: URL = AppPaths.supportDirectory.appendingPathComponent("state.json")) {
        self.url = url
        state = Self.read(url) ?? AppState()
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    var current: AppState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    @discardableResult
    func update(_ mutate: (inout AppState) -> Void) -> AppState {
        lock.lock(); defer { lock.unlock() }
        // Re-read first: the CLI writes the same file, and a stale in-memory
        // copy would drop its changes on the next save.
        var copy = Self.read(url) ?? state
        mutate(&copy)
        state = copy
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(copy) {
            try? data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return copy
    }

    func reload() -> AppState {
        lock.lock(); defer { lock.unlock() }
        if let read = Self.read(url) { state = read }
        return state
    }

    private static func read(_ url: URL) -> AppState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AppState.self, from: data)
    }
}
