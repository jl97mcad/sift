import Foundation

/// Paseo's status ends a turn and its native message ids identify replies.
/// Needs-you is not a cue here: it is live state (open asks, pending permission).
struct ControlAttention {
    private var previousStatus: String?
    private var previousReply: String?
    private var previousNeedsInput = false

    mutating func observe(status: String, needsInput: Bool = false, messages: [AgentMessage]) -> (reply: String?, alert: String?) {
        let reply = messages.last(where: \.isAssistant)?.id
        let newReply = previousStatus != nil && reply != nil && reply != previousReply
        let alert: String?
        if needsInput && !previousNeedsInput { alert = "Needs your permission" }
        else if status == "error" && previousStatus != "error" { alert = "Stopped with an error" }
        else if status == "idle" && (newReply || (previousStatus == "running" && reply != nil)) { alert = "Turn finished" }
        else { alert = nil }
        previousStatus = status
        previousReply = reply
        previousNeedsInput = needsInput
        return (newReply ? reply : nil, alert)
    }
}

/// An open ask for the owner from the Control's own runner, read from its Paseo daemon
/// (`control-plugins` `asks.open`). Answers stay on the board.
struct OpenAsk: Identifiable, Equatable {
    let id: String
    let plan: String
    let title: String
    let question: String
    let recommendation: String
    let link: URL?
}

enum AskReading: Equatable {
    case off
    case unavailable(String)
    case available([OpenAsk])

    var asks: [OpenAsk] { if case .available(let asks) = self { return asks }; return [] }
}

enum AskInbox {
    /// `off` when the Control runs no control-plugins suite; a failed or unreadable read is
    /// unknown, never "nothing needs you".
    static func parse(_ value: Any?) -> AskReading {
        guard let reply = value as? [String: Any], let status = reply["status"] as? String else {
            return .unavailable("Control's asks reply is unreadable")
        }
        switch status {
        case "off": return .off
        case "available":
            guard let rows = reply["asks"] as? [[String: Any]] else { return .unavailable("Control's asks reply is unreadable") }
            return .available(rows.compactMap { row in
                guard let id = row["id"] as? String, !id.isEmpty,
                      let question = row["question"] as? String, !question.isEmpty else { return nil }
                let link = (row["link"] as? String).flatMap(URL.init(string:)).flatMap { ["https", "http"].contains($0.scheme ?? "") ? $0 : nil }
                return OpenAsk(id: id, plan: row["plan"] as? String ?? "", title: row["title"] as? String ?? "",
                               question: question, recommendation: row["recommendation"] as? String ?? "", link: link)
            })
        default:
            let reason = reply["reason"] as? String ?? ""
            return .unavailable(reason.isEmpty ? "Control's asks are unavailable" : reason)
        }
    }
}
