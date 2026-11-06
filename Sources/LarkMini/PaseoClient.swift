import Foundation

struct AgentMessage: Identifiable, Equatable {
    enum Origin: Equatable { case control, you, agent(String), automation(String) }

    let id: String
    let role: String
    let text: String
    var ts: Int64? = nil
    /// Sift remembers its own prompts: the CLI gives them random ids, the same as scripts.
    var sentHere = false

    var isAssistant: Bool { role == "assistant" }
    var isMine: Bool { origin == .you }

    /// Paseo wraps prompts sent by another agent in a daemon envelope naming that agent.
    /// Its desktop/mobile apps id the person's prompts `msg_<ms>_<random>`; runner and
    /// script prompts carry CLI UUIDs or their own `kind:` ids.
    var origin: Origin {
        if isAssistant { return .control }
        if let envelope { return .agent(envelope.title) }
        if sentHere || id.hasPrefix("msg_") { return .you }
        let kind = id.split(separator: ":").first.map(String.init) ?? ""
        guard id.contains(":"), kind.range(of: #"^[a-z][a-z-]{2,30}$"#, options: .regularExpression) != nil else {
            return .automation("Automated message")
        }
        return .automation(kind.prefix(1).uppercased() + kind.dropFirst().replacingOccurrences(of: "-", with: " "))
    }

    var speaker: String {
        switch origin {
        case .control: return "Control"
        case .you: return "You"
        case .agent(let title), .automation(let title): return title
        }
    }

    /// Context from agents and automation is shown compactly; it is not the person's own words.
    var isContext: Bool {
        switch origin { case .agent, .automation: return true; default: return false }
    }

    var displayText: String { envelope?.body ?? text }

    private var envelope: (title: String, body: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard role == "user", trimmed.hasPrefix("<paseo-system"), let open = trimmed.firstIndex(of: ">"),
              let close = trimmed.range(of: "</paseo-system>", options: .backwards), open < close.lowerBound else { return nil }
        let head = String(trimmed[..<open])
        let title = head.range(of: #"source-agent-title="[^"]*""#, options: .regularExpression)
            .map { String(head[$0].dropFirst(20).dropLast()) } ?? ""
        let body = String(trimmed[trimmed.index(after: open)..<close.lowerBound])
        return (Self.unescape(title).isEmpty ? "Agent" : Self.unescape(title),
                Self.unescape(body).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func unescape(_ text: String) -> String {
        [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&amp;", "&")]
            .reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    func groups(with other: AgentMessage?) -> Bool {
        guard let other, origin == other.origin, let ts, let previous = other.ts else { return false }
        return ts / 60_000 == previous / 60_000
    }
}

/// A pending Paseo permission request; its id lets a seen request stop pulsing.
struct PermissionRequest: Equatable {
    let id: String
    let title: String
}

struct AgentReading {
    let messages: [AgentMessage]
    let status: String
    /// Paseo's own needs-input state: a pending permission request on this session.
    var needsInput = false
    let activity: String?
    let hasOlder: Bool
    var title: String? = nil
    /// The one live session that now holds this seat's `seat` label after a handoff.
    var successor: ControlOption? = nil
    /// Open asks from the same daemon's control-plugins suite.
    var asks: AskReading = .off
    var permissions: [PermissionRequest] = []
}

/// Talks to a local Paseo daemon through its CLI, so a pinned Control seat
/// works wherever Paseo is installed.
final class PaseoClient {
    enum PaseoError: LocalizedError {
        case notInstalled
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Paseo is not installed"
            case .failed(let message): return message
            }
        }
    }

    static func locate() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/paseo",
            "/opt/homebrew/bin/paseo",
            "/usr/local/bin/paseo",
            "\(home)/bin/paseo",
            "/Applications/Paseo.app/Contents/Resources/bin/paseo"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isAvailable: Bool { locate() != nil }

    func read(agentId: String, host: String? = nil, tail: Int = 80) async throws -> AgentReading {
        guard let cli = Self.locate() else { throw PaseoError.notInstalled }
        let resolved = URL(fileURLWithPath: cli).resolvingSymlinksInPath()
        let resources = resolved.path.contains(".app/Contents/Resources/bin/")
            ? resolved.deletingLastPathComponent().deletingLastPathComponent()
            : URL(fileURLWithPath: "/Applications/Paseo.app/Contents/Resources")
        let helper = resources.deletingLastPathComponent().appendingPathComponent("Frameworks/Paseo Helper.app/Contents/MacOS/Paseo Helper")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw PaseoError.failed("Open the Paseo desktop installation to read typed conversation history.")
        }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("sift-read-\(UUID().uuidString).mjs")
        try Self.readerScript.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }
        let output = try await run(["--disable-warning=DEP0040",
            resources.appendingPathComponent("app.asar.unpacked/dist/daemon/node-entrypoint-runner.js").path,
            "node-script", script.path,
            resources.appendingPathComponent("app.asar/node_modules/@getpaseo/cli/dist").path,
            agentId, host ?? "", String(max(1, min(200, tail)))], executablePath: helper.path)
        guard let reading = Self.reading(output) else {
            throw PaseoError.failed("Paseo conversation data is unavailable. Refresh to retry.")
        }
        return reading
    }

    static func reading(_ output: String) -> AgentReading? {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? String, json["entries"] is [[String: Any]] else { return nil }
        let successor = (json["successor"] as? [String: Any]).flatMap { next -> ControlOption? in
            guard let id = next["id"] as? String, !id.isEmpty else { return nil }
            return ControlOption(id: id, name: next["title"] as? String ?? "Control")
        }
        return AgentReading(messages: parse(output), status: status,
            needsInput: json["needsInput"] as? Bool ?? false,
            activity: activity(status: status, action: json["action"] as? [String: Any]),
            hasOlder: json["hasOlder"] as? Bool ?? false,
            title: json["title"] as? String, successor: successor, asks: AskInbox.parse(json["asks"]),
            permissions: (json["permissions"] as? [[String: Any]] ?? []).compactMap { row in
                guard let id = row["id"] as? String, !id.isEmpty else { return nil }
                return PermissionRequest(id: id, title: row["title"] as? String ?? "")
            })
    }

    // Use the installed CLI's own client, target selection and projected timeline.
    // The CLI's advertised --json logs flag still prints a lossy text transcript.
    // Control handoffs label every Control session `seat=control` and archive the old one;
    // an archived seat follows only when exactly one live session carries its label.
    static let readerScript = #"""
    import { pathToFileURL } from 'node:url';
    const [root, id, host, count] = process.argv.slice(2);
    const load = (path) => import(pathToFileURL(root + path));
    const {connectToDaemon} = await load('/utils/client.js');
    const {selectDaemonTarget} = await load('/utils/daemon-target.js');
    const {fetchAllAgents} = await load('/utils/agent-directory.js');
    const client = await connectToDaemon({target:selectDaemonTarget(host ? {host} : {}),timeout:10000});
    try {
      const {agent} = await client.fetchAgent({agentId:id});
      const seat = agent.labels?.seat;
      // Open asks come from the runner beside this daemon, through its control-plugins suite.
      let asks;
      try {
        const listed = await client.listPlugins();
        const suite = (Array.isArray(listed) ? listed : listed?.plugins ?? []).find(p => p.id === 'control-plugins');
        asks = suite?.status === 'running' ? await client.invokePluginRpc('control-plugins', 'asks.open', {}) : {status:'off'};
      } catch { asks = {status:'unavailable', reason:"This Control's plugins do not serve open asks yet"}; }
      const permissions = (agent.pendingPermissions ?? []).map(p => ({id:String(p.id ?? ''), title:String(p.title ?? p.name ?? '')})).filter(p => p.id);
      const base = {title:agent.title ?? null, asks, permissions,
        needsInput:Boolean(agent.pendingPermissions?.length)};
      if (agent.archivedAt) {
        const live = seat ? (await fetchAllAgents(client, {filter:{labels:{seat}}}))
          .filter(a => !a.archivedAt && a.labels?.seat === seat) : [];
        const next = live.length === 1 && live[0].id !== agent.id ? live[0] : null;
        process.stdout.write(JSON.stringify({...base, status:'archived', hasOlder:false, entries:[], action:null,
          successor:next ? {id:next.id, title:next.title ?? null} : null}));
      } else {
        const timeline = await client.fetchAgentTimeline(agent.id,{direction:'tail',limit:Number(count),projection:'projected',timeout:10000});
        if (timeline.error) throw new Error('Paseo timeline is unavailable');
        const entries = timeline.entries.map(e => ({
          id:e.item.messageId ?? `${timeline.epoch}:${e.seqStart}`,
          type:e.item.type, ts:Date.parse(e.timestamp) || null,
          text:['user_message','assistant_message'].includes(e.item.type) ? e.item.text : undefined
        }));
        const last = [...timeline.entries].reverse().find(e => e.item.type !== 'plugin')?.item;
        process.stdout.write(JSON.stringify({...base, status:agent.status, hasOlder:Boolean(timeline.hasOlder), entries,
          action:last ? {type:last.type, status:last.status, kind:last.detail?.type, name:last.name} : null}));
      }
    } finally { await client.close(); }
    """#

    func send(agentId: String, host: String? = nil, text: String) async throws {
        _ = try await run(["send", agentId, "--prompt", text, "--no-wait", "--json"], host: host)
    }

    /// Agents that look like Control. The MO agent keeps its id, so the list
    /// is stable across sessions.
    func controlOptions(host: String? = nil) async -> [ControlOption] {
        guard let text = try? await run(["ls", "--json"], host: host),
              let data = text.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let agents = list.compactMap { item -> ControlOption? in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            return ControlOption(id: id, name: name)
        }
        return agents
            .filter { $0.name.localizedCaseInsensitiveContains("control") }
            .sorted { left, right in
                let leftExact = left.name.caseInsensitiveCompare("Control") == .orderedSame
                let rightExact = right.name.caseInsensitiveCompare("Control") == .orderedSame
                if leftExact != rightExact { return leftExact }
                return left.name < right.name
            }
    }

    /// The current step of a running turn, from the newest timeline entry; nil when not running.
    static func activity(status: String, action: [String: Any]?) -> String? {
        guard status == "running" else { return nil }
        switch action?["type"] as? String {
        case "reasoning": return "Thinking"
        case "assistant_message": return "Writing a reply"
        case "tool_call" where action?["status"] as? String == "running":
            if action?["name"] as? String == "agent_message" { return "Messaging an agent" }
            switch action?["kind"] as? String {
            case "shell": return "Running a command"
            case "read": return "Reading files"
            case "edit", "write": return "Editing files"
            case "search": return "Searching"
            case "fetch": return "Reading the web"
            case "sub_agent": return "Running a sub-agent"
            default: return "Using a tool"
            }
        default: return "Working"
        }
    }

    func info(agentId: String, host: String? = nil) async -> (title: String, status: String)? {
        guard let text = try? await run(["inspect", agentId, "--json"], host: host),
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let title = json["Name"] as? String ?? json["name"] as? String ?? "Paseo agent"
        let status = json["Status"] as? String ?? json["status"] as? String ?? "unknown"
        return (title, status)
    }

    // MARK: - Transcript

    /// Typed events keep reasoning, tool output and plugin metadata out of the conversation.
    static func parse(_ text: String) -> [AgentMessage] {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["entries"] as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            let role: String
            switch entry["type"] as? String {
            case "assistant_message": role = "assistant"
            case "user_message": role = "user"
            default: return nil
            }
            guard let id = entry["id"] as? String, let body = entry["text"] as? String,
                  !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return AgentMessage(id: id, role: role, text: body, ts: (entry["ts"] as? NSNumber)?.int64Value)
        }
    }

    // MARK: - Process

    private func run(_ arguments: [String], host: String? = nil, timeout: TimeInterval = 30, executablePath: String? = nil) async throws -> String {
        guard let executable = executablePath ?? PaseoClient.locate() else { throw PaseoError.notInstalled }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        var args = arguments
        if let host, !host.isEmpty {
            args = ["--host", host] + args
        }
        process.arguments = args
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(home)/.local/bin"
        if executablePath != nil {
            environment["ELECTRON_RUN_AS_NODE"] = "1"
            environment["PASEO_NODE_ENV"] = "production"
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = stdout

        try process.run()

        let watchdog = DispatchWorkItem { [weak process] in
            if process?.isRunning == true { process?.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let output = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: output)
            }
        }
        watchdog.cancel()

        guard process.terminationStatus == 0 else {
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw PaseoError.failed(message.isEmpty ? "paseo exited \(process.terminationStatus)" : message)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
