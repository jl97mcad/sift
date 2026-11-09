import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ConversationView: View {
    @Environment(\.larkAccent) private var accent
    @EnvironmentObject var store: Store
    @Environment(\.siftReduceMotion) private var reduceMotion
    let chat: Chat
    @State private var importing = false
    @FocusState private var composing: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            messageScroll
            Divider().opacity(0.2)
            composer
            if let error = store.errorText {
                ErrorBar(text: error)
            }
        }
        .task {
            if store.focusComposer {
                store.focusComposer = false
                try? await Task.sleep(nanoseconds: 150_000_000)
                composing = true
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            let target = chat.id
            for (index, provider) in providers.enumerated() {
                let name = provider.suggestedName ?? "Dropped item \(index + 1)"
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    DispatchQueue.main.async {
                        guard let url else {
                            store.reportUnsent(["\(name): \(error?.localizedDescription ?? "Sift could not read this item as a file")"])
                            return
                        }
                        Task { await store.sendAttachment(url, to: target) }
                    }
                }
            }
            return true
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AvatarView(chat: chat, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(chat.displayName).font(.system(size: 16, weight: .semibold)).lineLimit(1).help(chat.name)
                Text((chat.isP2P ? "Lark · Direct message" : "Lark · Group conversation") + chat.tags.map { " · " + $0 }.joined())
                    .font(.system(size: 11)).foregroundStyle(SiftStyle.secondary)
            }
            .panelDragHandle().help("Drag to move Sift")
            Spacer(minLength: 0)
            if let link = chat.link {
                IconButton(symbol: "arrow.up.forward.app", help: "Open in Lark") {
                    NSWorkspace.shared.open(link)
                }
            }
        }
        .padding(.horizontal, 16).frame(height: 76)
    }

    private var messageScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.canLoadOlder {
                        Button {
                            Task { await store.loadOlder() }
                        } label: {
                            if store.loadingOlder {
                                ProgressView().controlSize(.mini)
                            } else {
                                Text("Earlier messages").font(.system(size: 12))
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                    }
                    if store.messages[chat.id] == nil {
                        PaneEmptyState(symbol: store.errorText == nil ? "bubble.left" : "exclamationmark.bubble",
                            title: store.errorText == nil ? "Loading conversation" : "Conversation unavailable",
                            detail: store.errorText == nil ? "Fetching messages from Lark." : "Open the chat again to retry.")
                    } else if store.messages[chat.id]?.isEmpty == true {
                        PaneEmptyState(symbol: "bubble.left", title: "Start a conversation", detail: "Your messages will appear here.")
                    }
                    ForEach(Array((store.messages[chat.id] ?? []).enumerated()), id: \.element.id) { index, message in
                        let previous = index > 0 ? store.messages[chat.id]?[index - 1] : nil
                        let list = store.messages[chat.id] ?? []
                        let next = index + 1 < list.count ? list[index + 1] : nil
                        if isNewDay(previous, message) {
                            Text(TimeFormat.day(message.ts))
                                .font(.system(size: 11))
                                .foregroundStyle(SiftStyle.muted)
                                .padding(.vertical, 6)
                        }
                        MessageBubble(message: message, isGroup: !chat.isP2P,
                                      senderName: store.memberNames[message.sender.id] ?? (message.fromApp ? "Bot" : ""),
                                      quote: quote(for: message, in: list), chatLink: chat.link,
                                      showSender: !message.groups(with: previous),
                                      showTimestamp: !message.groups(with: next))
                            .padding(.top, message.groups(with: previous) ? 4 : 10)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .scrollIndicators(.never)
            // Open at the newest message; a fresh identity per chat keeps a switch from
            // animating through another chat's history.
            .defaultScrollAnchor(.bottom)
            .id(chat.id)
            .onChange(of: (store.messages[chat.id] ?? []).last?.id) { old, _ in
                guard old != nil else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 6) {
                IconButton(symbol: "paperclip", help: "Attach a file") { importing = true }
                TextField("Message", text: Binding(
                    get: { store.draft(for: chat.id) },
                    set: { store.setDraft($0, for: chat.id) }
                ), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(2...5)
                    .frame(minHeight: 44, alignment: .topLeading)
                    .focused($composing)
                    .accessibilityLabel("Message \(chat.displayName)")
                    .onSubmit {
                        if canSend { Task { await store.send() } }
                    }
                Button {
                    Task { await store.send() }
                } label: {
                    Image(systemName: store.sending ? "clock" : "arrow.up")
                        .font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28)
                        .foregroundStyle(canSend ? Color.black : SiftStyle.muted)
                        .background(canSend ? Color.white : Color.white.opacity(0.05), in: Circle())
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
                .help("Send message (⌘Return)").accessibilityLabel("Send message")
            }
            .composerSurface().padding(.bottom, 12)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            if case let .success(url) = result {
                let target = chat.id
                let accessed = url.startAccessingSecurityScopedResource()
                Task {
                    await store.sendAttachment(url, to: target)
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
            }
        }
    }

    /// "Name: what they said" for a reply whose parent is loaded; a plain marker otherwise.
    private func quote(for message: ChatMessage, in list: [ChatMessage]) -> String? {
        guard let parentId = message.parentId else { return nil }
        guard let parent = list.first(where: { $0.id == parentId }) else { return "Reply to an earlier message" }
        let name = parent.isMine ? "You" : store.memberNames[parent.sender.id] ?? ""
        let text = UpdateText.short(parent.text, limit: 80)
        return name.isEmpty ? text : "\(name): \(text)"
    }

    private func isNewDay(_ previous: ChatMessage?, _ message: ChatMessage) -> Bool {
        guard let previous else { return false }
        let before = Date(timeIntervalSince1970: TimeInterval(previous.ts) / 1000)
        let current = Date(timeIntervalSince1970: TimeInterval(message.ts) / 1000)
        return !Calendar.current.isDate(before, inSameDayAs: current)
    }

    private var canSend: Bool {
        !store.draft(for: chat.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.sending
    }
}

struct MessageBubble: View {
    @Environment(\.larkAccent) private var accent
    let message: ChatMessage
    let isGroup: Bool
    var senderName: String = ""
    var quote: String? = nil
    var chatLink: URL? = nil
    var showSender = true
    var showTimestamp = true

    var body: some View {
        HStack {
            if message.isMine { Spacer(minLength: 44) }
            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 3) {
                if showSender, isGroup, !message.isMine, message.type != "system", !senderName.isEmpty {
                    Text(senderName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if let quote {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 1).fill(SiftStyle.muted).frame(width: 2)
                            Text(quote).font(.system(size: 11)).foregroundStyle(SiftStyle.secondary).lineLimit(2)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    content
                }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(message.isMine ? accent.opacity(0.16) : SiftStyle.raised)
                    )
                if showTimestamp || message.deleted || message.edited || message.threadId != nil {
                    HStack(spacing: 4) {
                        if message.deleted {
                            Text("recalled").font(.system(size: 11)).foregroundStyle(SiftStyle.muted)
                        } else if message.edited {
                            Text("edited").font(.system(size: 11)).foregroundStyle(SiftStyle.muted)
                        }
                        if message.threadId != nil {
                            Text("in a thread").font(.system(size: 11)).foregroundStyle(SiftStyle.muted)
                        }
                        if showTimestamp { Text(TimeFormat.clock(message.ts)).font(.system(size: 11)).foregroundStyle(SiftStyle.muted) }
                    }
                }
            }
            if !message.isMine { Spacer(minLength: 44) }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if let media = message.media {
            MediaContent(message: message, media: media, chatLink: chatLink)
        } else if let imageKey = message.imageKey {
            ResourceImage(messageId: message.id, fileKey: imageKey)
        } else if message.fileKey != nil {
            ResourceFile(message: message)
        } else {
            Text(LinkedText.attributed(message.text))
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(message.imageKeys.prefix(6), id: \.self) { key in
                ResourceImage(messageId: message.id, fileKey: key)
            }
            if message.imageKeys.count > 6 { LimitNote(text: "\(message.imageKeys.count - 6) more images in Lark", link: chatLink) }
        }
    }
}

/// Voice, video, stickers, shared chats and contacts, forwarded bundles and types Sift cannot draw.
struct MediaContent: View {
    @EnvironmentObject var store: Store
    let message: ChatMessage
    let media: LarkMedia
    let chatLink: URL?

    var body: some View {
        switch media {
        case .audio(let seconds):
            ResourceFile(message: message, title: joined("Voice message", LarkMedia.duration(seconds)), symbol: "waveform")
        case .video(let cover, let seconds):
            VStack(alignment: .leading, spacing: 6) {
                if let cover { ResourceImage(messageId: message.id, fileKey: cover) }
                ResourceFile(message: message, title: joined(message.fileName ?? "Video", LarkMedia.duration(seconds)), symbol: "film")
            }
        case .sticker:
            VStack(alignment: .leading, spacing: 4) {
                Label("Sticker", systemImage: "face.smiling").font(.system(size: 13))
                LimitNote(text: "Lark does not let apps load stickers.", link: chatLink)
            }
        case .sharedChat(let id):
            VStack(alignment: .leading, spacing: 4) {
                Label(joined("Shared group", store.chatName(id) ?? ""), systemImage: "person.3").font(.system(size: 13))
                if store.chatName(id) != nil {
                    Button("Open in Sift") { store.openLinkedChat(id) }.buttonStyle(.plain)
                        .font(.system(size: 12)).foregroundStyle(SiftStyle.green)
                } else { LimitNote(text: "You are not in this group.", link: nil) }
            }
        case .contact(let id):
            Label(joined("Contact card", store.memberNames[id] ?? ""), systemImage: "person.crop.square").font(.system(size: 13))
        case .forward:
            ForwardedView(message: message, chatLink: chatLink)
        case .other:
            VStack(alignment: .leading, spacing: 4) {
                Text(message.text).font(.system(size: 12.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                LimitNote(text: "Sift has no view for this yet.", link: chatLink)
            }
        }
    }

    private func joined(_ parts: String...) -> String { parts.filter { !$0.isEmpty }.joined(separator: " · ") }
}

/// A known limit, said plainly, with the way out.
struct LimitNote: View {
    let text: String
    let link: URL?

    var body: some View {
        HStack(spacing: 6) {
            Text(text).foregroundStyle(SiftStyle.muted)
            if let link { Link("Open in Lark", destination: link).foregroundStyle(SiftStyle.green) }
        }
        .font(.system(size: 11))
    }
}

/// Merged-and-forwarded messages, read only when opened.
struct ForwardedView: View {
    @EnvironmentObject var store: Store
    let message: ChatMessage
    let chatLink: URL?
    @State private var items: [ChatMessage]?
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Forwarded messages", systemImage: "arrowshape.turn.up.right").font(.system(size: 13))
            if let items {
                if items.isEmpty { LimitNote(text: "Lark returned no forwarded messages.", link: chatLink) }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        let name = item.isMine ? "You" : store.memberNames[item.sender.id] ?? ""
                        if !name.isEmpty { Text(name).font(.system(size: 10.5, weight: .medium)).foregroundStyle(SiftStyle.secondary) }
                        Text(item.type == "file" ? item.fileName ?? "File" : item.text).font(.system(size: 12))
                            .lineLimit(6).textSelection(.enabled)
                    }
                }
            } else if let failure {
                LimitNote(text: failure, link: chatLink)
            }
            if items == nil {
                Button(loading ? "Loading…" : failure == nil ? "Show them" : "Retry") { load() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(SiftStyle.green).disabled(loading)
            }
        }
    }

    private func load() {
        loading = true
        Task { @MainActor in
            defer { loading = false }
            do { items = try await store.forwarded(message); failure = nil }
            catch { failure = ResourceFailure.text(error, what: "forwarded messages") }
        }
    }
}

/// Lark refusing a resource (a missing grant) reads differently from a failed connection.
enum ResourceFailure {
    static func text(_ error: Error, what: String) -> String {
        if let api = error as? APIError, api.status == 403 || api.message.localizedCaseInsensitiveContains("permission") {
            return "Lark does not give this app access to these \(what)."
        }
        return "Could not load the \(what). Check the connection and retry."
    }
}

struct ResourceImage: View {
    @EnvironmentObject var store: Store
    let messageId: String
    let fileKey: String
    @State private var image: NSImage?
    @State private var failure: String?
    @State private var attempt = 0

    /// Decoded thumbnails, not full images: bounded in count and memory.
    private static let thumbnails: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 150
        return cache
    }()

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 190, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onTapGesture { Task { await open() } }
                    .help("Open the full image")
                    .contextMenu {
                        Button("Open") { Task { await open() } }
                        Button("Save Image…") { Task { await save() } }
                        Button("Copy Image") { Task { await copy() } }
                    }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                    VStack(spacing: 4) {
                        Image(systemName: failure == nil ? "photo.badge.arrow.down" : "photo")
                            .font(.system(size: 16))
                        if let failure {
                            Text(failure).font(.system(size: 10)).multilineTextAlignment(.center).padding(.horizontal, 8)
                            Button("Retry") { self.failure = nil; attempt += 1 }.buttonStyle(.plain).font(.system(size: 11))
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                .frame(width: 150, height: 100)
            }
        }
        .task(id: "\(messageId)/\(fileKey)/\(attempt)") {
            let key = "\(messageId)/\(fileKey)" as NSString
            if let hit = Self.thumbnails.object(forKey: key) { image = hit; return }
            do {
                let data = try await store.api.imageData(messageId: messageId, key: fileKey)
                guard let thumbnail = Self.thumbnail(data) else { failure = "Lark sent an image Sift cannot read."; return }
                Self.thumbnails.setObject(thumbnail, forKey: key)
                image = thumbnail
            } catch {
                failure = ResourceFailure.text(error, what: "image")
            }
        }
    }

    /// Downsampled once while decoding, at twice the shown size for Retina.
    static func thumbnail(_ data: Data, maxPixels: Int = 440) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
    }

    private func original() async -> (Data, String)? {
        guard let data = try? await store.api.imageData(messageId: messageId, key: fileKey) else {
            failure = "Could not load the full image. Retry."
            return nil
        }
        let type = CGImageSourceCreateWithData(data as CFData, nil).flatMap(CGImageSourceGetType) as String?
        let ext = type.flatMap { UTType($0)?.preferredFilenameExtension } ?? "png"
        return (data, ext)
    }

    private func open() async {
        guard let (data, ext) = await original() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sift-image-\(String(fileKey.filter { $0.isLetter || $0.isNumber || $0 == "_" }.suffix(60))).\(ext)")
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch { failure = error.localizedDescription }
    }

    private func save() async {
        guard let (data, ext) = await original() else { return }
        let chooser = NSSavePanel()
        chooser.nameFieldStringValue = "Image.\(ext)"
        guard chooser.runModal() == .OK, let url = chooser.url else { return }
        do { try data.write(to: url, options: .atomic) } catch { failure = error.localizedDescription }
    }

    private func copy() async {
        guard let (data, _) = await original(), let full = NSImage(data: data) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([full])
    }
}

struct ResourceFile: View {
    @EnvironmentObject var store: Store
    let message: ChatMessage
    var title: String? = nil
    var symbol = "doc"
    @State private var download: Task<Void, Never>?
    @State private var failure: String?
    @State private var saved: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title ?? message.fileName ?? "File", systemImage: symbol)
                .font(.system(size: 13)).lineLimit(2)
            if download != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Downloading…").font(.system(size: 12))
                    Button("Cancel") { download?.cancel() }.buttonStyle(.plain)
                }
            } else if let saved {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(SiftStyle.green)
            } else {
                Button(failure == nil ? "Save file…" : "Retry download…", action: chooseDestination)
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(SiftStyle.green)
            }
            if let failure { Text(failure).font(.system(size: 11)).foregroundStyle(SiftStyle.secondary) }
        }
        .onDisappear { download?.cancel() }
    }

    private func chooseDestination() {
        guard download == nil else { return }
        let chooser = NSSavePanel()
        chooser.nameFieldStringValue = URL(fileURLWithPath: message.fileName ?? "File").lastPathComponent
        chooser.canCreateDirectories = true
        guard chooser.runModal() == .OK, let destination = chooser.url else { return }
        failure = nil
        download = Task { @MainActor in
            defer { download = nil }
            do {
                try await store.saveFile(message, to: destination)
                saved = destination
            } catch is CancellationError { failure = "Download cancelled. You can retry." }
            catch {
                failure = Task.isCancelled ? "Download cancelled. You can retry." : error.localizedDescription
            }
        }
    }
}
