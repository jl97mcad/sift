import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CryptoKit
import Combine

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
            if isExpanded { dismissBubble() } else { seat?.closed() }
            seats.forEach { $0.sendWatchGap() }
        }
    }
    /// The thought bubble beside the collapsed head.
    @Published private(set) var bubble: EdgeBubble?
    /// Set when a bubble opens Control, so it scrolls to the asks.
    @Published var controlFocusAsks = false
    private var bubbleExpiry: Task<Void, Never>?
    private var bubbleHeld = false
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
    /// Agent seats in rail order; each owns its live connection and attention (ADR 0011).
    @Published private(set) var seats: [SeatSession] = []
    @Published var selectedSeatId: String?
    private var seatChanges: [String: AnyCancellable] = [:]
    private(set) var started = false
    /// The selected seat's conversation is showing.
    @Published var controlOpen = false {
        didSet {
            if !controlOpen { seat?.closed() } else { seat?.sendWatchGap() }
        }
    }

    /// The seat whose conversation opens; the first one until another is chosen.
    var seat: SeatSession? { seats.first { $0.id == selectedSeatId } ?? seats.first }
    var controlSeat: ControlSeat? { seat?.config }
    /// The seat that most needs the person: an unseen need first, then a new reply.
    var attentionSeat: SeatSession? {
        seats.first { $0.needsYouUnseen } ?? seats.first { $0.attention != nil }
    }
    var needsYouUnseen: Bool { seats.contains { $0.needsYouUnseen } }
    var attentionSummary: String? { seats.lazy.compactMap { seat in seat.attentionSummary.map { "\(seat.label) · \($0)" } }.first }
    var controlAttention: String? { seats.lazy.compactMap(\.attention).first }

    let voice = VoiceMode()
    let tokens = TokenStore()
    private(set) lazy var api = LarkAPI(tokens: tokens)
    let stateFile = StateFile.shared
    private var pollTask: Task<Void, Never>?
    private var tickCount = 0
    private var hydrated = Set<String>()
    private var previewInFlight = Set<String>()
    private var resolvedMembers = Set<String>()
    @Published private var pageToken: String?
    private var loadedFirstPage = false
    private var fetchingChats = false
    /// The top of Lark's activity-sorted chat list at the last poll.
    private var activityOrder: [String] = []
    /// Chats that moved up but whose preview could not be read yet, with failed attempts.
    /// They are retried every poll, since the order will not move again for the same message.
    private var pendingMovers: [String: Int] = [:]
    private var olderTokens: [String: String] = [:]
    private(set) var isDemo = false

    init() {
        let state = stateFile.current
        settings = state.settings
        settings.panelWidth = Settings.validWidth(settings.panelWidth)
        if settings != state.settings { stateFile.update { $0.settings = settings } }
        pinned = state.pinned
        lastSeen = state.lastSeen
        muted = state.muted
        let saved = DraftFile.load()
        drafts = saved.chats
        SeatSession.migrateSeenLists(to: state.control)
        setSeats(state.seats)
        voice.store = self
        // Agents first: the panel opens on the first seat when there is one.
        selectedSeatId = seats.first?.id
        controlOpen = !seats.isEmpty
        // The draft from before seats belonged to the one Control; it goes to that seat only.
        if !saved.control.isEmpty, let control = state.control,
           let seat = seats.first(where: { $0.id == control.id }), seat.draft.isEmpty { seat.draft = saved.control }
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
        if state.seats != seats.map(\.config) {
            setSeats(state.seats)
            if seats.isEmpty { controlOpen = false }
        }
        if tokens.tokens != nil, auth == .signedOut { auth = .signedIn }
        if tokens.tokens == nil, auth == .signedIn { auth = .signedOut }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isDemo else { return }
        started = true
        seats.forEach { $0.startWatch() }
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
        if tickCount % 3 == 1 { seats.forEach { $0.poll() } }
        guard auth == .signedIn else { return }
        if tickCount % 6 == 1 {
            await loadChats(reset: true, quiet: true)
        }
        // New messages are found from the activity order of the chat list: one small list read,
        // then previews only for the top chats and those that moved up (ADR 0010).
        var ids = Set<String>()
        var moved = Set<String>()
        if let openChat { ids.insert(openChat.id) }
        // The open panel shows the pins' unread state, so it keeps them at the poll interval;
        // collapsed, the order alone finds new messages (Lark reorders within about 20 s).
        if isExpanded { ids.formUnion(pinned) }
        if let page = try? await api.listChats(pageSize: 20) {
            let order = page.chats.map(\.id)
            if activityOrder.isEmpty { ids.formUnion(pinned) }  // first read: settle the pins once
            let change = ActivityOrder.changes(previous: activityOrder, current: order)
            activityOrder = order
            ids.formUnion(change.refresh)
            moved = change.moved
            let known = Set(chats.map(\.id))
            let newcomers = page.chats.filter { !known.contains($0.id) }
            if !newcomers.isEmpty { chats.insert(contentsOf: newcomers, at: 0) }
        } else {
            ids.formUnion(pinned)  // the list read failed: the pins are still checked
        }
        moved.formUnion(pendingMovers.keys)
        ids.formUnion(moved)
        let read = await refreshPreviews(Array(ids), moved: moved)
        let abandoned: [String]
        (pendingMovers, abandoned) = ActivityOrder.settle(pending: pendingMovers, moved: moved, read: read)
        if !abandoned.isEmpty {
            let names = abandoned.map { id in chats.first { $0.id == id }?.displayName ?? "a chat" }
            errorText = "Could not read new messages in " + names.joined(separator: ", ") + ". Open the chat to retry."
        }
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
        activityOrder = []
        pendingMovers = [:]
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
    /// `moved` chats rose in the activity order, so their newest message is new even without an
    /// earlier preview or read marker.
    /// Returns the chats whose newest message was read (an empty chat counts as read).
    @discardableResult
    private func refreshPreviews(_ ids: [String], moved: Set<String> = []) async -> Set<String> {
        guard auth == .signedIn, !isDemo else { return [] }
        var read = Set<String>()
        await withTaskGroup(of: (String, Preview?, Bool).self) { group in
            var iterator = ids.makeIterator()
            var inflight = 0
            while inflight < 10, let id = iterator.next() {
                inflight += 1
                group.addTask { [api] in await Self.readPreview(api, id) }
            }
            while let result = await group.next() {
                inflight -= 1
                if result.2 { read.insert(result.0) }
                if let preview = result.1 {
                    // Keep a newer preview, and skip unchanged ones so the list does not redraw every tick.
                    if let existing = self.previews[result.0], existing.ts > preview.ts || existing == preview {
                    } else {
                        let previous = self.previews[result.0]
                        self.previews[result.0] = preview
                        if self.lastSeen[result.0] == nil { self.setSeen(result.0, moved.contains(result.0) ? "" : preview.messageId) }
                        if previous != nil || moved.contains(result.0),
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
                    group.addTask { [api] in await Self.readPreview(api, id) }
                }
            }
        }
        return read
    }

    /// The newest message as a preview; `read` is false only when the request failed.
    nonisolated private static func readPreview(_ api: LarkAPI, _ id: String) async -> (String, Preview?, Bool) {
        do {
            guard let message = try await api.latestMessage(chatId: id) else { return (id, nil, true) }
            return (id, Preview(text: previewText(for: message), ts: message.ts, messageId: message.id, fromMe: message.isMine), true)
        } catch {
            return (id, nil, false)
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

    func saveDrafts() {
        guard loadedDrafts, !isDemo else { return }
        var all = drafts
        for seat in seats { all["seat:" + seat.id] = seat.draft }
        do { try DraftFile(chats: all).save() }
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

    // MARK: - Agent seats

    var paseoAvailable: Bool { PaseoClient.isAvailable }

    /// Sessions follow the saved list: existing seats keep their live state (a handoff written by
    /// the CLI is adopted), new ones start, removed ones stop their helper.
    private func setSeats(_ configs: [ControlSeat]) {
        let existing = Dictionary(seats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let drafts = DraftFile.load().chats
        let next = configs.map { config -> SeatSession in
            if let session = existing[config.id] {
                // A new session (handoff written by the CLI) restarts the seat; a rename does not.
                if session.config.agentId != config.agentId || session.config.host != config.host
                    || session.config.provider != config.provider { session.adopt(config) }
                else if session.config != config { session.config = config }
                return session
            }
            let session = SeatSession(config, store: self)
            if !isDemo { session.draft = drafts["seat:" + config.id] ?? "" }
            if started { session.startWatch() }
            return session
        }
        for session in seats where !next.contains(where: { $0 === session }) {
            session.stopWatch()
            voice.cancel(seat: session.id)
        }
        seats = next
        seatChanges = Dictionary(uniqueKeysWithValues: next.map { session in
            (session.id, session.objectWillChange.sink { [weak self] in self?.objectWillChange.send() })
        })
        if seat == nil { selectedSeatId = nil }
    }

    func addSeat(agentId: String, host: String? = nil, name: String = "", color: String = "", providerName: String? = nil) async {
        let trimmed = agentId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        errorText = nil
        let hostValue = host?.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = AgentProviders.resolve(providerName)
        guard let info = await provider.inspect(id: trimmed, host: hostValue) else {
            errorText = "No \(provider.name) session found for \(trimmed) (check the host)"
            return
        }
        let seat = ControlSeat(agentId: trimmed, title: info.title, host: hostValue,
                               provider: providerName ?? AgentProviders.fallback,
                               name: name.trimmingCharacters(in: .whitespacesAndNewlines), color: color)
        let state = stateFile.update { $0.seats.removeAll { $0.id == seat.id }; $0.seats.append(seat) }
        setSeats(state.seats)
        if let session = seats.first(where: { $0.id == seat.id }) { openSeat(session) }
    }

    func removeSeat(_ session: SeatSession) {
        let state = stateFile.update { $0.seats.removeAll { $0.id == session.id } }
        setSeats(state.seats)
        drafts["seat:" + session.id] = nil
        if selectedSeatId == session.id { selectedSeatId = seats.first?.id }
        if seats.isEmpty { controlOpen = false }
    }

    func moveSeat(from source: String, to target: String) {
        let state = stateFile.update { state in
            guard let from = state.seats.firstIndex(where: { $0.id == source }),
                  let to = state.seats.firstIndex(where: { $0.id == target }), from != to else { return }
            state.seats.insert(state.seats.remove(at: from), at: to)
        }
        setSeats(state.seats)
    }

    func openSeat(_ session: SeatSession) {
        if searchOpen { closeSearch() }
        if selectedSeatId != session.id { seat?.closed() }
        selectedSeatId = session.id
        controlOpen = true
        showingSettings = false
        openChat = nil
        markControlRead()
        Task { await session.refresh() }
    }

    func openSeat(id: String) {
        guard let session = seats.first(where: { $0.id == id }) else { return }
        openSeat(session)
    }

    /// The selected seat, or the first one.
    func openControl() {
        guard let seat else { return }
        openSeat(seat)
    }

    func closeControl() {
        controlOpen = false
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

    func markControlRead() {
        seat?.markRead()
    }

    static func sentKey(_ text: String) -> String {
        SHA256.hash(data: Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Edge bubble

    /// A new Lark message while collapsed: one soft bubble, bursts coalesce.
    func larkArrival(chat: Chat, text: String) {
        guard !isExpanded else { return }
        bubble = EdgeBubble.arrival(bubble, chatId: chat.id, name: chat.displayName, text: text)
        expireBubble(after: 6)
    }

    /// A genuine agent need (open ask or permission request); the seat shows each need once.
    func needArrival(seat: SeatSession, text: String) {
        guard !isExpanded else { return }
        bubble = EdgeBubble(target: .seat(seat.id), title: "\(seat.label) needs you", text: text)
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
        case .seat(let id): openSeat(id: id); controlFocusAsks = true
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

    // MARK: - Demo

    static func demo(needsYou: Bool = false) -> Store {
        let store = Store()
        store.isDemo = true
        store.drafts = [:]
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
        let control = SeatSession(ControlSeat(agentId: "7b389a28-demo", title: "Control"), store: store)
        let finance = SeatSession(ControlSeat(agentId: "finance-demo", title: "Finance", name: "Finance", color: "yellow"), store: store)
        store.setSeats([control.config, finance.config])
        let seats = store.seats
        store.selectedSeatId = seats[0].id
        let messages = [
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
        seats[0].demo(status: "idle",
            asks: .available(needsYou ? [OpenAsk(id: "a1", plan: "ALT-12", title: "Publish the release notes",
                question: "The notes are ready. Publish them now, or hold until tomorrow's standup?",
                recommendation: "Publish now; nothing in them is client-visible.", link: URL(string: "https://linear.app"))] : []),
            messages: messages,
            timeline: [.message(messages[0]), .message(messages[1]), .work(id: "work-s1", steps: work),
                       .notice(id: "n1", level: "warning", text: "Context is 90% full; Paseo will compact soon.", ts: nil),
                       .message(messages[2])],
            permissions: needsYou ? [PermissionRequest(id: "p1", title: "Publish the release notes", kind: "tool", name: "Bash",
                description: "Runs the publish script for the release notes.", detail: "./scripts/publish-notes --channel release",
                actions: ["Allow", "Deny"])] : [],
            needsInput: needsYou)
        let ledger = AgentMessage(id: "p3", role: "assistant", text: "October invoices are reconciled. Two are still unpaid; I have chased both.", ts: now - 3_600_000)
        seats[1].demo(status: "idle", asks: .off, messages: [ledger], timeline: [.message(ledger)])
        store.openChat = nil
        store.settings.panelWidth = 400
        return store
    }
}
