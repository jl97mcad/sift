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

/// A pending Paseo request (tool permission, plan approval, question, mode change); its id
/// lets a seen request stop pulsing. Answers stay in Paseo.
struct PermissionRequest: Equatable {
    let id: String
    let title: String
    var kind = "other"
    var name = ""
    var description = ""
    /// What it acts on (a command, a file) or the questions it asks, with their options.
    var detail = ""
    var actions: [String] = []

    var heading: String {
        switch kind {
        case "tool": return name.isEmpty ? "Wants to use a tool" : "Wants to use \(name)"
        case "plan": return "Plan to approve"
        case "question": return "Question for you"
        case "mode": return "Mode change"
        default: return "Request"
        }
    }

    /// One line for bubbles and notifications.
    var summary: String {
        let text = [title, description, detail].first { !$0.isEmpty } ?? ""
        return text.isEmpty ? heading : heading + ": " + UpdateText.short(text, limit: 80)
    }

    init(id: String, title: String, kind: String = "other", name: String = "", description: String = "",
         detail: String = "", actions: [String] = []) {
        (self.id, self.title, self.kind, self.name, self.description, self.detail, self.actions)
            = (id, title, kind, name, description, detail, actions)
    }

    init?(_ row: [String: Any]) {
        guard let id = row["id"] as? String, !id.isEmpty else { return nil }
        var detail = (row["detail"] as? [String: Any]).map { AgentStep.target(of: $0) } ?? ""
        // Questions (AskUserQuestion-style input) carry their text and options in the input.
        let input = row["input"] as? [String: Any]
        let questions = (input?["questions"] as? [[String: Any]] ?? []).map { question -> String in
            let options = (question["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
            return (question["question"] as? String ?? "") + (options.isEmpty ? "" : "\n" + options.map { "• " + $0 }.joined(separator: "\n"))
        }.filter { !$0.isEmpty }
        if !questions.isEmpty { detail = questions.joined(separator: "\n\n") }
        else if detail.isEmpty, let plan = input?["plan"] as? String { detail = plan }
        else if detail.isEmpty, let command = input?["command"] as? String { detail = command }
        self.init(id: id, title: row["title"] as? String ?? "", kind: row["kind"] as? String ?? "other",
                  name: row["name"] as? String ?? "", description: row["description"] as? String ?? "",
                  detail: detail, actions: row["actions"] as? [String] ?? [])
    }
}

/// One piece of Control's work between messages: a tool call, a thought, a checklist,
/// compaction or plugin output. Shown as labelled activity, never as a reply.
struct AgentStep: Identifiable, Equatable {
    struct Todo: Equatable { let text: String; let status: String }

    let id: String
    var ts: Int64? = nil
    /// Paseo's type: a tool's detail type (shell, read, edit…), or reasoning, todo, plugin, compaction.
    let kind: String
    let title: String
    var target = ""
    /// running, completed, failed or canceled for tools; empty otherwise.
    var status = ""
    /// Output, diff, log, thought or plugin data, bounded by the reader.
    var detail = ""
    var todos: [Todo] = []
    /// No Sift view exists for this content; it is named, not hidden.
    var unrendered = false

    var failed: Bool { status == "failed" }

    /// Short target text for a tool detail.
    static func target(of detail: [String: Any]) -> String {
        for key in ["command", "filePath", "query", "url", "description", "label", "subAgentType"] {
            if let value = detail[key] as? String, !value.isEmpty { return value }
        }
        return ""
    }

    init(id: String, ts: Int64? = nil, kind: String, title: String, target: String = "", status: String = "",
         detail: String = "", todos: [Todo] = [], unrendered: Bool = false) {
        (self.id, self.ts, self.kind, self.title, self.target, self.status, self.detail, self.todos, self.unrendered)
            = (id, ts, kind, title, target, status, detail, todos, unrendered)
    }

    /// nil for messages and notices, which are not steps.
    init?(id: String, ts: Int64?, item: [String: Any]) {
        let type = item["type"] as? String ?? ""
        if item["omitted"] as? Bool == true, !["user_message", "assistant_message", "error", "notification"].contains(type) {
            self.init(id: id, ts: ts, kind: type, title: "Details left out to keep this reading small",
                      detail: "Paseo shows this step in full.", unrendered: true)
            return
        }
        switch type {
        case "reasoning":
            self.init(id: id, ts: ts, kind: type, title: "Thought", detail: item["text"] as? String ?? "")
        case "todo":
            let todos = (item["items"] as? [[String: Any]] ?? []).map { row in
                Todo(text: row["text"] as? String ?? "",
                     status: row["status"] as? String ?? ((row["completed"] as? Bool ?? false) ? "completed" : "pending"))
            }
            let done = todos.filter { $0.status == "completed" }.count
            self.init(id: id, ts: ts, kind: type, title: "Checklist", target: "\(done) of \(todos.count) done", todos: todos)
        case "compaction":
            self.init(id: id, ts: ts, kind: type, title: "Compacted the context",
                      status: item["status"] as? String == "loading" ? "running" : "completed")
        case "tool_call":
            let detail = item["detail"] as? [String: Any] ?? [:]
            let detailType = detail["type"] as? String ?? "unknown"
            let name = item["name"] as? String ?? ""
            var status = item["status"] as? String ?? ""
            var body: String
            var title: String
            switch detailType {
            case "shell":
                title = "Ran a command"
                body = detail["output"] as? String ?? ""
                if let code = detail["exitCode"] as? Int, code != 0 {
                    body += (body.isEmpty ? "" : "\n") + "Exit code \(code)"
                    if status == "completed" { status = "failed" }
                }
            case "read": title = "Read a file"; body = ""
            case "edit": title = "Edited a file"; body = detail["unifiedDiff"] as? String ?? detail["newString"] as? String ?? ""
            case "write": title = "Wrote a file"; body = detail["content"] as? String ?? ""
            case "search":
                title = (detail["toolName"] as? String) == "web_search" ? "Searched the web" : "Searched"
                let web = (detail["webResults"] as? [[String: Any]] ?? []).map { "\($0["title"] as? String ?? "") \($0["url"] as? String ?? "")" }
                body = detail["content"] as? String ?? ((detail["filePaths"] as? [String]).map { $0.joined(separator: "\n") } ?? web.joined(separator: "\n"))
            case "fetch": title = "Read a web page"; body = detail["result"] as? String ?? ""
            case "sub_agent": title = "Ran a sub-agent"; body = detail["log"] as? String ?? ""
            case "plan": title = "Proposed a plan"; body = detail["text"] as? String ?? ""
            case "plain_text": title = detail["label"] as? String ?? (name.isEmpty ? "Used a tool" : name); body = detail["text"] as? String ?? ""
            case "worktree_setup": title = "Set up a worktree"; body = ""
            default:
                title = name.isEmpty ? "Used a tool" : "Used \(name)"
                body = [detail["input"], detail["output"]].compactMap(Self.compact).joined(separator: "\n")
            }
            if let message = item["agentMessage"] as? [String: Any] {
                title = "Messaged an agent"
                body = message["text"] as? String ?? body
            }
            if let error = item["error"], !(error is NSNull), let text = Self.compact(error) {
                body += (body.isEmpty ? "" : "\n") + "Error: " + text
            }
            let target = detailType == "plain_text" ? "" : Self.target(of: detail)
            self.init(id: id, ts: ts, kind: detailType, title: title, target: target, status: status, detail: body)
        case "plugin":
            let plugin = item["pluginId"] as? String ?? "plugin"
            self.init(id: id, ts: ts, kind: type, title: "\(plugin) · \(item["kind"] as? String ?? "entry")",
                      detail: Self.compact(item["data"]) ?? "", unrendered: true)
        case "user_message", "assistant_message", "error", "notification":
            return nil
        default:
            self.init(id: id, ts: ts, kind: type, title: "Paseo \(type.replacingOccurrences(of: "_", with: " "))",
                      detail: Self.compact(item) ?? "", unrendered: true)
        }
    }

    private static func compact(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let text = value as? String { return text.isEmpty ? nil : text }
        guard JSONSerialization.isValidJSONObject(value) || value is NSNumber,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8).map { String($0.prefix(1200)) }
    }

    /// "4 steps · 2 commands, 1 edit · 1 failed" for a collapsed run of work.
    static func summary(_ steps: [AgentStep]) -> String {
        let groups: [(String, String, (AgentStep) -> Bool)] = [
            ("command", "commands", { $0.kind == "shell" }),
            ("read", "reads", { $0.kind == "read" }),
            ("edit", "edits", { ["edit", "write"].contains($0.kind) }),
            ("search", "searches", { ["search", "fetch"].contains($0.kind) }),
            ("thought", "thoughts", { $0.kind == "reasoning" }),
            ("checklist", "checklists", { $0.kind == "todo" }),
            ("sub-agent", "sub-agents", { $0.kind == "sub_agent" })]
        var parts = groups.compactMap { one, many, match -> String? in
            let count = steps.filter(match).count
            return count == 0 ? nil : "\(count) \(count == 1 ? one : many)"
        }
        let other = steps.count - groups.reduce(0) { total, group in total + steps.filter(group.2).count }
        if other > 0 { parts.append("\(other) other") }
        let failed = steps.filter(\.failed).count
        let head = steps.count == 1 ? steps[0].title : "\(steps.count) steps"
        return ([head] + (steps.count == 1 ? [] : [parts.joined(separator: ", ")]) + (failed > 0 ? ["\(failed) failed"] : []))
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// What the Control pane lists, in timeline order.
enum ControlEntry: Identifiable, Equatable {
    case message(AgentMessage)
    /// Consecutive work between messages, collapsed to one line.
    case work(id: String, steps: [AgentStep])
    /// Errors and notifications stay visible.
    case notice(id: String, level: String, text: String, ts: Int64?)

    var id: String {
        switch self {
        case .message(let message): return message.id
        case .work(let id, _), .notice(let id, _, _, _): return id
        }
    }

    var message: AgentMessage? { if case .message(let message) = self { return message }; return nil }
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
    /// Messages, work and notices in order; `messages` stays the source for reply attention.
    var timeline: [ControlEntry] = []
    /// The daemon's server id, for `paseo://` links into the Paseo app.
    var serverId: String? = nil
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

    /// The installed Paseo app's helper (run as Node) and its CLI modules, plus the reader script.
    private static func launch(agentId: String, host: String?, tail: Int, watch: Bool) throws -> (helper: String, arguments: [String], script: URL) {
        guard let cli = locate() else { throw PaseoError.notInstalled }
        let resolved = URL(fileURLWithPath: cli).resolvingSymlinksInPath()
        let resources = resolved.path.contains(".app/Contents/Resources/bin/")
            ? resolved.deletingLastPathComponent().deletingLastPathComponent()
            : URL(fileURLWithPath: "/Applications/Paseo.app/Contents/Resources")
        let helper = resources.deletingLastPathComponent().appendingPathComponent("Frameworks/Paseo Helper.app/Contents/MacOS/Paseo Helper")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw PaseoError.failed("Open the Paseo desktop installation to read typed conversation history.")
        }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("sift-read-\(UUID().uuidString).mjs")
        try readerScript.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: script.path)
        return (helper.path, ["--disable-warning=DEP0040",
            resources.appendingPathComponent("app.asar.unpacked/dist/daemon/node-entrypoint-runner.js").path,
            "node-script", script.path,
            resources.appendingPathComponent("app.asar/node_modules/@getpaseo/cli/dist").path,
            agentId, host ?? "", String(max(1, min(Store.controlMaxTail, tail)))] + (watch ? ["watch"] : []), script)
    }

    private static var helperEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(home)/.local/bin"
        environment["ELECTRON_RUN_AS_NODE"] = "1"
        environment["PASEO_NODE_ENV"] = "production"
        return environment
    }

    /// The script's first line is the reason; its stack names temporary files.
    static func reason(_ message: String) -> String {
        let line = message.split(separator: "\n").first.map(String.init) ?? message
        return line.hasPrefix("Error: ") ? String(line.dropFirst(7)) : line
    }

    func read(agentId: String, host: String? = nil, tail: Int = 80) async throws -> AgentReading {
        let (helper, arguments, script) = try Self.launch(agentId: agentId, host: host, tail: tail, watch: false)
        defer { try? FileManager.default.removeItem(at: script) }
        let output: String
        do {
            output = try await run(arguments, executablePath: helper)
        } catch PaseoError.failed(let message) {
            throw PaseoError.failed(Self.reason(message))
        }
        guard let reading = Self.reading(output) else {
            throw PaseoError.failed("Paseo conversation data is unavailable. Refresh to retry.")
        }
        return reading
    }

    /// One connection that sends a fresh reading whenever Paseo reports a change (ADR 0009).
    /// Commands: `refresh`, `gap <seconds>`, `tail <entries>`. Callbacks run on the main queue.
    func watch(agentId: String, host: String?, tail: Int, onReading: @escaping (AgentReading) -> Void,
               onError: @escaping (String) -> Void, onExit: @escaping (Int32?) -> Void) throws -> ChildStream {
        Self.sweepScripts()
        let (helper, arguments, script) = try Self.launch(agentId: agentId, host: host, tail: tail, watch: true)
        var loaded = false
        do {
            return try ChildStream(helper, arguments, environment: Self.helperEnvironment, onLine: { line in
                let text = String(decoding: line, as: UTF8.self)
                // Only the script writes readings and error records, so one of those proves Node has
                // loaded it and the file can go: a helper that outlives Sift (it exits when Sift's end
                // of stdin closes) leaves nothing behind. Node's own warnings prove nothing.
                let loadedNow = { if !loaded { loaded = true; try? FileManager.default.removeItem(at: script) } }
                if let reading = Self.reading(text) { loadedNow(); onReading(reading) }
                else if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let error = json["error"] as? String {
                    loadedNow()
                    onError(error)
                } else if !text.hasPrefix("(node:") { onError(Self.reason(text)) }  // Node's own warnings are not errors
            }, onExit: { status in
                try? FileManager.default.removeItem(at: script)
                onExit(status)
            })
        } catch {
            try? FileManager.default.removeItem(at: script)
            throw error
        }
    }

    /// Removes reader scripts left by a run that never got to clean up (a quit before the first
    /// reading, or an older build). Only Sift's exact names (`sift-read-<UUID>.mjs`) that are
    /// regular files owned by this user and older than an hour; no read lives that long.
    static func sweepScripts(in folder: URL = FileManager.default.temporaryDirectory, olderThan age: TimeInterval = 3_600) {
        let files = FileManager.default
        guard let names = try? files.contentsOfDirectory(atPath: folder.path) else { return }
        let pattern = #"^sift-read-[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\.mjs$"#
        for name in names where name.range(of: pattern, options: .regularExpression) != nil {
            let url = folder.appendingPathComponent(name)
            // attributesOfItem does not follow symbolic links, so a link is never mistaken for a file.
            guard let attributes = try? files.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  let modified = attributes[.modificationDate] as? Date,
                  Date().timeIntervalSince(modified) > age else { continue }
            try? files.removeItem(at: url)
        }
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
            permissions: (json["permissions"] as? [[String: Any]] ?? []).compactMap(PermissionRequest.init),
            timeline: timeline(output), serverId: json["serverId"] as? String)
    }

    /// Every timeline entry, typed: messages as messages, work grouped between them, notices visible.
    static func timeline(_ output: String) -> [ControlEntry] {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["entries"] as? [[String: Any]] else { return [] }
        let messages = Dictionary(parse(output).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [ControlEntry] = []
        var work: [AgentStep] = []
        func flush() {
            guard let first = work.first else { return }
            result.append(.work(id: "work-" + first.id, steps: work))
            work = []
        }
        for entry in entries {
            guard let id = entry["id"] as? String else { continue }
            let ts = (entry["ts"] as? NSNumber)?.int64Value
            if let message = messages[id] { flush(); result.append(.message(message)); continue }
            guard let item = entry["item"] as? [String: Any] else { continue }
            switch item["type"] as? String {
            case "error":
                flush(); result.append(.notice(id: id, level: "error", text: item["message"] as? String ?? "Error", ts: ts))
            case "notification":
                flush(); result.append(.notice(id: id, level: item["level"] as? String ?? "info", text: item["message"] as? String ?? "", ts: ts))
            default:
                if let step = AgentStep(id: id, ts: ts, item: item) { work.append(step) }
            }
        }
        flush()
        return result
    }

    // Use the installed CLI's own client, target selection and projected timeline.
    // The CLI's advertised --json logs flag still prints a lossy text transcript.
    // Control handoffs label every Control session `seat=control` and archive the old one;
    // an archived seat follows only when exactly one live session carries its label.
    static let readerScript = #"""
    import { pathToFileURL } from 'node:url';
    import { createInterface } from 'node:readline';
    const [root, id, host, count, mode] = process.argv.slice(2);
    const load = (path) => import(pathToFileURL(root + path));
    const {connectToDaemon} = await load('/utils/client.js');
    const {selectDaemonTarget} = await load('/utils/daemon-target.js');
    const {fetchAllAgents} = await load('/utils/agent-directory.js');
    // Every value is bounded: long text keeps its start and end (a command's failure is usually at
    // the end), lists and objects stop after 60 items without copying the rest, depth stops at 5
    // (checked before lists and objects alike) and each value spends at most `budget`
    // characters, keys included, charged before their value is walked.
    const bound = (value, budget = 20000) => {
      let left = budget;
      const text = (v) => {
        let t = v.length > 1500 ? v.slice(0, 900) + '\n…\n' + v.slice(-500) : v;
        if (t.length > left) t = t.slice(0, Math.max(0, left)) + '…';
        left -= t.length;
        return t;
      };
      const walk = (v, depth) => {
        if (left <= 0) return '…';
        if (typeof v === 'string') return text(v);
        if (v === null || typeof v !== 'object') { left -= 8; return v; }
        if (depth >= 5) { left -= 1; return '…'; }
        if (Array.isArray(v)) {
          const out = [];
          for (let i = 0; i < v.length && i < 60 && left > 0; i++) out.push(walk(v[i], depth + 1));
          return out;
        }
        const out = {};
        let count = 0;
        for (const k in v) {
          if (!Object.prototype.hasOwnProperty.call(v, k)) continue;
          if (count++ >= 60 || left <= 0) break;
          const key = text(k);
          out[key] = walk(v[k], depth + 1);
        }
        return out;
      };
      return walk(value, 0);
    };
    const spoken = (text) => typeof text === 'string' && text.length > 20000 ? text.slice(0, 20000) + '\n\n… (the rest of this message is in Paseo)' : text;
    // The reading is at most BUDGET UTF-8 bytes. Everything but the timeline is bounded in
    // characters to at most a third of that (three bytes per character at worst); the timeline
    // gets the rest: details of the oldest steps go first, then the oldest entries. The final
    // serialized line is measured, so the limit holds whatever the estimates said.
    const BUDGET = 600000;
    const bytes = (x) => Buffer.byteLength(typeof x === 'string' ? x : JSON.stringify(x), 'utf8');
    const serialize = (rest, entries, older) => {
      const sizes = entries.map(e => bytes(e) + 1);
      let total = bytes({...rest, hasOlder:true, entries:[]}) + sizes.reduce((sum, size) => sum + size, 0);
      for (let i = 0; total > BUDGET && i < entries.length; i++) {
        if (!entries[i].item) continue;
        entries[i].item = {type:entries[i].item.type, omitted:true};
        const size = bytes(entries[i]) + 1;
        total -= sizes[i] - size;
        sizes[i] = size;
      }
      let start = 0;
      while (total > BUDGET && start < entries.length) total -= sizes[start++];
      let line = JSON.stringify({...rest, hasOlder:Boolean(older) || start > 0, entries:entries.slice(start)});
      while (bytes(line) > BUDGET && start < entries.length) {
        start = Math.min(entries.length, start + Math.max(1, Math.ceil((entries.length - start) / 10)));
        line = JSON.stringify({...rest, hasOlder:true, entries:entries.slice(start)});
      }
      if (bytes(line) > BUDGET) line = JSON.stringify({status:rest.status, title:null, asks:{status:'unavailable', reason:'Control\'s reply was too large to read'},
        permissions:[], needsInput:rest.needsInput, serverId:rest.serverId ?? null, hasOlder:true, entries:[], action:null});
      return line;
    };
    const client = await connectToDaemon({target:selectDaemonTarget(host ? {host} : {}),timeout:10000});
    // The serialized reading: one line of at most BUDGET UTF-8 bytes.
    async function snapshot(tail) {
      const agent = (await client.fetchAgent({agentId:id}))?.agent;
      if (!agent) throw new Error(`No Paseo session ${id} on this host`);
      const seat = agent.labels?.seat;
      // Open asks come from the runner beside this daemon, through its control-plugins suite.
      let asks;
      try {
        const listed = await client.listPlugins();
        const suite = (Array.isArray(listed) ? listed : listed?.plugins ?? []).find(p => p.id === 'control-plugins');
        asks = suite?.status === 'running' ? bound(await client.invokePluginRpc('control-plugins', 'asks.open', {}), 50000) : {status:'off'};
      } catch { asks = {status:'unavailable', reason:"This Control's plugins do not serve open asks yet"}; }
      const permissions = (agent.pendingPermissions ?? []).slice(0, 20).map(p => bound({id:String(p.id ?? ''), kind:p.kind ?? 'other',
        name:p.name ?? '', title:p.title ?? '', description:p.description ?? '', input:p.input ?? null,
        detail:p.detail ?? null, actions:(p.actions ?? []).slice(0, 10).map(a => a.label)}, 3000)).filter(p => p.id);
      const base = {title:bound(agent.title ?? null, 2000), asks, permissions, needsInput:Boolean(agent.pendingPermissions?.length),
        serverId:bound(client.getLastServerInfoMessage?.()?.serverId ?? null, 200)};
      if (agent.archivedAt) {
        const live = seat ? (await fetchAllAgents(client, {filter:{labels:{seat}}}))
          .filter(a => !a.archivedAt && a.labels?.seat === seat) : [];
        const next = live.length === 1 && live[0].id !== agent.id ? live[0] : null;
        return serialize({...base, status:'archived', action:null,
          successor:next ? {id:String(next.id).slice(0, 200), title:bound(next.title ?? null, 2000)} : null}, [], false);
      }
      const timeline = await client.fetchAgentTimeline(agent.id,{direction:'tail',limit:tail,projection:'projected',timeout:10000});
      if (timeline.error) throw new Error('Paseo timeline is unavailable');
      const entries = timeline.entries.map(e => {
        const said = ['user_message','assistant_message'].includes(e.item.type);
        return {id:e.item.messageId ?? `${timeline.epoch}:${e.seqStart}`, type:e.item.type, ts:Date.parse(e.timestamp) || null,
          text:said ? spoken(e.item.text) : undefined, item:said ? undefined : bound(e.item)};
      });
      // The current step is bounded too and counted with everything else before the timeline.
      const last = [...timeline.entries].reverse().find(e => e.item.type !== 'plugin')?.item;
      const action = last ? bound({type:last.type, status:last.status, kind:last.detail?.type, name:last.name}, 500) : null;
      return serialize({...base, status:bound(agent.status, 100), action}, entries, timeline.hasOlder);
    }
    if (mode !== 'watch') {
      try { process.stdout.write(await snapshot(Number(count))); } finally { await client.close(); }
    } else {
      // One connection for the app's lifetime. Every change refetches the tail, so a missed or
      // replayed event, a new epoch or a reconnect is reconciled by the next snapshot.
      // Requests and turn ends go out at once; other changes at most once per gap.
      let tail = Number(count), gap = 15000, last = 0, timer = null, busy = false, again = false, failures = 0, sent = '';
      const emit = async () => {
        if (busy) { again = true; return; }
        busy = true; clearTimeout(timer); timer = null;
        try {
          const line = await snapshot(tail);
          failures = 0;
          if (line !== sent) { sent = line; process.stdout.write(line + '\n'); }
        } catch (e) {
          sent = '';
          process.stdout.write(JSON.stringify({error:String(e?.message ?? e).split('\n')[0]}) + '\n');
          if (++failures >= 3) process.exit(1);
        } finally {
          busy = false; last = Date.now();
          if (again) { again = false; schedule(false); }
        }
      };
      const schedule = (urgent) => {
        if (urgent) { void emit(); return; }
        if (!timer) timer = setTimeout(emit, Math.max(300, last + gap - Date.now()));
      };
      const urgent = ['permission_requested','permission_resolved','attention_required','turn_started','turn_completed','turn_failed','turn_canceled'];
      client.subscribeAgentTimeline(id, (message) => schedule(urgent.includes(message?.payload?.event?.type ?? message?.event?.type)));
      client.subscribeConnectionStatus?.((state) => {
        if (state?.status === 'connected') schedule(true);
        if (state?.status === 'disposed') process.exit(1);
      });
      setInterval(() => schedule(false), 30000);
      createInterface({input:process.stdin}).on('line', (line) => {
        const [command, value] = line.trim().split(/\s+/);
        if (command === 'refresh') schedule(true);
        else if (command === 'gap') {
          gap = Math.max(1, Number(value) || 15) * 1000;
          // A change already waiting moves to the new deadline.
          if (timer) { clearTimeout(timer); timer = null; schedule(false); }
        }
        else if (command === 'tail') { tail = Math.max(1, Math.min(400, Number(value) || 80)); schedule(true); }
      }).on('close', () => process.exit(0));
      await emit();
    }
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
        var args = arguments
        if let host, !host.isEmpty {
            args = ["--host", host] + args
        }
        var environment = Self.helperEnvironment
        if executablePath == nil {
            environment["ELECTRON_RUN_AS_NODE"] = nil
            environment["PASEO_NODE_ENV"] = nil
        }
        let (data, exit) = try await ChildProcess.run(executable, args, environment: environment, timeout: timeout)
        let status: Int32
        switch exit {
        case .timedOut: throw PaseoError.failed("Paseo did not answer in time.")
        case .unobserved: throw PaseoError.failed("Paseo's exit could not be read. Refresh to retry.")
        case .code(let code): status = code
        }
        guard status == 0 else {
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw PaseoError.failed(message.isEmpty ? "paseo exited \(status)" : message)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
