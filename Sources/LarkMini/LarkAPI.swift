import Foundation

struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

actor LarkAPI {
    private let tokens: TokenStore
    private let session: URLSession
    private let openBase = URL(string: "https://open.larksuite.com")!
    private let accountsBase = URL(string: "https://accounts.larksuite.com")!
    private var refreshing: Task<String, Error>?
    private var meOpenId: String = StateFile.shared.current.meOpenId

    func setMeId(_ id: String) {
        meOpenId = id
    }

    var scopeList: String {
        [
            "im:chat:read",
            "im:message",
            "im:message.p2p_msg:get_as_user",
            "im:message.group_msg:get_as_user",
            "im:chat.members:read",
            "im:resource",
            "im:message.send_as_user",
            "contact:user.base:readonly",
            "offline_access"
        ].joined(separator: " ")
    }

    init(tokens: TokenStore) {
        self.tokens = tokens
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = ["User-Agent": "LarkMini/0.1"]
        session = URLSession(configuration: config)
    }

    // MARK: - Auth

    func hasSession() -> Bool {
        tokens.tokens != nil
    }

    func accessToken() async throws -> String {
        guard let current = tokens.tokens else {
            throw APIError(status: 401, message: "Not signed in")
        }
        if current.expiresAt.timeIntervalSinceNow > 90 {
            return current.access
        }
        if let refreshing {
            return try await refreshing.value
        }
        let task = Task<String, Error> { try await self.performRefresh(current) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func performRefresh(_ current: TokenStore.Tokens) async throws -> String {
        guard let creds = tokens.credentials else {
            throw APIError(status: 401, message: "Missing app credentials")
        }
        guard current.refreshExpiresAt > Date() else {
            tokens.setTokens(nil)
            throw APIError(status: 401, message: "Session expired, sign in again")
        }
        var req = URLRequest(url: openBase.appendingPathComponent("open-apis/authen/v2/oauth/token"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = [
            .init(name: "grant_type", value: "refresh_token"),
            .init(name: "client_id", value: creds.appId),
            .init(name: "client_secret", value: creds.appSecret),
            .init(name: "refresh_token", value: current.refresh)
        ]
        req.httpBody = Data((comps.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await session.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let access = json["access_token"] as? String else {
            let code = json["error"] as? String ?? ""
            let msg = json["error_description"] as? String ?? (code.isEmpty ? "Token refresh failed" : code)
            // A 429/5xx/captive portal must not sign the user out.
            if ["invalid_grant", "invalid_refresh_token", "refresh_token_expired"].contains(code) {
                tokens.setTokens(nil)
            }
            throw APIError(status: 401, message: msg)
        }
        let updated = TokenStore.Tokens(
            access: access,
            refresh: json["refresh_token"] as? String ?? current.refresh,
            expiresAt: Date().addingTimeInterval(TimeInterval(json["expires_in"] as? Int ?? 7200)),
            refreshExpiresAt: Date().addingTimeInterval(TimeInterval(json["refresh_token_expires_in"] as? Int ?? 604800)),
            scope: json["scope"] as? String ?? current.scope
        )
        tokens.setTokens(updated)
        return updated.access
    }

    func startDeviceFlow() async throws -> DeviceCode {
        guard let creds = tokens.credentials else {
            throw APIError(status: 400, message: "Add the app credentials first")
        }
        var req = URLRequest(url: accountsBase.appendingPathComponent("oauth/v1/device_authorization"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let basic = Data("\(creds.appId):\(creds.appSecret)".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        var comps = URLComponents()
        comps.queryItems = [
            .init(name: "client_id", value: creds.appId),
            .init(name: "scope", value: scopeList)
        ]
        req.httpBody = Data((comps.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await session.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String else {
            let msg = json["error_description"] as? String ?? json["error"] as? String ?? "Could not start sign-in"
            throw APIError(status: (response as? HTTPURLResponse)?.statusCode ?? 400, message: msg)
        }
        let verifyString = (json["verification_uri_complete"] as? String)
            ?? (json["verification_uri"] as? String)
            ?? ""
        guard let verifyURL = URL(string: verifyString) else {
            throw APIError(status: 400, message: "Sign-in page missing from the response")
        }
        return DeviceCode(
            deviceCode: deviceCode,
            userCode: userCode,
            verifyURL: verifyURL,
            interval: json["interval"] as? Int ?? 5,
            expiresIn: json["expires_in"] as? Int ?? 240
        )
    }

    func pollDeviceFlow(_ code: DeviceCode) async throws {
        guard let creds = tokens.credentials else {
            throw APIError(status: 400, message: "Missing app credentials")
        }
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        var interval = code.interval
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(min(max(interval, 1), 60)) * 1_000_000_000)
            var req = URLRequest(url: openBase.appendingPathComponent("open-apis/authen/v2/oauth/token"))
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var comps = URLComponents()
            comps.queryItems = [
                .init(name: "grant_type", value: "urn:ietf:params:oauth:grant-type:device_code"),
                .init(name: "device_code", value: code.deviceCode),
                .init(name: "client_id", value: creds.appId),
                .init(name: "client_secret", value: creds.appSecret)
            ]
            req.httpBody = Data((comps.percentEncodedQuery ?? "").utf8)
            let (data, _) = try await session.data(for: req)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let access = json["access_token"] as? String {
                tokens.setTokens(TokenStore.Tokens(
                    access: access,
                    refresh: json["refresh_token"] as? String ?? "",
                    expiresAt: Date().addingTimeInterval(TimeInterval(json["expires_in"] as? Int ?? 7200)),
                    refreshExpiresAt: Date().addingTimeInterval(TimeInterval(json["refresh_token_expires_in"] as? Int ?? 604800)),
                    scope: json["scope"] as? String ?? ""
                ))
                return
            }
            switch json["error"] as? String {
            case "authorization_pending":
                continue
            case "slow_down":
                interval = min(interval + 5, 60)
            case "access_denied":
                throw APIError(status: 403, message: "Sign-in was declined")
            case "expired_token", "invalid_grant":
                throw APIError(status: 400, message: "Code expired, try again")
            case let other?:
                throw APIError(status: 400, message: json["error_description"] as? String ?? other)
            case nil:
                continue
            }
        }
        throw APIError(status: 408, message: "Sign-in timed out")
    }

    // MARK: - Requests

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) async throws -> [String: Any] {
        let token = try await accessToken()
        var comps = URLComponents(url: openBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if status != 200 || (json["code"] as? Int ?? 0) != 0 {
            let message = json["msg"] as? String ?? "Request failed (\(status))"
            throw APIError(status: status, message: message)
        }
        return json["data"] as? [String: Any] ?? json
    }

    func userInfo() async throws -> Me {
        let data = try await request("open-apis/authen/v1/user_info")
        return Me(
            openId: data["open_id"] as? String ?? "",
            name: data["name"] as? String ?? "You",
            avatar: URL(string: data["avatar_url"] as? String ?? "")
        )
    }

    func listChats(pageToken: String? = nil, pageSize: Int = 100) async throws -> (chats: [Chat], next: String?) {
        var query: [URLQueryItem] = [
            .init(name: "page_size", value: String(pageSize)),
            .init(name: "types", value: "p2p,group"),
            .init(name: "sort", value: "active_time"),
            .init(name: "user_id_type", value: "open_id")
        ]
        if let pageToken { query.append(.init(name: "page_token", value: pageToken)) }
        let data = try await request("open-apis/im/v1/chats", query: query)
        let items = (data["items"] as? [[String: Any]]) ?? (data["chats"] as? [[String: Any]]) ?? []
        let hasMore = data["has_more"] as? Bool ?? false
        return (Self.parseChats(items), hasMore ? data["page_token"] as? String : nil)
    }

    /// open_id → display name for the people in a chat, so group bubbles can
    /// show who spoke. Messages themselves carry only the sender id.
    func chatMembers(chatId: String) async throws -> [String: String] {
        var names: [String: String] = [:]
        var pageToken: String?
        repeat {
            var query: [URLQueryItem] = [
                .init(name: "member_id_type", value: "open_id"),
                .init(name: "page_size", value: "100")
            ]
            if let pageToken { query.append(.init(name: "page_token", value: pageToken)) }
            let data = try await request("open-apis/im/v1/chats/\(chatId)/members", query: query)
            for item in data["items"] as? [[String: Any]] ?? [] {
                if let id = item["member_id"] as? String, let name = item["name"] as? String {
                    names[id] = name
                }
            }
            pageToken = (data["has_more"] as? Bool ?? false) ? data["page_token"] as? String : nil
        } while pageToken != nil
        return names
    }

    /// The contact profile endpoint refuses this app's user token, but user search
    /// (`contact:user:search`) returns avatars. Only an exact open_id match counts.
    func searchedAvatar(name: String, openId: String) async throws -> URL? {
        let data = try await request("open-apis/search/v1/user", query: [
            .init(name: "query", value: name), .init(name: "page_size", value: "20")])
        let users = (data["users"] as? [[String: Any]]) ?? (data["items"] as? [[String: Any]]) ?? []
        let avatar = users.first { $0["open_id"] as? String == openId }?["avatar"] as? [String: Any]
        return [avatar?["avatar_240"], avatar?["avatar_640"], avatar?["avatar_72"]]
            .compactMap { ($0 as? String).flatMap(URL.init(string:)) }.first { $0.scheme == "https" }
    }

    func chatDetail(_ chatId: String) async throws -> Chat? {
        let data = try await request("open-apis/im/v1/chats/\(chatId)",
                                     query: [.init(name: "user_id_type", value: "open_id")])
        // The detail body does not repeat chat_id; without it every detail parsed to nil.
        var object = (data["chat"] as? [String: Any]) ?? data
        object["chat_id"] = object["chat_id"] ?? chatId
        return Self.parseChats([object]).first
    }

    /// Group search only: Lark's search endpoint does not return direct chats.
    func searchChats(query text: String) async throws -> [Chat] {
        let data = try await request("open-apis/im/v1/chats/search", query: [
            .init(name: "query", value: text),
            .init(name: "page_size", value: "20"),
            .init(name: "user_id_type", value: "open_id")
        ])
        let items = (data["items"] as? [[String: Any]]) ?? (data["chats"] as? [[String: Any]]) ?? []
        return Self.parseChats(items)
    }

    private static func parseChats(_ items: [[String: Any]]) -> [Chat] {
        items.compactMap { item in
            guard let id = item["chat_id"] as? String else { return nil }
            let mode = item["chat_mode"] as? String ?? "group"
            return Chat(
                id: id,
                name: item["name"] as? String ?? "Untitled",
                avatar: URL(string: item["avatar"] as? String ?? ""),
                isP2P: mode == "p2p",
                isTopic: mode == "topic",
                detail: item["description"] as? String ?? "",
                link: URL(string: item["chat_app_link"] as? String ?? ""),
                peerId: item["p2p_target_id"] as? String
            )
        }
    }

    func messages(chatId: String, pageToken: String? = nil, pageSize: Int = 30) async throws -> (messages: [ChatMessage], next: String?) {
        var query: [URLQueryItem] = [
            .init(name: "container_id_type", value: "chat"),
            .init(name: "container_id", value: chatId),
            .init(name: "sort_type", value: "ByCreateTimeDesc"),
            .init(name: "page_size", value: String(pageSize))
        ]
        if let pageToken { query.append(.init(name: "page_token", value: pageToken)) }
        let data = try await request("open-apis/im/v1/messages", query: query)
        let items = data["items"] as? [[String: Any]] ?? []
        let parsed = items.compactMap { Self.parseMessage($0, chatId: chatId, meId: meOpenId) }.reversed()
        let hasMore = data["has_more"] as? Bool ?? false
        return (Array(parsed), hasMore ? data["page_token"] as? String : nil)
    }

    /// The messages inside a merged-and-forwarded message: Lark returns the container, then its children.
    func forwarded(messageId: String, chatId: String) async throws -> [ChatMessage] {
        let data = try await request("open-apis/im/v1/messages/\(messageId)", query: [.init(name: "user_id_type", value: "open_id")])
        let items = data["items"] as? [[String: Any]] ?? []
        return items.filter { $0["upper_message_id"] as? String == messageId }
            .compactMap { Self.parseMessage($0, chatId: chatId, meId: meOpenId) }
    }

    func latestMessage(chatId: String) async throws -> ChatMessage? {
        let page = try await messages(chatId: chatId, pageSize: 1)
        return page.messages.last
    }

    func sendText(chatId: String, text: String) async throws -> ChatMessage? {
        let payload: [String: Any] = [
            "receive_id": chatId,
            "msg_type": "text",
            "content": "{\"text\":\(jsonEscape(text))}",
            "uuid": UUID().uuidString.lowercased()
        ]
        return try await send(payload, chatId: chatId)
    }

    func sendImage(chatId: String, fileURL: URL) async throws -> ChatMessage? {
        let key = try await uploadImage(fileURL)
        let payload: [String: Any] = [
            "receive_id": chatId,
            "msg_type": "image",
            "content": "{\"image_key\":\"\(key)\"}"
        ]
        return try await send(payload, chatId: chatId)
    }

    func sendFile(chatId: String, fileURL: URL) async throws -> ChatMessage? {
        let key = try await uploadFile(fileURL)
        let payload: [String: Any] = [
            "receive_id": chatId,
            "msg_type": "file",
            "content": "{\"file_key\":\"\(key)\",\"file_name\":\(jsonEscape(fileURL.lastPathComponent))}"
        ]
        return try await send(payload, chatId: chatId)
    }

    private func send(_ payload: [String: Any], chatId: String) async throws -> ChatMessage? {
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await request("open-apis/im/v1/messages",
                                     method: "POST",
                                     query: [.init(name: "receive_id_type", value: "chat_id")],
                                     body: body)
        if let items = data["items"] as? [[String: Any]],
           let first = items.compactMap({ Self.parseMessage($0, chatId: chatId, meId: meOpenId) }).first {
            return first
        }
        return Self.parseMessage(data, chatId: chatId, meId: meOpenId)
    }

    func imageData(messageId: String, key: String) async throws -> Data {
        let token = try await accessToken()
        var req = URLRequest(url: Self.messageResourceURL(messageId: messageId, key: key, type: "image"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw APIError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "Could not load image")
        }
        return data
    }

    static func messageResourceURL(messageId: String, key: String, type: String) -> URL {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))
        let message = messageId.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let key = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        var components = URLComponents(string: "https://open.larksuite.com")!
        components.percentEncodedPath = "/open-apis/im/v1/messages/\(message)/resources/\(key)"
        components.queryItems = [.init(name: "type", value: type)]
        return components.url!
    }

    func downloadFile(messageId: String, key: String, to destination: URL) async throws {
        let token = try await accessToken()
        var request = URLRequest(url: Self.messageResourceURL(messageId: messageId, key: key, type: "file"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (download, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: download) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw APIError(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                           message: "Could not download file. Check the connection and Lark resource permission, then retry.")
        }
        try Task.checkCancellation()
        try Self.saveDownload(download, to: destination)
    }

    /// Stage beside the chosen file so a failed transfer cannot destroy an existing file.
    static func saveDownload(_ download: URL, to destination: URL) throws {
        let files = FileManager.default
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".sift-\(UUID().uuidString)")
        defer { try? files.removeItem(at: staged) }
        try files.copyItem(at: download, to: staged)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: staged, options: .usingNewMetadataOnly)
        } else { try files.moveItem(at: staged, to: destination) }
    }

    // MARK: - Uploads

    private func uploadImage(_ fileURL: URL) async throws -> String {
        let token = try await accessToken()
        let boundary = "----LarkMini\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image_type\"\r\n\r\nmessage\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: fileURL))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var req = URLRequest(url: openBase.appendingPathComponent("open-apis/im/v1/images"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, response) = try await session.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let payload = json["data"] as? [String: Any], let key = payload["image_key"] as? String else {
            throw APIError(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                           message: json["msg"] as? String ?? "Image upload failed")
        }
        return key
    }

    private func uploadFile(_ fileURL: URL) async throws -> String {
        let token = try await accessToken()
        let boundary = "----LarkMini\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file_type\"\r\n\r\nstream\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file_name\"\r\n\r\n\(fileURL.lastPathComponent)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: fileURL))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var req = URLRequest(url: openBase.appendingPathComponent("open-apis/im/v1/files"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, response) = try await session.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let payload = json["data"] as? [String: Any], let key = payload["file_key"] as? String else {
            throw APIError(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                           message: json["msg"] as? String ?? "File upload failed")
        }
        return key
    }

    // MARK: - Parsing

    private func jsonEscape(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let array = String(data: data ?? Data("[\"\"]".utf8), encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    static func parseMessage(_ raw: [String: Any], chatId: String, meId: String) -> ChatMessage? {
        guard let id = raw["message_id"] as? String else { return nil }
        let type = raw["msg_type"] as? String ?? "unknown"
        let body = raw["body"] as? [String: Any]
        let contentString = body?["content"] as? String ?? "{}"
        let content = (try? JSONSerialization.jsonObject(with: Data(contentString.utf8))) as? [String: Any] ?? [:]
        let senderDict = raw["sender"] as? [String: Any] ?? [:]
        let senderId = senderDict["id"] as? String ?? ""
        let ts = Int64(raw["create_time"] as? String ?? "") ?? Int64(Self.number(raw["create_time"], in: 0...4_102_444_800_000))
        let mentionList = (raw["mentions"] as? [[String: Any]] ?? []).prefix(100)
        var mentionNames: [String: String] = [:]
        for mention in mentionList {
            if let key = mention["key"] as? String, let name = mention["name"] as? String {
                mentionNames[key] = name
            }
        }
        var text = ""
        var imageKey: String?
        var fileKey: String?
        var fileName: String?
        var media: LarkMedia?
        let seconds = Int(Self.number(content["duration"], in: 0...86_400_000)) / 1000
        switch type {
        case "text":
            text = Self.clip(content["text"] as? String ?? "")
        case "post":
            text = Self.flattenRich(content, rows: "content")
        case "image":
            imageKey = content["image_key"] as? String
            text = "Photo"
        case "file", "folder":
            fileKey = type == "file" ? content["file_key"] as? String : nil
            fileName = content["file_name"] as? String
            text = fileName ?? (type == "file" ? "File" : "Folder")
            if type == "folder" { media = .other(type: type) }
        case "audio":
            fileKey = content["file_key"] as? String
            fileName = "Voice message \(id.suffix(6)).opus"
            media = .audio(seconds: seconds)
            text = "Voice message"
        case "media":
            fileKey = content["file_key"] as? String
            fileName = content["file_name"] as? String ?? "Video \(id.suffix(6)).mp4"
            media = .video(cover: content["image_key"] as? String, seconds: seconds)
            text = "Video"
        case "sticker":
            media = .sticker
            text = "Sticker"
        case "interactive":
            text = Self.flattenRich(content, rows: "elements")
            if text.isEmpty { text = "Card · open it in Lark" }
        case "share_chat":
            media = .sharedChat(id: content["chat_id"] as? String ?? "")
            text = "Shared group"
        case "share_user":
            media = .contact(id: content["user_id"] as? String ?? "")
            text = "Contact card"
        case "merge_forward":
            media = .forward
            text = "Forwarded messages"
        case "system":
            text = Self.systemText(content)
        default:
            media = .other(type: type)
            text = Self.otherText(type: type, content: content)
        }
        // Longest keys first, so @_user_1 never rewrites part of @_user_10.
        for (key, name) in mentionNames.sorted(by: { $0.key.count > $1.key.count }) {
            text = text.replacingOccurrences(of: key, with: "@\(name)")
        }
        text = text.replacingOccurrences(of: "@_all", with: "@all")
        let name = senderId == meId ? "You" : ""
        let nonEmpty = { (key: String) in (raw[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return ChatMessage(
            id: id,
            chatId: chatId,
            type: type,
            text: text,
            ts: ts,
            sender: Sender(id: senderId, name: name, isMe: senderId == meId),
            imageKey: imageKey,
            fileKey: fileKey,
            fileName: fileName,
            deleted: raw["deleted"] as? Bool ?? false,
            parentId: nonEmpty("parent_id"),
            threadId: nonEmpty("thread_id"),
            edited: raw["updated"] as? Bool ?? false,
            fromApp: senderDict["sender_type"] as? String == "app",
            media: media,
            imageKeys: ["post", "interactive"].contains(type) ? Self.embeddedImages(content) : []
        )
    }

    /// A JSON number as a finite value inside `range`, so a hostile value (1e300, NaN, negative)
    /// cannot trap an integer conversion. Anything else is the range's lower bound.
    static func number(_ value: Any?, in range: ClosedRange<Double>) -> Double {
        guard let double = (value as? NSNumber)?.doubleValue, double.isFinite else { return range.lowerBound }
        return min(max(double, range.lowerBound), range.upperBound)
    }

    /// System events come as a template with named parts: "{from_user} invited {to_chatters}".
    static func systemText(_ content: [String: Any]) -> String {
        guard var text = content["template"] as? String ?? content["text"] as? String else { return "System message" }
        for (key, value) in content where key != "template" {
            let names = (value as? [String]) ?? (value as? String).map { [$0] } ?? []
            text = text.replacingOccurrences(of: "{\(key)}", with: names.joined(separator: ", "))
        }
        return text.replacingOccurrences(of: #"\{[a-z_]+\}"#, with: "someone", options: .regularExpression)
    }

    /// Types Sift has no view for keep a name and their own summary, if any.
    static func otherText(type: String, content: [String: Any]) -> String {
        let labels = ["share_calendar_event": "Calendar event", "calendar": "Calendar invitation",
                      "general_calendar": "Calendar event", "todo": "Task", "vote": "Poll", "location": "Location",
                      "video_chat": "Video meeting", "hongbao": "Red packet", "share_doc": "Document"]
        let label = labels[type] ?? type.replacingOccurrences(of: "_", with: " ").capitalized
        let summary = (content["summary"] as? [String: Any])?["title"] as? String
            ?? ["summary", "topic", "title", "name", "text"].lazy.compactMap { content[$0] as? String }.first { !$0.isEmpty }
        var parts = [label]
        if let summary, !summary.isEmpty { parts.append(summary) }
        if let start = Int64(content["start_time"] as? String ?? ""), start > 0 { parts.append(TimeFormat.short(start)) }
        return parts.joined(separator: " · ")
    }

    /// Image keys inside a post or card, in order. The walk is iterative and bounded in depth and
    /// nodes, so hostile nesting cannot exhaust the stack or the CPU.
    static func embeddedImages(_ value: Any, maxDepth: Int = 16, maxNodes: Int = 5_000) -> [String] {
        var keys: [String] = []
        var stack: [(node: Any, depth: Int)] = [(value, 0)]
        var visited = 0
        // Children are queued only while visited plus queued nodes stay within the budget.
        func push(_ children: [Any], depth: Int) {
            let room = maxNodes - visited - stack.count
            guard room > 0 else { return }
            for child in children.prefix(room).reversed() { stack.append((child, depth + 1)) }
        }
        while let (node, depth) = stack.popLast(), visited < maxNodes {
            visited += 1
            if let object = node as? [String: Any] {
                if object["tag"] as? String == "img", let key = object["image_key"] as? String { keys.append(key) }
                guard depth < maxDepth else { continue }
                push(object.keys.sorted().filter { $0 != "image_key" }.map { object[$0]! }, depth: depth)
            } else if let list = node as? [Any], depth < maxDepth {
                push(list, depth: depth)
            }
        }
        return keys
    }

    /// Lark's read API returns posts as `{title, content: [[element]]}` and cards in a reduced
    /// `{title, elements: [[element]]}` form; send-side posts can sit in a locale wrapper.
    /// Text, link targets, mentions and card text stay; card controls are named, not invented.
    /// Bounded throughout: 200 rows of 200 elements, 4,000 characters per piece and the message
    /// as a whole within `textLimit`; the rest stays in Lark.
    static func flattenRich(_ content: [String: Any], rows key: String) -> String {
        var body = content
        for _ in 0..<2 where body[key] == nil && body["title"] == nil {
            guard let inner = body.keys.sorted().compactMap({ body[$0] as? [String: Any] }).first else { break }
            body = inner
        }
        var lines: [String] = []
        var total = 0
        if let title = body["title"] as? String, !title.isEmpty { lines.append(clip(title, limit: 4_000)) }
        var controls = false
        for row in (body[key] as? [[Any]] ?? []).prefix(200) {
            guard total < textLimit else { break }
            let line = row.prefix(200).compactMap { $0 as? [String: Any] }
                .map { clip(inline($0, controls: &controls, depth: 0), limit: 4_000) }.joined()
            if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(line)
                total += line.count
            }
        }
        if controls { lines.append("Buttons on this card work in Lark.") }
        return clip(lines.joined(separator: "\n"))
    }

    /// The most text one message shows in Sift.
    static let textLimit = 20_000

    static func clip(_ text: String, limit: Int = textLimit) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n… (the rest is in Lark)" : text
    }

    private static func inline(_ element: [String: Any], controls: inout Bool, depth: Int) -> String {
        let text = element["text"] as? String ?? ""
        switch element["tag"] as? String {
        case "a":
            let href = element["href"] as? String ?? ""
            return href.isEmpty || text == href ? (text.isEmpty ? href : text) : text.isEmpty ? href : "\(text) (\(href))"
        case "at":
            if let name = element["user_name"] as? String, !name.isEmpty { return "@" + name }
            let id = element["user_id"] as? String ?? ""
            return id.hasPrefix("@_") ? id : "@" + (id == "all" ? "all" : "user")
        case "img": return "[image]"
        case "media": return "[video]"
        case "emotion": return (element["emoji_type"] as? String).map { ":\($0):" } ?? ""
        case "hr": return "———"
        case "code_block": return text
        case "note":
            // Notes nest one level in practice; deeper nesting is cut off, not followed.
            guard depth < 4 else { return "" }
            return (element["elements"] as? [[String: Any]] ?? []).prefix(50).map { clip(inline($0, controls: &controls, depth: depth + 1), limit: 4_000) }.joined(separator: " ")
        case "button", "select_static", "select_person", "multi_select_static", "multi_select_person",
             "overflow", "date_picker", "picker_time", "picker_datetime", "input", "checker":
            controls = true
            let target = element["url"] as? String ?? (element["multi_url"] as? [String: Any])?["url"] as? String ?? ""
            if !text.isEmpty, target.hasPrefix("http") { return "[\(text)] (\(target)) " }
            return text.isEmpty ? "" : "[\(text)] "
        default: return text
        }
    }
}
