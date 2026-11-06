import Foundation

/// One place that can answer "who is this agent, what did it say, send it a
/// message". Paseo is the default; anything else can implement the same four
/// calls without touching the panel.
protocol AgentProvider {
    var name: String { get }
    func inspect(id: String, host: String?) async -> (title: String, status: String)?
    func read(id: String, host: String?, tail: Int) async throws -> AgentReading
    func send(id: String, host: String?, text: String) async throws
    func options(host: String?) async -> [ControlOption]
}

struct PaseoProvider: AgentProvider {
    let name = "paseo"
    private let client = PaseoClient()

    func inspect(id: String, host: String?) async -> (title: String, status: String)? {
        await client.info(agentId: id, host: host)
    }

    func read(id: String, host: String?, tail: Int) async throws -> AgentReading {
        try await client.read(agentId: id, host: host, tail: tail)
    }

    func send(id: String, host: String?, text: String) async throws {
        try await client.send(agentId: id, host: host, text: text)
    }

    func options(host: String?) async -> [ControlOption] {
        await client.controlOptions(host: host)
    }
}

extension AgentProvider {
    /// Reads the seat and, after a Control handoff, moves the shared seat to the provider's
    /// unambiguous successor on the same host. A seat changed meanwhile is left alone.
    func readFollowing(_ seat: ControlSeat, tail: Int, state: StateFile = .shared) async throws -> (ControlSeat, AgentReading) {
        let reading = try await read(id: seat.agentId, host: seat.host, tail: tail)
        guard let moved = seat.following(reading.successor, state: state) else { return (seat, reading) }
        return (moved, try await read(id: moved.agentId, host: moved.host, tail: tail))
    }
}

extension ControlSeat {
    /// The seat moved to a handoff successor, saved only if the shared seat is still this one.
    func following(_ next: ControlOption?, state: StateFile) -> ControlSeat? {
        guard let next else { return nil }
        var moved = self
        moved.agentId = next.id
        moved.title = next.name
        let saved = state.update { state in
            if let index = state.seats.firstIndex(where: { $0 == self }) { state.seats[index] = moved }
        }
        return saved.seats.contains(moved) ? moved : nil
    }
}

enum AgentProviders {
    static let all: [String: AgentProvider] = ["paseo": PaseoProvider()]
    static let fallback = "paseo"

    static func resolve(_ name: String?) -> AgentProvider {
        all[name ?? fallback] ?? all[fallback]!
    }
}
