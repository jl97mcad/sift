import AppKit
import CoreServices
import Foundation

/// Small command surface so an agent can configure Sift without touching the UI.
enum CLI {
    static func run(arguments: [String]) {
        if arguments.first == "companion" {
            exit(companion(Array(arguments.dropFirst())))
        }
        let semaphore = DispatchSemaphore(value: 0)
        var status: Int32 = 0
        Task.detached {
            status = await dispatch(arguments)
            semaphore.signal()
        }
        semaphore.wait()
        exit(status)
    }

    private static func dispatch(_ arguments: [String]) async -> Int32 {
        guard let command = arguments.first else {
            print(usage)
            return 0
        }
        let rest = Array(arguments.dropFirst())
        do {
            switch command {
            case "setup": return try await setup(rest)
            case "bootstrap": return try await bootstrap(rest)
            case "login": return try await login(rest)
            case "logout": return logout()
            case "status": return try await status(rest)
            case "chats": return try await chats(rest)
            case "messages": return try await messagesCommand(rest)
            case "pins": return try await pins(rest)
            case "control": return try await control(rest)
            case "doctor": return try await doctor(rest)
            case "open": return openApp()
            case "selftest": return selftest()
            case "help", "--help", "-h": print(usage); return 0
            default:
                return fail("Unknown command '\(command)'. Try sift help.")
            }
        } catch {
            return fail(error.localizedDescription)
        }
    }

    // MARK: - Commands

    private static func setup(_ args: [String]) async throws -> Int32 {
        let flags = Flags(args)
        let store = TokenStore()
        guard let appId = flags.value("--app-id"), !appId.isEmpty else {
            return fail("setup needs --app-id. Find both values at open.larksuite.com → your app → Credentials & Basic Info")
        }
        var secret = flags.value("--app-secret")
        if secret == nil, let path = flags.value("--app-secret-file") {
            secret = try? String(contentsOfFile: path, encoding: .utf8)
        }
        if secret == nil || secret == "-" {
            secret = readStdinLine()
        }
        guard let appSecret = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !appSecret.isEmpty else {
            return fail("No app secret given. Use --app-secret-file, --app-secret - (stdin) or --from-lark-cli")
        }
        store.setCredentials(TokenStore.Credentials(appId: appId, appSecret: appSecret))
        return ok(["ok": true, "app_id": appId, "stored": "~/Library/Application Support/Sift/credentials.json"])
    }

    /// One command for another person's agent: store credentials, start the
    /// device flow, and optionally set the Control seat.
    private static func bootstrap(_ args: [String]) async throws -> Int32 {
        let flags = Flags(args)
        guard let appId = flags.value("--app-id"), !appId.isEmpty else {
            return fail("bootstrap needs --app-id (and the secret on stdin)")
        }
        var secret = flags.value("--app-secret")
        if secret == nil, let path = flags.value("--app-secret-file") {
            secret = try? String(contentsOfFile: path, encoding: .utf8)
        }
        if secret == nil || secret == "-" {
            secret = readStdinLine()
        }
        guard let appSecret = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !appSecret.isEmpty else {
            return fail("No app secret given. Pipe it on stdin: printf '%s' \"$SECRET\" | sift bootstrap --app-id ...")
        }

        let tokens = TokenStore()
        tokens.setCredentials(TokenStore.Credentials(appId: appId, appSecret: appSecret))

        let api = LarkAPI(tokens: tokens)
        let code = try await api.startDeviceFlow()

        var payload: [String: Any] = [
            "ok": true,
            "app_id": appId,
            "user_code": code.userCode,
            "verification_url": code.verifyURL.absoluteString,
            "device_code": code.deviceCode,
            "expires_in": code.expiresIn,
            "next": "sift login --device-code \(code.deviceCode)"
        ]

        if let agentId = flags.value("--agent-id") {
            let host = flags.value("--host")
            if let info = await PaseoClient().info(agentId: agentId, host: host) {
                let seat = ControlSeat(agentId: agentId, title: flags.value("--title") ?? info.title, host: host)
                StateFile.shared.update { $0.control = seat }
                payload["control"] = ["agent_id": seat.agentId, "title": seat.title,
                                      "host": host ?? "", "status": info.status]
            } else {
                payload["control_error"] = "No Paseo session found for \(agentId) on \(host ?? "this Mac")"
            }
        }
        return ok(payload)
    }

    private static func login(_ args: [String]) async throws -> Int32 {
        let flags = Flags(args)
        let api = LarkAPI(tokens: TokenStore())
        if let code = flags.value("--device-code") {
            let pending = DeviceCode(
                deviceCode: code,
                userCode: flags.value("--user-code") ?? "",
                verifyURL: URL(string: flags.value("--verify-url") ?? "https://open.larksuite.com")!,
                interval: Int(flags.value("--interval") ?? "5") ?? 5,
                expiresIn: Int(flags.value("--expires") ?? "240") ?? 240
            )
            try await api.pollDeviceFlow(pending)
            return try await printSignedIn(api)
        }

        let code = try await api.startDeviceFlow()
        if flags.has("--no-wait") {
            return ok([
                "ok": true,
                "user_code": code.userCode,
                "verification_url": code.verifyURL.absoluteString,
                "device_code": code.deviceCode,
                "expires_in": code.expiresIn,
                "interval": code.interval,
                "next": "sift login --device-code \(code.deviceCode)"
            ])
        }
        try await api.pollDeviceFlow(code)
        return try await printSignedIn(api)
    }

    private static func printSignedIn(_ api: LarkAPI) async throws -> Int32 {
        var payload: [String: Any] = ["ok": true, "signed_in": true]
        if let me = try? await api.userInfo() {
            StateFile.shared.update { $0.meOpenId = me.openId }
            await api.setMeId(me.openId)
            payload["user"] = ["name": me.name, "open_id": me.openId]
        }
        return ok(payload)
    }

    private static func logout() -> Int32 {
        TokenStore().setTokens(nil)
        return ok(["ok": true, "signed_out": true])
    }

    private static func status(_ args: [String]) async throws -> Int32 {
        let store = TokenStore()
        var payload: [String: Any] = ["ok": true]
        payload["app_id"] = store.credentials?.appId ?? NSNull()
        guard let tokens = store.tokens else {
            payload["signed_in"] = false
            return ok(payload)
        }
        payload["signed_in"] = true
        payload["expires_at"] = ISO8601DateFormatter().string(from: tokens.expiresAt)
        payload["refresh_expires_at"] = ISO8601DateFormatter().string(from: tokens.refreshExpiresAt)
        let api = LarkAPI(tokens: store)
        if let me = try? await api.userInfo() {
            payload["user"] = ["name": me.name, "open_id": me.openId]
        } else {
            payload["user"] = NSNull()
        }
        return ok(payload)
    }

    private static func chats(_ args: [String]) async throws -> Int32 {
        let flags = Flags(args)
        let limit = Int(flags.value("--limit") ?? "20") ?? 20
        let api = LarkAPI(tokens: TokenStore())
        let listed = try await api.listChats()
        let slice = listed.chats.prefix(limit)
        let rows: [[String: Any]] = slice.map { chat in
            [
                "chat_id": chat.id,
                "name": chat.name,
                "type": chat.isP2P ? "p2p" : (chat.isTopic ? "topic" : "group"),
                "avatar": chat.avatar?.absoluteString ?? NSNull()
            ]
        }
        return ok(["ok": true, "count": listed.chats.count, "chats": rows])
    }

    private static func messagesCommand(_ args: [String]) async throws -> Int32 {
        let flags = Flags(args)
        guard let chatId = flags.value("--chat-id") else {
            return fail("messages needs --chat-id (see sift chats)")
        }
        let limit = Int(flags.value("--limit") ?? "10") ?? 10
        let page = try await LarkAPI(tokens: TokenStore()).messages(chatId: chatId, pageSize: min(50, max(1, limit)))
        let rows: [[String: Any]] = page.messages.suffix(limit).map { message in
            [
                "id": message.id,
                "type": message.type,
                "text": message.text,
                "ts": message.ts,
                "mine": message.isMine,
                "image_key": message.imageKey ?? NSNull(),
                "file_name": message.fileName ?? NSNull()
            ]
        }
        return ok(["ok": true, "count": rows.count, "has_more": page.next != nil, "messages": rows])
    }

    private static func pins(_ args: [String]) async throws -> Int32 {
        let store = TokenStore()
        let state = StateFile.shared
        guard let sub = args.first else {
            return ok(["ok": true, "pinned": state.current.pinned])
        }
        switch sub {
        case "list":
            return ok(["ok": true, "pinned": state.current.pinned])
        case "add":
            guard args.count > 1 else { return fail("pins add needs a chat id or --name") }
            var target = args[1]
            if target.hasPrefix("--name") {
                let needle = args.count > 2 ? args[2] : ""
                let api = LarkAPI(tokens: store)
                let listed = try await api.listChats()
                guard let match = listed.chats.first(where: { $0.name.caseInsensitiveCompare(needle) == .orderedSame })
                        ?? listed.chats.first(where: { $0.name.localizedCaseInsensitiveContains(needle) }) else {
                    return fail("No chat matching '\(needle)'")
                }
                target = match.id
            }
            var pinned = state.current.pinned
            guard !pinned.contains(target) else {
                return ok(["ok": true, "pinned": pinned, "note": "already pinned"])
            }
            guard pinned.count < 10 else { return fail("Ten pins is the limit") }
            pinned.append(target)
            state.update { $0.pinned = pinned }
            return ok(["ok": true, "pinned": pinned])
        case "remove", "rm":
            guard args.count > 1 else { return fail("pins remove needs a chat id") }
            let pinned = state.current.pinned.filter { $0 != args[1] }
            state.update { $0.pinned = pinned }
            return ok(["ok": true, "pinned": pinned])
        case "clear":
            state.update { $0.pinned = [] }
            return ok(["ok": true, "pinned": []])
        default:
            return fail("Unknown pins command '\(sub)'")
        }
    }

    private static func control(_ args: [String]) async throws -> Int32 {
        let state = StateFile.shared
        guard let sub = args.first else {
            return ok(controlStatus(state))
        }
        switch sub {
        case "status":
            return ok(controlStatus(state))
        case "set", "add":
            let flags = Flags(args)
            guard let agentId = flags.value("--agent-id") ?? (args.count > 1 && !args[1].hasPrefix("--") ? args[1] : nil) else {
                return fail("control set needs --agent-id <paseo session id>")
            }
            let client = PaseoClient()
            guard PaseoClient.isAvailable else { return fail("Paseo is not installed") }
            guard let info = await client.info(agentId: agentId, host: flags.value("--host")) else {
                return fail("No Paseo session found for \(agentId)")
            }
            let seat = ControlSeat(agentId: agentId, title: flags.value("--title") ?? info.title,
                                   host: flags.value("--host"),
                                   provider: flags.value("--provider") ?? AgentProviders.fallback)
            state.update { $0.control = seat }
            return ok(["ok": true, "control": ["agent_id": seat.agentId, "title": seat.title, "status": info.status]])
        case "options", "find":
            let options = await PaseoClient().controlOptions()
            return ok(["ok": true, "options": options.map { ["id": $0.id, "name": $0.name] }])
        case "off", "remove", "disable":
            state.update { $0.control = nil }
            return ok(["ok": true, "control": NSNull()])
        case "send":
            guard let seat = state.current.control else { return fail("No Control seat configured") }
            let text = args.dropFirst().filter { !$0.hasPrefix("--") }.joined(separator: " ")
            guard !text.isEmpty else { return fail("control send needs a message") }
            try await AgentProviders.resolve(seat.provider)
                .send(id: seat.agentId, host: seat.host, text: text)
            return ok(["ok": true, "sent": true])
        case "digest":
            guard let seat = state.current.control else { return fail("No Control seat configured") }
            let reading = try await AgentProviders.resolve(seat.provider).readFollowing(seat, tail: 80, state: state).1
            let last = reading.messages.last { $0.isAssistant }
            return ok(["ok": true,
                       "activity": reading.activity ?? "",
                       "last": last.map { UpdateText.short($0.text) } ?? ""])
        case "logs":
            guard let seat = state.current.control else { return fail("No Control seat configured") }
            let flags = Flags(args)
            let tail = Int(flags.value("--tail") ?? "12") ?? 12
            // Tool calls fill most timeline entries; read a wider bounded window for `tail` messages.
            let messages = try await AgentProviders.resolve(seat.provider)
                .readFollowing(seat, tail: min(200, max(80, tail * 10)), state: state).1.messages
            let rows = messages.suffix(tail).map { ["role": $0.role, "text": $0.text] }
            return ok(["ok": true, "messages": rows])
        case "asks":
            guard let seat = state.current.control else { return fail("No Control seat configured") }
            let reading = try await AgentProviders.resolve(seat.provider).readFollowing(seat, tail: 1, state: state).1
            switch reading.asks {
            case .off: return ok(["ok": true, "configured": false, "asks": []])
            case .unavailable(let reason): return fail("Asks unavailable: \(reason)")
            case .available(let asks):
                return ok(["ok": true, "configured": true, "asks": asks.map {
                    ["id": $0.id, "plan": $0.plan, "title": $0.title, "question": $0.question,
                     "recommendation": $0.recommendation, "link": $0.link?.absoluteString ?? ""] }])
            }
        default:
            return fail("Unknown control command '\(sub)'")
        }
    }

    private static func controlStatus(_ state: StateFile) -> [String: Any] {
        var payload: [String: Any] = ["ok": true, "paseo": PaseoClient.isAvailable]
        if let seat = state.current.control {
            payload["enabled"] = true
            payload["agent_id"] = seat.agentId
            payload["title"] = seat.title
        } else {
            payload["enabled"] = false
        }
        return payload
    }

    private static func companion(_ args: [String]) -> Int32 {
        let state = StateFile.shared
        guard let sub = args.first else {
            return companionStatus(state)
        }
        switch sub {
        case "status":
            return companionStatus(state)
        case "set":
            let flags = Flags(args)
            guard let raw = flags.value("--url") else {
                return fail("companion set needs --url <http(s)://host[:port]>")
            }
            guard let url = CompanionConfig.validatedURL(raw) else {
                return fail("Companion URL must be an absolute http or https URL")
            }
            state.update { $0.companionURL = url.absoluteString }
            return ok(["ok": true, "url": url.absoluteString])
        case "open":
            guard let raw = state.current.companionURL,
                  let base = CompanionConfig.validatedURL(raw) else {
                return fail("No Companion URL configured. Run sift companion set --url http://host:port")
            }
            let path = CompanionPath.accepted(Flags(args).value("--path"))
            guard let target = CompanionConfig.targetURL(base: base, path: path) else {
                return fail("Could not build the Companion URL")
            }
            guard let openURL = companionOpenURL(path: path) else {
                return fail("Could not build the Companion window URL")
            }
            LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
            guard NSWorkspace.shared.open(openURL) else {
                return fail("Could not open the Companion window")
            }
            return ok(["ok": true, "url": target.absoluteString, "path": path])
        default:
            return fail("Unknown companion command '\(sub)'")
        }
    }

    private static func companionStatus(_ state: StateFile) -> Int32 {
        var payload: [String: Any] = ["ok": true]
        guard let raw = state.current.companionURL else {
            payload["url"] = NSNull()
            payload["session_cookie"] = NSNull()
            payload["session_cookie_state"] = "unconfigured"
            return ok(payload)
        }
        payload["url"] = raw
        guard let base = CompanionConfig.validatedURL(raw) else {
            payload["valid"] = false
            payload["session_cookie"] = NSNull()
            payload["session_cookie_state"] = "unknown"
            return ok(payload)
        }
        if let signedIn = companionSessionStatus(for: base) {
            payload["session_cookie"] = signedIn
            payload["session_cookie_state"] = "checked"
        } else {
            payload["session_cookie"] = NSNull()
            payload["session_cookie_state"] = "unknown"
        }
        return ok(payload)
    }

    /// The CLI cannot read the app's live WebKit cookie store, so ask a running
    /// Sift with the same support directory. nil means no app answered.
    private static func companionSessionStatus(for base: URL) -> Bool? {
        let request = UUID().uuidString
        let prefix = "companion-status-\(request)-"
        let directory = AppPaths.supportDirectory
        let fileManager = FileManager.default
        DistributedNotificationCenter.default().post(
            name: .companionStatusRequest,
            object: nil,
            userInfo: [
                "id": request,
                "url": base.absoluteString,
                "home": directory.path
            ]
        )
        let deadline = Date().addingTimeInterval(1.5)
        var sawResponse = false
        var signedIn = false
        while Date() < deadline {
            if let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                for file in files where file.lastPathComponent.hasPrefix(prefix) {
                    sawResponse = true
                    if let data = try? Data(contentsOf: file),
                       let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let value = reply["session_cookie"] as? Bool {
                        signedIn = signedIn || value
                    }
                    try? fileManager.removeItem(at: file)
                }
            }
            if signedIn { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix(prefix) {
                try? fileManager.removeItem(at: file)
            }
        }
        if signedIn { return true }
        return sawResponse ? false : nil
    }

    private static func companionOpenURL(path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "sift"
        components.host = "companion"
        components.path = "/open"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url
    }

    private static func doctor(_ args: [String]) async throws -> Int32 {
        let store = TokenStore()
        var checks: [[String: Any]] = []
        let creds = store.credentials
        checks.append(["check": "app credentials", "ok": creds != nil,
                       "detail": creds.map { "app id \($0.appId)" } ?? "run sift setup"])
        let tokenOK = (try? await LarkAPI(tokens: store).accessToken()) != nil
        checks.append(["check": "user token", "ok": tokenOK,
                       "detail": tokenOK ? "valid or refreshed" : "run sift login"])
        if tokenOK {
            do {
                let api = LarkAPI(tokens: store)
                let listed = try await api.listChats()
                let p2p = listed.chats.filter(\.isP2P).count
                checks.append(["check": "chat list", "ok": true,
                               "detail": "\(listed.chats.count) chats, \(p2p) direct"])
            } catch {
                checks.append(["check": "chat list", "ok": false, "detail": error.localizedDescription])
            }
        }
        let allOK = checks.allSatisfy { $0["ok"] as? Bool == true }
        if allOK { return ok(["ok": true, "checks": checks]) }
        printJSON(["ok": false, "checks": checks])
        return 1
    }

    private static func selftest() -> Int32 {
        let visible = NSRect(x: 0, y: 0, width: 1600, height: 900)
        let size = NSSize(width: 340, height: 560)
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) {
            checks.append(["check": name, "ok": passed])
        }
        check("handle docked to right edge",
              PanelGeometry.rightEdge(size: NSSize(width: 72, height: 72), in: visible, margin: 10)
                == NSRect(x: 1518, y: 414, width: 72, height: 72))
        check("panel docked to right edge",
              PanelGeometry.rightEdge(size: size, in: visible, margin: 12)
                == NSRect(x: 1248, y: 170, width: 340, height: 560))
        check("partial name matches", SearchMatch.matches(name: "Morgan Ellis", query: "mor"))
        check("reordered words match", SearchMatch.matches(name: "Morgan Ellis", query: "ell mor"))
        check("punctuation-separated match", SearchMatch.matches(name: "Morgan Ellis", query: "mor-ell"))
        check("unrelated query rejected", !SearchMatch.matches(name: "Design Room", query: "finance"))
        let unseen = Preview(text: "x", ts: 0, messageId: "m2", fromMe: false)
        check("unknown baseline is not unread",
              !UnreadPolicy.isUnread(preview: unseen, lastSeenMessageId: nil, muted: false))
        check("new activity is unread",
              UnreadPolicy.isUnread(preview: unseen, lastSeenMessageId: "m1", muted: false))
        check("seen activity is read",
              !UnreadPolicy.isUnread(preview: unseen, lastSeenMessageId: "m2", muted: false))
        check("own message is read",
              !UnreadPolicy.isUnread(preview: Preview(text: "x", ts: 0, messageId: "m9", fromMe: true),
                                     lastSeenMessageId: "m1", muted: false))

        let allOK = checks.allSatisfy { $0["ok"] as? Bool == true }
        if allOK { return ok(["ok": true, "checks": checks]) }
        printJSON(["ok": false, "checks": checks])
        return 1
    }

    private static func openApp() -> Int32 {
        let bundle = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: bundle, configuration: config) { _, error in
            if let error { FileHandle.standardError.write(Data("open failed: \(error.localizedDescription)\n".utf8)) }
            semaphore.signal()
        }
        semaphore.wait()
        return ok(["ok": true, "opened": bundle.path])
    }

    // MARK: - Output

    private static func ok(_ payload: [String: Any]) -> Int32 {
        printJSON(payload)
        return 0
    }

    private static func fail(_ message: String) -> Int32 {
        printJSON(["ok": false, "error": message])
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 1
    }

    private static func printJSON(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        print(text)
    }

    private static func readStdinLine() -> String? {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let usage = """
    sift — configure and inspect Sift from the terminal

    USAGE
      sift <command> [flags]

    COMMANDS
      bootstrap Credentials + sign-in code + optional Control seat in one call
                  printf '%s' "$SECRET" | sift bootstrap --app-id ID
                    [--agent-id ID --host tcp://host:6767]
      setup     Store the Lark app id and secret
                  --app-id ID --app-secret-file PATH   read secret from a file
                  --app-id ID --app-secret -           read secret from stdin
      login     Sign in with the device flow
                  --no-wait                            print the code and exit
                  --device-code CODE                   finish a previous --no-wait
      status    JSON: signed in, app id, token expiry, user
      chats     JSON: your chats (--limit N, default 20)
      messages  JSON: history for a chat (--chat-id oc_xxx --limit N)
      pins      list | add <chat_id> | add --name "Design" | remove <chat_id> | clear
      control   Optional Paseo seat pinned above your chats
                  set --agent-id ID [--host H] [--provider paseo] [--title T]
                  status | send "text" | logs [--tail N] | digest | asks | off
      companion Open the real Companion web app in its own Sift window
                  set --url http://host:port
                  status | open [--path /companion/app/...]
      doctor    Check credentials, token and chat access
      open      Open the Sift app
      logout    Forget the current session

    All commands print JSON on stdout and exit 1 on failure.
    """
}

private struct Flags {
    let args: [String]
    init(_ args: [String]) { self.args = args }

    func value(_ name: String) -> String? {
        guard let index = args.firstIndex(of: name), args.count > index + 1 else { return nil }
        return args[index + 1]
    }

    func has(_ name: String) -> Bool { args.contains(name) }
}
