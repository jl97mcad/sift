import Foundation
import AppKit
import SwiftUI
import CryptoKit

/// One agent seat's live state: its session, the live Paseo connection (ADR 0009), attention,
/// open needs and the draft. The Store owns one per configured seat and forwards their changes.
@MainActor
final class SeatSession: ObservableObject, Identifiable {
    @Published var config: ControlSeat
    @Published var messages: [AgentMessage] = []
    @Published private(set) var timeline: [ControlEntry] = []
    /// How many timeline entries a refresh reads; "Earlier activity" raises it.
    @Published private(set) var tail = SeatSession.page {
        didSet { if tail != oldValue { watch?.send("tail \(tail)") } }
    }
    @Published var busy = false
    @Published var sending = false
    @Published var activity: String?
    @Published private(set) var hasOlder = false
    @Published private(set) var needsInput = false
    @Published private(set) var permissions: [PermissionRequest] = []
    @Published private(set) var asks: AskReading = .off
    @Published private(set) var status = "Not checked"
    /// A quiet "new reply" cue; device-local so it survives a restart.
    @Published private(set) var attention: String? {
        didSet { UserDefaults.standard.set(attention, forKey: "controlAttention.\(id)") }
    }
    @Published var draft = "" { didSet { store?.saveDrafts() } }

    nonisolated static let page = 80
    nonisolated static let maxTail = 400
    nonisolated let id: String
    /// Weak: a demo or test store may go away while a seat still has a task in flight.
    private(set) weak var store: Store?

    private var policy = ControlAttention()
    private var seenPermissions: Set<String>
    private var seenAsks: Set<String>
    private var bubbledNeeds = Set<String>()
    private var serverId: String?
    /// The live connection; nil while it restarts, when the one-shot read every third poll takes over.
    private var watch: ChildStream?
    private var watchGeneration = 0
    private var watchFailures = 0
    private var watchRestart: Task<Void, Never>?
    /// A stopped helper whose group has not exited yet; its replacement waits for it.
    private var retiringWatch: ChildStream?
    private var watchStartWaiting = false
    private var pendingReading: (AgentReading, ControlSeat)?
    private var applyingReading = false

    init(_ config: ControlSeat, store: Store) {
        self.config = config
        self.id = config.id
        self.store = store
        seenPermissions = Set(UserDefaults.standard.stringArray(forKey: "seenPermissions.\(config.id)") ?? [])
        seenAsks = Set(UserDefaults.standard.stringArray(forKey: "seenAsks.\(config.id)") ?? [])
        // Older builds stored "Needs you" as a cue; it is live state now.
        attention = UserDefaults.standard.string(forKey: "controlAttention.\(config.id)").flatMap { $0 == "Needs you" ? nil : $0 }
    }

    var label: String { config.label }
    var palette: FacePalette { config.palette }
    var isOpen: Bool { store.map { $0.controlOpen && $0.selectedSeatId == id } ?? false }

    // MARK: - Needs

    var openAskCount: Int { asks.asks.count }
    /// Open asks plus pending Paseo requests: everything listed at the top of the conversation.
    var openNeedCount: Int { openAskCount + permissions.count }
    /// Pulses until seen, then goes quiet like a read reply; open asks stay listed.
    var needsYouUnseen: Bool {
        permissions.contains { !seenPermissions.contains($0.id) } || asks.asks.contains { !seenAsks.contains($0.id) }
    }

    var attentionSummary: String? {
        if needsInput { return "Waiting for your permission" }
        if openAskCount > 0 { return openAskCount == 1 ? "1 open ask" : "\(openAskCount) open asks" }
        return attention
    }

    var asksSummary: String {
        switch asks {
        case .off: return "Off · this agent serves no open asks"
        case .unavailable(let reason): return "Unknown · " + reason
        case .available(let open): return open.isEmpty ? "None open" : "\(open.count) open"
        }
    }

    func markRead() {
        guard isOpen, store?.isExpanded == true, PanelBridge.shared.panel?.isKeyWindow == true else { return }
        attention = nil
        // Remember only needs that are still open, so both lists stay bounded.
        let open = Set(permissions.map(\.id))
        if !open.isSubset(of: seenPermissions) {
            seenPermissions = open
            UserDefaults.standard.set(Array(open), forKey: "seenPermissions.\(id)")
        }
        let openAsks = Set(asks.asks.map(\.id))
        guard !openAsks.isSubset(of: seenAsks) else { return }
        seenAsks = openAsks
        UserDefaults.standard.set(Array(seenAsks), forKey: "seenAsks.\(id)")
    }

    /// Seen and bubbled needs only ever name what is open now, so a closed request can
    /// never suppress a later one with the same id. Unknown asks change nothing.
    private func reconcileNeeds(permissions: Set<String>, asks reading: AskReading) {
        let keptPermissions = seenPermissions.intersection(permissions)
        if keptPermissions != seenPermissions {
            seenPermissions = keptPermissions
            UserDefaults.standard.set(Array(keptPermissions), forKey: "seenPermissions.\(id)")
        }
        guard case .available(let open) = reading else { return }
        let openAsks = Set(open.map(\.id))
        if !seenAsks.isSubset(of: openAsks) {
            seenAsks.formIntersection(openAsks)
            UserDefaults.standard.set(Array(seenAsks), forKey: "seenAsks.\(id)")
        }
        bubbledNeeds.formIntersection(Set(permissions.map { "permission-\($0)" } + openAsks.map { "ask-\($0)" }))
    }

    /// A genuine need (open ask or permission request), bubbled once per need while collapsed.
    private func needArrival(id needId: String, text: String) {
        guard bubbledNeeds.insert(needId).inserted else { return }
        store?.needArrival(seat: self, text: text)
    }

    // MARK: - Reading

    var canLoadEarlier: Bool { hasOlder && tail < Self.maxTail }

    // ponytail: a longer tail per refresh, not cursor paging; the SDK connection (D) pages properly.
    func loadEarlier() async {
        guard canLoadEarlier else { return }
        tail = min(Self.maxTail, tail + Self.page)
        await refresh()
    }

    /// Opens this session in the Paseo app, where requests are answered.
    func openInPaseo() {
        if let server = serverId, let url = Store.paseoLink(server: server, agent: config.agentId),
           NSWorkspace.shared.open(url) { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "sh.paseo.desktop")
            ?? URL(string: "file:///Applications/Paseo.app") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }

    /// Asks the live connection for a fresh reading, or reads once while it is down.
    func refresh() async {
        if let watch { watch.send("refresh"); return }
        guard let store, !store.isDemo, !busy else { return }
        let seat = config
        busy = true
        defer { busy = false }
        let provider = AgentProviders.resolve(seat.provider)
        do {
            let (current, reading) = try await provider.readFollowing(seat, tail: tail, state: store.stateFile)
            guard config == seat else { return }
            if current != seat { adopt(current) }
            await apply(reading, seat: current)
        } catch {
            guard config == seat else { return }
            unavailable(error.localizedDescription)
        }
    }

    /// A handoff successor: per-session state restarts; the seat's own cue and seen needs stay.
    func adopt(_ seat: ControlSeat) {
        policy = ControlAttention()
        status = "Not checked"
        activity = nil
        needsInput = false
        permissions = []
        hasOlder = false
        messages = []
        timeline = []
        tail = Self.page
        serverId = nil
        config = seat
        startWatch()
    }

    /// The name or colour changed in Settings: nothing live restarts.
    func rename(name: String, color: String) {
        config.name = name
        config.color = color
        let id = id
        store?.stateFile.update { state in
            if let index = state.seats.firstIndex(where: { $0.id == id }) {
                state.seats[index].name = name
                state.seats[index].color = color
            }
        }
    }

    private func unavailable(_ reason: String) {
        status = "Connection unavailable"
        activity = nil
        store?.errorText = "\(label): \(reason)"
    }

    // MARK: - Live Paseo connection

    func startWatch() {
        stopWatch()
        // One helper per seat: a replacement starts only once the old helper's group is gone.
        if retiringWatch != nil { watchStartWaiting = true; return }
        guard let store, store.started, !store.isDemo, config.provider == "paseo" else { return }
        let seat = config
        let generation = watchGeneration
        let current = { [weak self] in self?.watchGeneration == generation && self?.config == seat }
        do {
            watch = try PaseoClient().watch(agentId: seat.agentId, host: seat.host, tail: tail,
                onReading: { [weak self] reading in
                    MainActor.assumeIsolated {
                        guard let self, current() else { return }
                        self.watchFailures = 0
                        self.busy = false
                        if let store = self.store, let moved = seat.following(reading.successor, state: store.stateFile) {
                            self.adopt(moved)
                            return
                        }
                        self.enqueue(reading, seat: seat)
                    }
                },
                onError: { [weak self] message in
                    MainActor.assumeIsolated {
                        guard let self, current() else { return }
                        self.busy = false
                        self.unavailable(message)
                    }
                },
                onExit: { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, current() else { return }
                        self.watch = nil
                        self.busy = false
                        self.restartWatch()
                    }
                })
            busy = timeline.isEmpty
            sendWatchGap()
        } catch {
            restartWatch()
        }
    }

    /// Readings apply one at a time and only the newest waiting one, so a slow apply (it posts
    /// notifications) can never land after a newer reading.
    private func enqueue(_ reading: AgentReading, seat: ControlSeat) {
        pendingReading = (reading, seat)
        guard !applyingReading else { return }
        applyingReading = true
        Task {
            while let (next, seat) = pendingReading {
                pendingReading = nil
                if config == seat { await apply(next, seat: seat) }
            }
            applyingReading = false
        }
    }

    /// Backs off 5 s, 10 s, 20 s… up to a minute; polling covers the gap.
    private func restartWatch() {
        watchFailures += 1
        let delay = min(60, 5 * pow(2, Double(min(watchFailures, 6) - 1)))
        let generation = watchGeneration
        watchRestart = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.watchGeneration == generation else { return }
            self.startWatch()
        }
    }

    func stopWatch() {
        watchGeneration += 1
        watchRestart?.cancel()
        watchRestart = nil
        guard let watch else { return }
        self.watch = nil
        retiringWatch = watch
        watch.stop { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.retiringWatch === watch else { return }
                self.retiringWatch = nil
                if self.watchStartWaiting {
                    self.watchStartWaiting = false
                    self.startWatch()
                }
            }
        }
    }

    /// Transcript changes reach an open conversation within 3 s; elsewhere at most every 15 s.
    /// Requests and finished turns are sent at once either way.
    func sendWatchGap() {
        watch?.send("gap \(isOpen && store?.isExpanded == true ? 3 : 15)")
    }

    /// Leaving the conversation drops back to the short tail, so a collapsed panel polls little.
    func closed() {
        tail = Self.page
        sendWatchGap()
    }

    /// Polls once while the live connection is down.
    func poll() {
        guard watch == nil, !busy else { return }
        Task { await refresh() }
    }

    private func apply(_ reading: AgentReading, seat current: ControlSeat) async {
        let sent = Set(UserDefaults.standard.stringArray(forKey: "controlSent") ?? [])
        let messages = reading.messages.map { message -> AgentMessage in
            var message = message
            message.sentHere = message.role == "user" && sent.contains(Store.sentKey(message.text))
            return message
        }
        status = reading.status
        activity = reading.activity
        hasOlder = reading.hasOlder
        needsInput = reading.needsInput
        asks = reading.asks
        permissions = reading.permissions
        serverId = reading.serverId ?? serverId
        reconcileNeeds(permissions: Set(reading.permissions.map(\.id)), asks: reading.asks)
        for permission in reading.permissions where !seenPermissions.contains(permission.id) {
            needArrival(id: "permission-\(permission.id)", text: permission.summary)
        }
        for ask in asks.asks where !seenAsks.contains(ask.id) {
            needArrival(id: "ask-\(ask.id)", text: UpdateText.short(ask.title.isEmpty ? ask.question : ask.title, limit: 90))
            await Notifications.shared.post(title: "Needs you" + (ask.plan.isEmpty ? "" : " · \(ask.plan)"),
                body: UpdateText.short(ask.title.isEmpty ? ask.question : ask.title, limit: 120),
                id: "ask-\(ask.id)", destination: "seat:\(id)")
        }
        let event = policy.observe(status: reading.status, needsInput: reading.needsInput, messages: messages)
        if event.reply != nil || (event.alert != nil && !reading.needsInput) {
            attention = event.alert ?? "New reply"
        }
        markRead()
        if let alert = event.alert, attention != nil || reading.needsInput {
            let reply = messages.last(where: { $0.isAssistant })?.text ?? "Open \(label) to respond."
            await Notifications.shared.post(title: "\(label) · \(alert)",
                body: reading.needsInput ? "Paseo is waiting for your permission." : UpdateText.short(reply, limit: 120),
                id: "control-\(current.agentId)-\(event.reply ?? alert)-\(alert)", destination: "seat:\(id)")
        }
        if !messages.isEmpty || self.messages.isEmpty {
            self.messages = messages
            let byId = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            timeline = reading.timeline.map { entry in
                guard let message = entry.message, let marked = byId[message.id] else { return entry }
                return .message(marked)
            }
        }
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        draft = ""
        // Put it back without losing anything typed meanwhile.
        if await !send(text: text) { draft = draft.isEmpty ? text : text + "\n" + draft }
    }

    /// Sends a prompt as the person; false if it did not go.
    @discardableResult
    func send(text: String) async -> Bool {
        guard !sending else { return false }
        let seat = config
        sending = true
        activity = "Sending"
        // Remember the prompt so the timeline can attribute it to you, not to automation.
        let sent = UserDefaults.standard.stringArray(forKey: "controlSent") ?? []
        UserDefaults.standard.set(Array((sent + [Store.sentKey(text)]).suffix(50)), forKey: "controlSent")
        do {
            try await AgentProviders.resolve(seat.provider)
                .send(id: seat.agentId, host: seat.host, text: text)
            try? await Task.sleep(nanoseconds: 800_000_000)
            sending = false
            await refresh()
            return true
        } catch {
            store?.errorText = error.localizedDescription
            sending = false
            return false
        }
    }

    /// Before seats, seen needs were one list for the one Control. They move to that seat once
    /// and the global lists go, so a later seat never starts with another agent's seen state.
    static func migrateSeenLists(to control: ControlSeat?, defaults: UserDefaults = .standard) {
        for key in ["seenPermissions", "seenAsks"] {
            guard let old = defaults.stringArray(forKey: key) else { continue }
            if let control, defaults.stringArray(forKey: "\(key).\(control.id)") == nil {
                defaults.set(old, forKey: "\(key).\(control.id)")
            }
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Demo

    func demo(status: String, asks: AskReading, messages: [AgentMessage], timeline: [ControlEntry],
              permissions: [PermissionRequest] = [], needsInput: Bool = false) {
        self.status = status
        self.asks = asks
        self.messages = messages
        self.timeline = timeline
        self.permissions = permissions
        self.needsInput = needsInput
    }
}
