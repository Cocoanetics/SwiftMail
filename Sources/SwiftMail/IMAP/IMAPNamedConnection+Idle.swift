import Foundation

extension IMAPNamedConnection {
    /// Start IDLE and receive server events.
    public func idle() async throws -> AsyncStream<IMAPServerEvent> {
        try await withAuthenticatedOperation { [self] in
            let stream = try await connection.idle()
            try recordActivity()
            return stream
        }
    }

    /// Terminate an active IDLE command with DONE.
    public func done() async throws {
        try await connection.withOperationScope { [self] in
            try await connection.done()
            try recordActivity()
        }
    }

    /// Send NOOP and collect unsolicited events.
    public func noop() async throws -> [IMAPServerEvent] {
        try await withAuthenticatedOperation { [self] in
            let events = try await connection.noop()
            try recordActivity()
            return events
        }
    }
}
