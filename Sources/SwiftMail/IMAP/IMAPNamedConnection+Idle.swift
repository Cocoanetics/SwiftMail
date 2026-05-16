import Foundation

public extension IMAPNamedConnection {
    /// Start IDLE and receive server events.
    func idle() async throws -> AsyncStream<IMAPServerEvent> {
        try await ensureAuthenticated()
        let stream = try await connection.idle()
        recordActivity()
        return stream
    }

    /// Terminate an active IDLE command with DONE.
    func done() async throws {
        try await connection.done()
        recordActivity()
    }

    /// Send NOOP and collect unsolicited events.
    func noop() async throws -> [IMAPServerEvent] {
        try await ensureAuthenticated()
        let events = try await connection.noop()
        recordActivity()
        return events
    }
}
