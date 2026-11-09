import Foundation
import SwiftUI

struct Chat: Identifiable, Equatable, Hashable, Codable {
    let id: String
    let name: String
    let avatar: URL?
    let isP2P: Bool
    let isTopic: Bool
    let detail: String
    let link: URL?
    var peerId: String? = nil

    /// The name without its tags, so the real name fits: "Devs - Agents Room [INTERNAL]" -> "Devs - Agents Room".
    var displayName: String {
        let trimmed = ChatTitle.split(name).name
        if !trimmed.isEmpty { return trimmed }
        return isP2P ? "Direct chat" : "Group chat"
    }

    /// Tags like [INTERNAL] or a leading "Int |", shown as a small badge.
    var tags: [String] { ChatTitle.split(name).tags }

    var initials: String { ChatTitle.initials(displayName) }
}

enum ChatTitle {
    static func split(_ raw: String) -> (name: String, tags: [String]) {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var tags: [String] = []
        // [INTERNAL], [EXT] anywhere.
        while let range = name.range(of: #"\[([^\]]{1,16})\]"#, options: .regularExpression) {
            tags.append(String(name[range].dropFirst().dropLast()).trimmingCharacters(in: .whitespaces))
            name.removeSubrange(range)
        }
        // A short leading label before a bar: "Int | Full Crumbs".
        if let bar = name.range(of: #"^\s*[A-Za-z]{2,8}\s*\|\s*"#, options: .regularExpression) {
            tags.insert(name[bar].replacingOccurrences(of: "|", with: "").trimmingCharacters(in: .whitespaces), at: 0)
            name.removeSubrange(bar)
        }
        name = name.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–—|/")))
        return (name, tags.filter { !$0.isEmpty }.map { $0.uppercased() })
    }

    /// First letters of the first two real words; dashes, slashes and symbols are not words.
    static func initials(_ name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }.filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
        let letters = words.prefix(2).compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

/// Chat names that Control and asks mention, linked so a click opens that chat in Sift.
/// Only exact names of two or more words that belong to one chat link; single words
/// and names shared by several chats are too ambiguous. Code and existing links stay.
struct ChatLinks: Equatable {
    static let scheme = "sift"
    private var names: [Substring: [(name: String, id: String)]] = [:]

    init(chats: [Chat]) {
        var owners: [String: Set<String>] = [:]
        for chat in chats {
            let full = chat.name.trimmingCharacters(in: .whitespacesAndNewlines)
            var variants = [full]
            // Direct-chat names can carry a status: "Name (Travelling)" or "Name | Busy".
            if chat.isP2P, let cut = full.range(of: #"\s*[(|]"#, options: .regularExpression) {
                variants.append(String(full[..<cut.lowerBound]))
            }
            for name in variants where name.split(whereSeparator: \.isWhitespace).count >= 2 {
                owners[name, default: []].insert(chat.id)
            }
        }
        for (name, ids) in owners where ids.count == 1 {
            names[name.split(whereSeparator: \.isWhitespace)[0], default: []].append((name, ids.first!))
        }
        for key in names.keys { names[key]?.sort { $0.name.count > $1.name.count } }
    }

    static func == (left: ChatLinks, right: ChatLinks) -> Bool {
        left.names.mapValues { $0.map(\.id) } == right.names.mapValues { $0.map(\.id) }
    }

    static func chatId(from url: URL) -> String? {
        url.scheme == scheme && url.host == "chat" ? url.lastPathComponent : nil
    }

    func link(_ text: inout AttributedString) {
        guard !names.isEmpty else { return }
        let plain = String(text.characters)
        let isWord = { (c: Character) in c.isLetter || c.isNumber }
        var index = plain.startIndex
        while index < plain.endIndex {
            let atStart = isWord(plain[index]) && (index == plain.startIndex || !isWord(plain[plain.index(before: index)]))
            let token = plain[index...].prefix { !$0.isWhitespace }
            if atStart, let candidates = names[token] ?? names[token.prefix { isWord($0) || $0 == "-" || $0 == "'" }] {
                if let hit = candidates.first(where: { candidate in
                    guard plain[index...].hasPrefix(candidate.name) else { return false }
                    let end = plain.index(index, offsetBy: candidate.name.count)
                    return end == plain.endIndex || !isWord(plain[end])
                }) {
                    let end = plain.index(index, offsetBy: hit.name.count)
                    let lower = text.characters.index(text.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: index))
                    let upper = text.characters.index(lower, offsetBy: hit.name.count)
                    if !text[lower..<upper].runs.contains(where: { $0.link != nil || $0.inlinePresentationIntent?.contains(.code) == true }) {
                        text[lower..<upper].link = URL(string: "\(Self.scheme)://chat/\(hit.id)")
                    }
                    index = end
                    continue
                }
            }
            index = plain.index(after: index)
        }
    }
}

struct Preview: Equatable, Codable {
    let text: String
    let ts: Int64
    let messageId: String
    let fromMe: Bool
}

struct Sender: Equatable {
    let id: String
    let name: String
    let isMe: Bool
}

struct ChatMessage: Identifiable, Equatable {
    let id: String
    let chatId: String
    let type: String
    let text: String
    let ts: Int64
    let sender: Sender
    let imageKey: String?
    let fileKey: String?
    let fileName: String?
    let deleted: Bool
    /// The message this one replies to, and its thread in topic chats.
    var parentId: String? = nil
    var threadId: String? = nil
    var edited = false
    /// Sent by a bot or app, which has no member name.
    var fromApp = false
    /// Content beyond text, image and file; nil for those.
    var media: LarkMedia? = nil
    /// Images embedded in a post or card, shown under its text.
    var imageKeys: [String] = []

    var isMine: Bool { sender.isMe }

    func groups(with other: ChatMessage?) -> Bool {
        guard let other, chatId == other.chatId, !sender.id.isEmpty,
              sender.id == other.sender.id, isMine == other.isMine,
              type != "system", other.type != "system" else { return false }
        return ts / 60_000 == other.ts / 60_000
    }
}

/// Lark message content that is neither text nor a plain image or file. Voice and video keep
/// their file key in `fileKey`, so they save like files.
enum LarkMedia: Equatable {
    case audio(seconds: Int)
    case video(cover: String?, seconds: Int)
    /// Lark's resource API does not serve stickers to apps.
    case sticker
    case sharedChat(id: String)
    case contact(id: String)
    /// Merged-and-forwarded messages, fetched when opened.
    case forward
    /// A type Sift has no view for (calendar, task, poll, location…): named and opened in Lark.
    case other(type: String)

    static func duration(_ seconds: Int) -> String {
        seconds > 0 ? String(format: "%d:%02d", seconds / 60, seconds % 60) : ""
    }
}

struct Me: Equatable {
    let openId: String
    let name: String
    let avatar: URL?
}

enum AuthState: Equatable {
    case unknown
    case signedOut
    case signingIn
    case signedIn
    case failed(String)
}

struct DeviceCode: Equatable {
    let deviceCode: String
    let userCode: String
    let verifyURL: URL
    let interval: Int
    let expiresIn: Int
}

struct Settings: Codable, Equatable {
    init() {}

    private enum CodingKeys: String, CodingKey {
        case pollSeconds, panelWidth, accent, collapseOnOutsideClick, showPreviewText, launchAtLogin
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pollSeconds = try container.decodeIfPresent(Int.self, forKey: .pollSeconds) ?? 5
        panelWidth = try container.decodeIfPresent(Double.self, forKey: .panelWidth) ?? 400
        accent = try container.decodeIfPresent(String.self, forKey: .accent) ?? "blue"
        collapseOnOutsideClick = try container.decodeIfPresent(Bool.self, forKey: .collapseOnOutsideClick) ?? true
        showPreviewText = try container.decodeIfPresent(Bool.self, forKey: .showPreviewText) ?? true
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
    }

    static func validWidth(_ value: Double) -> Double {
        value.isFinite ? min(480, max(400, value)).rounded() : 400
    }

    var pollSeconds: Int = 5
    var panelWidth: Double = 400
    var accent: String = "blue"
    var collapseOnOutsideClick: Bool = true
    var showPreviewText: Bool = true
    var launchAtLogin: Bool = false
}

struct ChatToast: Identifiable, Equatable {
    let id: UUID
    let chat: Chat
    let text: String
}

struct ControlOption: Identifiable, Equatable {
    let id: String
    let name: String
}

/// One agent seat. `id` is fixed when the seat is added and survives handoffs, so device-local
/// state (seen needs, drafts, the unread cue) follows the agent, not its current session.
struct ControlSeat: Codable, Equatable, Identifiable {
    var id: String
    var agentId: String
    var title: String
    /// The name shown in the rail; blank means Paseo's title.
    var name: String = ""
    var color: String = ""
    var host: String?
    var provider: String = AgentProviders.fallback

    init(agentId: String, title: String, host: String? = nil, provider: String = AgentProviders.fallback,
         id: String? = nil, name: String = "", color: String = "") {
        self.id = id ?? agentId
        self.agentId = agentId
        self.title = title
        self.name = name
        self.color = color
        self.host = host
        self.provider = provider
    }

    /// A seat added through `sift control set`: named so `control` still finds it among other seats.
    static func control(agentId: String, title: String, name: String?, host: String?,
                        provider: String = AgentProviders.fallback) -> ControlSeat {
        let name = name ?? (title.localizedCaseInsensitiveContains("control") ? "" : "Control")
        return ControlSeat(agentId: agentId, title: title, host: host, provider: provider, name: name)
    }

    /// What the rail and header show: the chosen name, else Paseo's title without the owner,
    /// host or handoff note ("Jon's Control (AWS) — auto handoff" -> "Control").
    var label: String { name.isEmpty ? Self.shortTitle(title) : name }

    static func shortTitle(_ title: String) -> String {
        var short = title
        for pattern in [#"\s+[—–-]\s+.*$"#, #"\s*\([^)]*\)"#, #"^\[[^\]]*\]\s*"#, #"^\w+['’]s\s+"#] {
            short = short.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        short = short.trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? title : short
    }
    /// The Control seat is the one whose label says Control (Paseo titles them "Jon's Control (AWS)").
    var isControl: Bool { label.localizedCaseInsensitiveContains("control") }
    var palette: FacePalette { FacePalette.named(color.isEmpty ? FacePalette.pick(for: label) : color) }

    private enum CodingKeys: String, CodingKey {
        case id, agentId, title, name, color, host, provider
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentId = try container.decode(String.self, forKey: .agentId)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? agentId
        title = try container.decode(String.self, forKey: .title)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = try container.decodeIfPresent(String.self, forKey: .color) ?? ""
        host = try container.decodeIfPresent(String.self, forKey: .host)
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? AgentProviders.fallback
    }
}

enum TimeFormat {
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let sameYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter
    }()

    private static let otherYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yy"
        return formatter
    }()

    static func short(_ ms: Int64) -> String {
        guard ms > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return clockFormatter.string(from: date)
        }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let sameYear = cal.isDate(date, equalTo: Date(), toGranularity: .year)
        return (sameYear ? sameYearFormatter : otherYearFormatter).string(from: date)
    }

    static func clock(_ ms: Int64) -> String {
        clockFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    static func day(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM"
        return f.string(from: date)
    }
}

enum AccentPalette {
    static let names = ["blue", "purple", "pink", "orange", "green"]

    static func color(_ name: String) -> Color {
        switch name {
        case "purple": return .purple
        case "pink": return .pink
        case "orange": return .orange
        case "green": return .green
        default: return .blue
        }
    }
}

/// Case- and diacritic-insensitive token matching: every query word must
/// appear somewhere in the name, in any order, ignoring punctuation.
enum SearchMatch {
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let stripped = folded.replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
        return stripped.trimmingCharacters(in: .whitespaces)
    }

    static func tokens(_ query: String) -> [String] {
        normalized(query).split(separator: " ").map(String.init)
    }

    static func matches(name: String, query: String) -> Bool {
        let parts = tokens(query)
        guard !parts.isEmpty else { return true }
        let haystack = normalized(name)
        return parts.allSatisfy { haystack.contains($0) }
    }
}

/// Unread is only claimed when a previous read marker exists. Unknown
/// history is not "new", which keeps stale cached previews out of the inbox.
enum UnreadPolicy {
    static func isUnread(preview: Preview?, lastSeenMessageId: String?, muted: Bool) -> Bool {
        guard let preview, !muted, !preview.fromMe else { return false }
        guard let lastSeenMessageId else { return false }
        return preview.messageId != lastSeenMessageId
    }
}

/// Lark has no message push for user tokens, but its chat list sorts by activity: a new message
/// moves its chat to the top. Comparing two reads of the top of that list names the chats with
/// new activity. The top chats are always rechecked, since more activity there keeps the order.
enum ActivityOrder {
    /// `moved`: chats that overtook one that was above them, or entered the list above one.
    /// Chats that only shift up because another left the list have overtaken nothing.
    static func changes(previous: [String], current: [String], top: Int = 2) -> (refresh: [String], moved: Set<String>) {
        let rank = Dictionary(previous.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var moved = Set<String>()
        if !previous.isEmpty {
            for (index, id) in current.enumerated() {
                let before = rank[id] ?? Int.max
                if current[(index + 1)...].contains(where: { (rank[$0] ?? Int.max) < before }) { moved.insert(id) }
            }
        }
        var refresh: [String] = []
        for id in Array(current.prefix(top)) + current.filter(moved.contains) where !refresh.contains(id) { refresh.append(id) }
        return (refresh, moved)
    }

    /// Moved chats whose preview was not read stay pending, counting failed polls; after `limit`
    /// (about five minutes at the default interval) they are given up and returned to be reported.
    static func settle(pending: [String: Int], moved: Set<String>, read: Set<String>,
                       limit: Int = 60) -> (pending: [String: Int], abandoned: [String]) {
        var next = pending
        for id in moved where !read.contains(id) { next[id, default: 0] += 1 }
        for id in read { next[id] = nil }
        let abandoned = next.filter { $0.value >= limit }.map(\.key).sorted()
        abandoned.forEach { next[$0] = nil }
        return (next, abandoned)
    }
}
