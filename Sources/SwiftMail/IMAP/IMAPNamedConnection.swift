import Foundation
@preconcurrency import NIOIMAPCore

/// A user-controlled, reusable IMAP connection managed by ``IMAPServer``.
///
/// Instances are obtained via ``IMAPServer/connection(named:)``.
/// The server handles lifecycle bootstrap/authentication and teardown; callers decide
/// which mailbox and commands run on each named connection.
public actor IMAPNamedConnection {
    public let name: String

    // Widened from `private` to internal so the extensions split across files
    // (Mailbox/Idle/Fetch/Search/Manipulation) can reach them; not part of the
    // public API.
    let connection: IMAPConnection
    let authenticateOnConnection: @Sendable (IMAPConnection) async throws -> Void

    /// The timestamp of the last successfully completed command on this connection.
    /// Useful for implementing staleness checks in ephemeral connection patterns.
    public private(set) var lastActivity: Date?

    init(
        name: String,
        connection: IMAPConnection,
        authenticateOnConnection: @escaping @Sendable (IMAPConnection) async throws -> Void
    ) {
        self.name = name
        self.connection = connection
        self.authenticateOnConnection = authenticateOnConnection
    }

    /// Whether the underlying transport channel is currently active.
    public var isConnected: Bool {
        connection.isConnected
    }

    /// Whether this connection currently has an authenticated IMAP session.
    public var isAuthenticated: Bool {
        connection.isAuthenticated
    }

    /// Connect (or reconnect) the underlying transport and ensure authentication.
    public func connect() async throws {
        try await connection.connect()
        try await ensureAuthenticated()
    }

    /// Disconnect this named connection.
    public func disconnect() async throws {
        try await connection.disconnect()
    }

    /// Whether the server advertised UIDPLUS for this connection.
    public var supportsUIDPlus: Bool {
        capabilities.contains(.uidPlus)
    }

    // MARK: - Internal Helpers

    /// Capabilities snapshot reused by the split extensions when deciding
    /// whether optional commands are supported.
    var capabilities: Set<NIOIMAPCore.Capability> {
        connection.capabilitiesSnapshot
    }

    /// Mark a successful command — invoked by helpers that talk directly to
    /// `connection` (idle, noop, fetchCapabilities, …).
    func recordActivity() {
        lastActivity = Date()
    }

    func ensureAuthenticated() async throws {
        if !connection.isAuthenticated {
            try await authenticateOnConnection(connection)
        }
    }

    @discardableResult
    func executeCommand<CommandType: IMAPCommand>(
        _ command: CommandType
    ) async throws -> CommandType.ResultType {
        try await ensureAuthenticated()
        let result = try await connection.executeCommand(command)
        lastActivity = Date()
        return result
    }

    func resolveMailboxPath(_ mailboxName: String) -> String {
        guard let namespaces = connection.namespacesSnapshot else {
            return mailboxName
        }
        return namespaces.resolveMailboxPath(mailboxName)
    }
}
