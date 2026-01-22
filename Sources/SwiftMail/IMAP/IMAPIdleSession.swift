import Foundation

/// Represents a dedicated IDLE session running on its own IMAP connection.
public struct IMAPIdleSession: Sendable {
    public let events: AsyncStream<IMAPServerEvent>
    private let onDone: @Sendable () async throws -> Void

    init(events: AsyncStream<IMAPServerEvent>, onDone: @escaping @Sendable () async throws -> Void) {
        self.events = events
        self.onDone = onDone
    }

    /// Terminates the IDLE session and closes its underlying connection.
    public func done() async throws {
        try await onDone()
    }
}
