import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CryptoKit

@MainActor
final class Store: ObservableObject {
    @Published private(set) var chats: [Chat] = []
    @Published private(set) var pinned: [String] = []
    @Published private(set) var previews: [String: Preview] = [:]
    @Published private(set) var lastSeen: [String: String] = [:]
    @Published private(set) var messages: [String: [ChatMessage]] = [:]
    @Published private(set) var auth: AuthState = .unknown
    @Published private(set) var me: Me?
    @Published var openChat: Chat?
    @Published var isExpanded = true {
        didSet {
            if isExpanded { dismissBubble() } else { controlTail = Self.controlPage }
            sendWatchGap()
        }
    }
    /// The thought bubble beside the collapsed head.
    @Published private(set) var bubble: EdgeBubble?
    /// Set when a bubble opens Control, so it scrolls to the asks.
    @Published var controlFocusAsks = false
    private var bubbleExpiry: Task<Void, Never>?
    private var bubbleHeld = false
    private var bubbledNeeds = Set<String>()
    @Published var showingSettings = false
    @Published var showingShortcuts = false
    @Published var deviceCode: DeviceCode?
    @Published var errorText: String?
    @Published var loadingChats = false
    @Published var sending = false
    @Published var loadingOlder = false
    @Published var settings = Settings()
    /// Unsent text survives quitting and crashes: a device-local 0600 file, saved on each change.
    @Published var drafts: [String: String] = [:] { didSet { saveDrafts() } }
    @Published var search = ""
    @Published var remoteResults: [Chat] = []
    @Published var toasts: [ChatToast] = []
    @Published var searching = false
    @Published var searchOpen = false
    @Published var searchSelection = 0
    @Published var listSelection = 0
    @Published var showAllChats = false
    @Published var focusComposer = false
    @Published var offline = false
    @Published var muted: [String: Date] = [:]
    @Published var memberNames: [String: String] = [:]
    @Published private(set) var chatLinks = ChatLinks(chats: [])
    private var directory: [Chat] = []
    @Published var controlSeat: ControlSeat?
    @Published var controlMessages: [AgentMessage] = []
    @Published private(set) var controlTimeline: [ControlEntry] = []
    /// How many timeline entries a refresh reads; "Earlier activity" raises it.
    @Published private(set) var controlTail = Store.controlPage {
        didSet { if controlTail != oldValue { controlWatch?.send("tail \(controlTail)") } }
    }
    /// The live Paseo connection for the seat (ADR 0009); nil while it restarts, when the
    /// one-shot read every third poll takes over.
    private var controlWatch: ChildStream?
    private var watchGeneration = 0
    private var watchFailures = 0
    private var watchRestart: Task<Void, Never>?
    private var started = false
    nonisolated static let controlPage = 80
    nonisolated static let controlMaxTail = 400
    private var controlServerId: String?
    /// Leaving Control drops back to the short tail, so a collapsed panel polls little.
    @Published var controlOpen = false {
        didSet {
            if !controlOpen { controlTail = Self.controlPage }
            sendWatchGap()
        }
    }
    @Published var controlBusy = false
    @Published var controlSending = false
    @Published var controlDraft = "" { didSet { saveDrafts() } }
    @Published var controlActivity: String?
    @Published private(set) var controlHasOlder = false
    @Published private(set) var controlNeedsInput = false
    @Published private(set) var controlPermissions: [PermissionRequest] = []
    private var seenPermissions = Set(UserDefaults.standard.stringArray(forKey: "seenPermissions") ?? [])
    @Published private(set) var asks: AskReading = .off
    @Published private(set) var seenAsks = Set(UserDefaults.standard.stringArray(forKey: "seenAsks") ?? [])
    @Published private(set) var controlStatus = "Not checked"
    @Published private(set) var controlAttention: String? {
        didSet {
            if let seat = controlSeat {
                UserDefaults.standard.set(controlAttention, forKey: "controlAttention.\(seat.agentId)")
            }
        }
    }
    private var attention = ControlAttention()

    /// Live needs-you: Paseo is waiting on a permission, or the Control's runner has an open ask.
    var openAskCount: Int { asks.asks.count }
    /// Open asks plus pending Paseo requests: everything listed at the top of Control.
    var openNeedCount: Int { openAskCount + controlPermissions.count }
    /// Pulses until seen, then goes quiet like a read reply; open asks stay listed in Control.
    var needsYouUnseen: Bool {
        controlPermissions.contains { !seenPermissions.contains($0.id) } || asks.asks.contains { !seenAsks.contains($0.id) }
    }

    var attentionSummary: String? {
        if controlNeedsInput { return "Waiting for your permission" }
        if openAskCount > 0 { return openAskCount == 1 ? "1 open ask" : "\(openAskCount) open asks" }
        return controlAttention
    }

    var asksSummary: String {
        switch asks {
        case .off: return "Off · this Control serves no open asks"
        case .unavailable(let reason): return "Unknown · " + reason
        case .available(let open): return open.isEmpty ? "None open" : "\(open.count) open"
        }
    }

    let tokens = TokenStore()
    private(set) lazy var api = LarkAPI(tokens: tokens)
    private let stateFile = StateFile.shared
    private var pollTask: Task<Void, Never>?
    private var tickCount = 0
    private var hydrated = Set<String>()
    private var previewInFlight = Set<String>()
    private var resolvedMembers = Set<String>()
    @Published private var pageToken: String?
    private var loadedFirstPage = false
    private var fetchingChats = false
    private var discovery = PreviewDiscovery()
    private var olderTokens: [String: String] = [:]
    private var isDemo = false

    init() {
        let state = stateFile.current
        settings = state.settings
        settings.panelWidth = Settings.validWidth(settings.panelWidth)
        if settings != state.settings { stateFile.update { $0.settings = settings } }
        pinned = state.pinned
        lastSeen = state.lastSeen
        adoptSeat(state.control)
        muted = state.muted
        let saved = DraftFile.load()
        drafts = saved.chats
        controlDraft = saved.control
        loadedDrafts = true
        if let cache = Cache.load() {
            chats = cache.chats
            previews = cache.previews
        }
        auth = tokens.tokens != nil ? .signedIn : .signedOut
    }

    // MARK: - Settings

    var accentColor: Color { AccentPalette.color(settings.accent) }

    func updateSettings(_ mutate: (inout Settings) -> Void) {
        var copy = settings
        mutate(&copy)
        copy.panelWidth = Settings.validWidth(copy.panelWidth)
        settings = copy
        stateFile.update { $0.settings = copy }
    }

    /// Picks up pins, settings and sign-in changes written by the CLI.
    func reloadState() {
        guard !isDemo else { return }
        let state = stateFile.reload()
        if state.settings != settings {
            settings = state.settings
            settings.panelWidth = Settings.validWidth(settings.panelWidth)
            if settings != state.settings { stateFile.update { $0.settings = settings } }
        }
        if state.pinned != pinned { pinned = state.pinned }
        if state.lastSeen != lastSeen { lastSeen = state.lastSeen }
        if state.control != controlSeat {
            adoptSeat(state.control)
            if state.control == nil { controlOpen = false } }
        if tokens.tokens != nil, auth == .signedOut { auth = .signedIn }
        if tokens.tokens == nil, auth == .signedIn { auth = .signedOut }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isDemo else { return }
        started = true
        startControlWatch()
        startPolling()
        Task {
            if tokens.tokens != nil {
                await loadProfile()
                await loadChats(reset: true)
                await loadChatDirectory()
            } else {
                auth = .signedOut
            }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                let seconds = UInt64(max(2, self.settings.pollSeconds))
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }

    private func tick() async {
        guard !isDemo else { return }
        tickCount += 1
        // A slow Control read must never hold up Lark polling.
        if controlSeat != nil, controlWatch == nil, tickCount % 3 == 1, !controlBusy { Task { await refreshControl() } }
        guard auth == .signedIn else { return }
        if tickCount % 6 == 1 {
            await loadChats(reset: true, quiet: true)
        }
        var ids = Set(pinned)
        if let openChat { ids.insert(openChat.id) }
        let untracked = chats.map(\.id).filter { !ids.contains($0) }
        ids.formUnion(discovery.next(untracked, limit: 3))
        await refreshPreviews(Array(ids))
        if let chat = openChat {
            await refreshOpenChat(chat)
        }
    }

    // MARK: - Auth

    func signIn() {
        guard auth != .signingIn else { return }
        errorText = nil
        if tokens.credentials == nil {
            showingSettings = true
            errorText = "Paste the app id and secret from open.larksuite.com"
            return
        }
        auth = .signingIn
        Task {
            do {
                let code = try await api.startDeviceFlow()
                deviceCode = code
                NSWorkspace.shared.open(code.verifyURL)
                try await api.pollDeviceFlow(code)
                deviceCode = nil
                auth = .signedIn
                await loadProfile()
                await loadChats(reset: true)
                await loadChatDirectory()
            } catch {
                auth = .signedOut
                deviceCode = nil
                errorText = error.localizedDescription
            }
        }
    }

    func cancelSignIn() {
        deviceCode = nil
        if auth == .signingIn { auth = .signedOut }
    }

    func signOut() {
        tokens.setTokens(nil)
        chats = []
        previews = [:]
        messages = [:]
        pageToken = nil
        loadedFirstPage = false
        discovery = PreviewDiscovery()
        memberNames = [:]
        me = nil
        auth = .signedOut
        openChat = nil
        Cache.clear()
    }

    func saveCredentials(appId: String, secret: String) {
        tokens.setCredentials(TokenStore.Credentials(appId: appId, appSecret: secret))
    }

    func currentCredentials() -> TokenStore.Credentials? { tokens.credentials }

    private func loadProfile() async {
        do {
            let profile = try await api.userInfo()
            me = profile
            stateFile.update { $0.meOpenId = profile.openId }
            await api.setMeId(profile.openId)
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: - Chats

    func loadChats(reset: Bool, quiet: Bool = false) async {
        guard auth == .signedIn, !isDemo else { return }
        guard !fetchingChats else { return }
        fetchingChats = true
        if !quiet { loadingChats = true }
        defer { fetchingChats = false; if !quiet { loadingChats = false } }
        do {
            let page = try await api.listChats(pageToken: reset ? nil : pageToken)
            if reset {
                let existing = Dictionary(uniqueKeysWithValues: chats.map { ($0.id, $0) })
                let merged = page.chats.map { fresh in
                    guard let old = existing[fresh.id] else { return fresh }
                    return Chat(id: fresh.id,
                                name: fresh.name.isEmpty ? old.name : fresh.name,
                                avatar: fresh.avatar ?? old.avatar,
                                isP2P: fresh.isP2P,
                                isTopic: fresh.isTopic,
                                detail: fresh.detail.isEmpty ? old.detail : fresh.detail,
                                link: fresh.link ?? old.link,
                                peerId: fresh.peerId ?? old.peerId)
                }
                // Keep chats from earlier pages; the first page is not the catalogue.
                let mergedIds = Set(merged.map(\.id))
                chats = merged + chats.filter { !mergedIds.contains($0.id) }
            } else {
                let existing = Set(chats.map(\.id))
                chats.append(contentsOf: page.chats.filter { !existing.contains($0.id) })
            }
            offline = false
            // Refreshing page one must not rewind the user's history cursor.
            if !loadedFirstPage || !reset { pageToken = page.next }
            loadedFirstPage = true
            if reset {
                // A pin can sit beyond the loaded pages; fetch it so the rail never drops it.
                for id in pinned where !chats.contains(where: { $0.id == id }) {
                    if let chat = try? await api.chatDetail(id) { chats.append(chat) }
                }
                await hydrateNames(chats.filter { $0.name.isEmpty || $0.avatar == nil })
                Cache.save(CachePayload(chats: chats, previews: previews, savedAt: Date()))
            }
        } catch {
            offline = true
            if !quiet { errorText = error.localizedDescription }
        }
    }

    var canLoadMoreChats: Bool { pageToken != nil }

    func loadNextChatPage() async {
        guard canLoadMoreChats else { return }
        await loadChats(reset: false)
    }

    /// Fills in names and avatars that the list endpoint leaves empty. Direct chats never
    /// list an avatar and the contact profile endpoint refuses this user token, so their
    /// picture comes from user search matched on the exact peer id. One attempt per launch.
    private func hydrateNames(_ candidates: [Chat]) async {
        guard auth == .signedIn, !isDemo else { return }
        let pending = candidates.filter { !hydrated.contains($0.id) }
        for chat in pending.prefix(6) {
            hydrated.insert(chat.id)
            var name = chat.name, avatar = chat.avatar, detail = chat.detail, link = chat.link
            if name.isEmpty || (!chat.isP2P && avatar == nil), let found = try? await api.chatDetail(chat.id) {
                name = name.isEmpty ? found.name : name
                avatar = avatar ?? found.avatar
                detail = detail.isEmpty ? found.detail : detail
                link = link ?? found.link
            }
            if chat.isP2P, avatar == nil, !name.isEmpty, let peer = chat.peerId {
                avatar = try? await api.searchedAvatar(name: name, openId: peer)
            }
            guard let index = chats.firstIndex(where: { $0.id == chat.id }) else { continue }
            chats[index] = Chat(id: chat.id, name: name, avatar: avatar, isP2P: chat.isP2P, isTopic: chat.isTopic,
                                detail: detail, link: link, peerId: chat.peerId)
        }
    }

    /// Fetches a preview the first time a row becomes visible.
    func ensurePreview(_ chatId: String) async {
        guard auth == .signedIn, !isDemo, previews[chatId] == nil, !previewInFlight.contains(chatId) else { return }
        previewInFlight.insert(chatId)
        defer { previewInFlight.remove(chatId) }
        guard let message = try? await api.latestMessage(chatId: chatId) else { return }
        let preview = Preview(text: Self.previewText(for: message), ts: message.ts,
                              messageId: message.id, fromMe: message.isMine)
        if let existing = previews[chatId], existing.ts > preview.ts { return }
        previews[chatId] = preview
        if lastSeen[chatId] == nil { setSeen(chatId, preview.messageId) }
    }

    /// Only what the panel actually shows: the pinned icons and the open chat.
    private func refreshPreviews(_ ids: [String]) async {
        guard auth == .signedIn, !isDemo else { return }
        await withTaskGroup(of: (String, Preview?).self) { group in
            var iterator = ids.makeIterator()
            var inflight = 0
            while inflight < 10, let id = iterator.next() {
                inflight += 1
                group.addTask { [api] in
                    let message = try? await api.latestMessage(chatId: id)
                    guard let message else { return (id, nil) }
                    let text = Self.previewText(for: message)
                    return (id, Preview(text: text, ts: message.ts, messageId: message.id, fromMe: message.isMine))
                }
            }
            while let result = await group.next() {
                inflight -= 1
                if let preview = result.1 {
                    // Keep a newer preview, and skip unchanged ones so the list does not redraw every tick.
                    if let existing = self.previews[result.0], existing.ts > preview.ts || existing == preview {
                    } else {
                        let previous = self.previews[result.0]
                        self.previews[result.0] = preview
                        if self.lastSeen[result.0] == nil { self.setSeen(result.0, preview.messageId) }
                        if previous != nil,
                           previous?.messageId != preview.messageId,
                           !preview.fromMe,
                           !self.isMuted(id: result.0),
                           !self.isVisible(id: result.0),
                           self.lastSeen[result.0] != preview.messageId,
                           let chat = self.chats.first(where: { $0.id == result.0 }) {
                            if self.pinned.contains(result.0) { self.pushToast(chat: chat, text: preview.text) }
                            else { self.larkArrival(chat: chat, text: preview.text) }
                        }
                    }
                }
                if let id = iterator.next() {
                    inflight += 1
                    group.addTask { [api] in
                        let message = try? await api.latestMessage(chatId: id)
                        guard let message else { return (id, nil) }
                        let text = Self.previewText(for: message)
                        return (id, Preview(text: text, ts: message.ts, messageId: message.id, fromMe: message.isMine))
                    }
                }
            }
        }
    }

    nonisolated private static func previewText(for message: ChatMessage) -> String {
        let body: String
        switch message.type {
        case "file": body = message.fileName ?? "File"
        case "interactive": body = "Card"
        default: body = message.text
        }
        let prefix = message.isMine ? "You: " : ""
        return prefix + body.replacingOccurrences(of: "\n", with: " ")
    }

    var pinnedChats: [Chat] {
        pinned.compactMap { id in chats.first { $0.id == id } }
    }

    /// Inbox contains known unread activity; All chats includes pinned history too.
    var visibleChats: [Chat] {
        let base = chats.filter { showAllChats || isUnread($0) }
        return base.enumerated().sorted { left, right in
            let leftTS = previews[left.element.id]?.ts ?? 0
            let rightTS = previews[right.element.id]?.ts ?? 0
            if leftTS == rightTS { return left.offset < right.offset }
            return leftTS > rightTS
        }.map(\.element)
    }

    func moveListSelection(_ delta: Int) {
        let count = visibleChats.count
        guard count > 0 else { return }
        listSelection = max(0, min(count - 1, listSelection + delta))
    }

    func selectedInboxChat() -> Chat? {
        let list = visibleChats
        guard list.indices.contains(listSelection) else { return nil }
        return list[listSelection]
    }

    func markSelectedRead() {
        guard let chat = selectedInboxChat() else { return }
        if let preview = previews[chat.id] {
            setSeen(chat.id, preview.messageId)
        }
        listSelection = max(0, min(listSelection, max(0, visibleChats.count - 1)))
    }

    func isUnread(_ chat: Chat) -> Bool {
        UnreadPolicy.isUnread(preview: previews[chat.id],
                              lastSeenMessageId: lastSeen[chat.id],
                              muted: isMuted(chat))
    }

    var unreadCount: Int {
        chats.filter(isUnread).count
    }

    func isMuted(id: String) -> Bool {
        guard let until = muted[id] else { return false }
        return until > Date()
    }

    func isMuted(_ chat: Chat) -> Bool { isMuted(id: chat.id) }

    func mute(_ chat: Chat, minutes: Double = 60) {
        muted[chat.id] = Date().addingTimeInterval(minutes * 60)
        let copy = muted
        stateFile.update { $0.muted = copy }
    }

    func unmute(_ chat: Chat) {
        muted.removeValue(forKey: chat.id)
        let copy = muted
        stateFile.update { $0.muted = copy }
    }

    private var query: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func matchesSearch(_ chat: Chat) -> Bool {
        guard !query.isEmpty else { return true }
        return SearchMatch.matches(name: chat.name, query: search)
    }

    var pinnedMatches: [Chat] { pinnedChats.filter(matchesSearch) }

    var chatMatches: [Chat] {
        let pinnedSet = Set(pinned)
        return chats.filter { !pinnedSet.contains($0.id) && matchesSearch($0) }
    }

    var remoteOnly: [Chat] {
        let known = Set(chats.map(\.id)).union(pinned)
        // Lark already matched these; re-filtering locally hides real results.
        return remoteResults.filter { !known.contains($0.id) }
    }

    var isSearching: Bool { !query.isEmpty }

    var searchResults: [Chat] { pinnedMatches + chatMatches + remoteOnly }

    func moveSearchSelection(_ delta: Int) {
        let count = searchResults.count
        guard count > 0 else { return }
        searchSelection = max(0, min(count - 1, searchSelection + delta))
    }

    func openSelectedSearchResult() {
        let list = searchResults
        guard list.indices.contains(searchSelection) else { return }
        let chat = list[searchSelection]
        closeSearch()
        open(chat)
    }

    func openSearch() {
        searchSelection = 0
        searchOpen = true
        showingSettings = false
        openChat = nil
        controlOpen = false
    }

    func closeSearch() {
        searchOpen = false
        search = ""
        remoteResults = []
    }

    func searchAll() async {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, auth == .signedIn, !isDemo else {
            remoteResults = []
            return
        }
        searching = true
        let results = (try? await api.searchChats(query: text)) ?? []
        // Ignore replies for a query the user has already moved past.
        if search == text, searchOpen {
            remoteResults = results
        }
        searching = false
    }

    func pushToast(chat: Chat, text: String) {
        let event = "chat-\(chat.id)-\(previews[chat.id]?.messageId ?? "")"
        Task { await Notifications.shared.post(title: chat.displayName, body: text, id: event, destination: chat.id) }
        guard isExpanded else { larkArrival(chat: chat, text: text); return }
        toasts.removeAll { $0.chat.id == chat.id }
        let toast = ChatToast(id: UUID(), chat: chat, text: text)
        toasts.append(toast)
        if toasts.count > 3 { toasts.removeFirst(toasts.count - 3) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.toasts.removeAll { $0.id == toast.id }
        }
    }

    func dismissToast(_ toast: ChatToast) {
        toasts.removeAll { $0.id == toast.id }
    }

    func togglePin(_ chat: Chat) {
        if let index = pinned.firstIndex(of: chat.id) {
            pinned.remove(at: index)
        } else {
            guard pinned.count < 10 else {
                errorText = "Ten pins is the limit"
                return
            }
            pinned.append(chat.id)
            if !chats.contains(where: { $0.id == chat.id }) {
                chats.append(chat)
            }
        }
        stateFile.update { $0.pinned = pinned }
    }

    func movePin(from source: String, to target: String) {
        guard let from = pinned.firstIndex(of: source), let to = pinned.firstIndex(of: target), from != to else { return }
        var copy = pinned
        let item = copy.remove(at: from)
        copy.insert(item, at: to)
        pinned = copy
        stateFile.update { $0.pinned = copy }
    }

    func canPin(_ chat: Chat) -> Bool {
        pinned.contains(chat.id) || pinned.count < 10
    }

    // MARK: - Conversation

    /// Every chat's name and id, so Control can link the people and groups it mentions.
    // ponytail: one bounded crawl per launch (30 pages of 100); persist it if launches feel slow.
    func loadChatDirectory() async {
        guard auth == .signedIn, !isDemo else { return }
        var found: [Chat] = []
        var token: String?
        for _ in 0..<30 {
            guard let page = try? await api.listChats(pageToken: token) else { break }
            found += page.chats
            guard let next = page.next else { break }
            token = next
        }
        directory = found
        // Your own chat is not someone Control mentions.
        let named = (found + chats.filter { chat in !found.contains { $0.id == chat.id } })
            .filter { me == nil || $0.peerId != me?.openId }
        chatLinks = ChatLinks(chats: named)
    }

    /// Opens a chat named in Control's text, including one beyond the loaded list.
    func openLinkedChat(_ id: String) {
        guard let chat = chats.first(where: { $0.id == id }) ?? directory.first(where: { $0.id == id }) else { return }
        if !chats.contains(where: { $0.id == id }) { chats.append(chat) }
        open(chat)
    }

    func open(_ chat: Chat) {
        showingSettings = false
        controlOpen = false
        if searchOpen { closeSearch() }
        openChat = chat
        if !chat.isP2P { Task { await resolveMembers(chat) } }
        errorText = nil
        if messages[chat.id] == nil {
            Task { await loadMessages(chat, reset: true) }
        } else {
            markRead(chat)
        }
    }

    func showInbox() {
        showingSettings = false
        controlOpen = false
        openChat = nil
        showAllChats = false
        if searchOpen { closeSearch() }
    }

    func closeConversation() {
        openChat = nil
    }

    func draft(for chatId: String) -> String { drafts[chatId] ?? "" }

    func setDraft(_ text: String, for chatId: String) { drafts[chatId] = text }

    func loadMessages(_ chat: Chat, reset: Bool) async {
        guard auth == .signedIn, !isDemo else { return }
        if reset { olderTokens[chat.id] = nil }
        do {
            let page = try await api.messages(chatId: chat.id, pageToken: reset ? nil : olderTokens[chat.id])
            if reset {
                messages[chat.id] = page.messages
            } else {
                messages[chat.id] = page.messages + (messages[chat.id] ?? [])
            }
            olderTokens[chat.id] = page.next
            markRead(chat)
        } catch {
            errorText = error.localizedDescription
        }
    }

    func loadOlder() async {
        guard let chat = openChat, !loadingOlder, olderTokens[chat.id] != nil else { return }
        loadingOlder = true
        await loadMessages(chat, reset: false)
        loadingOlder = false
    }

    var canLoadOlder: Bool {
        guard let chat = openChat else { return false }
        return olderTokens[chat.id] != nil
    }

    private func resolveMembers(_ chat: Chat) async {
        guard auth == .signedIn, !isDemo, !resolvedMembers.contains(chat.id) else { return }
        resolvedMembers.insert(chat.id)
        guard let names = try? await api.chatMembers(chatId: chat.id) else {
            resolvedMembers.remove(chat.id)
            return
        }
        if !names.isEmpty {
            memberNames.merge(names) { old, new in old.isEmpty ? new : old }
        }
    }

    /// New messages join; loaded ones are replaced when Lark reports an edit, recall or card update.
    // ponytail: only the newest 20 are rechecked each tick; older rows refresh when the chat reopens.
    private func refreshOpenChat(_ chat: Chat) async {
        guard let page = try? await api.messages(chatId: chat.id, pageSize: 20),
              let current = Self.merge(messages[chat.id] ?? [], page.messages) else { return }
        messages[chat.id] = current
        if let last = current.last {
            previews[chat.id] = Preview(text: Self.previewText(for: last), ts: last.ts,
                                        messageId: last.id, fromMe: last.isMine)
        }
        if openChat?.id == chat.id, isVisible(chat) { markRead(chat) }
    }

    /// Loaded rows plus a fresh page: changed rows replaced in place, new ones added in time
    /// order. nil when nothing changed, so an unchanged poll publishes nothing.
    nonisolated static func merge(_ loaded: [ChatMessage], _ page: [ChatMessage]) -> [ChatMessage]? {
        var current = loaded
        let index = Dictionary(current.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for message in page {
            if let at = index[message.id] {
                if current[at] != message { current[at] = message; changed = true }
            } else { current.append(message); changed = true }
        }
        guard changed else { return nil }
        return current.sorted { $0.ts < $1.ts }
    }

    /// Collapsed panels still poll; they must not consume unread state.
    private func isVisible(_ chat: Chat) -> Bool {
        isVisible(id: chat.id)
    }

    private func isVisible(id: String) -> Bool {
        isExpanded && openChat?.id == id && PanelBridge.shared.panel?.isKeyWindow == true
    }

    func markRead(_ chat: Chat) {
        guard let newest = messages[chat.id]?.last else {
            if let preview = previews[chat.id] { setSeen(chat.id, preview.messageId) }
            return
        }
        setSeen(chat.id, newest.id)
    }

    private func setSeen(_ chatId: String, _ messageId: String) {
        lastSeen[chatId] = messageId
        stateFile.update { $0.lastSeen[chatId] = messageId }
    }

    func send() async {
        guard let chat = openChat else { return }
        let chatId = chat.id
        let text = draft(for: chatId).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        setDraft("", for: chatId)
        do {
            if let message = try await api.sendText(chatId: chatId, text: text) {
                append(message, chatId: chatId)
            }
        } catch {
            errorText = error.localizedDescription
            if draft(for: chatId).isEmpty { setDraft(text, for: chatId) }
        }
        sending = false
    }

    /// Dropped or picked files upload one at a time, in order; none is dropped silently.
    func sendAttachment(_ url: URL, to chatId: String) async {
        attachmentQueue.append((url, chatId))
        guard !drainingAttachments else { return }
        drainingAttachments = true
        defer { drainingAttachments = false }
        var failed: [String] = []
        while !attachmentQueue.isEmpty {
            let (file, target) = attachmentQueue.removeFirst()
            while sending { try? await Task.sleep(nanoseconds: 100_000_000) }  // a text send is in flight
            sending = true
            do {
                let type = try? file.resourceValues(forKeys: [.contentTypeKey]).contentType
                let message = type?.conforms(to: .image) == true
                    ? try await api.sendImage(chatId: target, fileURL: file)
                    : try await api.sendFile(chatId: target, fileURL: file)
                if let message { append(message, chatId: target) }
            } catch {
                failed.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
            sending = false
        }
        reportUnsent(failed)
    }

    private var attachmentQueue: [(URL, String)] = []
    private var drainingAttachments = false

    /// One error line names every file that did not go, however it failed.
    func reportUnsent(_ failures: [String]) {
        guard !failures.isEmpty else { return }
        let prefix = "Not sent — "
        let earlier = errorText?.hasPrefix(prefix) == true ? [String(errorText!.dropFirst(prefix.count))] : []
        errorText = prefix + (earlier + failures).joined(separator: "; ")
    }

    private var loadedDrafts = false

    private func saveDrafts() {
        guard loadedDrafts, !isDemo else { return }
        do { try DraftFile(chats: drafts, control: controlDraft).save() }
        catch { errorText = "Drafts could not be saved: \(error.localizedDescription)" }
    }

    private func append(_ message: ChatMessage, chatId: String) {
        var current = messages[chatId] ?? []
        if !current.contains(where: { $0.id == message.id }) {
            current.append(message)
            messages[chatId] = current
        }
        previews[chatId] = Preview(text: Self.previewText(for: message), ts: message.ts, messageId: message.id, fromMe: message.isMine)
        setSeen(chatId, message.id)
    }

    func image(for message: ChatMessage) async -> Data? {
        guard let key = message.imageKey else { return nil }
        return try? await api.imageData(messageId: message.id, key: key)
    }

    /// The messages inside a forwarded bundle, read when the person opens it.
    func forwarded(_ message: ChatMessage) async throws -> [ChatMessage] {
        guard !isDemo else { return [] }
        return try await api.forwarded(messageId: message.id, chatId: message.chatId)
    }

    func chatName(_ id: String) -> String? {
        (chats.first { $0.id == id } ?? directory.first { $0.id == id })?.displayName
    }

    func saveFile(_ message: ChatMessage, to destination: URL) async throws {
        guard !isDemo else { throw APIError(status: 0, message: "Demo files cannot be downloaded.") }
        guard let key = message.fileKey else { throw APIError(status: 0, message: "File resource is unavailable.") }
        try await api.downloadFile(messageId: message.id, key: key, to: destination)
    }

    // MARK: - Control seat

    var paseoAvailable: Bool { PaseoClient.isAvailable }

    func setControlSeat(agentId: String, host: String? = nil, providerName: String? = nil) async {
        let trimmed = agentId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        errorText = nil
        let hostValue = host?.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = AgentProviders.resolve(providerName)
        let info = await provider.inspect(id: trimmed, host: hostValue)
        if info == nil {
            errorText = "No \(provider.name) session found for \(trimmed) (check the host)"
            return
        }
        let seat = ControlSeat(agentId: trimmed, title: info?.title ?? "Control",
                               host: hostValue, provider: providerName ?? AgentProviders.fallback)
        adoptSeat(seat)
        stateFile.update { $0.control = seat }
        await refreshControl()
    }

    func disableControl() {
        controlAttention = nil
        adoptSeat(nil)
        controlStatus = "Not connected"
        controlOpen = false
        stateFile.update { $0.control = nil }
    }

    /// Per-seat state restarts with a new session; its own unread cue is device-local.
    private func adoptSeat(_ seat: ControlSeat?) {
        attention = ControlAttention()
        controlStatus = "Not checked"
        controlActivity = nil
        controlNeedsInput = false
        controlPermissions = []
        controlHasOlder = false
        controlMessages = []
        controlTimeline = []
        controlTail = Self.controlPage
        controlServerId = nil
        controlSeat = seat
        startControlWatch()
        if seat == nil { asks = .off }
        // Older builds stored "Needs you" as a cue; it is live state now.
        controlAttention = seat.flatMap { UserDefaults.standard.string(forKey: "controlAttention.\($0.agentId)") }
            .flatMap { $0 == "Needs you" ? nil : $0 }
    }

    func openControl() {
        if searchOpen { closeSearch() }
        controlOpen = true
        showingSettings = false
        openChat = nil
        markControlRead()
        Task { await refreshControl() }
    }

    func closeControl() {
        controlOpen = false
    }

    var canLoadEarlierControl: Bool { controlHasOlder && controlTail < Self.controlMaxTail }

    // ponytail: a longer tail per refresh, not cursor paging; the SDK connection (D) pages properly.
    func loadEarlierControl() async {
        guard canLoadEarlierControl else { return }
        controlTail = min(Self.controlMaxTail, controlTail + Self.controlPage)
        await refreshControl()
    }

    /// Paseo's own agent link. Each id is encoded down to unreserved characters, so an id cannot
    /// add a path, query or fragment to the route.
    nonisolated static func paseoLink(server: String, agent: String) -> URL? {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard !server.isEmpty, !agent.isEmpty,
              let server = server.addingPercentEncoding(withAllowedCharacters: unreserved),
              let agent = agent.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: "paseo://h/\(server)/agent/\(agent)")
    }

    /// Opens this Control session in the Paseo app, where requests are answered.
    func openInPaseo() {
        guard let seat = controlSeat else { return }
        if let server = controlServerId, let url = Self.paseoLink(server: server, agent: seat.agentId),
           NSWorkspace.shared.open(url) { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "sh.paseo.desktop")
            ?? URL(string: "file:///Applications/Paseo.app") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }

    func markControlRead() {
        guard controlOpen, isExpanded, PanelBridge.shared.panel?.isKeyWindow == true else { return }
        controlAttention = nil
        // Remember only needs that are still open, so both lists stay bounded.
        let permissions = Set(controlPermissions.map(\.id))
        if !permissions.isSubset(of: seenPermissions) {
            seenPermissions = permissions
            UserDefaults.standard.set(Array(permissions), forKey: "seenPermissions")
        }
        let open = Set(asks.asks.map(\.id))
        guard !open.isSubset(of: seenAsks) else { return }
        seenAsks = open
        UserDefaults.standard.set(Array(seenAsks), forKey: "seenAsks")
    }

    /// Seen and bubbled needs only ever name what is open now, so a closed request can
    /// never suppress a later one with the same id. Unknown asks change nothing.
    private func reconcileNeeds(permissions: Set<String>, asks reading: AskReading) {
        let keptPermissions = seenPermissions.intersection(permissions)
        if keptPermissions != seenPermissions {
            seenPermissions = keptPermissions
            UserDefaults.standard.set(Array(keptPermissions), forKey: "seenPermissions")
        }
        guard case .available(let open) = reading else { return }
        let openAsks = Set(open.map(\.id))
        if !seenAsks.isSubset(of: openAsks) {
            seenAsks.formIntersection(openAsks)
            UserDefaults.standard.set(Array(seenAsks), forKey: "seenAsks")
        }
        bubbledNeeds.formIntersection(Set(permissions.map { "permission-\($0)" } + openAsks.map { "ask-\($0)" }))
    }

    // MARK: - Edge bubble

    /// A new Lark message while collapsed: one soft bubble, bursts coalesce.
    func larkArrival(chat: Chat, text: String) {
        guard !isExpanded else { return }
        bubble = EdgeBubble.arrival(bubble, chatId: chat.id, name: chat.displayName, text: text)
        expireBubble(after: 6)
    }

    /// A genuine Control need (open ask or permission request), shown once per need.
    func needArrival(id: String, text: String) {
        guard !isExpanded, bubbledNeeds.insert(id).inserted else { return }
        bubble = EdgeBubble(target: .control, title: "Control needs you", text: text)
        expireBubble(after: 12)
    }

    func holdBubble(_ hovering: Bool) {
        bubbleHeld = hovering
        if !hovering, bubble != nil { expireBubble(after: 3) }
    }

    func dismissBubble() {
        bubbleExpiry?.cancel()
        bubbleHeld = false
        if bubble != nil { bubble = nil }
    }

    /// Opens what the bubble is about; never sends anything.
    func openBubble() {
        guard let target = bubble?.target else { return }
        dismissBubble()
        switch target {
        case .chat(let id): openLinkedChat(id)
        case .inbox: showInbox()
        case .control: openControl(); controlFocusAsks = true
        }
        NotificationCenter.default.post(name: .expandPanel, object: nil)
    }

    private func expireBubble(after seconds: Double) {
        bubbleExpiry?.cancel()
        bubbleExpiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.bubbleHeld else { return }
            self.bubble = nil
        }
    }

    /// Asks the live connection for a fresh reading, or reads once while it is down.
    func refreshControl() async {
        if let controlWatch { controlWatch.send("refresh"); return }
        guard !isDemo, let seat = controlSeat, !controlBusy else { return }
        controlBusy = true
        defer { controlBusy = false }
        let provider = AgentProviders.resolve(seat.provider)
        do {
            let (current, reading) = try await provider.readFollowing(seat, tail: controlTail, state: stateFile)
            guard controlSeat == seat else { return }
            if current != seat { adoptSeat(current) }
            await applyControl(reading, seat: current)
        } catch {
            guard controlSeat == seat else { return }
            controlUnavailable(error.localizedDescription)
        }
    }

    private func controlUnavailable(_ reason: String) {
        controlStatus = "Connection unavailable"
        controlActivity = nil
        errorText = "Control: \(reason)"
    }

    // MARK: - Live Paseo connection

    private func startControlWatch() {
        stopControlWatch()
        guard started, !isDemo, let seat = controlSeat, seat.provider == "paseo" else { return }
        let generation = watchGeneration
        let current = { [weak self] in self?.watchGeneration == generation && self?.controlSeat == seat }
        do {
            controlWatch = try PaseoClient().watch(agentId: seat.agentId, host: seat.host, tail: controlTail,
                onReading: { [weak self] reading in
                    MainActor.assumeIsolated {
                        guard let self, current() else { return }
                        self.watchFailures = 0
                        self.controlBusy = false
                        if let moved = seat.following(reading.successor, state: self.stateFile) {
                            self.adoptSeat(moved)
                            return
                        }
                        self.enqueueControl(reading, seat: seat)
                    }
                },
                onError: { [weak self] message in
                    MainActor.assumeIsolated {
                        guard let self, current() else { return }
                        self.controlBusy = false
                        self.controlUnavailable(message)
                    }
                },
                onExit: { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, current() else { return }
                        self.controlWatch = nil
                        self.controlBusy = false
                        self.restartControlWatch()
                    }
                })
            controlBusy = controlTimeline.isEmpty
            sendWatchGap()
        } catch {
            restartControlWatch()
        }
    }

    /// Readings apply one at a time and only the newest waiting one, so a slow apply (it posts
    /// notifications) can never land after a newer reading.
    private func enqueueControl(_ reading: AgentReading, seat: ControlSeat) {
        pendingReading = (reading, seat)
        guard !applyingReading else { return }
        applyingReading = true
        Task {
            while let (next, seat) = pendingReading {
                pendingReading = nil
                if controlSeat == seat { await applyControl(next, seat: seat) }
            }
            applyingReading = false
        }
    }

    private var pendingReading: (AgentReading, ControlSeat)?
    private var applyingReading = false

    /// Backs off 5 s, 10 s, 20 s… up to a minute; polling covers the gap.
    private func restartControlWatch() {
        watchFailures += 1
        let delay = min(60, 5 * pow(2, Double(min(watchFailures, 6) - 1)))
        let generation = watchGeneration
        watchRestart = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.watchGeneration == generation else { return }
            self.startControlWatch()
        }
    }

    private func stopControlWatch() {
        watchGeneration += 1
        watchRestart?.cancel()
        watchRestart = nil
        controlWatch?.stop()
        controlWatch = nil
    }

    /// Transcript changes reach an open Control within 3 s; elsewhere at most every 15 s.
    /// Requests and finished turns are sent at once either way.
    private func sendWatchGap() {
        controlWatch?.send("gap \(controlOpen && isExpanded ? 3 : 15)")
    }

    private func applyControl(_ reading: AgentReading, seat current: ControlSeat) async {
        let sent = Set(UserDefaults.standard.stringArray(forKey: "controlSent") ?? [])
        let messages = reading.messages.map { message -> AgentMessage in
            var message = message
            message.sentHere = message.role == "user" && sent.contains(Self.sentKey(message.text))
            return message
        }
        controlStatus = reading.status
        controlActivity = reading.activity
        controlHasOlder = reading.hasOlder
        controlNeedsInput = reading.needsInput
        asks = reading.asks
        controlPermissions = reading.permissions
        controlServerId = reading.serverId ?? controlServerId
        reconcileNeeds(permissions: Set(reading.permissions.map(\.id)), asks: reading.asks)
        for permission in reading.permissions where !seenPermissions.contains(permission.id) {
            needArrival(id: "permission-\(permission.id)", text: permission.summary)
        }
        for ask in asks.asks where !seenAsks.contains(ask.id) {
            needArrival(id: "ask-\(ask.id)", text: UpdateText.short(ask.title.isEmpty ? ask.question : ask.title, limit: 90))
            await Notifications.shared.post(title: "Needs you" + (ask.plan.isEmpty ? "" : " · \(ask.plan)"),
                body: UpdateText.short(ask.title.isEmpty ? ask.question : ask.title, limit: 120),
                id: "ask-\(ask.id)", destination: "control")
        }
        let event = attention.observe(status: reading.status, needsInput: reading.needsInput, messages: messages)
        if event.reply != nil || (event.alert != nil && !reading.needsInput) {
            controlAttention = event.alert ?? "New reply"
        }
        markControlRead()
        if let alert = event.alert, controlAttention != nil || reading.needsInput {
            let reply = messages.last(where: { $0.isAssistant })?.text ?? "Open Control to respond."
            await Notifications.shared.post(title: "Control · \(alert)",
                body: reading.needsInput ? "Paseo is waiting for your permission." : UpdateText.short(reply, limit: 120),
                id: "control-\(current.agentId)-\(event.reply ?? alert)-\(alert)", destination: "control")
        }
        if !messages.isEmpty || controlMessages.isEmpty {
            controlMessages = messages
            let byId = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            controlTimeline = reading.timeline.map { entry in
                guard let message = entry.message, let marked = byId[message.id] else { return entry }
                return .message(marked)
            }
        }
    }

    static func sentKey(_ text: String) -> String {
        SHA256.hash(data: Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func sendControl() async {
        let text = controlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let seat = controlSeat, !controlSending else { return }
        controlSending = true
        controlActivity = "Sending"
        controlDraft = ""
        // Remember the prompt so the timeline can attribute it to you, not to automation.
        let sent = UserDefaults.standard.stringArray(forKey: "controlSent") ?? []
        UserDefaults.standard.set(Array((sent + [Self.sentKey(text)]).suffix(50)), forKey: "controlSent")
        do {
            try await AgentProviders.resolve(seat.provider)
                .send(id: seat.agentId, host: seat.host, text: text)
            try? await Task.sleep(nanoseconds: 800_000_000)
            await refreshControl()
        } catch {
            errorText = error.localizedDescription
            controlDraft = text
        }
        controlSending = false
    }

    // MARK: - Demo

    static func demo(needsYou: Bool = false) -> Store {
        let store = Store()
        store.isDemo = true
        store.drafts = [:]
        store.controlDraft = ""
        store.settings = Settings()
        store.muted = [:]
        store.auth = .signedIn
        store.me = Me(openId: "demo", name: "Alex", avatar: nil)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        store.chats = [
            Chat(id: "c1", name: "Ops Assistant", avatar: nil, isP2P: true, isTopic: false, detail: "", link: nil),
            Chat(id: "c2", name: "Sam Patel", avatar: nil, isP2P: true, isTopic: false, detail: "", link: nil),
            Chat(id: "c3", name: "Design Room", avatar: nil, isP2P: false, isTopic: false, detail: "", link: nil),
            Chat(id: "c4", name: "Agents Room", avatar: nil, isP2P: false, isTopic: false, detail: "", link: nil),
            Chat(id: "c5", name: "Launch Crew", avatar: nil, isP2P: false, isTopic: true, detail: "", link: nil),
            Chat(id: "c6", name: "Riley Chen", avatar: nil, isP2P: true, isTopic: false, detail: "", link: nil),
            Chat(id: "c7", name: "Finance", avatar: nil, isP2P: false, isTopic: false, detail: "", link: nil),
            Chat(id: "c8", name: "North Studio", avatar: nil, isP2P: true, isTopic: false, detail: "", link: nil)
        ]
        store.pinned = ["c1", "c2", "c3", "c4", "c5"]
        store.previews = [
            "c1": Preview(text: "Deployed to staging, want a look?", ts: now - 60_000, messageId: "m1", fromMe: false),
            "c2": Preview(text: "You: send it over", ts: now - 300_000, messageId: "m2", fromMe: true),
            "c3": Preview(text: "New dock icons are up", ts: now - 900_000, messageId: "m3", fromMe: false),
            "c4": Preview(text: "[agent] PR merged", ts: now - 1_800_000, messageId: "m4", fromMe: false),
            "c5": Preview(text: "Ticket batch goes live Friday", ts: now - 3_600_000, messageId: "m5", fromMe: false),
            "c6": Preview(text: "You: looks good", ts: now - 7_200_000, messageId: "m6", fromMe: true)
        ]
        store.lastSeen = ["c1": "earlier", "c3": "earlier", "c4": "m4", "c5": "earlier"]
        let minute = (now / 60_000 - 1) * 60_000
        store.messages["c1"] = [
            ChatMessage(id: "d1", chatId: "c1", type: "text", text: "Is the release ready to review?", ts: minute - 60_000,
                sender: Sender(id: "me", name: "You", isMe: true), imageKey: nil, fileKey: nil, fileName: nil, deleted: false),
            ChatMessage(id: "d2", chatId: "c1", type: "text", text: "The build is ready.", ts: minute + 1_000,
                sender: Sender(id: "a", name: "Ops Assistant", isMe: false), imageKey: nil, fileKey: nil, fileName: nil, deleted: false),
            ChatMessage(id: "d3", chatId: "c1", type: "text", text: "Checks passed too.", ts: minute + 2_000,
                sender: Sender(id: "a", name: "Ops Assistant", isMe: false), imageKey: nil, fileKey: nil, fileName: nil, deleted: false),
            ChatMessage(id: "m1", chatId: "c1", type: "text", text: "Deployed to staging, want a look?", ts: minute + 3_000,
                sender: Sender(id: "a", name: "Ops Assistant", isMe: false), imageKey: nil, fileKey: nil, fileName: nil, deleted: false)
        ]
        for chat in store.chats where store.messages[chat.id] == nil {
            if let preview = store.previews[chat.id] {
                store.messages[chat.id] = [ChatMessage(
                    id: preview.messageId, chatId: chat.id, type: "text",
                    text: preview.fromMe ? String(preview.text.dropFirst(5)) : preview.text,
                    ts: preview.ts, sender: Sender(id: preview.fromMe ? "me" : chat.id,
                        name: preview.fromMe ? "You" : chat.displayName, isMe: preview.fromMe),
                    imageKey: nil, fileKey: nil, fileName: nil, deleted: false)]
            } else {
                store.messages[chat.id] = []
            }
        }
        // Group chat: replies, edits, voice, video, stickers, forwards and a type Sift cannot draw.
        let design = { (id: String, sender: String, type: String, text: String, at: Int64) in
            ChatMessage(id: id, chatId: "c3", type: type, text: text, ts: minute + at,
                        sender: Sender(id: sender, name: "", isMe: sender == "me"), imageKey: nil, fileKey: nil, fileName: nil, deleted: false)
        }
        store.memberNames = ["u-riley": "Riley Chen", "u-sam": "Sam Patel"]
        var reply = design("g2", "u-sam", "text", "Love the new set. Ship them Friday?", 61_000)
        reply.parentId = "g1"
        var edited = design("g3", "me", "text", "Friday works, I'll update the build.", 122_000)
        edited.parentId = "g2"
        edited.edited = true
        var voice = design("g4", "u-riley", "audio", "Voice message", 183_000)
        voice.media = .audio(seconds: 14)
        var forward = design("g5", "u-sam", "merge_forward", "Forwarded messages", 244_000)
        forward.media = .forward
        var sticker = design("g6", "u-riley", "sticker", "Sticker", 245_000)
        sticker.media = .sticker
        var event = design("m3", "u-riley", "share_calendar_event", "Calendar event · Icon review", 306_000)
        event.media = .other(type: "share_calendar_event")
        store.messages["c3"] = [design("g1", "u-riley", "text", "New dock icons are up", 0), reply, edited, voice, forward, sticker, event]
        store.controlSeat = ControlSeat(agentId: "7b389a28-demo", title: "Control")
        store.controlStatus = "idle"
        store.asks = .available(needsYou ? [OpenAsk(id: "a1", plan: "ALT-12", title: "Publish the release notes",
            question: "The notes are ready. Publish them now, or hold until tomorrow's standup?",
            recommendation: "Publish now; nothing in them is client-visible.", link: URL(string: "https://linear.app"))] : [])
        store.controlMessages = [
            AgentMessage(id: "msg_demo_1", role: "user", text: "Ship the release notes before standup.", ts: now - 240_000),
            AgentMessage(id: "control-wait:demo:receipt", role: "user", text: "Control wait receipt ALT-12: the release check finished.", ts: now - 200_000),
            AgentMessage(id: "p2", role: "assistant", text: "## Release notes are ready\n\nThe notes and changelog are ready for review.\n\n- **Changed:** grouped messages and a smaller composer.\n- **Checked:** the focused tests passed.\n- **Needs you:** choose when to publish.\n\n[Open the review](https://example.com/review)", ts: now - 180_000)
        ]
        let work = [
            AgentStep(id: "s1", kind: "reasoning", title: "Thought", detail: "Check the changelog against the merged PRs."),
            AgentStep(id: "s2", kind: "shell", title: "Ran a command", target: "git log --oneline -5", status: "completed",
                      detail: "a1b2c3d Group messages\n9f8e7d6 Smaller composer"),
            AgentStep(id: "s3", kind: "edit", title: "Edited a file", target: "docs/release-notes.md", status: "completed",
                      detail: "+ Grouped messages and a smaller composer."),
            AgentStep(id: "s4", kind: "todo", title: "Checklist", target: "2 of 3 done", todos: [
                .init(text: "Draft the notes", status: "completed"), .init(text: "Check the changelog", status: "completed"),
                .init(text: "Publish", status: "in_progress")])]
        let messages = store.controlMessages
        store.controlTimeline = [.message(messages[0]), .message(messages[1]), .work(id: "work-s1", steps: work),
                                 .notice(id: "n1", level: "warning", text: "Context is 90% full; Paseo will compact soon.", ts: nil),
                                 .message(messages[2])]
        if needsYou {
            store.controlPermissions = [PermissionRequest(id: "p1", title: "Publish the release notes", kind: "tool", name: "Bash",
                description: "Runs the publish script for the release notes.", detail: "./scripts/publish-notes --channel release",
                actions: ["Allow", "Deny"])]
            store.controlNeedsInput = true
        }
        store.openChat = nil
        store.settings.panelWidth = 400
        return store
    }
}
